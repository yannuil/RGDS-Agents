local script = arg[0]
local slash = script:match("^.*()/")
local root = slash and (script:sub(1, slash) .. "..") or ".."
package.path = root .. "/?.lua;" .. package.path

local screens = require("screens")

local function check(count, menuSdl, agentsSdl, loveDisplay, openSecondWindow)
    local plan = screens.plan(count)
    local label = tostring(count)
    local function eq(got, want, field)
        if got ~= want then
            io.stderr:write(string.format(
                "count %s %s: got %s want %s\n",
                label, field, tostring(got), tostring(want)))
            os.exit(1)
        end
    end
    eq(plan.menuSdl, menuSdl, "menuSdl")
    eq(plan.agentsSdl, agentsSdl, "agentsSdl")
    eq(plan.loveDisplay, loveDisplay, "loveDisplay")
    eq(plan.openSecondWindow, openSecondWindow, "openSecondWindow")
end

check(0, nil, 0, 1, true)
check(1, nil, 0, 1, true)
check(nil, nil, 0, 1, true)
check(2, 0, 1, 2, false)
check(4, 0, 1, 2, false)

print("screens plan ok")
os.exit(0)
