-- 云端对话：游戏启动时拉起 rgds-aid，退出时关掉。
-- 主线程只提交已经识别出的文字，并在信息面板和主屏顶部显示回复。
-- 密钥、网络或助手出问题就把 phase 设成 "error"，游戏继续跑。

local M = {
    phase = "off",     -- off | loading | ready | thinking | streaming | done | error
    detail = "",
    reply = "",
    reqId = nil,
    bannerText = nil,
    bannerUntil = -1,
    epoch = 0,
    rev = 0,
    log = {},
    activity = nil,
    setup = nil,
    setupFile = "/tmp/opencode-setup.json",
    setupPollInterval = 0.5,
}

local BANNER_S = 5
local seq = 0
local bannerHeld = false
local LOG_MAX = 50
local activeTools = {}
local pendingRemote = nil
local setupAt = -1

local function now()
    return love.timer.getTime()
end

local function bump()
    M.rev = M.rev + 1
end

local function clearTools()
    activeTools = {}
    M.activity = nil
end

local function closeLive(dropIfEmpty, toolStatus)
    local turn = M.log[#M.log]
    if not (turn and turn.who == "ai" and turn.live) then return end
    if dropIfEmpty and turn.text == "" then
        table.remove(M.log)
    else
        if turn.tool and turn.tool.status == "running" then
            turn.tool.status = toolStatus or "error"
        end
        turn.live = false
    end
    clearTools()
end

local function trimLog()
    while #M.log > LOG_MAX do table.remove(M.log, 1) end
end

local function youRow(text, lang, pc)
    local row = {who = "you", text = text, lang = lang or ""}
    if pc then row.pc = true end
    return row
end

local function aiRow()
    return {who = "ai", text = "", lang = "", live = true, err = ""}
end

function M.toolText(snap)
    if type(snap) ~= "table" then return nil end
    local name = snap.tool
    if type(name) ~= "string" or name == "" then return nil end
    local title = snap.title
    if type(title) == "string" and title:gsub("%s", "") ~= "" then
        return name .. ": " .. title
    end
    return name
end

function M.youTag(turn)
    if type(turn) ~= "table" then return "YOU" end
    if turn.pc then return "PC" end
    if type(turn.lang) == "string" and turn.lang ~= "" then return turn.lang end
    return "YOU"
end

local function blank(s)
    return type(s) ~= "string" or s:gsub("%s", "") == ""
end

local function adoptRemote(msg)
    pendingRemote = nil
    closeLive(false, "error")
    M.reqId = msg.id
    M.reply, M.detail = "", ""
    M.phase = "thinking"
    clearTools()
    bannerHeld = false
    M.bannerText, M.bannerUntil = nil, -1
    local text = blank(msg.text) and "(PC)" or msg.text
    M.log[#M.log + 1] = youRow(text, "", true)
    M.log[#M.log + 1] = aiRow()
    trimLog()
    M.epoch = M.epoch + 1
    bump()
end

local function beginRemote(msg)
    if type(msg.id) ~= "string" or msg.id == "" then return end
    if msg.id == M.reqId then return end
    if M.phase == "thinking" or M.phase == "streaming" then
        pendingRemote = {id = msg.id, text = msg.text}
        return
    end
    adoptRemote(msg)
end

local function takePending()
    local msg = pendingRemote
    if not msg then return end
    pendingRemote = nil
    adoptRemote(msg)
end

local function toolKey(msg, name)
    local id = msg.call_id
    if id ~= nil and id ~= "" then return tostring(id) end
    return name
end

local function applyTool(msg)
    local name = msg.tool
    if type(name) ~= "string" or name == "" then name = "tool" end
    local status = msg.status
    if status ~= "running" and status ~= "completed" and status ~= "error" then return end
    local title = type(msg.title) == "string" and msg.title or ""
    local key = toolKey(msg, name)
    local snap = {tool = name, status = status, title = title}
    local found
    for i, item in ipairs(activeTools) do
        if item.key == key then
            found = i
            break
        end
    end
    if status == "running" then
        if found then
            activeTools[found].snap = snap
        else
            activeTools[#activeTools + 1] = {key = key, snap = snap}
        end
    elseif found then
        table.remove(activeTools, found)
    end
    local visible = activeTools[#activeTools]
    local turn = M.log[#M.log]
    if visible then
        M.activity = visible.snap
        if turn and turn.who == "ai" then turn.tool = visible.snap end
    else
        M.activity = nil
        if turn and turn.who == "ai" then turn.tool = snap end
    end
    bump()
end

local function readSetup(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a") or ""
    f:close()
    local url = text:match('"url"%s*:%s*"([^"]+)"')
    local token = text:match('"token"%s*:%s*"([^"]+)"')
    if type(url) ~= "string" or not url:match("^https?://") then return nil end
    if type(token) ~= "string" or not token:match("^%w%w%w%w%w%w$") then return nil end
    return {url = url, token = token}
end

local function sameSetup(a, b)
    if a == nil or b == nil then return a == nil and b == nil end
    return a.url == b.url and a.token == b.token
end

local function refreshSetup()
    local interval = M.setupPollInterval
    if type(interval) ~= "number" or interval < 0 then interval = 0.5 end
    local t = now()
    if interval > 0 and setupAt >= 0 and (t - setupAt) < interval then return end
    setupAt = t
    local path = M.setupFile
    local nextSetup = nil
    if type(path) == "string" and path ~= "" then
        nextSetup = readSetup(path)
    end
    if sameSetup(M.setup, nextSetup) then return end
    M.setup = nextSetup
    bump()
end
local PANE = {
    no_key = "AI: no API key",
    offline = "AI offline",
    timeout = "AI timed out",
    auth = "AI: key rejected",
    rate_limit = "AI busy, try again",
    server = "AI unavailable",
    interrupted = "AI interrupted",
    helper = "AI helper off",
    cancelled = "",
}

local thread
local jobChannel, evChannel

local ffi_ok, ffi = pcall(require, "ffi")
if ffi_ok then pcall(ffi.cdef, "int kill(int pid, int sig);") end

local function readable(path)
    local f = io.open(path, "rb")
    if not f then return false end
    f:close()
    return true
end

local function fail(detail)
    M.phase, M.detail = "error", detail
    bump()
    print("aid: " .. detail)
    io.stdout:flush()
    return false
end

function M.start()
    if thread and thread:isRunning() then return true end
    local source = love.filesystem.getSource()
    local script = source .. "/rgds-aid.py"
    local python = "/usr/bin/python3"
    if not readable(script) then return fail("AI helper off") end
    if not readable(python) then return fail("AI helper off") end

    jobChannel = love.thread.getChannel("rgds-aid-job")
    evChannel = love.thread.getChannel("rgds-aid-ev")
    jobChannel:clear()
    evChannel:clear()
    if M.phase ~= "thinking" and M.phase ~= "streaming" then
        M.phase, M.detail = "loading", ""
        bump()
    end
    thread = love.thread.newThread("aidthread.lua")
    local ok, err = pcall(function()
        thread:start({
            script = script,
            python = python,
            port = 7788,
            log = "/tmp/rgds-aid.log",
        })
    end)
    if not ok then
        thread = nil
        return fail("AI helper off")
    end
    print("aid: helper starting")
    io.stdout:flush()
    return true, err
end

function M.chat(text, lang)
    if type(text) ~= "string" or text:gsub("%s", "") == "" then return end
    pendingRemote = nil
    if not thread or not thread:isRunning() then
        if not M.start() then return end
    end
    closeLive(false, "error")
    local prev = M.reqId
    seq = seq + 1
    M.reqId = "c" .. seq
    M.reply, M.detail = "", ""
    M.phase = "thinking"
    clearTools()
    bannerHeld = false
    M.bannerText, M.bannerUntil = nil, -1
    M.log[#M.log + 1] = youRow(text, lang)
    M.log[#M.log + 1] = aiRow()
    trimLog()
    M.epoch = M.epoch + 1
    bump()
    if prev then jobChannel:push({op = "cancel", id = prev}) end
    jobChannel:push({op = "chat", id = M.reqId, text = text})
end

function M.dismiss()
    local id = M.reqId
    closeLive(true, "error")
    M.reqId = nil
    M.detail = ""
    clearTools()
    local last = M.log[#M.log]
    if last and last.who == "ai" then M.reply = last.text or "" end
    if M.phase == "thinking" or M.phase == "streaming" or M.phase == "error" then
        M.phase = (M.reply ~= "" and "done") or "ready"
    end
    if id and jobChannel then
        pcall(function() jobChannel:push({op = "cancel", id = id}) end)
    end
    bump()
    takePending()
end

function M.hasLog()
    return #M.log > 0
end

local function showError(kind)
    local text = PANE[kind]
    if text == nil then text = "AI unavailable" end
    M.phase = "error"
    M.detail = text
    if text ~= "" then
        print("aid: " .. text)
        io.stdout:flush()
    end
end

local function finishIdle()
    M.reqId = nil
    bump()
    takePending()
end

function M.update()
    refreshSetup()
    if evChannel then
        local msg = evChannel:pop()
        while msg do
            local mine = msg.id == nil or msg.id == M.reqId
            if msg.ev == "ready" then
                if M.phase == "loading" then
                    M.phase = "ready"
                    bump()
                end
                print("aid: ready")
                io.stdout:flush()
            elseif msg.ev == "remote_user" then
                beginRemote(msg)
            elseif mine and msg.ev == "start" then
                if M.phase ~= "streaming" and M.phase ~= "thinking" then
                    M.phase = "thinking"
                    bump()
                end
            elseif mine and msg.ev == "tool"
                and (M.phase == "thinking" or M.phase == "streaming") then
                applyTool(msg)
            elseif mine and msg.ev == "delta" then
                M.reply = M.reply .. (msg.text or "")
                local turn = M.log[#M.log]
                if turn and turn.who == "ai" and turn.live then turn.text = M.reply end
                M.phase = "streaming"
                if M.reply ~= "" then
                    M.bannerText = M.reply
                    if not bannerHeld then
                        M.bannerUntil = now() + BANNER_S
                        bannerHeld = true
                    end
                end
                bump()
            elseif mine and msg.ev == "done" then
                local turn = M.log[#M.log]
                if turn and turn.who == "ai" then
                    if turn.tool and turn.tool.status == "running" then
                        turn.tool.status = "completed"
                    end
                    turn.live = false
                    if M.reply ~= "" then turn.text = M.reply end
                end
                clearTools()
                M.phase = "done"
                bannerHeld = false
                if M.reply ~= "" then
                    M.bannerText = M.reply
                    M.bannerUntil = now() + BANNER_S
                end
                finishIdle()
            elseif mine and msg.ev == "error" then
                if msg.kind ~= "cancelled" then
                    if msg.partial and msg.partial ~= "" then M.reply = msg.partial end
                    showError(msg.kind)
                    local turn = M.log[#M.log]
                    if turn and turn.who == "ai" and turn.live then
                        if turn.tool and turn.tool.status == "running" then
                            turn.tool.status = "error"
                        end
                        if M.reply ~= "" then turn.text = M.reply end
                        turn.err = M.detail
                        turn.live = false
                    end
                    clearTools()
                elseif M.phase == "thinking" or M.phase == "streaming" then
                    closeLive(true, "error")
                    M.phase = (M.reply ~= "" and "done") or "ready"
                end
                finishIdle()
            elseif mine and msg.ev == "status" and M.phase == "loading" then
                M.phase = "ready"
                bump()
            end
            msg = evChannel:pop()
        end
    end
    if thread and M.phase ~= "off" and M.phase ~= "error" and not thread:isRunning() then
        local err = thread:getError()
        local turn = M.log[#M.log]
        if turn and turn.who == "ai" then
            if turn.tool and turn.tool.status == "running" then
                turn.tool.status = "error"
            end
            if turn.live then turn.live = false end
        end
        clearTools()
        M.phase = "error"
        M.detail = "AI helper off"
        M.reqId = nil
        bump()
        if err then
            print("aid: thread " .. (tostring(err):match("^[^\n]+") or "error"))
            io.stdout:flush()
        end
    end
end

function M.bannerActive()
    return M.bannerText and M.bannerText ~= "" and now() < M.bannerUntil
end

function M.active()
    return M.phase == "thinking" or M.phase == "streaming" or M.phase == "error"
        or (M.reply and M.reply ~= "")
end

function M.stop()
    if jobChannel then pcall(function() jobChannel:push({op = "stop"}) end) end
    -- 读线程若堵在 socket 上，先关掉助手，套接字关闭后线程才能退出
    local f = io.open("/tmp/rgds-aid.pid", "r")
    local pid = f and tonumber(f:read("*a"))
    if f then f:close() end
    if pid and pid > 0 and ffi_ok then
        pcall(function() ffi.C.kill(pid, 15) end)
    end
    if thread then
        thread:wait()
        thread = nil
    end
    M.reqId = nil
    pendingRemote = nil
    clearTools()
end

return M
