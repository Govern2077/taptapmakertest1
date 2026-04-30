-- ============================================================================
-- ItemSystem.lua - 道具系统（蜘蛛网、带刺木桩、微型黑洞）
-- 道具放置在竞技场中，对场内球体产生区域效果
-- ============================================================================

local Settings = require("config.Settings")
local BALL = Settings.Ball

local ItemSystem = {}

-- ============================================================================
-- 道具定义
-- ============================================================================

ItemSystem.DEFS = {
    {
        id       = "spider_web",
        name     = "蜘蛛网",
        emoji    = "🕸️",
        desc     = "降低范围内速度",
        cooldown = 10,
        radius   = 55,
        slowFactor = 0.35,   -- speed multiplier while inside
        hp       = 1,        -- broken when hit once
    },
    {
        id       = "thorny_stake",
        name     = "带刺木桩",
        emoji    = "🌵",
        desc     = "碰撞反弹+伤害",
        cooldown = 10,
        radius   = 30,
        damage   = 8,
        hp       = 3,        -- takes 3 hits before breaking
    },
    {
        id       = "micro_blackhole",
        name     = "黑洞",
        emoji    = "🌀",
        desc     = "吸引双方球体",
        cooldown = 10,
        radius   = 70,
        duration = 5,
        pullForce = 180,     -- acceleration toward center
        pushForce = 350,     -- push away at end
    },
}

-- ============================================================================
-- State
-- ============================================================================

local placed_ = {}       -- active placed items on the arena
local cooldowns_ = { 0, 0, 0 }  -- per-slot cooldown timers
local SLOT_COUNT = 3

-- ============================================================================
-- API
-- ============================================================================

function ItemSystem.Init()
    placed_ = {}
    cooldowns_ = { 0, 0, 0 }
end

function ItemSystem.GetSlotCount()
    return SLOT_COUNT
end

function ItemSystem.GetDef(slot)
    return ItemSystem.DEFS[slot]
end

function ItemSystem.GetCooldown(slot)
    return cooldowns_[slot] or 0
end

function ItemSystem.IsReady(slot)
    return (cooldowns_[slot] or 0) <= 0
end

--- Place an item at arena-local position (ax, ay)
function ItemSystem.Place(slot, ax, ay)
    local def = ItemSystem.DEFS[slot]
    if not def then return false end
    if not ItemSystem.IsReady(slot) then return false end

    local item = {
        defId    = def.id,
        slot     = slot,
        x        = ax,
        y        = ay,
        radius   = def.radius,
        hp       = def.hp or 999,
        elapsed  = 0,
        duration = def.duration or 999,
        alive    = true,
    }

    -- Type-specific fields
    if def.id == "spider_web" then
        item.slowFactor = def.slowFactor
    elseif def.id == "thorny_stake" then
        item.damage = def.damage
    elseif def.id == "micro_blackhole" then
        item.pullForce = def.pullForce
        item.pushForce = def.pushForce
        item.pushed = false
    end

    table.insert(placed_, item)
    cooldowns_[slot] = def.cooldown
    return true
end

--- Update all placed items + apply effects to balls
function ItemSystem.Update(dt, balls)
    -- Update cooldowns
    for i = 1, SLOT_COUNT do
        if cooldowns_[i] > 0 then
            cooldowns_[i] = cooldowns_[i] - dt
            if cooldowns_[i] < 0 then cooldowns_[i] = 0 end
        end
    end

    local size = Settings.Arena.Size
    local i = 1
    while i <= #placed_ do
        local item = placed_[i]
        item.elapsed = item.elapsed + dt

        if not item.alive or item.elapsed >= item.duration then
            -- End-of-life push for black hole
            if item.defId == "micro_blackhole" and not item.pushed then
                item.pushed = true
                for team = 1, 2 do
                    local b = balls[team]
                    if b then
                        local dx, dy = b.x - item.x, b.y - item.y
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d < 1 then d = 1 end
                        local pushF = item.pushForce or 350
                        b.vx = b.vx + (dx / d) * pushF
                        b.vy = b.vy + (dy / d) * pushF
                    end
                end
            end
            table.remove(placed_, i)
        else
            -- Apply per-type effects
            if item.defId == "spider_web" then
                ItemSystem._UpdateSpiderWeb(item, balls, dt)
            elseif item.defId == "thorny_stake" then
                ItemSystem._UpdateThornyStake(item, balls, dt)
            elseif item.defId == "micro_blackhole" then
                ItemSystem._UpdateBlackHole(item, balls, dt)
            end
            i = i + 1
        end
    end
end

function ItemSystem._UpdateSpiderWeb(item, balls, dt)
    for team = 1, 2 do
        local b = balls[team]
        if not b then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < item.radius + BALL.Radius then
            -- Slow the ball while inside
            local spd = math.sqrt(b.vx * b.vx + b.vy * b.vy)
            local maxSpd = BALL.Speed * item.slowFactor
            if spd > maxSpd then
                local scale = maxSpd / spd
                b.vx = b.vx * scale
                b.vy = b.vy * scale
            end
            -- Check collision with center (break on hit)
            if d < item.radius * 0.5 then
                item.hp = item.hp - 1
                -- Restore speed on break
                if item.hp <= 0 then
                    item.alive = false
                end
            end
        end
        ::continue::
    end
end

