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
    log = {},
    activity = nil,
    setup = nil,
    setupFile = "/tmp/opencode-setup.json",
}

local BANNER_S = 5
local seq = 0
local bannerHeld = false
local LOG_MAX = 50

local function closeLive(dropIfEmpty)
    local turn = M.log[#M.log]
    if not (turn and turn.who == "ai" and turn.live) then return end
    if dropIfEmpty and turn.text == "" then
        table.remove(M.log)
    else
        turn.live = false
    end
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

local function beginRemote(msg)
    if type(msg.id) ~= "string" or msg.id == "" or blank(msg.text) then return end
    if msg.id == M.reqId then return end
    closeLive(false)
    M.reqId = msg.id
    M.reply, M.detail = "", ""
    M.phase = "thinking"
    M.activity = nil
    bannerHeld = false
    M.bannerText, M.bannerUntil = nil, -1
    M.log[#M.log + 1] = youRow(msg.text, "", true)
    M.log[#M.log + 1] = aiRow()
    trimLog()
    M.epoch = M.epoch + 1
end

local function applyTool(msg)
    local name = msg.tool
    if type(name) ~= "string" or name == "" then name = "tool" end
    local status = msg.status
    if status ~= "running" and status ~= "completed" and status ~= "error" then return end
    local title = type(msg.title) == "string" and msg.title or ""
    local snap = {tool = name, status = status, title = title}
    local turn = M.log[#M.log]
    if turn and turn.who == "ai" then turn.tool = snap end
    if status == "running" then
        M.activity = snap
    else
        M.activity = nil
    end
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

local function refreshSetup()
    local path = M.setupFile
    if type(path) ~= "string" or path == "" then
        M.setup = nil
        return
    end
    M.setup = readSetup(path)
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
    if not thread or not thread:isRunning() then
        if not M.start() then return end
    end
    closeLive(false)
    local prev = M.reqId
    seq = seq + 1
    M.reqId = "c" .. seq
    M.reply, M.detail = "", ""
    M.phase = "thinking"
    M.activity = nil
    bannerHeld = false
    M.bannerText, M.bannerUntil = nil, -1
    M.log[#M.log + 1] = youRow(text, lang)
    M.log[#M.log + 1] = aiRow()
    trimLog()
    M.epoch = M.epoch + 1
    if prev then jobChannel:push({op = "cancel", id = prev}) end
    jobChannel:push({op = "chat", id = M.reqId, text = text})
end

function M.dismiss()
    local id = M.reqId
    closeLive(true)
    M.reqId = nil
    M.detail = ""
    M.activity = nil
    local last = M.log[#M.log]
    if last and last.who == "ai" then M.reply = last.text or "" end
    if M.phase == "thinking" or M.phase == "streaming" or M.phase == "error" then
        M.phase = (M.reply ~= "" and "done") or "ready"
    end
    if id and jobChannel then
        pcall(function() jobChannel:push({op = "cancel", id = id}) end)
    end
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

function M.update()
    refreshSetup()
    if evChannel then
        local msg = evChannel:pop()
        while msg do
            local mine = msg.id == nil or msg.id == M.reqId
            if msg.ev == "ready" then
                if M.phase == "loading" then M.phase = "ready" end
                print("aid: ready")
                io.stdout:flush()
            elseif msg.ev == "remote_user" then
                beginRemote(msg)
            elseif mine and msg.ev == "start" then
                if M.phase ~= "streaming" then M.phase = "thinking" end
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
                        M.bannerUntil = love.timer.getTime() + BANNER_S
                        bannerHeld = true
                    end
                end
            elseif mine and msg.ev == "done" then
                M.activity = nil
                local turn = M.log[#M.log]
                if turn and turn.who == "ai" then
                    turn.live = false
                    if M.reply ~= "" then turn.text = M.reply end
                end
                M.phase = "done"
                bannerHeld = false
                if M.reply ~= "" and (not M.bannerText or M.bannerText == "") then
                    M.bannerText = M.reply
                    M.bannerUntil = love.timer.getTime() + BANNER_S
                end
            elseif mine and msg.ev == "error" then
                M.activity = nil
                if msg.kind ~= "cancelled" then
                    if msg.partial and msg.partial ~= "" then M.reply = msg.partial end
                    showError(msg.kind)
                    local turn = M.log[#M.log]
                    if turn and turn.who == "ai" and turn.live then
                        if M.reply ~= "" then turn.text = M.reply end
                        turn.err = M.detail
                        turn.live = false
                    end
                elseif M.phase == "thinking" or M.phase == "streaming" then
                    closeLive(true)
                    M.phase = (M.reply ~= "" and "done") or "ready"
                end
            elseif mine and msg.ev == "status" and M.phase == "loading" then
                M.phase = "ready"
            end
            msg = evChannel:pop()
        end
    end
    if thread and M.phase ~= "off" and M.phase ~= "error" and not thread:isRunning() then
        local err = thread:getError()
        M.phase = "error"
        M.detail = "AI helper off"
        if err then
            print("aid: thread " .. (tostring(err):match("^[^\n]+") or "error"))
            io.stdout:flush()
        end
    end
end

function M.bannerActive()
    return M.bannerText and M.bannerText ~= "" and love.timer.getTime() < M.bannerUntil
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
    M.activity = nil
end

return M
