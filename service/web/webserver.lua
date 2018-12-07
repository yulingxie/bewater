local skynet        = require "skynet"
local socket        = require "skynet.socket"
local httpd         = require "http.httpd"
local sockethelper  = require "http.sockethelper"
local urllib        = require "http.url"
local bewater       = require "bewater"
local conf          = require "conf"
local whitelist     = require "ip.whitelist"
local blacklist     = require "ip.blacklist"
local hotfix        = require "hotfix"
local errcode       = require "def.errcode"
local util          = require "util"

local mode, server_path, handler_path, port, preload, gate = ...
port = tonumber(port)
preload = preload and tonumber(preload) or 20

local function response(fd, ...)
    local ok, err = httpd.write_response(sockethelper.writefunc(fd), ...)
    if not ok then
        -- if err == sockethelper.socket_error , that means socket closed.
        skynet.error(string.format("fd = %d, %s", fd, err))
    end
end

if mode == "agent" then
local handler = require(handler_path)

-- handler 需要提供
-- hander.api = {[[/api/xxx/ooo]] = func}
-- hander.auth = function(auth) return uid end -- 授权
-- 如果是非字符串，handler需要提供pack和unpack方法
handler.pack = handler.pack or function (data)
    return data
end
handler.unpack = handler.unpack or function (data)
    return data
end

local function on_message(url, args, body, header, ip)
    local auth = header.authorization
    local api = handler.api[url]
    if api then
        local ret, data = bewater.try(function()
            return handler.unpack(body, url)
        end)
        if not ret then
            return {
                err = errcode.BODY_ERROR,
                desc = "body error"
            }
        end
        ret = {}
        local uid = handler.auth and handler.auth(handler, auth)
        if api.auth and not uid then
            return {
                err = errcode.AUTH_FAIL,
                desc = "authorization fail",
            }
        end
        if api.args then
            -- todo check args
        end
        if not bewater.try(function()
            local func = require(handler.root..string.gsub(url, '/', '.'))
            assert(func, url)
            ret = func(args, data, uid, ip, header) or {}
        end) then
            return {
                err = errcode.TRACEBACK, 
                desc = "server traceback"
            }
        end
        ret.err = ret.err or 0
        return ret
    else
        return {
            err = errcode.API_NOT_EXIST, 
            desc = "api not exist"
        }
    end
end

skynet.start(function()
    skynet.dispatch("lua", function (_,_, ...)
        local args = {...}
        if args[1] == "hotfix" then
            handler = hotfix.module(handler_path)
            return
        end
        if type(args[1]) == "string" then
            return bewater.ret(handler[args[1]](...))
        end
        local fd, ip = ...
        socket.start(fd)
        -- limit request body size to 8192 (you can pass nil to unlimit)
        local code, url, method, header, body = httpd.read_request(sockethelper.readfunc(fd), nil)
        --util.printdump(header)
        skynet.error(string.format("recv code:%s, url:%s, method:%s, header:%s", code, url, method, header))
        if code then
            if code ~= 200 then
                response(fd, code)
            else
                local data
                local _, query = urllib.parse(url)
                if query then
                    data = urllib.parse_query(query)
                end
                ip = header['x-real-ip'] or string.match(ip, "[^:]+")
                response(fd, code, handler.pack(on_message(url, data, body, header, ip)), 
                    {["Access-Control-Allow-Origin"] = "*"})
            end
        else
            if url == sockethelper.socket_error then
                skynet.error("socket closed")
            else
                skynet.error(url)
            end
        end
        socket.close(fd)
    end)
    hotfix.reg()
end)

elseif mode == "gate" then

local server
if server_path then
    server = require(server_path)
end

local agents = {}
local CMD = {}
function CMD.hotfix()
    server = hotfix.module(server_path)
    return bewater.NORET
end

function CMD.call_agent(...)
    return skynet.call(agents[1], "lua", ...)
end

function CMD.call_all_agent(...)
    for _, agent in pairs(agents) do
        skynet.pcall(agent, "lua", ...)
    end
end

skynet.start(function()
    for i= 1, preload do
        agents[i] = skynet.newservice(SERVICE_NAME, "agent", server_path, handler_path, port, preload, skynet.self())
    end
    local balance = 1
    local fd = socket.listen("0.0.0.0", port)
    socket.start(fd , function(_fd, ip)
        if conf.whitelist and not whitelist.check(ip) then
            socket.start(_fd)
            skynet.error(string.format("not in whitelist:%s", ip))
            response(_fd, 403)
            socket.close(_fd)
            return
        end
        if conf.blacklist and blacklist.check(ip) then
            socket.start(fd)
            skynet.error(string.format("in blacklist:%s", ip))
            response(fd, 403)
            socket.close(fd)
            return
        end
        skynet.error(string.format("%s connected, pass it to agent :%08x", _fd, agents[balance]))
        skynet.send(agents[balance], "lua", _fd, ip)
        balance = balance + 1
        if balance > #agents then
            balance = 1
        end
    end)

    skynet.dispatch("lua", function(_, _, cmd, subcmd, ...)
        if CMD[cmd] then
            return bewater.ret(CMD[cmd](subcmd, ...))
        end
        local f = assert(server[cmd], cmd)
        if type(f) == "function" then
            bewater.ret(f(subcmd, ...))
        else
            bewater.ret(f[subcmd](f, ...))
        end
    end)

    hotfix.reg()
end)

else
    assert(false, "mode error")
end
