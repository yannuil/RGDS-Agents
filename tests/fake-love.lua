-- Minimal fake `love` for running micthread.lua / micwave.lua under plain LuaJIT on the device.
-- Recording goes through the system OpenAL Soft (the same libopenal LÖVE links), so ALSOFT_CONF →
-- dsnoop behaves exactly as in the game.
local ffi = require("ffi")
ffi.cdef[[
typedef struct ALCdevice ALCdevice;
ALCdevice *alcCaptureOpenDevice(const char *name, unsigned freq, int format, int bufsize);
char alcCaptureCloseDevice(ALCdevice *d);
void alcCaptureStart(ALCdevice *d);
void alcCaptureStop(ALCdevice *d);
void alcCaptureSamples(ALCdevice *d, void *buf, int n);
void alcGetIntegerv(ALCdevice *d, int param, int size, int *values);
const char *alcGetString(ALCdevice *d, int param);
struct rgds_timespec { long tv_sec; long tv_nsec; };
int clock_gettime(int clk, struct rgds_timespec *ts);
int nanosleep(const struct rgds_timespec *req, struct rgds_timespec *rem);
]]
local alLib
local function openal()
    if not alLib then alLib = ffi.load("libopenal.so.1") end
    return alLib
end
local F = {threads = {}, threadCpu = 0, meshUploads = 0}

function F.now()
    local ts = ffi.new("struct rgds_timespec")
    ffi.C.clock_gettime(1, ts)
    return tonumber(ts.tv_sec) + tonumber(ts.tv_nsec) * 1e-9
end
function F.realSleep(s)
    ffi.C.nanosleep(ffi.new("struct rgds_timespec", 0, s * 1e9), nil)
end
function F.defaultCaptureDevice()
    return ffi.string(openal().alcGetString(nil, 0x311))
end

local Data = {}
Data.__index = Data
function Data:getFFIPointer() return self.buf end
function Data:getSize() return self.size end
local function newByteData(n) return setmetatable({buf = ffi.new("uint8_t[?]", n), size = n}, Data) end

local Sound = setmetatable({}, {__index = Data})
Sound.__index = Sound
function Sound:getSampleCount() return self.n end
function Sound:getString() return ffi.string(self.buf, self.n * self.ch * 2) end
function Sound:release() end
local function newSoundData(n, rate, bits, ch)
    assert(bits == 16)
    return setmetatable({buf = ffi.new("int16_t[?]", n * ch), n = n, ch = ch, rate = rate}, Sound)
end

local Channel = {}
Channel.__index = Channel
function Channel:push(v) self.q[#self.q + 1] = v end
function Channel:pop() return table.remove(self.q, 1) end
function Channel:peek() return self.q[1] end
function Channel:clear() self.q = {} end
function Channel:performAtomic(fn, ...) return fn(self, ...) end
local channels = {}

local Dev = {}
Dev.__index = Dev
function Dev:start(samples, rate, bits, ch)
    if F.forceChannels and ch ~= F.forceChannels then return false end
    self.d = openal().alcCaptureOpenDevice(self.name, rate, ch == 2 and 0x1103 or 0x1101, samples)
    if self.d == nil then return false end
    openal().alcCaptureStart(self.d)
    self.rate, self.ch = rate, ch
    return true
end
function Dev:getData()
    local n = ffi.new("int[1]")
    openal().alcGetIntegerv(self.d, 0x312, 1, n)
    if n[0] == 0 then return nil end
    local sd = newSoundData(n[0], self.rate, 16, self.ch)
    openal().alcCaptureSamples(self.d, sd.buf, n[0])
    return sd
end
function Dev:isRecording() return self.d ~= nil end
function Dev:stop()
    if self.d ~= nil then openal().alcCaptureStop(self.d); openal().alcCaptureCloseDevice(self.d); self.d = nil end
end
function Dev:getName() return self.name end
function Dev:getSampleRate() return self.rate end

local function pack(_, fmt, ...)
    local args, parts, i = {...}, {}, 0
    for tok in fmt:gmatch("[cI]%d") do
        i = i + 1
        local kind, size = tok:sub(1, 1), tonumber(tok:sub(2))
        if kind == "c" then
            assert(#args[i] == size)
            parts[#parts + 1] = args[i]
        else
            local v, b = args[i], {}
            for k = 1, size do b[k] = string.char(v % 256); v = math.floor(v / 256) end
            parts[#parts + 1] = table.concat(b)
        end
    end
    return table.concat(parts)
end

local Thread = {}
Thread.__index = Thread
function Thread:start(...)
    local args = {...}
    local chunk = self.chunk
    self.co = coroutine.create(function() chunk(unpack(args)) end)
    F.threads[#F.threads + 1] = self
end
function Thread:getError() return self.err end
function Thread:step()
    if not self.co or coroutine.status(self.co) == "dead" then return false end
    local c0 = os.clock()
    local ok, err = coroutine.resume(self.co)
    F.threadCpu = F.threadCpu + os.clock() - c0
    if not ok then self.err = tostring(err) end
    return coroutine.status(self.co) ~= "dead"
end
function Thread:wait()
    while self:step() do F.realSleep(0.01) end
end
function F.stepThreads()
    for _, t in ipairs(F.threads) do t:step() end
end

local Mesh = {}
Mesh.__index = Mesh
function Mesh:setVertices(data)
    assert(data.size == self.n * 8, "vertex data size mismatch")
    F.meshUploads = F.meshUploads + 1
    F.lastVerts = ffi.cast("float *", data.buf)
end
function Mesh:setVertex() error("setVertex fallback should not be needed") end

function F.install(appdir, outdir)
    love = {
        timer = {getTime = F.now, sleep = function(s) coroutine.yield(s) end},
        data = {newByteData = newByteData, pack = pack},
        sound = {newSoundData = newSoundData},
        system = {getOS = function() return "Linux" end},
        thread = {
            getChannel = function(name)
                channels[name] = channels[name] or setmetatable({q = {}}, Channel)
                return channels[name]
            end,
            newThread = function(file)
                return setmetatable({chunk = assert(loadfile(appdir .. "/" .. file))}, Thread)
            end,
        },
        audio = {getRecordingDevices = function()
            return {setmetatable({name = F.defaultCaptureDevice()}, Dev)}
        end},
        filesystem = {
            write = function(name, s)
                local f = assert(io.open(outdir .. "/" .. name, "wb"))
                f:write(s); f:close()
                return true
            end,
            getSaveDirectory = function() return outdir end,
        },
        graphics = {
            newMesh = function(_, n) return setmetatable({n = n}, Mesh) end,
            draw = function() end,
        },
    }
    for _, m in ipairs({"timer", "data", "sound", "audio", "filesystem"}) do
        package.preload["love." .. m] = function() return love[m] end
    end
    package.path = appdir .. "/?.lua;" .. package.path
end

return F
