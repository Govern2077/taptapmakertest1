-- ============================================================================
-- BallCustomization.lua - Save/Load Ball Customization Data
-- Uses cjson + File API for local persistence
-- ============================================================================

local SkillRegistry = require("game.SkillRegistry")
local Expressions   = require("game.Expressions")

local BallCustomization = {}

local SAVE_FILE = "ball_custom.json"

-- ============================================================================
-- Default Customization
-- ============================================================================

function BallCustomization.GetDefault()
    return {
        color = { r = 66, g = 165, b = 245 },  -- default blue
        expression = nil,
        skills = {
            normal   = nil,  -- skill id or nil
            enhanced = nil,
            ultimate = nil,
        },
    }
end

-- ============================================================================
-- Randomize (for AI balls)
-- ============================================================================

local randomColors = {
    { r = 239, g = 83,  b = 80  },  -- red
    { r = 255, g = 167, b = 38  },  -- orange
    { r = 156, g = 39,  b = 176 },  -- purple
    { r = 76,  g = 175, b = 80  },  -- green
    { r = 255, g = 235, b = 59  },  -- yellow
    { r = 233, g = 30,  b = 99  },  -- pink
    { r = 0,   g = 188, b = 212 },  -- cyan
}

function BallCustomization.Randomize()
    -- Pick random color
    local color = randomColors[math.random(1, #randomColors)]

    -- Pick random expression
    local exprIdx = math.random(1, #Expressions.list)
    local expression = Expressions.list[exprIdx].id

    -- Pick random skills (one per tier, or none)
    local skills = {}
    for _, tier in ipairs({ "normal", "enhanced", "ultimate" }) do
        local tierSkills = SkillRegistry.GetByTier(tier)
        if #tierSkills > 0 and math.random() > 0.3 then
            skills[tier] = tierSkills[math.random(1, #tierSkills)].id
        else
            skills[tier] = nil
        end
    end

    return {
        color      = color,
        expression = expression,
        skills     = skills,
    }
end

-- ============================================================================
-- Save / Load
-- ============================================================================

function BallCustomization.Save(data)
    local json = cjson.encode(data)
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(json)
        file:Close()
        print("[BallCustomization] Saved to " .. SAVE_FILE)
        return true
    end
    print("[BallCustomization] ERROR: Failed to save")
    return false
end

function BallCustomization.Load()
    if not fileSystem:FileExists(SAVE_FILE) then
        print("[BallCustomization] No save file, using defaults")
        return BallCustomization.GetDefault()
    end

    local file = File(SAVE_FILE, FILE_READ)
    if not file:IsOpen() then
        return BallCustomization.GetDefault()
    end

    local str = file:ReadString()
    file:Close()

    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then
        print("[BallCustomization] ERROR: Failed to parse save file")
        return BallCustomization.GetDefault()
    end

    -- Validate and fill missing fields
    local defaults = BallCustomization.GetDefault()
    if type(data.color) ~= "table" then data.color = defaults.color end
    if type(data.expression) ~= "string" then data.expression = defaults.expression end
    if type(data.skills) ~= "table" then data.skills = defaults.skills end

    -- Validate skill ids
    for _, tier in ipairs({ "normal", "enhanced", "ultimate" }) do
        local sid = data.skills[tier]
        if sid and not SkillRegistry.Get(sid) then
            data.skills[tier] = nil
        end
    end

    return data
end

-- ============================================================================
-- Deep Copy utility
-- ============================================================================

function BallCustomization.DeepCopy(data)
    return {
        color = { r = data.color.r, g = data.color.g, b = data.color.b },
        expression = data.expression,
        skills = {
            normal   = data.skills.normal,
            enhanced = data.skills.enhanced,
            ultimate = data.skills.ultimate,
        },
    }
end

return BallCustomization
