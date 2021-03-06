-- vim: set expandtab tabstop=2 shiftwidth=2 softtabstop=2 :

local require = require
local json    = require "luci.json"
local sys     = require "luci.sys"

local http     = require("socket.http")
local https    = require("ssl.https")
local ltn12    = require("ltn12")
local io       = require("io")
local os       = require("os")
local string   = require("string")
local posix    = require("posix")
local sys_stat = require("posix.sys.stat")

local print = print
local ipairs, pairs, next, type, tostring, tonumber = ipairs, pairs, next, type, tostring, tonumber
local table, setmetatable, getmetatable = table, setmetatable, getmetatable

local uci = require("luci.model.uci")
local debug = false
local VERSION = "<VERSION>"
module "overthebox"
_VERSION = VERSION
local api_url = 'https://provisionning.overthebox.net:4443/'

-- Subscribe Sticky to OVH Network as soon as possible a request an unic identifier
function subscribe()
  local lan = iface_info('lan')
  local ip4 = ''
  if #lan.ipaddrs > 0 then
    ip4 = lan.ipaddrs[1].addr
  end

  local rcode, res = POST('subscribe', {private_ips = {ip4}})

  if rcode == 200 then
    local configfile = "/etc/config/overthebox"
    if not file_exists(configfile) then
      local file = io.open(configfile, "w")
      file:write("")
      file:close()
    end
    local ucic = uci.cursor()
    ucic:set("overthebox", "me", "config")
    ucic:set("overthebox", "me", "token", res.token)
    ucic:set("overthebox", "me", "device_id", res.device_id)
    ucic:save("overthebox")
    ucic:commit("overthebox")
  end
  return (rcode == 200), res
end

function status()
  return GET('devices/'.. (uci.cursor():get("overthebox", "me", "device_id", {}) or "null").."/actions")
end

function exists(obj, ...)
  for i,v in ipairs(arg) do
    if obj[v] == nil then
      return false
    end
  end
  return true
end

function addInterfaceInZone(name, ifname)
  local ucic = uci.cursor()
  ucic:foreach("firewall", "zone", function (zone)
      if zone["name"] == name then
        local list = ucic:get_list("firewall", zone[".name"], "network")
        if list then
          local zones = {}
          list = table.concat(list, " "):gmatch("%S+")
          for itf in list do
            if itf == ifname then
              return false;
            end
            table.insert(zones, itf)
          end
          table.insert(zones, ifname)
          ucic:set_list("firewall", zone[".name"], "network", zones)
          ucic:save('firewall')
          ucic:commit('firewall')
          return true
        else
          ucic:set_list("firewall", zone[".name"], "network", { ifname })
          ucic:save('firewall')
          ucic:commit('firewall')
          return true
        end
      end
    end
  )
  return false
end

function config()
  local ret = {}
  local ucic = uci.cursor()
  local rcode, res = GET('devices/'..ucic:get("overthebox", "me", "device_id", {}).."/config")
  if rcode ~= 200 then
    table.insert(ret, "Error getting config : ".. rcode)
    return false, ret
  end

  if res.glorytun_conf and exists( res.glorytun_conf, 'server', 'port', 'key', 'dev', 'ip_peer', 'ip_local', 'mtu' ) then
    ucic:set('glorytun', 'otb', 'tunnel')
    ucic:set('glorytun', 'otb', 'dev',     res.glorytun_conf.dev )
    ucic:set('glorytun', 'otb', 'server',  res.glorytun_conf.server)
    ucic:set('glorytun', 'otb', 'port',    res.glorytun_conf.port)
    ucic:set('glorytun', 'otb', 'key',     res.glorytun_conf.key)

    ucic:set('network', res.glorytun_conf.dev, 'interface')
    ucic:set('network', res.glorytun_conf.dev, 'ifname', res.glorytun_conf.dev)
    if res.tun_conf.app == 'glorytun' then
      ucic:set('network', res.glorytun_conf.dev, 'proto', 'static')
      ucic:set('network', res.glorytun_conf.dev, 'ipaddr', res.glorytun_conf.ip_local)
      ucic:set('network', res.glorytun_conf.dev, 'netmask', '255.255.255.0')
      ucic:set('network', res.glorytun_conf.dev, 'gateway', res.glorytun_conf.ip_peer)
      ucic:set('network', res.glorytun_conf.dev, 'metric', res.glorytun_conf.metric)
      ucic:set('network', res.glorytun_conf.dev, 'txqueuelen', res.glorytun_conf.txqueuelen or '1000')
      ucic:set('network', res.glorytun_conf.dev, 'mtu', res.glorytun_conf.mtu)
    end
    ucic:set('network', res.glorytun_conf.dev, 'multipath', 'off')
    ucic:delete('network', res.glorytun_conf.dev, 'auto')
    ucic:set('network', res.glorytun_conf.dev, 'type', 'tunnel')

    addInterfaceInZone("wan", res.glorytun_conf.dev)

    if exists( res.glorytun_conf, 'additional_interfaces') and type(res.glorytun_conf.additional_interfaces) == 'table' then
      for _, conf in pairs(res.glorytun_conf.additional_interfaces) do
        if conf and exists( conf, 'dev', 'ip_peer', 'ip_local', 'port', 'mtu', 'table', 'metric' ) then
          ucic:set('glorytun', conf.dev, 'tunnel')
          ucic:set('glorytun', conf.dev, 'dev', conf.dev)
          ucic:set('glorytun', conf.dev, 'server', conf.server or res.glorytun_conf.server)
          ucic:set('glorytun', conf.dev, 'port', conf.port)
          ucic:set('glorytun', conf.dev, 'key', conf.key or res.glorytun_conf.key)

          ucic:set('network', conf.dev, 'interface')
          ucic:set('network', conf.dev, 'ifname', conf.dev)
          if res.tun_conf.app == 'glorytun' then
            ucic:set('network', conf.dev, 'proto', 'static')
            ucic:set('network', conf.dev, 'ipaddr', conf.ip_local)
            ucic:set('network', conf.dev, 'netmask', '255.255.255.0')
            ucic:set('network', conf.dev, 'gateway', conf.ip_peer)
            ucic:set('network', conf.dev, 'metric', conf.metric)
            ucic:set('network', conf.dev, 'txqueuelen', conf.txqueuelen or res.glorytun_conf.txqueuelen or '1000')
            ucic:set('network', conf.dev, 'mtu', conf.mtu or res.glorytun_conf.mtu)
          end
          ucic:set('network', conf.dev, 'multipath', 'off')
          ucic:delete('network', conf.dev, 'auto')
          ucic:set('network', conf.dev, 'type', 'tunnel')

          addInterfaceInZone("wan", conf.dev)
        end
      end
    end
    -- We do not commit network now because network will be restarted later
    ucic:save('network')

    ucic:save('glorytun')
    ucic:commit('glorytun')

    table.insert(ret, 'glorytun')
  end

  if res.glorytun_mud_conf and exists( res.glorytun_mud_conf, 'server', 'port', 'key', 'dev', 'ip_peer', 'ip_local', 'mtu' ) then
    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'mud')

    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'dev',     res.glorytun_mud_conf.dev)
    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'server',  res.glorytun_mud_conf.server)
    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'port',    res.glorytun_mud_conf.port)
    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'key',     res.glorytun_mud_conf.key)
    ucic:set('glorytun', res.glorytun_mud_conf.dev, 'mtu',     res.glorytun_mud_conf.mtu)

    ucic:set('network', res.glorytun_mud_conf.dev, 'interface')
    ucic:set('network', res.glorytun_mud_conf.dev, 'ifname', res.glorytun_mud_conf.dev)
    if res.tun_conf.app == 'glorytun_mud' then
      ucic:set('network', res.glorytun_mud_conf.dev, 'proto', 'static')
      ucic:set('network', res.glorytun_mud_conf.dev, 'ipaddr', res.glorytun_mud_conf.ip_local)
      ucic:set('network', res.glorytun_mud_conf.dev, 'netmask', '255.255.255.0')
      ucic:set('network', res.glorytun_mud_conf.dev, 'gateway', res.glorytun_mud_conf.ip_peer)
      ucic:set('network', res.glorytun_mud_conf.dev, 'metric', res.glorytun_mud_conf.metric)
      ucic:set('network', res.glorytun_mud_conf.dev, 'txqueuelen', res.glorytun_mud_conf.txqueuelen or '1000')
      ucic:delete('network', res.glorytun_mud_conf.dev, 'mtu')
    end
    ucic:set('network', res.glorytun_mud_conf.dev, 'multipath', 'off')
    ucic:delete('network', res.glorytun_mud_conf.dev, 'auto')
    ucic:set('network', res.glorytun_mud_conf.dev, 'type', 'tunnel')

    addInterfaceInZone("wan", res.glorytun_mud_conf.dev)
    ucic:save('glorytun')
    ucic:commit('glorytun')

    table.insert(ret, 'glorytun-udp')
  end

  if not res.tun_conf then
    res.tun_conf = {}
  end
  if not res.tun_conf.app then
    res.tun_conf.app = "none"
  end

  if res.tun_conf.app == 'glorytun_mud' then
    -- Activate MUD
    ucic:foreach("glorytun", "mud",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '1')
    end
    )
    -- Deactivate Glorytun
    ucic:foreach("glorytun", "tunnel",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '0')
    end
    )
    -- Delete glorytun additionnal interface when using mud
    if exists( res.glorytun_conf, 'additional_interfaces') and type(res.glorytun_conf.additional_interfaces) == 'table' then
      for _, conf in pairs(res.glorytun_conf.additional_interfaces) do
        if conf and exists('dev') then
          ucic:delete('network', conf.dev)
        end
      end
      ucic:commit('network')
    end
    ucic:set('mwan3', 'socks', 'dest_ip', res.glorytun_mud_conf.server)
  elseif res.tun_conf.app == 'glorytun' then
    -- Activate Glorytun
    ucic:foreach("glorytun", "tunnel",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '1' )
    end
    )
    -- Deactivate MUD
    ucic:foreach("glorytun", "mud",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '0' )
    end
    )
    ucic:set('mwan3', 'socks', 'dest_ip', res.glorytun_conf.server)
  else
    -- Deactivate MUD
    ucic:foreach("glorytun", "mud",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '0' )
    end
    )
    -- Deactivate Glorytun
    ucic:foreach("glorytun", "tunnel",
    function (e)
      ucic:set('glorytun', e[".name"], 'enable', '0' )
    end
    )
  end
  ucic:save('glorytun')
  ucic:commit('glorytun')

  ucic:delete('mwan3', 'socks', 'dest_port')
  ucic:save('mwan3')
  ucic:commit('mwan3')

  if res.shadow_conf and exists( res.shadow_conf, 'server', 'port', 'lport', 'password', 'method', 'timeout')  then
    ucic:set('shadowsocks','proxy','client')
    ucic:set('shadowsocks','proxy','server',   res.shadow_conf.server )
    ucic:set('shadowsocks','proxy','port',     res.shadow_conf.port)
    ucic:set('shadowsocks','proxy','lport',    res.shadow_conf.lport)
    ucic:set('shadowsocks','proxy','password', res.shadow_conf.password)
    ucic:set('shadowsocks','proxy','method',   res.shadow_conf.method)
    ucic:set('shadowsocks','proxy','timeout',  res.shadow_conf.timeout)

    if exists( res.shadow_conf, 'monitoring_ip', 'track_retry', 'track_timeout', 'track_interval' ) then
      ucic:set('shadowsocks','proxy','monitoring_ip', res.shadow_conf.monitoring_ip)
      ucic:set('shadowsocks','proxy','track_timeout', res.shadow_conf.track_timeout)
      ucic:set('shadowsocks','proxy','track_interval', res.shadow_conf.track_interval)
      ucic:set('shadowsocks','proxy','track_retry', res.shadow_conf.track_retry)
    end

    ucic:save('shadowsocks')
    ucic:commit('shadowsocks')
    table.insert(ret, "shadowsocks")
  end

  if res.graph_conf and exists( res.graph_conf, 'host') then
    ucic:set('graph', 'opentsdb', 'opentsdb')
    ucic:set('graph', 'opentsdb', 'url', res.graph_conf.host )
    ucic:set('graph', 'opentsdb', 'freq', (res.graph_conf.write_frequency or 300) )

    ucic:save('graph')
    ucic:commit('graph')
    table.insert(ret, 'graph')
  end

  if res.log_conf and exists( res.log_conf, 'host', 'port') then

    ucic:foreach("system", "system",
    function (e)
      ucic:set('system', e[".name"], 'log_ip', res.log_conf.host )
      ucic:set('system', e[".name"], 'log_port', res.log_conf.port )
      ucic:set('system', e[".name"], 'log_proto', res.log_conf.protocol )
      ucic:set('system', e[".name"], 'log_prefix', res.log_conf.key )
    end
    )

    ucic:save('system')
    ucic:commit('system')

    table.insert(ret, 'log')
  end

  return true, ret
