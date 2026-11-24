-- 麦克风：录音线程（micthread.lua）+ 主线程这边的读取、电平表和波形绘制。
-- 主线程只读共享内存里的波形环和线程经 Channel 发布的计数，不碰 OpenAL；
-- 线程或设备出问题时 state 变成 "off"/"error"，面板显示 MIC off 并照常运行。

local ffi = require("ffi")

local M = {
    state = "off", detail = "not started",
    rmsDb = -90, peakDb = -90, holdDb = -90, gain = 1,
    recording = false, recSeconds = 0, lastClip = nil, clipNotice = nil, clipNoticeTime = -10,
    maxClipSeconds = 15,
}

local RATE = 16000
local PCM_SECONDS = 30
local BIN_SAMPLES = 32            -- 2 ms 一列，500 列/秒
local BIN_CAP = 4096
local POS_CHANNEL, CTL_CHANNEL, CLIP_CHANNEL = "rgds-mic-pos", "rgds-mic-ctl", "rgds-mic-clip"
local FLOOR_DB = -60
local AGC_FLOOR = 0.06            -- 安静时最多放大约 15 倍，免得把底噪放成满幅
local STALE_S = 1.5

local thread, pcmData, binData, bmin, bmax
local posChannel, ctlChannel, clipChannel
local lastPcm, lastPcmTime = -1, 0
local clipId = 0
local env = AGC_FLOOR
local holdTimer = 0

local mesh, vertexData, verts, cols, meshWithData
local meshDirty = true

local function toDb(v)
    if v <= 0 then return -90 end
    return math.max(-90, 20 * math.log10(v / 32768))
end

function M.start()
    local ok, err = pcall(function()
        pcmData = love.data.newByteData(RATE * PCM_SECONDS * 2)
        binData = love.data.newByteData(BIN_CAP * 2 * 2)
        bmin = ffi.cast("const int16_t *", binData:getFFIPointer())
        bmax = bmin + BIN_CAP
        posChannel = love.thread.getChannel(POS_CHANNEL)
        ctlChannel = love.thread.getChannel(CTL_CHANNEL)
        clipChannel = love.thread.getChannel(CLIP_CHANNEL)
        posChannel:clear(); ctlChannel:clear(); clipChannel:clear()
        thread = love.thread.newThread("micthread.lua")
        thread:start(pcmData, binData, {
            rate = RATE, pcmCap = RATE * PCM_SECONDS, binCap = BIN_CAP, binSamples = BIN_SAMPLES,
            ringSamples = 8192,   -- OpenAL 内部环 0.5 s；线程 10 ms 取一次
            posChannel = POS_CHANNEL, ctlChannel = CTL_CHANNEL, clipChannel = CLIP_CHANNEL,
            prerollSamples = RATE / 4, tailSamples = RATE / 5,
            maxClipSamples = RATE * M.maxClipSeconds, minClipSamples = RATE * 3 / 10,
            clipFile = "ptt-last.wav",
            needConf = love.system.getOS() == "Linux",
        })
    end)
    if not ok then
        thread = nil
        M.state, M.detail = "off", "thread: " .. tostring(err)
        return false, M.detail
    end
    M.state, M.detail = "starting", "opening mic"
    return true
end

function M.isLive()
    return M.state == "live"
end

function M.isRecording()
    return M.recording
end

-- 片段从按下前 0.25 s 开始（线程那边截取），结果在 update 里经 M.onClip 回调交给调用方
function M.beginClip()
    if not thread or M.recording then return false end
    clipId = clipId + 1
    ctlChannel:push({cmd = "clip_start", id = clipId})
    M.recording, M.recSeconds = true, 0
    return true
end

function M.endClip()
    if not thread or not M.recording then return end
    ctlChannel:push({cmd = "clip_end", id = clipId})
end

-- 给以后的语音识别：共享的 16 kHz 单声道 int16 环、容量和当前累计写入数
function M.pcmRing()
    return pcmData, RATE * PCM_SECONDS, lastPcm
end

