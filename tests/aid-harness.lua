local src = debug.getinfo(1, "S").source
if src:sub(1, 1) == "@" then src = src:sub(2) end
local here = src:match("^(.*)/") or "."
local APPDIR = os.getenv("APPDIR") or here:match("^(.*)/tests$") or (here == "tests" and "." or here)
local SETUP = os.getenv("SETUP") or os.tmpname()

local F = dofile(APPDIR .. "/tests/fake-love.lua")
F.install(APPDIR, os.getenv("OUT") or "/tmp")

love.filesystem.getSource = function() return APPDIR end
local helper = {running = true, err = nil}
love.thread.newThread = function()
    return {
        start = function() end,
        isRunning = function() return helper.running end,
        getError = function() return helper.err end,
        wait = function() end,
    }
end

local function boot()
    helper.running, helper.err = true, nil
    package.loaded.aid = nil
    local aid = require("aid")
    aid.setupFile = SETUP
    aid.setupPollInterval = 0
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

local function testRemoteQueuesBehindHandheld()
    local aid = boot()
    aid.chat("from the handheld")
    local id = aid.reqId
    jobs():pop()
    push(aid, {ev = "delta", id = id, text = "partial"})
    push(aid, {ev = "remote_user", id = "pc-2", text = "from the desk"})
    assert(aid.reqId == id, "a queued PC turn does not hijack the handheld turn")
    assert(aid.phase == "streaming", "handheld turn stays in streaming")
    assert(#aid.log == 2, "the PC row waits until the handheld turn finishes")
    assert(aid.log[2].text == "partial" and aid.log[2].live == true, "partial reply stays live")
    push(aid, {ev = "done", id = id})
    assert(aid.reqId == "pc-2", "the queued PC turn is adopted after the handheld turn")
    assert(aid.phase == "thinking", "the adopted PC turn is the active one")
    assert(aid.log[1].text == "from the handheld" and aid.log[1].pc == nil, "handheld row stays")
    assert(aid.log[2].text == "partial" and aid.log[2].live == false, "handheld reply is closed")
    assert(aid.log[3].pc == true and aid.log[3].text == "from the desk", "adopted row is PC")
    assert(aid.youTag(aid.log[3]) == "PC", "adopted tag is PC")
    assert(aid.log[4].live == true and aid.reply == "", "new reply starts empty")
    assert(aid.activity == nil, "adoption clears tool activity")
end

local function testChatDropsQueuedRemote()
    local aid = boot()
    aid.chat("first")
    local first = aid.reqId
    jobs():pop()
    push(aid, {ev = "remote_user", id = "pc-q", text = "queued"})
    assert(aid.reqId == first, "the PC turn stays queued")
    aid.chat("second")
    local second = aid.reqId
    assert(jobs():pop().op == "cancel" and jobs():pop().op == "chat", "a new handheld turn cancels the previous one")
    push(aid, {ev = "done", id = second})
    assert(aid.reqId == nil and aid.phase == "done", "the handheld turn finishes with nothing queued")
    for _, row in ipairs(aid.log) do
        assert(row.text ~= "queued", "a newer handheld chat drops the queued PC turn")
    end
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

local function testConcurrentTools()
    local aid = boot()
    aid.chat("two tools")
    local id = aid.reqId
    jobs():pop()
    local rev = aid.rev
    push(aid, {ev = "tool", id = id, call_id = "r1", tool = "read", status = "running", title = "a.lua"})
    assert(aid.rev > rev, "activity bumps rev")
    push(aid, {ev = "tool", id = id, call_id = "b1", tool = "bash", status = "running", title = "uname"})
    assert(aid.activity.tool == "bash" and aid.activity.status == "running", "the newest running tool is visible")
    assert(aid.log[2].tool.tool == "bash", "the turn shows the newest running tool")
    push(aid, {ev = "tool", id = id, call_id = "r1", tool = "read", status = "completed", title = "a.lua"})
    assert(aid.activity and aid.activity.tool == "bash" and aid.activity.status == "running",
        "completing read leaves bash running")
    assert(aid.log[2].tool.tool == "bash" and aid.log[2].tool.status == "running",
        "the turn keeps the bash call")
    push(aid, {ev = "tool", id = id, call_id = "b2", tool = "bash", status = "running", title = "second"})
    push(aid, {ev = "tool", id = id, call_id = "b1", tool = "bash", status = "completed", title = "uname"})
    assert(aid.activity.tool == "bash" and aid.activity.title == "second" and aid.activity.status == "running",
        "call_id completes only that call")
    push(aid, {ev = "done", id = id})
    assert(aid.activity == nil, "done clears activity")
    assert(aid.log[2].tool.status == "completed", "done finalizes a still-running tool")
    assert(aid.log[2].tool.tool == "bash" and aid.log[2].tool.title == "second", "done seals the visible call")
    assert(aid.reqId == nil, "done clears reqId")
end

local function testBannerRefreshAfterTool()
    local aid = boot()
    aid.chat("slow")
    local id = aid.reqId
    jobs():pop()
    push(aid, {ev = "delta", id = id, text = "hi"})
    assert(aid.bannerActive(), "banner starts with the reply")
    assert(aid.bannerText == "hi", "banner text is the reply")
    push(aid, {ev = "tool", id = id, tool = "bash", status = "running", title = "sleep 9"})
    F.advance(6)
    assert(not aid.bannerActive(), "banner expires after 5s")
    push(aid, {ev = "done", id = id})
    assert(aid.bannerText == "hi", "done puts the reply back on the banner")
    assert(aid.bannerActive(), "done refreshes the banner deadline")
    assert(aid.activity == nil, "done clears the tool line")
    assert(aid.log[2].tool.status == "completed", "done finalizes the running tool")
end

local function testDismissFinalizesTool()
    local aid = boot()
    aid.chat("partial please")
    local id = aid.reqId
    jobs():pop()
    push(aid, {ev = "delta", id = id, text = "wait"})
    push(aid, {ev = "tool", id = id, tool = "bash", status = "running", title = "sleep 30"})
    aid.dismiss()
    assert(aid.activity == nil, "dismiss clears activity")
    assert(aid.log[2].live == false, "dismiss closes the row")
    assert(aid.log[2].text == "wait", "partial reply stays")
    assert(aid.log[2].tool.status == "error", "dismiss finalizes a running tool")
    local cancel = jobs():pop()
    assert(cancel and cancel.op == "cancel" and cancel.id == id, "dismiss cancels that turn")
    assert(aid.phase == "done", "a partial reply dismisses as done")
end

local function testHelperCrash()
    local aid = boot()
    aid.chat("crash")
    local id = aid.reqId
    jobs():pop()
    push(aid, {ev = "tool", id = id, tool = "bash", status = "running", title = "sleep"})
    assert(aid.activity and aid.activity.status == "running", "tool is running before the crash")
    helper.running = false
    helper.err = "boom"
    aid.update()
    assert(aid.phase == "error", "a dead helper is an error")
    assert(aid.detail == "AI helper off", "crash detail")
    assert(aid.activity == nil, "crash clears activity")
    assert(aid.log[2].live == false, "crash closes the row")
    assert(aid.log[2].tool.status == "error", "crash finalizes the running tool")
end

local function testToolError()
    local aid = boot()
    aid.chat("nope")
    local id = aid.reqId
    jobs():pop()
    push(aid, {ev = "tool", id = id, tool = "bash", status = "error", title = "nope"})
    assert(aid.activity == nil, "an error tool leaves the live line")
    assert(aid.log[2].tool.status == "error", "the turn keeps the error")
    assert(aid.toolText(aid.log[2].tool) == "bash: nope", "error tool text")
    assert(aid.phase == "thinking", "a tool error does not end the turn")
end

local function testDismissPcTurn()
    local aid = boot()
    push(aid, {ev = "remote_user", id = "pc-9", text = "from the desk"})
    push(aid, {ev = "delta", id = "pc-9", text = "soon"})
    push(aid, {ev = "tool", id = "pc-9", tool = "read", status = "running", title = "note"})
    aid.dismiss()
    local cancel = jobs():pop()
    assert(cancel and cancel.op == "cancel" and cancel.id == "pc-9", "dismiss cancels the PC turn")
    assert(aid.reqId == nil, "dismiss clears the PC id")
    assert(aid.activity == nil, "dismiss clears PC activity")
    assert(aid.phase == "done", "a partial PC reply dismisses as done")
    assert(aid.log[2].tool.status == "error", "dismiss finalizes the PC tool")
    assert(aid.log[2].live == false, "dismiss closes the PC row")
end

local function testBlankAndReusedPcId()
    local aid = boot()
    push(aid, {ev = "remote_user", id = "pc-turn", text = "   "})
    assert(aid.phase == "thinking", "blank PC text still opens a turn")
    assert(aid.reqId == "pc-turn", "blank PC text keeps the id")
    assert(aid.log[1].text == "(PC)" and aid.log[1].pc == true, "blank PC text uses the fallback")
    assert(aid.youTag(aid.log[1]) == "PC", "fallback row is tagged PC")
    push(aid, {ev = "done", id = "pc-turn"})
    assert(aid.reqId == nil, "done clears the fallback id")
    assert(aid.phase == "done", "the blank turn can finish")
    push(aid, {ev = "remote_user", id = "pc-turn", text = "next"})
    assert(aid.phase == "thinking" and aid.reqId == "pc-turn", "the same id is adopted on the next turn")
    assert(aid.log[3].text == "next", "the second turn is logged")
    push(aid, {ev = "error", id = "pc-turn", kind = "server"})
    assert(aid.reqId == nil, "error clears the fallback id")
    push(aid, {ev = "remote_user", id = "pc-turn", text = "third"})
    assert(aid.reqId == "pc-turn" and aid.phase == "thinking", "the same id works again after error")
    assert(aid.log[#aid.log - 1].text == "third", "the third turn is logged")
end

local function testSetupPoll()
    local aid = boot()
    aid.setupPollInterval = 0.5
    aid.setup = {url = "http://10.0.0.8:8787/", token = "AB2CD3"}
    writeSetup('{"url":"http://10.0.0.8:8787/","token":"AB2CD3"}')
    aid.update()
    assert(aid.setup and aid.setup.token == "AB2CD3", "populated setup stays when the file matches")
    local rev = aid.rev
    os.remove(SETUP)
    aid.update()
    assert(aid.setup and aid.setup.token == "AB2CD3", "populated setup stays cached inside the interval")
    assert(aid.rev == rev, "a cached poll does not bump rev")
    F.advance(0.6)
    aid.update()
    assert(aid.setup == nil, "the next poll clears a populated setup when the file is gone")
    assert(aid.rev > rev, "clearing setup bumps rev")
    writeSetup('{"url":"http://10.0.0.9:8787/","token":"ZZ9YY8"}')
    aid.update()
    assert(aid.setup == nil, "a new file stays unseen until the interval elapses")
    F.advance(0.6)
    rev = aid.rev
    aid.update()
    assert(aid.setup and aid.setup.token == "ZZ9YY8", "the next poll reads the new token")
    assert(aid.setup.url == "http://10.0.0.9:8787/", "the next poll reads the new url")
    assert(aid.rev == rev + 1, "a changed token bumps rev once")
    writeSetup('{"url":"http://10.0.0.9:8787/","token":"ZZ9YY8"}')
    F.advance(0.6)
    aid.update()
    assert(aid.rev == rev + 1, "the same url and token do not bump rev")
end

local function testRevSignals()
    local aid = boot()
    local rev = aid.rev
    aid.chat("hi")
    assert(aid.rev > rev, "chat bumps rev")
    local id = aid.reqId
    jobs():pop()
    rev = aid.rev
    push(aid, {ev = "delta", id = id, text = "yo"})
    assert(aid.rev > rev, "a reply bumps rev")
    assert(aid.phase == "streaming", "delta streams")
    rev = aid.rev
    push(aid, {ev = "done", id = id})
    assert(aid.rev > rev, "finishing a turn bumps rev")
end

local function testToolTextAndYouTag()
    local aid = boot()
    assert(aid.toolText(nil) == nil, "nil snap")
    assert(aid.toolText("bash") == nil, "non-table snap")
    assert(aid.toolText({}) == nil, "missing tool name")
    assert(aid.toolText({tool = ""}) == nil, "blank tool name")
    assert(aid.toolText({tool = "bash"}) == "bash", "tool without a title")
    assert(aid.toolText({tool = "bash", title = "   "}) == "bash", "blank title is dropped")
    assert(aid.toolText({tool = "bash", title = "ls"}) == "bash: ls", "tool title")
    assert(aid.youTag(nil) == "YOU", "nil turn")
    assert(aid.youTag({}) == "YOU", "empty turn")
    assert(aid.youTag({lang = "ja"}) == "ja", "language tag")
    assert(aid.youTag({pc = true, lang = "en"}) == "PC", "PC wins over language")
    assert(aid.youTag({lang = ""}) == "YOU", "blank language falls back")
end

testToolAndBanner()
testRemoteUser()
testRemoteQueuesBehindHandheld()
testChatDropsQueuedRemote()
testDismissCancels()
testSetupFile()
testConcurrentTools()
testBannerRefreshAfterTool()
testDismissFinalizesTool()
testHelperCrash()
testToolError()
testDismissPcTurn()
testBlankAndReusedPcId()
testSetupPoll()
testRevSignals()
testToolTextAndYouTag()
os.remove(SETUP)
print("OK")