end

function get_kernel_build_info()
  local file = io.open("/proc/version", "r")
  if file then
    local build_info = file:read("*line")
    file:close()
    if string.match(build_info, "Linux version") then
      return build_info
    end
  end
  return nil
end

function get_mptcp_version()
  local file = io.open("/dev/kmsg", "r")
  if file then
    local readmax = 1000
    while readmax > 0 do
      local mptcp_info = file:read("*line")
      if string.match(mptcp_info, ";MPTCP") then
        file:close()
        return mptcp_info:gsub(".*;","")
      end
      readmax = readmax - 1;
    end
    file:close()
  end
  return nil
end

-- Send properties about the box on a regular basis
function send_properties( props )
  local body = {}

  -- Send kernel build infos
  if props.build_version then
    local version = get_kernel_build_info()
    if version then
      body.build_version = version
    end
  end

  -- Send MPTCP infos
  if props.mptcp_version then
    local version = get_mptcp_version()
    if version then
      body.mptcp_version = version
    end
  end

  -- Get information about network interfaces
  local ucic = uci.cursor()
  if props.interfaces then
    body.interfaces = {}
    ucic:foreach("network", "interface",
    function (e)
      if not e.ifname then
        return
      end
      local entry = {
        ip=e.ipaddr,
        netmask=e.netmask,
        gateway=e.gateway,
        name=e.ifname,
        multipath_status=e.multipath
      }
      if e.dns then
        entry.dns_servers = string.gmatch( e.dns , "%S+")
      end
      if e.gateway then
        entry.public_ip = get_ip_public(e.ifname)
      end
      if e.label then
        entry.label = e.label
      end
      if e.trafficcontrol then
        entry.traffic_control = e.trafficcontrol
        if e.upload then
          entry.upload = tonumber(e.upload)
        end
        if e.download then
          entry.download = tonumber(e.download)
        end
      end

      table.insert( body.interfaces, entry)
    end
    )
  end

  if props.packages then
    body.packages = {}
    for i, pkg in pairs(props.packages) do
      -- TODO: deal with this return code
      local ret, _ = run("opkg status ".. pkg .. " |grep Version: ")
      ret = string.gsub(chomp(ret), "Version: ", "" ) -- remove Version: prefix
      table.insert( body.packages, {name=pkg, version=ret})
    end
  end

  if props.mounts then
    body.mounts = get_mounts()
  end

  local rcode, res = POST('devices/'.. (ucic:get("overthebox", "me", "device_id", {}) or "null")..'/properties',  body)
  tprint(res)
  print(rcode)
  return (rcode == 200), res
end

function get_mounts()
  local mounts = {}
  for line in io.lines("/proc/mounts") do
    local t = split(line)
    table.insert(mounts, {device=t[1], mount_point=t[2], fs=t[3], options=t[4]})
  end
  return mounts
end

function checkReadOnly()
  for _, mount in pairs(get_mounts()) do
    if mount.mount_point and mount.mount_point == "/" then
      if mount.options and mount.options:match("^ro") then -- assume ro is always the first of the option
        return true
      end
    end
  end
  return false
end

function get_ip_public(interface)
  local ret, _ = run("curl -s --max-time 1 --interface "..interface.." ifconfig.ovh" )
  return ret:match("(%d+%.%d+%.%d+%.%d+)")
end

function check_release_channel(rc)
  local myrc = uci.cursor():get("overthebox", "me", "release_channel", {}) or ""
  return myrc == rc
end

function update_release_channel()
  local ucic = uci.cursor()
  local rcode, res = GET('devices/'..ucic:get("overthebox", "me", "device_id", {}).."/release_channel")
  if rcode == 200 then
    if res.feeds then
      set_feeds(res.feeds)
    end
    if res.name and res.image_url then
      ucic:set("overthebox", "me", "release_channel", res.name)
      ucic:set("overthebox", "me", "image_url", res.image_url)
      ucic:save('overthebox')
      ucic:commit('overthebox')
    end
    return true, "ok"
  end
  return false, "error"
end

-- write feeds in distfeeds.conf file
function set_feeds(feeds)
  local txt = ""
  for i, f in pairs(feeds) do
    txt = txt .. f.type .. " " .. f.name .. " " ..f.url .."\n"
  end

  if txt ~= "" then
    local fd = io.open("/etc/opkg/distfeeds.conf", "w")
    if fd then
      fd:write("# generated file, do not edit\n")
      fd:write(txt)
      fd:close()
    end
  end
end

local diags = {
  cpuinfo = { cmd = 'cat /proc/cpuinfo'},
  mem = { cmd = 'free -m'},
  dhcp_leases = { cmd = 'cat /tmp/dhcp.leases'},
  mwan3_status = { cmd = 'mwan3 status'},
  ifconfig = { cmd = 'ifconfig'},
  df = { cmd = 'df'},
  netstat = { cmd = 'netstat -natupe'},
  lsof_network = { cmd = 'lsof -i -n'},
  dig = { cmd = 'dig {{domain}} @{{server}}', default = { domain = 'www.ovh.com', server = '127.0.0.1' }},
  mtr = { cmd = 'mtr -rn -c {{count}} {{host}}', default = { host = 'www.ovh.com', count = 2 }},
  iptables_save = { cmd = 'iptables-save'},
  iproute = { cmd = 'ip route show table {{table}}', default = { table = 0 }},
  iprule = { cmd = 'ip rule' },
  tc = { cmd = 'tc qdisc show' },
  ping = { cmd = 'ping -c {{count}} {{ip}}', default = { ip = '213.186.33.99', count = 2 }},
  dmidecode = { cmd = 'dmidecode -s baseboard-serial-number' },
  uptime = { cmd = 'uptime' },
}

function send_diagnostic(id, info)
  -- TODO: use api_ok
  local api_ok, diag_id = create_diagnostic( id or "")
  if diag_id == "" then
    return false, "no diag id found"
  end

  ret = true
  if info and info.diags and type(info.diags) == "table" then
    for _, name in ipairs(info.diags) do
      ret = run_diagnostic( diag_id, name, info and info.arguments and info.arguments[name]) and ret
    end
  else
    for name, diag in pairs(diags) do
      ret = run_diagnostic( diag_id, name, info and info.arguments and info.arguments[name]) and ret
    end
  end

  return ret, "ok"
end

function run_diagnostic( id, name, arg )
  local cmd = string.gsub( diags[name].cmd, "{{(%w+)}}", function(w)
    return (arg and arg[w]) or diags[name].default[w] or ""
  end )
  local ret, rcode = run(cmd)
  -- TODO: use ret_api
  local ret_api = post_result_diagnostic(id, name, cmd, ret, rcode)
  return rcode==0
end