function M.update(dt)
    if not thread then return end
    local err = thread:getError()
    if err then
        if M.state ~= "off" then print("mic: thread error: " .. err); io.stdout:flush() end
        M.state, M.detail = "off", "thread error"
        thread = nil
        meshDirty = true
        M.recording = false
        return
    end

    local now = love.timer.getTime()
    local t = posChannel:peek()
    if t then
        if t.state ~= M.state or t.detail ~= M.detail then
            meshDirty = true
            print(string.format("mic: %s (%s)", t.state, tostring(t.detail))); io.stdout:flush()
        end
        M.state, M.detail = t.state, t.detail
        if t.pcm ~= lastPcm then
            lastPcm, lastPcmTime = t.pcm, now
            meshDirty = true
        elseif M.state == "live" and now - lastPcmTime > STALE_S then
            M.state, M.detail = "error", "no data"
        end
        M.bins = t.bins
        if M.recording and t.rec then M.recSeconds = t.recSamples / RATE end

        local rmsDb, peakDb = toDb(t.rms), toDb(t.peak)
        M.rmsDb = math.max(rmsDb, M.rmsDb - 30 * dt)
        if peakDb >= M.holdDb then
            M.holdDb, holdTimer = peakDb, 1
        else
            holdTimer = holdTimer - dt
            if holdTimer <= 0 then M.holdDb = math.max(peakDb, M.holdDb - 15 * dt) end
        end
        M.peakDb = peakDb
        local peak = t.peak / 32768
        env = math.max(AGC_FLOOR, peak, env * math.exp(-dt / 2))
        M.gain = 1 / env
    end

    local c = clipChannel:pop()
    while c do
        if c.id == clipId then
            M.recording = false
            if c.ok then
                M.lastClip = c
                M.clipNotice = string.format("clip %.1f s · peak %.0f dB%s", c.seconds, toDb(c.peak),
                    c.reason == "max length" and " · max length" or "")
            else
                M.clipNotice = "no clip · " .. tostring(c.reason)
            end
            M.clipNoticeTime = now
            print(string.format("mic: clip %s (%s) %s", c.ok and string.format("%.2fs", c.seconds) or "dropped",
                tostring(c.reason), c.path or "")); io.stdout:flush()
            if M.onClip then M.onClip(c) end
        end
        c = clipChannel:pop()
    end
end

-- Mali 上每帧 setVertices 同一个 Mesh 会等 GPU 用完上一帧的缓冲（实测游玩时 60 → 52 fps），
-- 所以轮流写 3 个 Mesh；逐列 rectangle 更慢（43 fps）
local MESH_RING = 3
local meshes, meshIndex = {}, 1

local function ensureMesh(width)
    if verts and cols == width then return end
    cols = width
    vertexData = love.data.newByteData(cols * 2 * 2 * 4)
    verts = ffi.cast("float *", vertexData:getFFIPointer())
    for i = 1, MESH_RING do
        meshes[i] = love.graphics.newMesh({{"VertexPosition", "float", 2}}, cols * 2, "strip", "stream")
    end
    mesh = meshes[1]
    meshWithData = pcall(mesh.setVertices, mesh, vertexData)
    meshDirty = true
end

local function fillMesh(halfH)
    local scale = halfH * 0.92 / 32768 * M.gain
    local newest = (M.state == "live" or M.state == "error") and (M.bins or 0) or 0
    for i = 0, cols - 1 do
        local b = newest - cols + i
        local top, bottom = 0, 0
        if b >= 0 then
            local j = b % BIN_CAP
            top, bottom = -bmax[j] * scale, -bmin[j] * scale
            if top < -halfH then top = -halfH end
            if bottom > halfH then bottom = halfH end
        end
        if bottom - top < 1 then top, bottom = top - 0.5, bottom + 0.5 end
        local k = i * 4
        verts[k], verts[k + 1], verts[k + 2], verts[k + 3] = i + 0.5, top, i + 0.5, bottom
    end
    meshIndex = meshIndex % MESH_RING + 1
    mesh = meshes[meshIndex]
    if meshWithData then
        mesh:setVertices(vertexData)
    else
        for i = 0, cols * 2 - 1 do mesh:setVertex(i + 1, verts[i * 2], verts[i * 2 + 1]) end
    end
end

-- 波形：最近 w 列（每列 2 ms）的 min/max 包络，最新的在右边；颜色由调用方先 setColor
function M.drawWave(x, y, w, h)
    if not bmin then return end
    ensureMesh(w)
    if meshDirty then
        fillMesh(h / 2)
        meshDirty = false
    end
    love.graphics.draw(mesh, x, y + h / 2)
end

function M.stop()
    if not thread then return end
    ctlChannel:push("stop")
    thread:wait()
    thread = nil
end

return M
