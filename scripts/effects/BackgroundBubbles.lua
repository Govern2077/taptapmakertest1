-- ============================================================================
-- BackgroundBubbles.lua - 背景大圆气泡效果
-- 几个缓慢移动、相互碰撞的大圆，颜色比背景略浅
-- ============================================================================

local BackgroundBubbles = {}

-- ============================================================================
-- Config
-- ============================================================================

local BUBBLE_COUNT   = 5
local MIN_RADIUS_PCT = 0.15   -- 占屏幕高度的百分比
local MAX_RADIUS_PCT = 0.38
local SPEED_MIN      = 8
local SPEED_MAX      = 25
local BASE_ALPHA     = 30     -- 半透明叠加在背景上
local BOUNCE         = 0.9    -- 碰撞弹性系数

-- ============================================================================
-- State
-- ============================================================================

local bubbles_ = {}
local inited_  = false
local lastW_   = 0
local lastH_   = 0

-- ============================================================================
-- Init / Reinit
-- ============================================================================

function BackgroundBubbles.Init(w, h)
    bubbles_ = {}
    lastW_ = w
    lastH_ = h

    for i = 1, BUBBLE_COUNT do
        local rPct = MIN_RADIUS_PCT + math.random() * (MAX_RADIUS_PCT - MIN_RADIUS_PCT)
        local radius = h * rPct
        local angle = math.random() * 2 * math.pi
        local speed = SPEED_MIN + math.random() * (SPEED_MAX - SPEED_MIN)

        -- Slight color variation per bubble (lighter gray tones)
        local shade = 40 + math.random(0, 20)

        bubbles_[i] = {
            x  = radius + math.random() * (w - radius * 2),
            y  = radius + math.random() * (h - radius * 2),
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            radius = radius,
            shade  = shade,
        }
    end

    inited_ = true
end

-- ============================================================================
-- Update
-- ============================================================================

function BackgroundBubbles.Update(dt, w, h)
    if not inited_ then
        BackgroundBubbles.Init(w, h)
        return
    end

    -- Reinit if screen size changed significantly
    if math.abs(w - lastW_) > 10 or math.abs(h - lastH_) > 10 then
        BackgroundBubbles.Init(w, h)
        return
    end

    for _, b in ipairs(bubbles_) do
        b.x = b.x + b.vx * dt
        b.y = b.y + b.vy * dt

        -- Wall bounce
        if b.x - b.radius < 0 then
            b.x = b.radius
            b.vx = math.abs(b.vx) * BOUNCE
        elseif b.x + b.radius > w then
            b.x = w - b.radius
            b.vx = -math.abs(b.vx) * BOUNCE
        end
        if b.y - b.radius < 0 then
            b.y = b.radius
            b.vy = math.abs(b.vy) * BOUNCE
        elseif b.y + b.radius > h then
            b.y = h - b.radius
            b.vy = -math.abs(b.vy) * BOUNCE
        end
    end

    -- Bubble-bubble collision (elastic)
    for i = 1, BUBBLE_COUNT do
        for j = i + 1, BUBBLE_COUNT do
            local a = bubbles_[i]
            local b = bubbles_[j]
            local dx = b.x - a.x
            local dy = b.y - a.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local minDist = a.radius + b.radius

            if dist < minDist and dist > 0.1 then
                local nx, ny = dx / dist, dy / dist
                -- Separate overlap
                local overlap = minDist - dist
                a.x = a.x - nx * overlap * 0.5
                a.y = a.y - ny * overlap * 0.5
                b.x = b.x + nx * overlap * 0.5
                b.y = b.y + ny * overlap * 0.5

                -- Elastic velocity exchange (equal mass)
                local dvx = a.vx - b.vx
                local dvy = a.vy - b.vy
                local dvn = dvx * nx + dvy * ny
                if dvn > 0 then
                    a.vx = a.vx - dvn * nx * BOUNCE
                    a.vy = a.vy - dvn * ny * BOUNCE
                    b.vx = b.vx + dvn * nx * BOUNCE
                    b.vy = b.vy + dvn * ny * BOUNCE
                end
            end
        end
    end
end

-- ============================================================================
-- Draw (call after filling background, before any foreground)
-- ============================================================================

function BackgroundBubbles.Draw(vg)
    if not inited_ then return end

    for _, b in ipairs(bubbles_) do
        nvgBeginPath(vg)
        nvgCircle(vg, b.x, b.y, b.radius)
        nvgFillColor(vg, nvgRGBA(b.shade, b.shade, b.shade + 4, BASE_ALPHA))
        nvgFill(vg)
    end
end

return BackgroundBubbles
