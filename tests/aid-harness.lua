local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local APPDIR = os.getenv("APPDIR") or here:match("^(.*)/tests$") or (here == "tests" and "." or here)
local SETUP = os.getenv("SETUP") or os.tmpname()

local F = dofile(APPDIR .. "/tests/fake-love.lua")
F.install(APPDIR, os.getenv("OUT") or "/tmp")

love.filesystem.getSource = function() return APPDIR end
love.thread.newThread = function()
    return {
        start = function() end,
        isRunning = function() return true end,
        getError = function() return nil end,
        wait = function() end,
    }
end

local function boot()
    package.loaded.aid = nil
    local aid = require("aid")
    aid.setupFile = SETUP
    os.remove(SETUP)
    assert(aid.start(), "helper should start against the stub thread")
    return aid
end

local function ev(aid)
    return love.thread.getChannel("rgds-aid-ev")
end

local function jobs()
    return love.thread.getChannel("rgds-aid-job")
end

local function push(aid, msg)
    ev(aid):push(msg)
    aid.update()
end

local function writeSetup(body)
    local f = assert(io.open(SETUP, "w"))
    f:write(body)
    f:close()
end

local function testToolAndBanner()
    local aid = boot()
    aid.chat("run uname")
    local chat = jobs():pop()
    assert(chat and chat.op == "chat" and chat.id == aid.reqId, "chat op")
    assert(aid.youTag(aid.log[1]) == "YOU", "handheld tag")
    push(aid, {ev = "tool", id = aid.reqId, tool = "bash", status = "running", title = "uname -a"})
    assert(aid.toolText(aid.activity) == "bash: uname -a", "running tool line")
    assert(aid.toolText(aid.log[2].tool) == "bash: uname -a", "turn keeps the running tool")
    assert(aid.bannerText == nil, "tool text stays off the top banner")
    assert(aid.reply == "", "tool text is not reply text")
    push(aid, {ev = "delta", id = aid.reqId, text = "Linux"})
    assert(aid.reply == "Linux", "delta still appends")
    assert(aid.bannerText == "Linux", "banner is the reply")
    assert(aid.toolText(aid.activity) == "bash: uname -a", "tool stays while the reply streams")
    push(aid, {ev = "tool", id = aid.reqId, tool = "bash", status = "completed", title = "uname -a"})
    assert(aid.activity == nil, "completed tool leaves the live line")
    assert(aid.log[2].tool.status == "completed", "turn keeps the completed tool")
    assert(aid.toolText(aid.log[2].tool) == "bash: uname -a", "log still names the tool")
    assert(aid.bannerText == "Linux", "completed tool does not replace the banner")
    push(aid, {ev = "tool", id = "other", tool = "read", status = "running", title = "secret"})
    assert(aid.activity == nil, "another turn's tool is ignored")
    assert(aid.log[2].tool.tool == "bash", "another turn does not overwrite this turn")
    push(aid, {ev = "done", id = aid.reqId})
    assert(aid.phase == "done", "done finishes the turn")
    assert(aid.activity == nil, "done clears activity")
end

local function testRemoteUser()
    local aid = boot()
    push(aid, {ev = "remote_user", id = "pc-1", text = "from the desk"})
    assert(aid.phase == "thinking", "PC turn opens a reply")
    assert(aid.reqId == "pc-1", "PC id becomes the active turn")
    assert(#aid.log == 2, "PC turn adds a you row and a live reply")
    assert(aid.log[1].who == "you" and aid.log[1].text == "from the desk", "PC text is in the log")
    assert(aid.log[1].pc == true, "PC row is marked")
    assert(aid.youTag(aid.log[1]) == "PC", "PC tag")
    assert(aid.log[2].who == "ai" and aid.log[2].live == true, "live reply follows the PC row")
    local queued = jobs():pop()
    assert(queued == nil, "adopting a PC turn does not send chat")
    push(aid, {ev = "start", id = "pc-1"})
    push(aid, {ev = "delta", id = "pc-1", text = "ok"})
    assert(aid.log[2].text == "ok", "PC reply lands on the live row")
    push(aid, {ev = "remote_user", id = "pc-1", text = "from the desk"})
    assert(#aid.log == 2, "the same PC id is not adopted twice")
    push(aid, {ev = "done", id = "pc-1"})
    assert(aid.phase == "done", "PC turn can finish")
end

local function testRemoteReplacesHandheld()
    local aid = boot()
    aid.chat("from the handheld")
    jobs():pop()
    push(aid, {ev = "delta", id = aid.reqId, text = "partial"})
    push(aid, {ev = "remote_user", id = "pc-2", text = "from the desk"})
    assert(aid.reqId == "pc-2", "a new PC id replaces the handheld turn")
    assert(aid.log[1].text == "from the handheld" and aid.log[1].pc == nil, "handheld row stays")
    assert(aid.log[2].text == "partial" and aid.log[2].live == false, "partial reply is closed")
    assert(aid.log[3].pc == true and aid.youTag(aid.log[3]) == "PC", "replacement row is PC")
    assert(aid.log[4].live == true and aid.reply == "", "new reply starts empty")
    assert(aid.activity == nil, "replacement clears tool activity")
end

local function testDismissCancels()
    local aid = boot()
    aid.chat("stop this")
    local chat = jobs():pop()
    push(aid, {ev = "tool", id = chat.id, tool = "bash", status = "running", title = "sleep 30"})
    assert(aid.toolText(aid.activity) == "bash: sleep 30", "tool before dismiss")
    aid.dismiss()
    assert(aid.activity == nil, "dismiss clears the live tool")
    local cancel = jobs():pop()
    assert(cancel and cancel.op == "cancel" and cancel.id == chat.id, "dismiss sends cancel for that id")
end

local function testSetupFile()
    local aid = boot()
    writeSetup('{\n  "ip": "10.0.0.8",\n  "port": 8787,\n  "token": "AB2CD3",\n  "url": "http://10.0.0.8:8787/"\n}\n')
    aid.update()
    assert(aid.setup and aid.setup.token == "AB2CD3", "six character token")
    assert(aid.setup.url == "http://10.0.0.8:8787/", "setup url")
    writeSetup('{"url":"http://10.0.0.8:8787/","token":"ABCDE"}')
    aid.update()
    assert(aid.setup == nil, "short token is not shown")
    writeSetup('{"url":"ftp://10.0.0.8/","token":"AB2CD3"}')
    aid.update()
    assert(aid.setup == nil, "non-http url is not shown")
    os.remove(SETUP)
    aid.update()
    assert(aid.setup == nil, "missing file clears setup")
end

testToolAndBanner()
testRemoteUser()
testRemoteReplacesHandheld()
testDismissCancels()
testSetupFile()
os.remove(SETUP)
print("OK")
