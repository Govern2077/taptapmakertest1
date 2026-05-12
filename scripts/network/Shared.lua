-- ============================================================================
-- Shared.lua - Shared Code for Server and Client
-- ============================================================================

local Shared = {}
local Settings = require("config.Settings")

Shared.Settings = Settings
Shared.CTRL    = Settings.CTRL
Shared.EVENTS  = Settings.EVENTS
Shared.VARS    = Settings.VARS

-- ============================================================================
-- Utility Functions
-- ============================================================================

function Shared.Clamp(value, min, max)
    if value < min then return min end
    if value > max then return max end
    return value
end

--- Convert 2D game coordinates to 3D node position
--- @param x number 2D x
--- @param y number 2D y
--- @return Vector3
function Shared.To3D(x, y)
    return Vector3(x, 0, y)
end

--- Convert 3D node position back to 2D game coordinates
--- @param pos Vector3
--- @return number x, number y
function Shared.To2D(pos)
    return pos.x, pos.z
end

--- Distance between two 2D points
function Shared.Dist2D(x1, y1, x2, y2)
    local dx = x2 - x1
    local dy = y2 - y1
    return math.sqrt(dx * dx + dy * dy)
end

--- Normalize a 2D vector, returns (0,0) if length is 0
function Shared.Normalize2D(x, y)
    local len = math.sqrt(x * x + y * y)
    if len < 0.0001 then return 0, 0 end
    return x / len, y / len
end

--- Get spawn position for a ball by team (1 or 2)
function Shared.GetSpawnPos(team)
    local sp = Settings.SpawnPoints[team]
    if sp then return sp.x, sp.y end
    return 0, 0
end

-- ============================================================================
-- Register Remote Events
-- ============================================================================

function Shared.RegisterEvents()
    for _, eventName in pairs(Settings.EVENTS) do
        network:RegisterRemoteEvent(eventName)
    end
end

return Shared
