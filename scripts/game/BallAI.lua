-- ============================================================================
-- BallAI.lua - Ball AI Behavior Module (Shooting Only)
-- Movement is pure physics (no AI control), AI only controls skill firing
-- ============================================================================

local Settings = require("config.Settings")

local BallAI = {}

-- ============================================================================
-- AI State per ball
-- ============================================================================

function BallAI.CreateState()
    return {
        fireDelay = 0,  -- delay before next shot
    }
end

-- ============================================================================
-- Auto-aim: compute direction toward opponent with lead prediction
-- ============================================================================

function BallAI.GetAimDirection(self, opponent, projectileSpeed)
    local dx = opponent.x - self.x
    local dy = opponent.y - self.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return 1, 0 end

    -- Lead prediction
    if projectileSpeed > 0 then
        local tof = dist / projectileSpeed
        local lead = Settings.AI.AimLeadFactor
        dx = dx + (opponent.vx or 0) * tof * lead
        dy = dy + (opponent.vy or 0) * tof * lead
        dist = math.sqrt(dx * dx + dy * dy)
        if dist < 1 then return 1, 0 end
    end

    return dx / dist, dy / dist
end

-- ============================================================================
-- Shooting decision: returns true if AI should fire this frame
-- ============================================================================

function BallAI.ShouldShoot(state, cooldown, dt)
    if cooldown > 0 then
        state.fireDelay = 0
        return false
    end

    if state.fireDelay <= 0 then
        state.fireDelay = Settings.AI.ShootRandomDelay + math.random() * 1.2
    end

    state.fireDelay = state.fireDelay - dt
    if state.fireDelay <= 0 then
        return true
    end

    return false
end

-- ============================================================================
-- Determine available tiers based on current HP
-- New: multiple tiers can be active simultaneously
-- normal: all HP, enhanced: HP <= 60, ultimate: HP <= 30
-- ============================================================================

--- Returns all available tiers for given HP (highest priority first)
---@param hp number
---@return string[]
function BallAI.GetAvailableTiers(hp)
    local tiers = Settings.Tiers
    local available = {}
    -- Check from highest priority to lowest
    if hp <= tiers.ultimate.max then table.insert(available, "ultimate") end
    if hp <= tiers.enhanced.max then table.insert(available, "enhanced") end
    if hp <= tiers.normal.max then table.insert(available, "normal") end
    return available
end

--- Returns the highest priority active tier (for display/aura purposes)
---@param hp number
---@return string
function BallAI.GetActiveTier(hp)
    local tiers = Settings.Tiers
    if hp <= tiers.ultimate.max then return "ultimate" end
    if hp <= tiers.enhanced.max then return "enhanced" end
    return "normal"
end

-- ============================================================================
-- Full AI tick: returns shoot flag + aim direction
-- No movement output (pure physics handles movement)
-- ============================================================================

function BallAI.Update(state, self, opponent, cooldown, projectileSpeed, dt)
    local shouldShoot = BallAI.ShouldShoot(state, cooldown, dt)
    local aimX, aimY = BallAI.GetAimDirection(self, opponent, projectileSpeed)

    return {
        shoot = shouldShoot,
        aimX = aimX,
        aimY = aimY,
    }
end

return BallAI
