-- ============================================================================
-- BallAI.lua - Ball AI Behavior Module (Movement + Shooting)
-- AI controls both movement and skill firing
-- ============================================================================

local Settings = require("config.Settings")

local BallAI = {}

-- ============================================================================
-- AI State per ball
-- ============================================================================

function BallAI.CreateState()
    return {
        fireDelay = 0,       -- delay before next shot
        moveTimer = 0,       -- time until next movement decision
        moveAngle = 0,       -- current wander angle
        strafeDir = 1,       -- 1 or -1, strafe direction
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

--- Returns all available tiers (all tiers always available regardless of HP)
---@param hp number
---@return string[]
function BallAI.GetAvailableTiers(hp)
    return { "ultimate", "enhanced", "normal" }
end

--- Returns the highest priority active tier (for display/aura purposes)
---@param hp number
---@return string
function BallAI.GetActiveTier(hp)
    return "ultimate"
end

-- ============================================================================
-- Movement AI: chase / strafe / dodge / wall avoidance
-- Returns desired velocity (moveVX, moveVY)
-- ============================================================================

function BallAI.ComputeMovement(state, self, opponent, dt)
    local arenaSize = Settings.Arena.Size
    local prefDist = Settings.AI.PreferredDistance
    local ballR = Settings.Ball.Radius
    local speed = Settings.Ball.Speed

    -- Direction toward opponent
    local dx = opponent.x - self.x
    local dy = opponent.y - self.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then dist = 1 end
    local nx, ny = dx / dist, dy / dist

    -- Perpendicular (strafe direction)
    local px, py = -ny * state.strafeDir, nx * state.strafeDir

    -- Decide movement blend
    local moveX, moveY = 0, 0

    if dist > prefDist + 30 then
        -- Too far: chase opponent
        moveX = nx * 0.7 + px * 0.3
        moveY = ny * 0.7 + py * 0.3
    elseif dist < prefDist - 50 then
        -- Too close: back away + strafe
        moveX = -nx * 0.5 + px * 0.5
        moveY = -ny * 0.5 + py * 0.5
    else
        -- Good range: strafe around opponent
        moveX = px * 0.8 + nx * 0.1
        moveY = py * 0.8 + ny * 0.1
    end

    -- Wall avoidance: push away from edges
    local wallMargin = 40
    if self.x < wallMargin then moveX = moveX + (wallMargin - self.x) / wallMargin end
    if self.x > arenaSize - wallMargin then moveX = moveX - (self.x - (arenaSize - wallMargin)) / wallMargin end
    if self.y < wallMargin then moveY = moveY + (wallMargin - self.y) / wallMargin end
    if self.y > arenaSize - wallMargin then moveY = moveY - (self.y - (arenaSize - wallMargin)) / wallMargin end

    -- Normalize and apply speed
    local len = math.sqrt(moveX * moveX + moveY * moveY)
    if len > 0.01 then
        moveX = moveX / len * speed
        moveY = moveY / len * speed
    end

    -- Periodically change strafe direction
    state.moveTimer = state.moveTimer - dt
    if state.moveTimer <= 0 then
        state.strafeDir = (math.random() > 0.5) and 1 or -1
        state.moveTimer = 1.0 + math.random() * 2.0
    end

    return moveX, moveY
end

-- ============================================================================
-- Full AI tick: returns shoot flag + aim direction + movement velocity
-- ============================================================================

function BallAI.Update(state, self, opponent, cooldown, projectileSpeed, dt)
    local shouldShoot = BallAI.ShouldShoot(state, cooldown, dt)
    local aimX, aimY = BallAI.GetAimDirection(self, opponent, projectileSpeed)
    local moveVX, moveVY = BallAI.ComputeMovement(state, self, opponent, dt)

    return {
        shoot = shouldShoot,
        aimX = aimX,
        aimY = aimY,
        moveVX = moveVX,
        moveVY = moveVY,
    }
end

return BallAI