function ItemSystem._UpdateThornyStake(item, balls, dt)
    for team = 1, 2 do
        local b = balls[team]
        if not b then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        local hitDist = item.radius + BALL.Radius
        if d < hitDist and d > 1 then
            -- Bounce the ball away (treat as wall)
            local nx, ny = dx / d, dy / d
            -- Push out of overlap
            b.x = item.x + nx * hitDist
            b.y = item.y + ny * hitDist
            -- Reflect velocity
            local dot = b.vx * nx + b.vy * ny
            if dot < 0 then  -- only bounce if moving toward stake
                b.vx = b.vx - 2 * dot * nx
                b.vy = b.vy - 2 * dot * ny
                -- Apply damage
                b.hp = b.hp - item.damage
                if b.hp < 0 then b.hp = 0 end
                item.hp = item.hp - 1
                if item.hp <= 0 then
                    item.alive = false
                end
            end
        end
        ::continue::
    end
end

function ItemSystem._UpdateBlackHole(item, balls, dt)
    for team = 1, 2 do
        local b = balls[team]
        if not b then goto continue end
        local dx, dy = item.x - b.x, item.y - b.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < 1 then d = 1 end
        -- Attract toward center
        local force = item.pullForce or 180
        -- Stronger when closer
        local strength = force * math.min(1.0, (item.radius * 2) / d)
        b.vx = b.vx + (dx / d) * strength * dt
        b.vy = b.vy + (dy / d) * strength * dt
        ::continue::
    end
end

--- Draw all placed items
function ItemSystem.Draw(vg, arenaX, arenaY, fontId)
    for _, item in ipairs(placed_) do
        local cx, cy = arenaX + item.x, arenaY + item.y
        local r = item.radius
        local life = 1 - item.elapsed / item.duration

        if item.defId == "spider_web" then
            -- Web circle with radial lines
            local alpha = math.floor(160 * math.min(1, life * 3))
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, r * 0.2, r,
                nvgRGBA(200, 200, 200, math.floor(alpha * 0.3)),
                nvgRGBA(200, 200, 200, 0)))
            nvgFill(vg)
            -- Web lines
            nvgStrokeColor(vg, nvgRGBA(220, 220, 220, alpha))
            nvgStrokeWidth(vg, 1)
            for a = 0, 5 do
                local angle = a * math.pi / 3
                nvgBeginPath(vg)
                nvgMoveTo(vg, cx, cy)
                nvgLineTo(vg, cx + math.cos(angle) * r, cy + math.sin(angle) * r)
                nvgStroke(vg)
            end
            -- Concentric circles
            for ri = 1, 3 do
                nvgBeginPath(vg); nvgCircle(vg, cx, cy, r * ri / 3)
                nvgStrokeColor(vg, nvgRGBA(220, 220, 220, math.floor(alpha * 0.6)))
                nvgStrokeWidth(vg, 0.8)
                nvgStroke(vg)
            end
            -- HP indicator
            if item.hp > 0 and fontId >= 0 then
                nvgFontFaceId(vg, fontId)
                nvgFontSize(vg, 14)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
                nvgText(vg, cx, cy, "🕸️", nil)
            end

        elseif item.defId == "thorny_stake" then
            -- Spiky circle
            local alpha = math.floor(200 * math.min(1, life * 3))
            local spikeCount = 10
            -- Base circle
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
            nvgFillColor(vg, nvgRGBA(100, 60, 30, math.floor(alpha * 0.6))); nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(180, 120, 60, alpha)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
            -- Spikes
            for s = 0, spikeCount - 1 do
                local angle = s * 2 * math.pi / spikeCount + item.elapsed * 0.5
                local innerR = r * 0.7
                local outerR = r * 1.3
                nvgBeginPath(vg)
                nvgMoveTo(vg, cx + math.cos(angle - 0.15) * innerR, cy + math.sin(angle - 0.15) * innerR)
                nvgLineTo(vg, cx + math.cos(angle) * outerR, cy + math.sin(angle) * outerR)
                nvgLineTo(vg, cx + math.cos(angle + 0.15) * innerR, cy + math.sin(angle + 0.15) * innerR)
                nvgFillColor(vg, nvgRGBA(160, 100, 40, alpha)); nvgFill(vg)
            end
            -- HP text
            if fontId >= 0 then
                nvgFontFaceId(vg, fontId)
                nvgFontSize(vg, 12)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
                nvgText(vg, cx, cy, tostring(item.hp), nil)
            end

        elseif item.defId == "micro_blackhole" then
            -- Swirling vortex
            local alpha = math.floor(220 * math.min(1, life * 3))
            local pulse = 1.0 + 0.08 * math.sin(item.elapsed * 4)
            local pr = r * pulse
            -- Outer glow
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, pr)
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, pr * 0.1, pr,
                nvgRGBA(80, 0, 160, alpha),
                nvgRGBA(20, 0, 60, 0)))
            nvgFill(vg)
            -- Swirl arcs
            nvgStrokeWidth(vg, 2)
            for a = 0, 3 do
                local baseAngle = a * math.pi / 2 + item.elapsed * 3
                nvgBeginPath(vg)
                nvgArc(vg, cx, cy, pr * 0.5, baseAngle, baseAngle + math.pi * 0.6, NVG_CW)
                nvgStrokeColor(vg, nvgRGBA(160, 80, 255, math.floor(alpha * 0.6)))
                nvgStroke(vg)
            end
            -- Core
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, pr * 0.15)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, alpha)); nvgFill(vg)
            -- Timer ring
            if item.duration < 900 then
                local pct = 1 - item.elapsed / item.duration
                nvgBeginPath(vg)
                nvgArc(vg, cx, cy, pr * 0.75, -math.pi / 2, -math.pi / 2 + pct * 2 * math.pi, NVG_CW)
                nvgStrokeColor(vg, nvgRGBA(200, 120, 255, math.floor(alpha * 0.5)))
                nvgStrokeWidth(vg, 2)
                nvgStroke(vg)
            end
        end
    end
end

function ItemSystem.GetPlaced()
    return placed_
end

function ItemSystem.Clear()
    placed_ = {}
    cooldowns_ = { 0, 0, 0 }
end

return ItemSystem
