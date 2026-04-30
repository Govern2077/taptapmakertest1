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
-- Determine which tier is active based on current HP
-- ============================================================================

function BallAI.GetActiveTier(hp)
    local tiers = Settings.Tiers
    if hp > tiers.normal.min then return "normal" end
    if hp > tiers.enhanced.min then return "enhanced" end
    return "ultimate"
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
