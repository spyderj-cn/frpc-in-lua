#!/usr/bin/lua

--------------------------------------------------------------------------------
-- frpc-in-lua:
-- The client of frp(https://github.com/fatedier/frp) reimplemented in Lua.
--
-- Under the same license as frp.
--------------------------------------------------------------------------------

local log = require 'log'
local cjson = require 'cjson'
local zlib = require 'zlib'
local tasklet = require 'tasklet'
require 'tasklet.channel.stream'
require 'tasklet.channel.message'

local strerror, EBADF = errno.strerror, errno.EBADF

local VERSION_STRING = '0.9.3'

local MSG_TYPE = {
    NewCtlConn = 0,
	NewWorkConn = 1,
	NoticeUserConn = 2,
	NewCtlConnRes = 3,
	HeartbeatReq = 4,
	HeartbeatRes = 5,
	NewWorkConnUdp = 6
}

local common = {
    name = 'common',
    server_addr = '0.0.0.0',
    server_port = 7000,
    http_proxy = false,
    log_file = '/tmp/frpc.log',
    log_level = 'info',
    privilege_token = false,
    auth_token = false,
    heartbeat_timeout = 300,
    heartbeat_interval = 120,
}
common.__index = common
local clients = {}  -- proxy clients


local function new_client(name)
    return setmetatable({
        -- conf fields
        name = name,
        local_ip = '127.0.0.1',
        local_port = false,
        type = 'tcp',
        use_encryption = false,
        use_gzip = false,
        pool_count = 0,
        privilege_mode = false,

        -- runtime fields(prefixed with 'rt_' to avoid possible name conflicts)
        rt_local_unixsock = false,
        rt_chclose = false,
        rt_tskpalive = tasklet.now,
        rt_wbuf = buffer.new(),  -- write-buffer for control sccket io
        rt_login = false,   -- whether succeeded login of the last control task
        rt_num_spawned = 0,  -- how many times the control task is spawned
        rt_num_tunnels = 0, -- number of tunnels running now
        rt_num_all_tunnels = 0, -- number of tunnels ever runned(include the running ones)
        rt_tunnel_list = false, -- running tunnel list
        rt_l2r_bytes = 0,  -- total bytes from local to remote of all tunnels
        rt_r2l_bytes = 0,  -- total bytes from remote to local of all tunnels
    }, common)
end


--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local clog = (function ()
    local function make_clog(level)
        return function (client, ...)
            log[level]('client[', client.name, ']: ', ...)
        end
    end

    local ret = {}
    for _, v in pairs({'debug', 'info', 'warn', 'error', 'fatal'}) do
        ret[v] = make_clog(v)
    end
    return ret
end)()

local function make_http_proxy_conn(client, addr, port)
    local http = require 'http'
    -- TODO
    log.fatal('make_http_proxy_conn not implemented yet')
end

local function evalstr(str)
    str = str:gsub('%$%(([^%(%)]+)%)', function (cmd)
        local file = io.popen(cmd, 'r')
        if not file then
            log.fatal('conf: failed to execute ', cmd)
        end

        local val = file:read('*line')
        if not val or #val == 0 then
            log.fatal('conf: command failed -> ', cmd)
        end
        file:close()
        return val
    end)
    return str
end

--------------------------------------------------------------------------------
-- conf
--------------------------------------------------------------------------------

local function conf_init(conffile)
    local function check_integer(section, field, min, max)
        local val = section[field]
        if type(val) == 'string' then
            val = tonumber(val)
            if not val or val < min or val > max then
                log.fatal('conf: illegal ', field, ' in section[', section.name, ']: ', 'ranged [', min, ', ', max, ']')
            end
            section[field] = val
        end
    end

    -- check and merge section [common]
    local function check_common(common)
        check_integer(common, 'server_port', 1, 65535)

        if not common.http_proxy then
            common.http_proxy = os.getenv('http_proxy')
        end

        if common.log_file == 'console' then
            common.log_file = 'stdout'
        end

        check_integer(common, 'heartbeat_timeout', 5, 7200)
        check_integer(common, 'heartbeat_interval', 5, 7200)
        if common.heartbeat_interval >= common.heartbeat_timeout then
            log.fatal('conf: please make sure heartbeat_timeout > heartbeat_interval in [common]')
        end
    end

    local function check_client(client)
        local val

        local local_ip = client.local_ip
        if not local_ip:is_ipv4() then
            if fs.issock(local_ip) then
                client.rt_local_unixsock = true
            else
                log.fatal('conf: illegal local_ip in section [', client.name, ']')
            end
        end

        if not client.rt_local_unixsock then
            check_integer(client, 'local_port', 1, 65535)
            if not client.local_port then
                log.fatal('conf: missing local_port in [', section.name, ']')
            end
        elseif client.local_port then
            log.warn('conf: ignore local_port when local_ip is a unix domain address')
        end

        if type(client.use_encryption) == 'string' then
            client.use_encryption = client.use_encryption == 'true'
        end

        if type(client.use_gzip) == 'string' then
            client.use_gzip = client.use_gzip == 'true'
        end

        if not ({tcp=1, udp=1, http=1, https=1})[client.type] then
            log.fatal('conf: illegal type in [', client.name, ']')
        end

        if type(client.privilege_mode) == 'string' then
            client.privilege_mode = client.privilege_mode == 'true'
        end

        check_integer(client, 'pool_count', 0, 100) -- ?

        if client.privilege_mode then
            if not client.privilege_token then
                log.fatal('conf: requires privilege_token if privilege_mode is enabled in setion [', client.name, ']')
            end

            local ctype = client.type
            if ctype == 'tcp' or ctype == 'udp' then
                check_integer(client, 'remote_port', 1, 65535)
            elseif ctype == 'http' or ctype == 'https' then
                -- custome domains
                local custom_domains = client.custom_domains
                if custom_domains then
                    custom_domains = custom_domains:tokenize(', ')
                    client.custom_domains = {}
                    for i, v in ipairs(custom_domains) do
                        client.custom_domains[i] = v:lower()
                    end
                else
                    client.custom_domains = NULL
                end

                -- subdomain
                if #client.custom_domains == 0 and not client.subdomain then
                    log.fatal('conf: need subdomain or custome_domains in section [', client.name, ']')
                end

                -- locations
                if ctype == 'http' then
                    local locations = client.locations
                    if locations then
                        client.locations = locations:tokenize(', ')
                    else
                        client.locations = NULL
                    end
                end
            end
        end

        clients[client.name] = client
    end

    local section
    for line in io.lines(conffile) do
        if line:match('^%s*#') then
            -- skip commentary line
        else
            local secname = line:match('^%s*%[%s*([^%]]+)%s*%]')
            if secname then
                secname = evalstr(secname)
                if section then
                    (section == common and check_common or check_client)(section)
                end
                section = secname == 'common' and common or new_client(secname)
            elseif not section then
                log.fatal('corrutped ini file')
            else
                local k, v = line:match('^%s*([^%s=]+)%s*=%s*(%S.*)$')
                if k and v then
                    section[k] = evalstr(v:gsub('(%s*)$', ''))
                end
            end
        end
    end

    if section then
        (section == common and check_common or check_client)(section)
    end
end


--------------------------------------------------------------------------------
-- tunnel
--------------------------------------------------------------------------------

local function tunnel_task()
    local tunnel = tasklet.current_task()
    local client, addr, port = tunnel.client, tunnel.addr, tunnel.port
    local err = 0

    ----------------------------------------------------------------------------
    -- make remote connection {
    local ch_remote
    if client.http_proxy then
        ch_remote, err = make_http_proxy_conn(client, addr, port)
        if not ch_remote then
            return
        end
    else
        ch_remote = tasklet.stream_channel.new(-1, 5 * 1024 + 4)
        err = ch_remote:connect(addr, port)
        if err ~= 0 then
            clog.error(client, 'failed to connect tunne-remote, err -> ', strerror(err))
            return
        end
    end

    local now = math.floor(tasklet.now_unix)
    local req = {
        type = MSG_TYPE.NewWorkConn,
        proxy_name = client.name,
        privilege_mode = client.privilege_mode,
        timestamp = now
    }

	if req.privilege_mode then
		req.privilege_key = md5(client.name .. client.privilege_token .. now)
	else
        req.auth_key = md5(client.name .. client.auth_token .. now)
	end

    -- just a few bytes, guess no problem with tmpbuf here.
    cjson.encodeb(req, tmpbuf:rewind())
    tmpbuf:putstr('\n')
	err = ch_remote:write(tmpbuf)
    if err ~= 0 then
        clog.error('failed to write the initial request to tunnel-remote, err -> ', strerror(err))
        return
    end
    clog.info(client, 'tunnel-remote connection established')
    -- }
    ----------------------------------------------------------------------------


    -- make local connection
    local ch_local = tasklet.stream_channel.new(-1, 5 * 1024)
    err = ch_local:connect(client.local_ip, client.local_port)
    if err ~= 0 then
        clog.error(client, 'failed to connect tunnel-local, err -> ', strerror(err))
        ch_remote:close()
        return
    end
    clog.info(client, 'tunnel-local connection established')

    local function read_with_log(which, bytes)
        local ch = which == 'local' and ch_local or ch_remote
        local rd, err = ch:read(bytes)
        if not rd then
            if err == 0 then
                clog.warn(client, 'tunnel-', which, ' closed the connection')
            elseif err ~= EBADF then
                clog.error(client, 'failed to read from tunnel-', which, ', err -> ', strerror(err))
            else
                clog.info(client, 'hereby closed the connection with tunnel-', which)
            end
        end
        return rd, err
    end

    local function write_with_log(which, buf)
        local ch = which == 'local' and ch_local or ch_remote
        local err = ch:write(buf)
        if err ~= 0 then
            if err == EBADF then
                clog.info(client, 'hereby closed the connection with tunnel-', which)
            else
                clog.error(client, 'failed to write to tunnel-', which, ', err -> ', strerror(err))
            end
        end
        return err
    end

    local gzip, encrypt = client.use_gzip, client.use_encryption

    local function pipe_encrypt()
        local buf = buffer.new(5 * 1024 + 4)

        while true do
            local rd, err = read_with_log('local', -1)
            if not rd then
                break
            end
            buf:putu(0)

            if gzip then
                err = zlib.compress(rd, buf)
                if err ~= 0 then
                    clog(client, 'compression error, err -> ', err)
                    break
                end
            else
                buf:putreader(rd)
            end

            if encrypt then
                -- TODO
            end

            buf:overwrite(0, #buf - 4)
            err = write_with_log('remote', buf)
            if err ~= 0 then
                break
            end
            buf:rewind()

            tunnel.l2r_bytes = tunnel.l2r_bytes + #rd
        end
        ch_local:close()
        ch_remote:close()
    end

    local function pipe_decrypt()
        local buf = buffer.new()

        while true do
            local rd, err = read_with_log('reomte', 4)
            if not rd then
                break
            end

            local len = rd:getu()
            if len == 0 or len > 1024000 then -- check length limit
                clog.error(client, 'illegal tunnel-local length -> ', len)
                err = errno.EOVERFLOW
                break
            end

            buf:rewind()
            while len > 0 do
                rd, err = read_with_log('remote', len)
                if not rd then
                    break
                end
                buf:putreader(rd)
                len = len - #rd
            end
            if err ~= 0 then
                break
            end

            if encrypt then
                -- TODO
            end

            if gzip then
                err = zlib.uncompress(buf)
                if err ~= 0 then
                    clog(client, 'compression error, err -> ', err)
                    break
                end
            end

            err = write_with_log('local', buf)
            if err ~= 0 then
                break
            end
            tunnel.r2l_bytes = tunnel.r2l_bytes + #buf
        end
        ch_local:close()
        ch_remote:close()
    end

    tasklet.start_task(pipe_encrypt, nil, true)
    tasklet.start_task(pipe_decrypt, nil, true)
    tasklet.join_tasks()
    clog.info(client, 'tunnel exited (r->l ', tunnel.r2l_bytes, ', l->r ', tunnel.l2r_bytes, ')')

    client.rt_num_tunnels = client.rt_num_tunnels - 1
    if client.rt_num_tunnels == 0 then
        client.rt_tskpalive = tasklet.now
    end

    client.rt_r2l_bytes = client.rt_r2l_bytes + tunnel.r2l_bytes
    client.rt_l2r_bytes = client.rt_l2r_bytes + tunnel.l2r_bytes

    local prev, next = tunnel.prev, tunnel.next
    if next then
        next.prev = prev
    end
    if prev then
        prev.next = next
    else
        client.rt_tunnel_list = next
    end
end

local function start_tunnel(client, addr, port)
    local head = client.rt_tunnel_list
    local tunnel = {
        client = client,
        addr = addr,
        port = port,
        prev = false,
        next = head,
        l2r_bytes = 0,
        r2l_bytes = 0,
    }

    if head then
        head.prev = tunnel
    end
    client.rt_tunnel_list = tunnel
    client.rt_num_tunnels = client.rt_num_tunnels + 1
    client.rt_num_all_tunnels = client.rt_num_all_tunnels + 1

    tasklet.start_task(tunnel_task, tunnel)
end

--------------------------------------------------------------------------------
-- control
--------------------------------------------------------------------------------

-- login
local function make_control_conn(client)
    local ch, err
    if client.http_proxy then
        ch, err = make_http_proxy_conn(client, client.server_addr, client.server_port)
        if not ch then
            return
        end
    else
        ch = tasklet.stream_channel.new()
        err = ch:connect(client.server_addr, client.server_port)
    end
    client.rt_chclose = ch

    if err ~= 0 then
        clog.error(client, string.format('failed to connect %s:%d, errno -> %s',
            client.server_addr, client.server_port, strerror(err)))
        return
    end

    local now = math.floor(tasklet.now_unix)
    local req = {
        type = MSG_TYPE.NewCtlConn,
        proxy_name = client.name,
        use_encryption = client.use_encryption,
        use_gzip = client.use_gzip,
        privilege_mode = client.privilege_mode,
        proxy_type = client.type,
        pool_count = client.pool_count,
        host_header_rewrite = client.host_header_rewrite,
        http_username = client.http_username,
        http_password = client.http_password,
        subdomain = client.subdomain,
        timestamp = now,
    }

    if req.privilege_mode then
        req.privilege_key = md5(client.name .. client.privilege_token .. now)
        req.remote_port = client.remote_port
        req.custom_domains = client.custom_domains
        req.locations = client.locations
    else
        req.auth_key = md5(client.name .. client.auth_token .. now)
    end

    repeat
        local buf = client.rt_wbuf:rewind()
        cjson.encodeb(req, buf)
        buf:putstr('\n')
        err = ch:write(buf)
        if err ~= 0 then
            clog.error(client, 'failed to write to server, err -> ', strerror(err))
            break
        end

        local resp_line
        resp_line, err = ch:read(nil, 15)  -- read the response line in 15 seconds
        if err ~= 0 then
            clog.error(client, 'failed to read from server, errno -> ', strerror(err))
            break
        end

        clog.debug(client, 'read response -> ', resp_line)

        local ok, resp = pcall(cjson.decode, resp_line)
        local code = ok and resp.code
        if not code then
            clog.error(client, 'corrupted response -> ', resp_line)
            err = -1
            break
        end

        if code ~= 0 then
            clog.error(client, 'start proxy error, ', resp.msg)
            err = -1
        end
    until true

    if err == 0 then
        clog.info(client, 'login finished')
        return ch
    else
        ch:close()
    end
end

local function control_loop(client)
    local ch_conn = make_control_conn(client)
    if not ch_conn then
        return
    end
    client.rt_login = true

    local ch_msg = tasklet.message_channel.new(20)
    local dog_hungry = true
    local watchdog = false

    client.rt_chclose = ch_msg

    local function heartbeat_task()
        local msg = {
            type = MSG_TYPE.HeartbeatReq
        }
        clog.info(client, 'heartbeat task started')
        while true do
            tasklet.sleep(client.heartbeat_interval)
            if ch_msg:write(msg) ~= 0 then
                -- must be someone closed it, don't make any logs
                break
            end
        end
        clog.info(client, 'heartbeat task exited')
    end

    local function watchdog_task()
        clog.info(client, 'watchdog task started')
        while true do
            tasklet.sleep(client.heartbeat_timeout)
            if dog_hungry then
                clog.error(client, 'heartbeat timed out')
                watchdog = false
            elseif client.temp and client.rt_num_tunnels == 0 and
                    tasklet.now - client.rt_tskpalive > client.keepalive then
                clog.error(client, 'keepalive timed out')
                watchdog = false
            end

            if not watchdog then
                ch_msg:close()
                break
            end
            dog_hungry = true
        end
        clog.info(client, 'watchdog task exited')
    end

    local function send_msg_task()
        clog.info(client, 'send message task started')
        local buf = client.rt_wbuf
        local err = 0
        while true do
            local msg = ch_msg:read()
            if not msg then
                ch_conn:close()
                break
            end

            cjson.encodeb(msg, buf:rewind())
            buf:putstr('\n')
            err = ch_conn:write(buf)
            if err ~= 0 then
                clog.error(client, 'failed to send heartbeat, err -> ', strerror(err))
                ch_conn:close()
                ch_msg:close()
                break
            end
        end
        clog.info(client, 'send message task exited')
    end

    tasklet.start_task(heartbeat_task, nil, true)
    watchdog = tasklet.start_task(watchdog_task, nil, true)
    tasklet.start_task(send_msg_task, nil, true)

    -- recv message loop
    while true do
        local line, err = ch_conn:read()
        if not line then
            ch_conn:close()
            if watchdog then
                tasklet.reap_task(watchdog)
                watchdog = false
            end
            break
        end

        local ok, msg = pcall(cjson.decode, line)
        local type = ok and msg.type
        if not type then
            clog.warn(client, 'corrupted message from server -> ', line)
        elseif type == MSG_TYPE.HeartbeatRes then
            clog.debug(client, 'received heartbeat response')
            dog_hungry = false
        elseif type == MSG_TYPE.NoticeUserConn then
            clog.debug(client, 'new user connection')
            start_tunnel(client, client.server_addr, client.server_port)
        else
            clog.warn(client, 'unknown message type -> ', tostring(type))
        end
    end
    tasklet.join_tasks()
    clog.info(client, 'main task exited')
end

local function control_manager_task()
    local ch_ctrlmgr = tasklet.message_channel.new(20)

    local function start_control_task(client)
        tasklet.start_task(function ()
            local num_spawned = client.rt_num_spawned
            if num_spawned > 0 then
                tasklet.sleep(client.rt_login and 5 or 30)
                client.rt_login = false
            end

            client.rt_num_spawned = num_spawned + 1

            control_loop(client)

            ch_ctrlmgr:write(client)
        end)
    end

    if not common.server_addr:is_ipv4() then
        require 'tasklet.util'
        while true do
            local ip = tasklet.getaddrbyname(common.server_addr)[1]
            if ip then
                log.info(common.server_addr, ' resolved as ', ip)
                common.server_addr = ip
                break
            else
                tasklet.sleep(15)
            end
        end
    end

    for _, client in pairs(clients) do
        start_control_task(client)
    end

    while true do
        start_control_task(ch_ctrlmgr:read())
    end
end

--------------------------------------------------------------------------------
-- commands
--------------------------------------------------------------------------------

local commands = {}

-- frpctl add ssh 'remote_port=54321,local_port=22[,keepalive=7200[,local_ip=127.0.0.1]]'
function commands.add(argv)
	local name, params  = argv[1], argv[2]
	if not params then
		return errno.EINVAL
	end

    local client = clients[name]
    if client then
        if not client.temp then
            return errno.EINVAL
        else
            return 0, tostring(client.remote_port)
        end
    end

    local defaults = {
        remote_port = true,
        local_port = true,
        local_ip = true,
        keepalive = 7200,
    }
    client = new_client()
    for k, v in params:gmatch('([^,=]+)=([^,=]+)') do
        if defaults[k] then
            client[k] = v
        end
	end
    client.keepalive = tonumber(client.keepalive) or defaults.keepalive
    client.remote_port = tonumber(client.remote_port)
    if not client.remote_port then
        return errno.EINVAL
    end
    client.local_port = tonumber(client.local_port)
    if not client.local_port then
        return errno.EINVAL
    end

	client.privilege_mode = true
    client.temp = true
    client.name = name
    clients[name] = client
    tasklet.start_task(function ()
        control_loop(client)
        clients[name] = nil
    end)

    return 0, tostring(client.remote_port)
end

-- frpctl del ssh
function commands.del(argv)
	local name  = argv[1]
    local client = name and clients[name]
    if not client or not client.temp then
		return errno.EINVAL
	end
    if client.rt_num_tunnels > 0 then
        return errno.EBUSY
    end
	if client.rt_chclose then
        client.rt_chclose:close()
    end
    return 0
end

-- frpctl status ssh
function commands.status(argv)
    local name = argv[1]
    if not name then
        return errno.EINVAL
    end

    local client = clients[name]
    if not client then
        return errno.ENOENT
    end

    local l2r, r2l = client.rt_l2r_bytes, client.rt_r2l_bytes
    local node = client.rt_tunnel_list
    while node do
        l2r = l2r + node.l2r_bytes
        r2l = r2l + node.r2l_bytes
        node = node.next
    end

    return 0, tmpbuf:rewind():putstr(string.format([[
name: %s
number of tunnels: %d
number of tunnels running: %d
local to remote: %d
remote to local: %d]],
        client.name,
        client.rt_num_all_tunnels,
        client.rt_num_tunnels,
        l2r,
        r2l)  -- string.format
    ):str()
end

--------------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------------

local function main(argv)
    local help = [[frpc(-in-lua) is the client of frp reimplemented in Lua.

Options:
    -c  <fileapth>
    --config-file=<filepath>        set config file, defaulted to /etc/frpc.ini

    -s <server-addr>
    --server-addr=<serveraddr>      addr which frps is listening for, example: 0.0.0.0:7000

    -o <filepath>
    --log_file=<filepath>           set log file path, defaulted to /tmp/frpc.log

    -l <level>
    --log_level=<level>             set log level, defaulted to 'info'

    -f --foreground                 do not daemonize
    -d --debug                      run in debug mode(foreground, loglevel=debug, logpath=stdout)
    -h --help                       show this screen
    -v --version                    show version
]]

    local opts = getopt(argv, 'hvdfl:o:c:s:', {
            'log_level=', 'log_file=', 'foreground', 'help',
            'version',  'debug', 'config-file=', 'server-addr='
        }) or log.fatal('illegal arguments\n', usage)

    if opts.h or opts.help then
        print(help)
        os.exit(0)
    end
    if opts.v or opts.version then
        print(VERSION_STRING)
        os.exit(0)
    end
    local conffile = opts.c or opts['config-file'] or './frpc.ini'
    if fs.access(conffile, fs.R_OK) ~= 0 then
        log.fatal('unable to read ', conffile)
    end

    conf_init(conffile)

    local server_addr = opts.s or opts['server-addr']
    if server_addr then
        if server_addr:find(':') then -- ip:port
            local addr, port = server_addr:match('^([^:]+):(%d)+$')
            if not port then
                log.fatal('invalid server-addr argument')
            end
            common.server_addr = addr
            common.server_port = port
        else
            local port = tonumber(server_addr)
            if port then
                common.server_port = port
            else
                common.server_addr = server_addr
            end
        end
    end

    opts.logpath = opts.log_file or opts.o or common.log_file
    if opts.logpath == 'console' then
        opts.logpath = 'stdout'
    end
    opts.loglevel = opts.log_level or opts.l or common.log_level

    local app = require 'app'
    app.APPNAME = 'frpc'
    os.exit(app.run(opts, function ()
        app.start_ctlserver_task(commands)
        tasklet.start_task(control_manager_task)
    end))
end

main(arg)