function create_diagnostic(action_id)
  local rcode, res = POST('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}).."/diagnostics",  {device_action_id=action_id or "" })
  if rcode == 200 then
    return true, res.diagnostic_id or ""
  end
  return false, ""
end

function post_result_diagnostic(id, name, cmd, output, exit_code)
  -- TODO: check response
  local rcode, _ = POST('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}).."/diagnostics/"..id , { name= name, cmd=cmd, output=output, exit_code=exit_code})
  return (rcode == 200)
end

--
-- Begin of backup config section
--

-- List config files that will be backuped
-- We'll backup only text files
function list_config_files()
  local files = {}
  local list = io.popen("sysupgrade -l")
  if not list then
    log("unable to run sysupgrade -l")
    return files
  end

  -- Iterate over the config files
  for ln in list:lines() do
    -- Check the file type
    local filetype = get_filetype(ln)
    if string.find(filetype, "text") == nil then
      log("skipping file "..ln..", not a text -> "..filetype)
    else
      files[#files+1] = ln
    end
  end
  list:close()
  return files
end

-- Take a file and return the filetype
function get_filetype(file)
  local ret, rcode = run("file -b "..file)
  if not rcode then
    return "Unknown"
  end

  return ret
end

-- Post a backup of a file to the provisionning
function post_result_backup(id, file, mode, uid, gid, is_symlink, symlink, content)
  local ucic = uci.cursor()
  local device_id = ucic:get("overthebox", "me", "device_id")
  local service_id = ucic:get("overthebox", "me", "service")
  local uri = string.format("devices/%s/service/%s/backups/%s", device_id, service_id, id)

  -- If call is successful, response is "OK", else, it will be the error
  -- message
  local rcode, response = POST(uri , {
    filename=file,
    mode=mode,
    uid=uid,
    gid=gid,
    is_symlink=is_symlink,
    symlink=symlink,
    content=content
  })
  return (rcode == 200), response
end

-- Launch a backup of a file
function run_backup(id, file)
  local pstat = sys_stat.lstat(file)
  if not pstat then
    return false, "can not stat file"
  end

  local mode = string.sub(string.format("%o", pstat.st_mode), -4)
  local uid = pstat.st_uid
  local gid = pstat.st_gid
  local is_symlink = sys_stat.S_ISLNK(pstat.st_mode)
  local symlink, content = nil

  if is_symlink ~= 0 then
    is_symlink = true
    symlink = require("posix.unistd").readlink(file)
  else
    is_symlink = false
    local fd = io.open(file, "rb")
    if not fd then
      return false, "can not read file"
    end
    content = fd:read("*all")
    fd:close()
  end
  return post_result_backup(id, file, mode, uid, gid, is_symlink, symlink, content)
end

-- Create a backupp object on the provisionning
function create_backup(action_id)
  local rcode, res = POST('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}) ..
  '/service/'..uci.cursor():get("overthebox", "me", "service", {}) ..
  '/backups',  {device_action_id=action_id or "" })
  if rcode == 200 and res ~= nil then
    return true, res.backup_id or ""
  end
  return false, res or ""
end

-- Create a backup and send it
function send_backup(id)
  local api_ok, backup_id = create_backup(id or "")
  if not api_ok or backup_id == "" then
    return false, "error while getting backup_id ".. backup_id
  end

  log("created backup ".. backup_id)

  local ret = true
  local err
  for _, file in pairs(list_config_files()) do
    ret, err = run_backup(backup_id, file)
    if not ret then return ret, err end
  end

  log("backup successfully finished")

  return ret, "ok"
end

-- Get the tar of a backup
function retrieve_backup(id)
  local rcode, res = GET('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}) ..
  '/service/'..uci.cursor():get("overthebox", "me", "service", {}) ..
  '/backups/'.. id ..
  '/tar')
  return (rcode == 200), res
end

-- Restore a given backup and untar it
function restore_backup(id, info)
  local backup_id = id
  if info and info.backup_id then
    backup_id = info.backup_id
  end
  -- Retrieve the tar'ed backup
  local ret, content = retrieve_backup(backup_id)
  if not ret then
    return ret, "error while retrieving backup " .. content
  end

  log("got the tar'ed backup ".. backup_id)

  -- Open the process in write mode
  local fp = io.popen("sysupgrade --restore-backup -", "w")
  if fp == nil then
    return false, "can not run sysupgrade"
  end

  -- Write the content to the process
  fp:write(content)
  -- Check the response code
  local rc = {fp:close()}
  if rc[4] ~= 0 then
    return false, "sysupgrade has returned an error "..rc[4]
  end

  log("restore is successful, rebooting now")
  return true, "ok"
end
--
-- End of backup config section
--

-- This function converts a remote access id to a name usable as key in uci.
-- Uci doesn't support "-" in key names so we replace '-' by'_'.
function remoteAccessIdToUci(remote_access_id)
  return "remote_" .. string.gsub(remote_access_id, "-", "_")
end

function remoteAccessPrepare(args)
  if not args or not exists(args, 'remote_access_id') then
    return false, "no arguments or remote_access_id arg is missing"
  end

  local ret, key = create_ssh_key()
  if not ret or not key then
    return false, "key not well created"
  end

  local name = remoteAccessIdToUci(args.remote_access_id)
  local ucic = uci.cursor()
  ucic:set("overthebox", name, "remote")

  -- create luci user if requested
  if exists(args, 'luci_user', 'luci_password') and
    args.luci_user ~= '' and args.luci_password ~= '' then

    local _, rcode = run("useradd -c "
    .. args.remote_access_id
    .. " -d /root -s /bin/false -u 0 -g root -MNo "
    .. args.luci_user)

    if not status_code_ok(rcode) then return false, "error creating luci user" end

    rcode = sys.user.setpasswd(args.luci_user, args.luci_password)
    if not status_code_ok(rcode) then
      -- Rollback user creation
      run("userdel -f " .. args.luci_user)
      return false, "error when changing password for luci user"
    end

    ucic:set("overthebox", name, "luci_user", args.luci_user)
  end
  ucic:save("overthebox")
  ucic:commit("overthebox")

  local rcode, _ = POST('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}).."/remote_accesses/"..args.remote_access_id.."/keys",   {public_key=key})
  return (rcode == 200), "ok"
end

function create_ssh_key()
  local private_key = "/root/.ssh_otb_remote"
  local public_key = private_key..".pub"

  if not file_exists( private_key ) then
    local _, rcode = run("dropbearkey -t rsa -s 4096 -f ".. private_key .. " |grep ^ssh- > ".. public_key)
    if not status_code_ok(rcode) then return false, "error create key" end
  end
  if not file_exists( public_key ) then
    local _, rcode = run("dropbearkey -t rsa -s 4096 -f ".. private_key .. " -y |grep ^ssh- > ".. public_key )
    if not status_code_ok(rcode) then return false, "error dump key" end
  end

  key=""
  -- read public key
  for line in io.lines(public_key) do
    if string_starts( line, "ssh-") then
      key = line
      break
    end
  end

  return true, key
end

function remoteAccessConnect(args)
  if not args or not exists(args, 'remote_access_id', 'forwarded_port',
    'ip', 'port', 'server_public_key', 'remote_public_key') then
    return false, "no arguments or missing"
  end

  local name = remoteAccessIdToUci(args.remote_access_id)
  local ucic = uci.cursor()
  ucic:set("overthebox", name, "forwarded_port", args.forwarded_port)
  ucic:set("overthebox", name, "ip", args.ip)
  ucic:set("overthebox", name, "port", args.port)
  ucic:set("overthebox", name, "server_public_key", args.server_public_key)
  ucic:set("overthebox", name, "remote_public_key", args.remote_public_key)

  ucic:save("overthebox")
  ucic:commit("overthebox")

  local _, rcode = run("/etc/init.d/otb-remote restart")
  if not status_code_ok(rcode) then return false, "error on otb-remote daemon restart" end
  return true, "ok"
end

function remoteAccessDisconnect(args)
  if not args or not exists(args, 'remote_access_id', 'port') then
    return false, "no arguments or missing"
  end

  -- TODO: Remember to remove oldName and the requirement for 'port' to be in args
  -- once all old remote accesses have been deleted or expired.
  local oldName = "remote" .. args.port
  local name = remoteAccessIdToUci(args.remote_access_id)

  local ucic = uci.cursor()

  local luci_user = ucic:get("overthebox", oldName, "luci_user")
  if luci_user == nil then
    luci_user = ucic:get("overthebox", name, "luci_user")
  end

  -- Delete luci user if we created one earlier
  if luci_user ~= nil then
    local _, rcode = run("userdel -f " .. luci_user)
    if not status_code_ok(rcode) then return false, "error when deleting user " .. luci_user end
  end

  ucic:delete("overthebox", oldName)
  ucic:delete("overthebox", name)
  ucic:save("overthebox")
  ucic:commit("overthebox")

  local _, rcode = run("/etc/init.d/otb-remote restart")
  if not status_code_ok(rcode) then return false, "error on otb-remote daemon restart" end
  return true, "ok"
end

function string_starts(String,Start)
  return string.sub(String,1,string.len(Start))==Start
end

function file_exists(name)
  local f=io.open(name,"r")
  if f~=nil then io.close(f) return true else return false end
end

-- exec command local
function restart(service)
  local ret, rcode = run("/etc/init.d/"..service.." restart")
  return status_code_ok(rcode), ret
end
function restartmwan3()
  local ret = os.execute("/usr/sbin/mwan3 restart")
  return true, ret
end


function opkg_update()
  local ret, rcode = run("opkg update 2>&1")
  return status_code_ok(rcode), ret
end

function opkg_upgradable()
  local ret, rcode = run("opkg list-upgradable")
  return status_code_ok(rcode), ret
end
function opkg_install(package)
  local ret, rcode = run("opkg install "..package.. " --force-overwrite 2>&1" ) -- to fix
  return status_code_ok(rcode), ret
end
function opkg_remove(package)
  local ret, rcode = run("opkg remove "..package )
  return status_code_ok(rcode), ret
end


-- all our packages, and the minimum version needed.
local pkgs = {
  ["sqm-scripts"]         = {
    version               = '-',
  },
  ["overthebox"]          = {
    version               = '0.4-24',
  },
  ["lua"]                 = {
    version               = '5.1.5-3',
  },
  ["liblua"]              = {
    version               = '5.1.5-3',
  },
  ["luac"]                = {
    version               = '5.1.5-3',
  },
  ["luci-base"]           = {
    version               = 'v1.0-1',
  },
  ["luci-mod-admin-full"] = {
    version               = 'v1.0-1',
  },
  ["luci-app-overthebox"] = {
    version               = 'v1.0-2',
  },
  ["luci-app-mwan3otb"]   = {
    version               = '1.5-6',
  },
  ["shadowsocks-libev"]   = {
    version               = '2.5.0-1-ovh-2-5',
  },
  ["luci-theme-ovh"]      = {
    version               = 'v0.1-3',
  },
  ["dnsmasq-full"]        = {
    version               = '2.76-3',
  },
  -- We do not want dnsmasq to fight with dnsmasq-full
  ["dnsmasq"]             = {
    version               = '-',
  },
  ["mptcp"]               = {
    version               = '1.0.0-6',
  },
  ["netifd"]              = {
    version               = '2015-08-25-59',
  },
  ["mwan3otb"]            = {
    version               = '1.7-30',
  },
  ["bosun"]               = {
    version               = '-',
  },
  ["graph"]               = {
    version               = '0.1-0',
  },
  ["vtund"]               = {
    version               = '-',
  },
  ["e2fsprogs"]           = {
    version               = '1.42.12-1',
  },
  ["e2freefrag"]          = {
    version               = '1.42.12-1',
  },
  ["dumpe2fs"]            = {
    version               = '1.42.12-1',
  },
  ["resize2fs"]           = {
    version               = '1.42.12-1',
  },
  ["tune2fs"]             = {
    version               = '1.42.12-1',
  },
  ["libsodium"]           = {
    version               = '1.0.11-1',
  },
  ["glorytun"]            = {
    version               = '0.0.34-4',
  },
  ["glorytun-udp"]        = {
    version               = '0.0.84-mud-4',
  },
  ["bandwidth"]           = {
    version               = '0.6.2-1',
  },
  ["rdisc6"]              = {
    version               = '1.0.3-1',
  },
  ["shadow-useradd"]      = {
    version               = '4.2.1-4',
  },
  ["shadow-userdel"]      = {
    version               = '4.2.1-4',
  },
  ["luci-app-sqm"]        = {
    version               = '-',
  },
  ['luci-app-qos']        = {
    version               = '-',
  },
  ['qos-scripts']         = {
    version               = '-'
  },
}

local services = {
  ["dnsmasq"]='enable'
}

-- function ensure_service_state ensures that the service is :
-- - enabled and running
--   or
-- - disabled and not running
function ensure_service_state(service, status)
  local initd = "/etc/init.d/" .. service
  local _, rcode = run(initd .. " enabled")
  if not status_code_ok(rcode) and status == "enable" then
    ret = service .. " needs to be enabled because it isn't yet. Enabling and restarting..."
    local ret_initd, rcode = run(initd .. " enable; " .. initd .. " restart")
    ret = ret_initd .. "\n" .. ret
    return status_code_ok(rcode), ret
  end

  if status_code_ok(rcode) and status == "disable" then
    ret = service .. " needs to be disabled because it isn't yet. Disabling and stopping..."
    local ret_initd, rcode = run(initd .. " disable; " .. initd .. " stop")
    ret = ret_initd .. "\n" .. ret
    return status_code_ok(rcode), ret
  end

  return true, "We didn't need to change " .. service .. " state as it's already as expected"
end


-- function upgrade check if all package asked are up to date
function upgrade()
  -- first, we upgrade ourself
  local success, r = opkg_install("overthebox")
  if not success then
    return success, "Failed to install overthebox: \n" .. r
  end

  -- let's check other packages
  -- list installed packets
  local listpkginstalled, _ = run("opkg list-installed")
  local ret = ""
  local retcode = true
  local checked = {}
  local additional_actions = {}

  -- Iterate over installed packages and check if we need to
  -- upgrade/install/remove them
  for str in string.gmatch(listpkginstalled,'[^\r\n]+') do
    -- Parse the version
    local f = split(str)
    local pkg, version  = f[1], f[3]

    if pkgs[pkg] ~= nil then
      local expected_version = pkgs[pkg].version
      -- If there is no package number, package needs to be removed,
      -- remove it
      if expected_version == '-' then
        info("removing "..pkg)
        local success, r = opkg_remove(pkg)
        retcode = retcode and success
        ret = ret .. "remove "..pkg.. ": \n" .. r .."\n"
      else
        -- Upgrade the package
        local success, r = opkg_install(pkg)
        retcode = retcode and success
        if success then
          -- Check the diff between the versions
          if version:find(expected_version,1, true) == 1  then
            ret = ret .. "install "..pkg.." version match, installed:"..version.." asked:"..expected_version.."\n".. r .."\n"
          elseif version < expected_version then
            ret = ret .. "install "..pkg.." version obsolete, installed:"..version.." asked:"..expected_version.."\n".. r
            -- Check if we have additional actions to do
            if pkgs[pkg].actions ~= nil then
              for _, action in ipairs(pkgs[pkg].actions) do
                info("appending action "..action)
                additional_actions[action] = true
                ret = ret .. "Appending action "..action.."\n"
              end
            end
            ret = ret .. "\n"
          else
            ret = ret .. "install "..pkg.." version newest, installed:"..version.." asked:"..expected_version.."\n".. r .."\n"
          end
        else
          warning(pkg.." got error when installing: "..r)
          ret = ret .. "Failed to install "..pkg.." :\n".. r .."\n"
        end
      end
      checked[pkg] = 1
    end
  end

  -- Check within the rest of the packages to ensure that their are
  -- correctly installed or removed
  for pkg, info in pairs(pkgs) do
    if checked[pkg] == nil then -- not seen
      if info.version == '-' then
        local c, r = opkg_remove(pkg)
        retcode = retcode and c
        ret = ret .. "remove "..pkg.. ": \n" .. r .."\n"
      else
        local c, r = opkg_install(pkg)
        retcode = retcode and c
        ret = ret .. "install "..pkg.."\n" ..  r .."\n"
      end
    end
  end

  -- Check that all the needed services are correctly enabled and running
  for service, status in pairs(services) do
    local success, r = ensure_service_state(service, status)
    retcode = retcode and success
    ret = ret .. r .. "\n"
  end

  return retcode, ret, additional_actions
end


function sysupgrade()
  local ret, rcode = run("overthebox_last_upgrade -f")
  return status_code_ok(rcode), ret
end
function reboot()
  local ret, rcode = run("reboot")
  return status_code_ok(rcode), ret
end


-- action api
function backup_last_action(id)
  local ucic = uci.cursor()
  ucic:set("overthebox", "me", "last_action_id", id)
  ucic:save("overthebox")
  ucic:commit("overthebox")
end

function get_last_action()
  return uci.cursor():get("overthebox", "me", "last_action_id")
end

function flush_action(id)
  local ucic = uci.cursor()
  ucic:delete("overthebox", "me", "last_action_id", id)
  ucic:save("overthebox")
  ucic:commit("overthebox")
end


function confirm_action(action, status, msg )
  if action == nil then
    return false, {error = "Can't confirm a nil action"}
  end
  if msg == nil then
    msg = ""
  end
  if status == nil then
    status = "error"
  end

  local rcode, res = POST('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}).."/actions/"..action, {status=status, details = msg})

  return (rcode == 200), res
end

-- notification events
function notify_boot()
  send_properties( {interfaces="all", mounts="all"} )
  if sys.uptime() > 180 then
    return notify("START")
  end
  return notify("BOOT")
end
function notify_shutdown()
  return notify("SHUTDOWN")
end
function notify_ifdown(iface)
  mprobe = uci.cursor():get("mwan3", iface, "track_method") or ""
  return notify("IFDOWN", {interface=iface, probe=mprobe})
end
function notify_ifup(iface)
  mprobe = uci.cursor():get("mwan3", iface, "track_method") or ""
  return notify("IFUP", {interface=iface, probe=mprobe})
end
function notify(event, details)
  return POST('devices/'..(uci.cursor():get("overthebox", "me", "device_id", {}) or "none" ).."/events", {event_name = event, timestamp = os.time(), details = details})
end


-- service ovh
function ask_service_confirmation(service)
  local ucic = uci.cursor()
  ucic:set("overthebox", "me", "service", service)
  ucic:set("overthebox", "me", "askserviceconfirmation", "1")
  ucic:save("overthebox")
  ucic:commit("overthebox")
  -- Ask web interface to display activation form
  ucic:set("luci", "overthebox", "overthebox")
  ucic:set("luci", "overthebox", "activate", "1")
  ucic:save("luci")
  ucic:commit("luci")

  return true
end
function get_service()
  local rcode, ret = GET('devices/'..uci.cursor():get("overthebox", "me", "device_id", {}).."/service")
  return (rcode == 200), ret
end
function confirm_service(service)
  local ucic = uci.cursor()
  if service ~= ucic:get("overthebox", "me", "service") then
    return false, "service does not match"
  end

  local rcode, ret = POST('devices/'..ucic:get("overthebox", "me", "device_id", {}).."/service/"..service.."/confirm", nil )
  if rcode == 200 then
    ucic:delete("overthebox", "me", "askserviceconfirmation")
    ucic:save("overthebox")
    ucic:commit("overthebox")
    -- Ask web interface to enter activated mode
    ucic:delete("luci", "overthebox", "activate")
    ucic:save("luci")
    ucic:commit("luci")
  end
  return (rcode == 200), ret
end


-- base API helpers
function GET(uri)
  return API(uri, "GET", nil)
end

function POST(uri, data)
  return API(uri, "POST", data)
end


function API(uri, method, data)
  local ucic = uci.cursor()
  url = api_url .. uri

  -- Buildin JSON POST
  local reqbody   = json.encode(data)
  local respbody  = {}
  -- Building Request
  http.TIMEOUT=5
  local _, code, headers, status = https.request{
    method = method,
    url = url,
    protocol = "tlsv1",
    headers =
    {
      ["Content-Type"] = "application/json",
      ["Content-length"] = reqbody:len(),
      ["X-Auth-OVH"] = ucic:get("overthebox", "me", "token"),
      ["X-Overthebox-Version"] = VERSION
    },
    source = ltn12.source.string(reqbody),
    sink = ltn12.sink.table(respbody),
  }
  -- Parsing response
  -- Parsing json response

  if debug then
    print(method .. " " ..url)
    print('headers:')
    tprint(headers)
    print('reqbody:' .. reqbody)
    print('body:' .. tostring(table.concat(respbody)))
    print('code:' .. tostring(code))
    print('status:' .. tostring(status))
    print()
  end

  if ( headers and type(headers) == "table" and headers["x-otb-client-ip"] and headers["x-otb-client-ip"]:match("(%d+)%.(%d+)%.(%d+)%.(%d+)") ) then
    fd = io.open("/tmp/wanip", "w")
    if fd then
      fd:write(headers["x-otb-client-ip"])
      fd:close()
    end
  end

  -- Sometimes something's wrong and we have nil code
  -- We warn and change the value of code so we can at least use it later
  if code == nil then
    warning("Got nil code while doing ".. method .." on ".. url)
    -- I'm a teapot
    code = 418
  elseif code ~= 200 then
    err("HTTP error " .. code .. " while doing ".. method .." on ".. url)
  end

  return code, (json.decode(table.concat(respbody)) or table.concat(respbody))
end

-- Remove any final \n from a string.
--   s: string to process
-- returns
--   s: processed string
function chomp(s)
  return string.gsub(s, "\n$", "")
end

function split(t)
  local r = {}
  if t == nil then return r end
  for v in string.gmatch(t, "%S+") do
    table.insert(r, v)
  end
  return r
end


-- Mwan conf generator
function update_confmwan()
  local ucic = uci.cursor()
  -- Check if we need to update mwan conf
  local oldmd5 = ucic:get("mwan3", "netconfchecksum")
  local newmd5 = string.match(sys.exec("uci -q export network | egrep -v 'upload|download|trafficcontrol|label' | md5sum"), "[0-9a-f]*")
  if oldmd5 and (oldmd5 == newmd5) then
    log("update_confmwan: no changes !")
    return false, nil
  end
  -- Avoid race condition
  local l = lock("update_confmwan")
  if not l then
    log("Could not acquire lock !")
    return false, nil
  end
  log("Lock on update_confmwan() acquired")
  -- Start main code
  local results={}
  -- clear up mwan config
  ucic:foreach("mwan3", "policy",
  function (section)
    if section["generated"] == "1" and section["edited"] ~= "1" then
      ucic:delete("mwan3", section[".name"])
    end
  end
  )
  ucic:foreach("mwan3", "member",
  function (section)
    if section["generated"] == "1" and section["edited"] ~= "1" then
      ucic:delete("mwan3", section[".name"])
    end
  end
  )
  ucic:foreach("mwan3", "interface",
  function (section)
    if section["generated"] == "1" and section["edited"] ~= "1" then
      ucic:delete("mwan3", section[".name"])
    end
  end
  )
  ucic:foreach("mwan3", "rule",
  function (section)
    if section["generated"] == "1" and section["edited"] ~= "1" then
      ucic:delete("mwan3", section[".name"])
    end
  end
  )
  -- Setup trackers IPs
  local tracking_servers = {}
  table.insert( tracking_servers, "51.254.49.132" )
  table.insert( tracking_servers, "51.254.49.133" )
  local tracking_tunnels = {}
  table.insert( tracking_tunnels, "169.254.254.1" )
  --
  local interfaces={}
  local size_interfaces = 0 -- table.getn( does not work....

  -- Table indexed with dns ips to list reacheable interface for this DNS ip
  local dns_policies = {}

  -- Create a tracker for each mptcp interface
  ucic:foreach("network", "interface",
  function (section)
    if section["multipath"] == "on" or section["multipath"] == "master" or section["multipath"] == "backup" or section["multipath"] == "handover" then
      size_interfaces = size_interfaces + 1
      interfaces[ section[".name"] ] = section
      ucic:set("mwan3", section[".name"], "interface")
      if ucic:get("mwan3", section[".name"], "edited") ~= "1" then
        ucic:set("mwan3", section[".name"], "enabled", "1")
        if next(tracking_servers) then
          ucic:set_list("mwan3", section[".name"], "track_ip", tracking_servers)
        end
        ucic:set("mwan3", section[".name"], "track_method","dns")
        ucic:set("mwan3", section[".name"], "reliability", "1")
        ucic:set("mwan3", section[".name"], "count", "1")
        ucic:set("mwan3", section[".name"], "timeout", "2")
        ucic:set("mwan3", section[".name"], "interval", "5")
        ucic:set("mwan3", section[".name"], "down", "3")
        ucic:set("mwan3", section[".name"], "up", "3")
      end
      ucic:set("mwan3", section[".name"], "generated", "1")
      if section["dns"] then
        local seen = {}
        for dns in string.gmatch(section["dns"], "%S+") do
          if seen[dns] == nil then
            if dns_policies[dns] == nil then
              dns_policies[dns] = {}
            end
            seen[dns] = section[".name"]
            table.insert(dns_policies[dns], section[".name"])
          end
        end
      end
    elseif section["type"] == "tunnel" then
      size_interfaces = size_interfaces + 1
      interfaces[section[".name"]] = section
      -- Create a tracker used to monitor tunnel interface
      ucic:set("mwan3", section[".name"], "interface")
      if ucic:get("mwan3", section[".name"], "edited") ~= "1" then
        ucic:set("mwan3", section[".name"], "enabled", "1")
        if next(tracking_tunnels) then
          ucic:set_list("mwan3", section[".name"], "track_ip", tracking_tunnels) -- No tracking ip for tunnel interface
        end
        ucic:set("mwan3", section[".name"], "track_method","icmp")
        ucic:set("mwan3", section[".name"], "reliability", "1")
        ucic:set("mwan3", section[".name"], "count", "1")
        ucic:set("mwan3", section[".name"], "timeout", "2")
        ucic:set("mwan3", section[".name"], "interval", "5")
        ucic:set("mwan3", section[".name"], "down", "3")
        ucic:set("mwan3", section[".name"], "up", "3")
      end
      ucic:set("mwan3", section[".name"], "generated", "1")
    elseif section[".name"] == "tun0" then
      size_interfaces = size_interfaces + 1
      interfaces[section[".name"]] = section
      -- Create a tun0 tracker used for non tcp traffic
      ucic:set("mwan3", "tun0", "interface")
      if ucic:get("mwan3", "tun0", "edited") ~= "1" then
        ucic:set("mwan3", "tun0", "enabled", "1")
        if next(tracking_tunnels) then
          ucic:set_list("mwan3", "tun0", "track_ip", tracking_tunnels) -- No tracking ip for tunnel interface
        end
        ucic:set("mwan3", section[".name"], "track_method","icmp")
        ucic:set("mwan3", "tun0", "reliability", "1")
        ucic:set("mwan3", "tun0", "count", "1")
        ucic:set("mwan3", "tun0", "timeout", "2")
        ucic:set("mwan3", "tun0", "interval", "5")
        ucic:set("mwan3", "tun0", "down", "3")
        ucic:set("mwan3", "tun0", "up", "3")
      end
      ucic:set("mwan3", "tun0", "generated", "1")
    end
  end
  )
  -- generate all members
  local members = {}

  local members_wan = {}
  local members_tun = {}
  local members_qos = {}

  local list_interf = {}
  local list_wan    = {}
  local list_tun    = {}
  local list_qos    = {}

  -- sorted iterator to sort interface by metric
  function __genOrderedIndex( t )
    local orderedIndex = {}
    for key in pairs(t) do
      table.insert( orderedIndex, key )
    end
    table.sort( orderedIndex, function (a, b)
      return tonumber(interfaces[a].metric or 0) < tonumber(interfaces[b].metric or 0)
    end )
    return orderedIndex
  end

  function orderedNext(t, state)
    key = nil
    if state == nil then
      t.__orderedIndex = __genOrderedIndex( t )
      key = t.__orderedIndex[1]
    else
      for i = 1,table.getn(t.__orderedIndex) do
        if t.__orderedIndex[i] == state then
          key = t.__orderedIndex[i+1]
        end
      end
    end
    if key then
      return key, t[key]
    end
    t.__orderedIndex = nil
    return
  end

  function sortByMetric(t)
    return orderedNext, t, nil
  end
  -- create interface members
  for name, interf in sortByMetric(interfaces) do
    log("Creating mwan policy for " .. name)
    for i=1,size_interfaces do
      local metric = i
      -- build policy name
      local name = interf[".name"].."_m"..metric.."_w1"
      if not members[metric] then
        members[metric] = {}
      end
      if not list_interf[metric] then
        list_interf[metric] =  {}
      end
      -- parc type of members
      if interf[".name"] == "tun0" then
        if not members_tun[metric] then
          members_tun[metric] = {}
        end
        if not list_tun[metric] then
          list_tun[metric] = {}
        end
        table.insert(members_tun[metric], name)
        table.insert(list_tun[metric], interf[".name"])

      elseif interf["type"] == "tunnel" then
        if not members_qos[metric] then
          members_qos[metric] = {}
        end
        if not list_qos[metric] then
          list_qos[metric] = {}
        end
        table.insert(members_qos[metric], name)
        table.insert(list_qos[metric], interf[".name"])
      elseif interf["multipath"] == "on" or interf["multipath"] == "master" or interf["multipath"] == "backup" or interf["multipath"] == "handover" then
        if not members_wan[metric] then
          members_wan[metric] = {}
        end
        if not list_wan[metric] then
          list_wan[metric] = {}
        end
        table.insert(members_wan[metric], name)
        table.insert(list_wan[metric], interf[".name"])
      end
      -- populating ref tables
      table.insert(members[metric], name)
      table.insert(list_interf[metric], interf[".name"])
      --- Creating mwan3 member
      ucic:set("mwan3", name, "member")
      if ucic:get("mwan3", name, "edited") ~= "1" then
        ucic:set("mwan3", name, "interface", interf[".name"])
        ucic:set("mwan3", name, "metric", metric)
        ucic:set("mwan3", name, "weight", 1)
      end
      ucic:set("mwan3", name, "generated", 1)
    end
  end
  -- generate policies
  if #members_wan and members_wan[1] then
    log("Creating mwan balanced policy")
    ucic:set("mwan3", "balanced", "policy")
    if ucic:get("mwan3", "balanced", "edited") ~= "1" then
      ucic:set_list("mwan3", "balanced", "use_member", members_wan[1])
    end
    ucic:set("mwan3", "balanced", "generated", "1")
  end

  ucic:set("mwan3", "failover_api", "policy")
  if #members_tun and members_tun[1] then
    ucic:set("mwan3", "balanced_tuns", "policy")
    if ucic:get("mwan3", "balanced_tuns", "edited") ~= "1" then
      ucic:set_list("mwan3", "balanced_tuns", "use_member", members_tun[1])
    end
    ucic:set("mwan3", "balanced_tuns", "generated", "1")
    if ucic:get("mwan3", "failover_api", "edited") ~= "1" then
      ucic:set_list("mwan3", "failover_api", "use_member", members_tun[1])
    end
  end

  if #members_qos and members_qos[1] then
    ucic:set("mwan3", "balanced_qos", "policy")
    if ucic:get("mwan3", "balanced_qos", "edited") ~= "1" then
      ucic:set_list("mwan3", "balanced_qos", "use_member", members_qos[1])
    end
    ucic:set("mwan3", "balanced_qos", "generated", "1")
    if ucic:get("mwan3", "failover_api", "edited") ~= "1" then
      ucic:set_list("mwan3", "failover_api", "use_member", members_qos[1])
    end
  end

  if #members_qos and #members_tun and members_qos[1] and members_tun[2] then
    local members_tuns = {}
    for k, v in pairs(members_qos[1]) do
      table.insert(members_tuns, v)
    end
    for k, v in pairs(members_tun[2]) do
      table.insert(members_tuns, v)
    end
    if ucic:get("mwan3", "failover_api", "edited") ~= "1" then
      ucic:set_list("mwan3", "failover_api", "use_member", members_tuns)
    end
  end
  ucic:set("mwan3", "failover_api", "generated", "1")

  -- all uniq policy
  log("Creating mwan single policy")
  for i=1,#list_interf[1] do
    local name = list_interf[1][i].."_only"
    ucic:set("mwan3", name, "policy")
    if ucic:get("mwan3", name, "edited") ~= "1" then
      ucic:set_list("mwan3", name, "use_member", members[1][i])
    end
    ucic:set("mwan3", name, "generated", "1")
  end

  local seenName = { }
  function generate_route(route)
    local my_members = {}
    local my_interf = {}
    local metric=0

    for i=1,#route do
      metric = metric + 1
      table.insert(my_members, members[metric][route[i]])
      table.insert(my_interf, list_interf[metric][route[i]])
    end

    local name = table.concat(my_interf, "_")
    if #my_interf > 3 then
      name = table.concat(my_interf, "", 1, 3)
    end
    if string.len(name) > 15 then
      name = string.sub(name, 1, 15)
    end
    if seenName[name] == nil then
      log("genrating route of " .. name)
      ucic:set("mwan3", name, "policy")
      if ucic:get("mwan3", name, "edited") ~= "1" then
        ucic:set_list("mwan3", name, "use_member", my_members)
      end
      ucic:set("mwan3", name, "generated", "1")
      seenName[name] = my_members
      if first_tun0_policy == nil and string.find(name, '^tun0*') then
        first_tun0_policy=name
      end
    end
  end

  function table_copy(obj, seen)
    if type(obj) ~= 'table' then
      return obj
    end
    if seen and seen[obj] then
      return seen[obj]
    end
    local s = seen or {}
    local res = setmetatable({}, getmetatable(obj))
    s[obj] = res
    for k, v in pairs(obj) do
      res[table_copy(k, s)] = table_copy(v, s)
    end
    return res
  end

  function generate_all_routes(tree, possibities, depth)
    if not possibities or #possibities == 0 then
      generate_route(tree)
    else
      for i=1,#possibities do
        local c = table_copy(possibities)
        table.remove(c, i)
        local d = table_copy(tree)
        table.insert(d, possibities[i])
        generate_all_routes( d, c, depth+1)
      end
    end
  end

  local key_members={}
  local n=0

  for k,v in pairs(members) do
    n=n+1
    key_members[n]=k
  end

  -- Setting rule to forward all non tcp traffic to tun0
  if not ucic:get("mwan3", "all") then
    ucic:set("mwan3", "all", "rule")
    ucic:set("mwan3", "all", "proto", "all")
    ucic:set("mwan3", "all", "sticky", "0")
  end
  if ucic:get("mwan3", "all", "edited") ~= "1" then
    ucic:set("mwan3", "all", "use_policy", "tun0_only")
  end

  if n > 1 then
    if n < 4 then
      generate_all_routes({}, key_members, 0)
    end

    -- Generate failover policy
    ucic:set("mwan3", "failover", "policy")
    local my_members = {}
    if #members_tun then
      for i=1,#members_tun[1] do
        table.insert(my_members, members_tun[i][i])
      end
    end
    if #members_wan then
      for i=1,#members_wan[1] do
        if members_wan[i + #members_tun[1]] then
          table.insert(my_members, members_wan[#my_members + 1][i])
        end
      end
    end
    if ucic:get("mwan3", "failover", "edited") ~= "1" then
      ucic:set_list("mwan3", "failover", "use_member", my_members)
    end
    ucic:set("mwan3", "failover", "generated", "1")
    -- Update "all" policy
    ucic:set("mwan3", "all", "rule")
    ucic:set("mwan3", "all", "proto", "all")
    if ucic:get("mwan3", "all", "edited") ~= "1" then
      ucic:set("mwan3", "all", "use_policy", "failover")
    end
    ucic:set("mwan3", "all", "generated", "1")
    -- Create icmp policies
    ucic:set("mwan3", "icmp", "rule")
    ucic:set("mwan3", "icmp", "proto", "icmp")
    if ucic:get("mwan3", "icmp", "edited") ~= "1" then
      ucic:set("mwan3", "icmp", "use_policy", "failover")
    end
    ucic:set("mwan3", "icmp", "generated", "1")
    -- Create voip policies
    ucic:set("mwan3", "voip", "rule")
    if ucic:get("mwan3", "voip", "edited") ~= "1" then
      ucic:set("mwan3", "voip", "proto", "udp")
      ucic:set("mwan3", "voip", "dest_ip", '91.121.128.0/23')
      ucic:set("mwan3", "voip", "use_policy", "failover")
    end
    ucic:set("mwan3", "voip", "generated", "1")
    -- Create api policies
    ucic:set("mwan3", "api", "rule")
    if ucic:get("mwan3", "api", "edited") ~= "1" then
      ucic:set("mwan3", "api", "proto", "tcp")
      ucic:set("mwan3", "api", "dest_ip", 'api')
      ucic:set("mwan3", "api", "dest_port", '80')
      ucic:set("mwan3", "api", "use_policy", "failover_api")
    end
    ucic:set("mwan3", "api", "generated", "1")
    -- Create DSCPs policies
    -- cs1
    ucic:set("mwan3", "CS1_Scavenger", "rule")
    ucic:set("mwan3", "CS1_Scavenger", "proto", "all")
    ucic:set("mwan3", "CS1_Scavenger", "dscp_class", "cs1")
    if ucic:get("mwan3", "CS1_Scavenger", "edited") ~= "1" then
      ucic:set("mwan3", "CS1_Scavenger", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS1_Scavenger", "generated", "1")
    -- cs2
    ucic:set("mwan3", "CS2_Normal", "rule")
    ucic:set("mwan3", "CS2_Normal", "proto", "all")
    ucic:set("mwan3", "CS2_Normal", "dscp_class", "cs2")
    if ucic:get("mwan3", "CS2_Normal", "edited") ~= "1" then
      ucic:set("mwan3", "CS2_Normal", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS2_Normal", "generated", "1")
    -- cs3
    ucic:set("mwan3", "CS3_Signaling", "rule")
    ucic:set("mwan3", "CS3_Signaling", "proto", "all")
    ucic:set("mwan3", "CS3_Signaling", "dscp_class", "cs3")
    if ucic:get("mwan3", "CS3_Signaling", "edited") ~= "1" then
      ucic:set("mwan3", "CS3_Signaling", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS3_Signaling", "generated", "1")
    -- cs4
    ucic:set("mwan3", "CS4_Realtime", "rule")
    ucic:set("mwan3", "CS4_Realtime", "proto", "all")
    ucic:set("mwan3", "CS4_Realtime", "dscp_class", "cs4")
    if ucic:get("mwan3", "CS4_Realtime", "edited") ~= "1" then
      ucic:set("mwan3", "CS4_Realtime", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS4_Realtime", "generated", "1")
    -- cs5
    ucic:set("mwan3", "CS5_BroadcastVd", "rule")
    ucic:set("mwan3", "CS5_BroadcastVd", "proto", "all")
    ucic:set("mwan3", "CS5_BroadcastVd", "dscp_class", "cs5")
    if ucic:get("mwan3", "CS5_BroadcastVd", "edited") ~= "1" then
      ucic:set("mwan3", "CS5_BroadcastVd", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS5_BroadcastVd", "generated", "1")
    -- cs6
    ucic:set("mwan3", "CS6_NetworkCtrl", "rule")
    ucic:set("mwan3", "CS6_NetworkCtrl", "proto", "all")
    ucic:set("mwan3", "CS6_NetworkCtrl", "dscp_class", "cs6")
    if ucic:get("mwan3", "CS6_NetworkCtrl", "edited") ~= "1" then
      ucic:set("mwan3", "CS6_NetworkCtrl", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS6_NetworkCtrl", "generated", "1")
    -- cs7
    ucic:set("mwan3", "CS7_Reserved", "rule")
    ucic:set("mwan3", "CS7_Reserved", "proto", "all")
    ucic:set("mwan3", "CS7_Reserved", "dscp_class", "cs7")
    if ucic:get("mwan3", "CS7_Reserved", "edited") ~= "1" then
      ucic:set("mwan3", "CS7_Reserved", "use_policy", "failover")
    end
    ucic:set("mwan3", "CS7_Reserved", "generated", "1")
    -- Generate qos failover policy
    if #members_qos and members_qos[1] then
      for i=1,#members_qos[1] do
        local name = list_qos[1][i].."_failover"
        ucic:set("mwan3", name, "policy")
        local my_members = {}
        table.insert(my_members, members_qos[1][i])
        for j=i,#list_wan[1] do
          table.insert(my_members, members_wan[j + 1][j])
        end
        if ucic:get("mwan3", name, "edited") ~= "1" then
          ucic:set_list("mwan3", name, "use_member", my_members)
        end
        ucic:set("mwan3", name, "generated", "1")
        --
        if list_qos[1][i] == "xtun0" then
          -- Update voip and icmp policies
          if ucic:get("mwan3", "voip", "edited") ~= "1" then
            ucic:set("mwan3", "voip", "use_policy", name)
          end
          if ucic:get("mwan3", "icmp", "edited") ~= "1" then
            ucic:set("mwan3", "icmp", "use_policy", name)
          end
          -- Update DSCPs policies
          if ucic:get("mwan3", "CS3_Signaling", "edited") ~= "1" then
            ucic:set("mwan3", "CS3_Signaling", "use_policy", name)
          end
          if ucic:get("mwan3", "CS4_Realtime", "edited") ~= "1" then
            ucic:set("mwan3", "CS4_Realtime", "use_policy", name)
          end
          if ucic:get("mwan3", "CS5_BroadcastVd", "edited") ~= "1" then
            ucic:set("mwan3", "CS5_BroadcastVd", "use_policy", name)
          end
          if ucic:get("mwan3", "CS6_NetworkCtrl", "edited") ~= "1" then
            ucic:set("mwan3", "CS6_NetworkCtrl", "use_policy", name)
          end
          if ucic:get("mwan3", "CS7_Reserved", "edited") ~= "1" then
            ucic:set("mwan3", "CS7_Reserved", "use_policy", name)
          end
        end
        if list_qos[1][i] == "stun0" then
          if ucic:get("mwan3", "CS1_Scavenger", "edited") ~= "1" then
            ucic:set("mwan3", "CS1_Scavenger", "use_policy", name)
          end
        end
      end
    end
  end
  -- Generate DNS policy at top
  local count = 0
  for dns, interfaces in pairs(dns_policies) do
    count = count + 1;
    local members = {};
    for i=1,#interfaces do
      table.insert(members, interfaces[i].."_m1_w1")
    end
    table.insert(members, "tun0_m2_w1")

    ucic:set("mwan3", "dns_p_" .. count, "policy")
    if ucic:get("mwan3", "dns_p_" .. count, "edited") ~= "1" then
      ucic:set_list("mwan3", "dns_p_" .. count, "use_member", members)
      ucic:set("mwan3", "dns_p_" .. count, "last_resort", "default")

      ucic:set("mwan3", "dns_" .. count, "rule")
      if ucic:get("mwan3", "dns_" .. count, "edited") ~= "1" then
        ucic:set("mwan3", "dns_" .. count, "proto", "udp")
        ucic:set("mwan3", "dns_" .. count, "sticky", "0")
        ucic:set("mwan3", "dns_" .. count, "use_policy", "dns_p_" .. count)
        ucic:set("mwan3", "dns_" .. count, "dest_ip", dns)
        ucic:set("mwan3", "dns_" .. count, "dest_port", 53)
      end
      ucic:set("mwan3", "dns_" .. count, "generated", "1")
    end
    ucic:set("mwan3", "dns_p_" .. count, "generated", "1")
    ucic:reorder("mwan3", "dns_" .. count, count - 1)
  end
  -- reorder lasts policies
  ucic:reorder("mwan3", "api", 244)
  ucic:reorder("mwan3", "icmp", 245)
  ucic:reorder("mwan3", "voip", 246)
  ucic:reorder("mwan3", "CS1_Scavenger", 247)
  ucic:reorder("mwan3", "CS2_Normal", 248)
  ucic:reorder("mwan3", "CS3_Signaling", 249)
  ucic:reorder("mwan3", "CS4_Realtime", 250)
  ucic:reorder("mwan3", "CS5_BroadcastVd", 251)
  ucic:reorder("mwan3", "CS6_NetworkCtrl", 252)
  ucic:reorder("mwan3", "CS7_Reserved", 253)
  ucic:reorder("mwan3", "all", 254)

  ucic:set("mwan3", "netconfchecksum", newmd5)
  ucic:save("mwan3")
  ucic:commit("mwan3")
  -- We don't call reload_config here anymore as this is done in hotplug.d/net
  -- Release mwan3 lock
  l:close()
  return result, interfaces
end

function list_running_dhcp()
  local result = {}
  local dhcpd = (sys.exec("cat /var/etc/dnsmasq.conf | grep dhcp-range | cut -c12- | cut -f1 -d','"))
  for line in string.gmatch(dhcpd,'[^\r\n]+') do
    result[line] = true
  end
  return result
end

function ipv6_discover(interface)
  local interface = interface or 'eth0'
  local result = {}

  local ra6_list = (sys.exec("rdisc6 -nm " .. interface))
  -- dissect results
  local lines = {}
  local index = {}
  ra6_list:gsub('[^\r\n]+', function(c)
    table.insert(lines, c)
    if c:match("Hop limit") then
      table.insert(index, #lines)
    end
  end)
  local ra6_result = {}
  for k,v in ipairs(index) do
    local istart = v
    local iend = index[k+1] or #lines

    local entry = {}
    for i=istart,iend - 1 do
      local level = lines[i]:find('%w')
      local line = lines[i]:sub(level)

      local param, value
      if line:match('^from') then
        param, value = line:match('(from)%s+(.*)$')
      else
        param, value = line:match('([^:]+):(.*)$')
        -- Capitalize param name and remove spaces
        param = param:gsub("(%a)([%w_']*)", function(first, rest) return first:upper()..rest:lower() end):gsub("[%s-]",'')
        param = param:gsub("%.$", '')
        -- Remove text between brackets, seconds and spaces
        value = value:lower()
        value = value:gsub("%(.*%)", '')
        value = value:gsub("%s-seconds%s-", '')
        value = value:gsub("^%s+", '')
        value = value:gsub("%s+$", '')
      end

      if entry[param] == nil then
        entry[param] = value
      elseif type(entry[param]) == "table" then
        table.insert(entry[param], value)
      else
        old = entry[param]
        entry[param] = {}
        table.insert(entry[param], old)
        table.insert(entry[param], value)
      end
    end
    table.insert(ra6_result, entry)
  end
  return ra6_result
end

function create_dhcp_server()
  local result = {}
  local ucic = uci.cursor()
  -- Setup a dhcp server if needed
  local dhcpd_configured = 0
  local dhcpd = list_running_dhcp()
  for i, _ in pairs(dhcpd) do
    dhcpd_configured = dhcpd_configured + 1
  end
  log( "Count of dhcp configured : " .. dhcpd_configured )
  local minMetricInterface;
  if dhcpd_configured == 0 then
    -- find the interface with the lowest metric
    local minMetric = 255;
    ucic:foreach("network", "interface",
    function (section)
      if section["type"] == "macvlan" then
        if section["proto"] == "static" then
          if section[".name"] == "lan" then
            minMetric = 0
            minMetricInterface = section[".name"]
          end
          if section["metric"] ~= nil then
            if tonumber(section["metric"]) < minMetric then
              minMetric = tonumber(section["metric"])
              minMetricInterface = section[".name"]
            end
          end
        end
      end
    end
    )
    if minMetricInterface == nil then
      ucic:foreach("network", "interface",
      function (section)
        if section["type"] == "macvlan" then
          if section["proto"] == "static" then
            -- add static only interface => our wans
            log( "Adding DHCP on interface : "..section[".name"] )
            result[ section[".name"] ] = section
            ucic:set("dhcp", section[".name"], "dhcp")
            ucic:set("dhcp", section[".name"], "interface", section[".name"])
            ucic:set("dhcp", section[".name"], "authoritative", "0")
            ucic:set("dhcp", section[".name"], "ignore", "0")
            ucic:set("dhcp", section[".name"], "force", "1")
            ucic:set("dhcp", section[".name"], "start", "50")
            ucic:set("dhcp", section[".name"], "limit", "200")
            ucic:set("dhcp", section[".name"], "leasetime", "12h")
            dhcpd_configured = dhcpd_configured + 1
            return;
          end
        end
      end
      )
    else
      ucic:set("dhcp", minMetricInterface, "dhcp")
      ucic:set("dhcp", minMetricInterface, "interface", minMetricInterface)
      ucic:set("dhcp", minMetricInterface, "authoritative", "0")
      ucic:set("dhcp", minMetricInterface, "ignore", "0")
      ucic:set("dhcp", minMetricInterface, "force", "1")
      ucic:set("dhcp", minMetricInterface, "start", "50")
      ucic:set("dhcp", minMetricInterface, "limit", "200")
      ucic:set("dhcp", minMetricInterface, "leasetime", "12h")
      dhcpd_configured = dhcpd_configured + 1
    end
  end
  ucic:save("dhcp")
  ucic:commit("dhcp")
  -- Cleaning UP lease info for DHCP wizard
  sys.exec("uci delete dhcpdiscovery.if0.lastcheck")
  sys.exec("uci delete dhcpdiscovery.if0.timestamp")
  sys.exec("uci commit dhcpdiscovery")
  -- Reloading Dnsmask
  sys.exec("/etc/init.d/dnsmasq restart")
  if minMetricInterface then
    sys.exec("ifup " .. minMetricInterface)
  end
  return true
end

-- Checks methods
--  check if the daemon is running
--  check if it has more than 1h old sockets
-- If one of the check is not successfull, return true
function is_daemon_stalled()
  local otb_cmdline = "lua /usr/bin/overtheboxd"
  local max_age_socket = 3600

  local nb_pid = 0
  -- Iterate over the processes of overtheboxd daemon
  for pid, cmdline in pairs(pidof(otb_cmdline)) do
    -- Iterate over all its sockets
    for k, v in pairs(tcpsocketsof(pid)) do
      -- Check the socket's age is not to old
      -- If too old, restart the daemon
      if v.age > max_age_socket then
        return true
      end
    end
    nb_pid = nb_pid +  1
  end
  -- If no pid of the daemon is found, restart the daemon
  if nb_pid == 0 then
    return true
  end

  return false
end

-- test_if_running tests if a process is running
-- Take a command line
-- Return true or false if a running PID as a cmdline matching the given name
function test_if_running(cmdline)
  local nb_pid = 0
  for _, _ in pairs(pidof(cmdline)) do
    nb_pid = nb_pid +  1
  end
  return nb_pid ~= 0
end

-- restart_daemon restarts the overtheboxd daemon
function restart_daemon()
  local ret, rcode = run("/etc/init.d/overtheboxd restart")
  return status_code_ok(rcode), ret
end

--
-- function getzombieppid search zombie programs
-- return array of zombie's pid and ppid
function getzombieppid()
  local ret = {}
  local pids = list_pids()
  -- Iterate over pids
  for _, name in ipairs(pids) do
    -- Get process stats
    local filename = string.format('/proc/%s/stat', name)
    local f = io.open(filename, "r")
    if f ~= nil then
      -- Iterate over the lines of the stat files
      for line in f:lines() do
        -- Split the line and check if the process state is Z for Zombie
        local fis = split(line or "" )
        if #fis > 4 and fis[3] == "Z" then
          table.insert(ret, {pid=name, ppid=fis[4]})
        end
      end

      -- Close the file
      f:close()
    else
      warning("getzombieppid : couldn't open file ".. filename)
    end
  end

  return ret
end

--
-- function list_pids lists pids
-- returns array of pid
function list_pids()
  local ret = {}
  -- List files in /proc
  local files = posix.dir("/proc")

  for _, name in ipairs(files) do
    -- Append only files whose name is a number (PID)
    if string.match(name, '^[0-9]+$') then
      table.insert(ret, name)
    end
  end

  return ret
end

--
-- function sigkill kill a pid
--
function sigkill(pid)
  return posix.kill(pid, posix.SIGKILL)
end

--
-- function get_cmdline read cmdline file for a PID
-- return the command line which start the PID process
function get_cmdline(pid)
  local f = io.open(string.format('/proc/%s/cmdline', pid), "rb")
  if f == nil then return ' ' end
  local t = f:read("*all")
  f:close()
  local z = string.char(0)
  return t:gsub("(.)", function(c) if c == z then return ' ' end return c end)
end

-- function pidof search program in processus running
-- return array of pid
function pidof(program)
  local ret = {}
  if program == nil then return ret end
  local pids = list_pids()
  local me = posix.getpid()
  for _, name in ipairs(pids) do
    if tonumber(name) ~= me  then
      local cmdline = get_cmdline(name)
      if cmdline and cmdline:find(program, 1, true) ~= nil then
        table.insert(ret, tonumber(name), cmdline)
      end
    end
  end
  return ret
end

-- function
local function display_ipport(a,b,c,d,p)
  return string.format("%d.%d.%d.%d:%d", tonumber(d, 16), tonumber(c, 16), tonumber(b, 16), tonumber(a, 16),    tonumber(p, 16))
end

--
-- function ipport transform hexa notation ip:port in decimal
local function ipport(str)
  return str:gsub( '(%x%x)(%x%x)(%x%x)(%x%x):(%x%x%x%x)', display_ipport)
end

-- function get_sockets retreive sockets opened by pid
-- return and array of socket informations
function tcpsocketsof(pid)
  local ret = {}
  local sockets={}
  -- format described below
  local f = io.open(string.format('/proc/%s/net/tcp',pid), "r")
  if f == nil then return ret end
  for line in f:lines() do
    local fis = split(line or "")
    if #fis > 12 then
      fis[1] = fis[1]:gsub(":", "") -- clean id
      fis[2] = ipport(fis[2])
      fis[3] = ipport(fis[3])

      local inode = tonumber(fis[10])
      if sockets[inode] == nil then sockets[inode]={} end
      table.insert(sockets[inode], fis)
    end
  end
  f:close()

  for id, infos in pairs(socketsof(pid)) do
    if infos.inode ~= nil and sockets[infos.inode] ~= nil and type(sockets[infos.inode]) == "table" then
      for _, s in pairs(sockets[infos.inode]) do
        infos.src = s[2]
        infos.dst = s[3]
        table.insert(ret, infos)
      end
    end
  end
  return ret
end

function socketsof(pid)
  local ret = {}
  local files = posix.dir(string.format('/proc/%s/fd/',pid))
  for _, name in ipairs(files) do
    local fn = string.format('/proc/%s/fd/%s',pid,name)
    local fstat = sys_stat.stat(fn)
    -- for k,v in pairs(fstat) do print(k,v) end

    if fstat ~= nil and fstat.st_mode ~= nil and  sys_stat.S_ISSOCK ( fstat.st_mode ) ~= 0 then
      local age = os.time() - sys_stat.lstat(fn).st_ctime
      table.insert(ret, {name=name, fn=fn, age=age, inode=fstat.st_ino} )
    end
  end

  return ret
end

-- helpers
function lock(name)
  -- Open fd for appending
  local nixio = require('nixio')
  local oflags = nixio.open_flags("wronly", "creat")
  local file, code, msg = nixio.open("/tmp/" .. name, oflags)

  if not file then
    return file, code, msg
  end

  -- Acquire lock
  local stat
  stat, code, msg = file:lock("tlock")
  if not stat then
    return stat, code, msg
  end

  file:seek(0, "end")

  return file
end

-- function run execute a program
-- return stdout + stderr and status code
function run(command)
  local handle = io.popen(command .. " 2>&1")
  local result = handle:read("*a")
  local rc = {handle:close()}
  return result, rc[4]
end

-- function status_code_ok test a status code returned by the function run
-- return true if status code is OK, else if not
function status_code_ok(rcode)
  return rcode ~= nil and rcode == 0
end

function iface_info(iface)
  local result = {}

  local netm = require 'luci.model.network'.init()
  local net = netm:get_network(iface)
  local device = net and net:get_interface()

  if device then
    result.name = device:shortname()
    result.macaddr  = device:mac()
    result.ipaddrs  = { }
    result.ip6addrs = { }
    -- populate ipv4 address
    for _, a in ipairs(device:ipaddrs()) do
      result.ipaddrs[#result.ipaddrs+1] = {
        addr  = a:host():string(),
        netmask = a:mask():string(),
        prefix  = a:prefix()
      }
    end
    -- populate ipv6 address
    for _, a in ipairs(device:ip6addrs()) do
      if not a:is6linklocal() then
        result.ip6addrs[#result.ip6addrs+1] = {
          addr  = a:host():string(),
          netmask = a:mask():string(),
          prefix  = a:prefix()
        }
      end
    end
  end

  return result
end

function tc_stats()
  local output = {}
  for line in string.gmatch((sys.exec("tc -s q")), '[^\r\n]+') do
    table.insert(output, line)
  end


  local result = {}
  result["upload"] = {}
  local curdev;
  local curq;
  for i=1, #output do
    if string.byte(output[i]) ~= string.byte(' ') then
      curdev = nil
      curq = nil
    end
    if string.match(output[i], "dev ([^%s]+)") then
      curdev = string.match(output[i], "dev ([^%s]+)")
    end
    if string.match(output[i], "sfq (%d+)") then
      curq = string.match(output[i], "sfq (%d+)")
    end
    if curdev and curq then
      for bytes, pkt, dropped, overlimits, reque in string.gmatch(output[i], "Sent (%d+) bytes (%d+) pkt %(dropped (%d+), overlimits (%d+) requeues (%d+)") do
        -- print("["..curdev..", "..curq..", "..bytes.. ", "..pkt..", "..dropped..", "..overlimits..", ".. reque .. "]")
        if result["upload"][curq] == nil then
          result["upload"][curq] = {}
        end
        result["upload"][curq][curdev] = { bytes=bytes, pkt=pkt, dropped=dropped, overlimits=overlimits, requeues=reque }
      end
    end
  end

  output = {}
  result["download"] = {}
  local tcstats = json.decode(sys.exec("curl -s --max-time 1 api/qos/tcstats"))
  if tcstats and tcstats.raw_output then

    for line in string.gmatch(tcstats.raw_output, '[^\r\n]+') do
      table.insert(output, line)
    end

    for i=1, #output do
      if string.byte(output[i]) ~= string.byte(' ') then
        curdev = nil
        curq = nil
      end
      if string.match(output[i], "dev ([^%s]+)") then
        curdev = string.match(output[i], "dev ([^%s]+)")
      end
      if string.match(output[i], "sfq (%d+)") then
        curq = string.match(output[i], "sfq (%d+)")
      end
      if curdev and curq then
        for bytes, pkt, dropped, overlimits, reque in string.gmatch(output[i], "Sent (%d+) bytes (%d+) pkt %(dropped (%d+), overlimits (%d+) requeues (%d+)") do
          -- print("["..curdev..", "..curq..", "..bytes.. ", "..pkt..", "..dropped..", "..overlimits..", ".. reque .. "]")
          if result["download"][curq] == nil then
            result["download"][curq] = {}
          end
          result["download"][curq][curdev] = { bytes=bytes, pkt=pkt, dropped=dropped, overlimits=overlimits, requeues=reque }
        end
      end
    end
  end
  return result
end

-- Debug utils
function log(msg)
  if (type(msg) == "table") then
    for key, val in pairs(msg) do
      log('{')
      log(key)
      log(':')
      log(val)
      log('}')
    end
  else
    sys.exec("logger -t luci \"" .. tostring(msg) .. '"')
  end
end

function tprint (tbl, indent)
  if not indent then indent = 0 end
  if not tbl then return end

  if type(tbl) == "string" then
    print(tbl)
    return
  elseif type(tbl) ~= "table" then
    return
  end

  local formatting
  for k, v in pairs(tbl) do
    formatting = string.rep("  ", indent) .. k .. ": "
    if type(v) == "table" then
      print(formatting)
      tprint(v, indent+1)
    elseif type(v) == 'boolean' then
      print(formatting .. tostring(v))
    else
      print(formatting .. v)
    end
  end
end

function info(msg)
  posix.syslog( posix.LOG_INFO, msg)
end

function warning(msg)
  posix.syslog( posix.LOG_WARNING, msg)
end

function err(msg)
  posix.syslog( posix.LOG_ERR, msg)
end
