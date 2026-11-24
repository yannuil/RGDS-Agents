local M = {}

function M.plan(displayCount)
    local menuSdl = nil
    local agentsSdl = 0
    local openSecondWindow = true
    if displayCount and displayCount >= 2 then
        menuSdl = 0
        agentsSdl = 1
        openSecondWindow = false
    end
    return {
        menuSdl = menuSdl,
        agentsSdl = agentsSdl,
        loveDisplay = agentsSdl + 1,
        openSecondWindow = openSecondWindow,
    }
end

return M
