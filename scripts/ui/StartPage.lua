-- ============================================================================
-- StartPage.lua - Game start page with title logo + showcase balls
-- Layout strictly matches reference screenshot proportions
-- Uses TriangleFill module for reusable triangle rendering
-- ============================================================================

local UI = require("urhox-libs/UI")
local Expressions = require("game.Expressions")
local TriangleFill = require("effects.TriangleFill")
local TriangleButton = require("ui.TriangleButton")

local StartPage = {}

-- ============================================================================
-- State
-- ============================================================================

local active_ = false
local elapsedTime_ = 0

-- Per-ball TriangleFill instances
local ballFills_ = {}

-- Title logo image
local titleImage_ = -1
local titleImgW_  = 1379   -- actual image width (fixed, not queried at runtime)
local titleImgH_  = 724    -- actual image height

-- Screen dimensions (design coords)
local screenW_ = 1920
local screenH_ = 1080

-- ============================================================================
-- Configuration — all proportions derived from reference screenshot
-- ============================================================================

-- Background color (used for masking)
local BG_R, BG_G, BG_B = 10, 10, 20

-- Logo proportions (percentage of screen)
local LOGO_TOP       = 0.04       -- top edge at 4% of screen height
local LOGO_MAX_W     = 0.496      -- max width: 0.62 * 0.8 = 49.6%
local LOGO_MAX_H     = 0.384      -- max height: 0.48 * 0.8 = 38.4%

-- Ball proportions (percentage of screen)
local BALL_RADIUS_PCT = 0.104     -- radius: 10.4% of screen height
local BALL_Y_PCT      = 0.63      -- center Y: moved up from 0.69
local BALL_OFFSET_PCT = 0.103     -- center offset from mid-X: 10.3% of screen width

-- Ball definitions
local BALL_DEFS = {
    { color = { 255, 120, 40 },  expression = "angry",  bobPhase = 0 },
    { color = { 60, 200, 255 },  expression = "crying", bobPhase = math.pi },
}

-- ============================================================================
-- Update (called from Standalone HandleUpdate)
-- ============================================================================

function StartPage.Update(dt)
    if not active_ then return end
    elapsedTime_ = elapsedTime_ + dt

    for bi = 1, 2 do
        if ballFills_[bi] then
            ballFills_[bi]:Update(dt)
        end
    end
end

-- ============================================================================
-- Render (called from Standalone HandleNanoVGRender)
-- ============================================================================

---@param vg userdata NanoVG context
---@param w number screen width (design coords)
---@param h number screen height (design coords)
---@param fontId number font face id
function StartPage.Render(vg, w, h, fontId)
    if not active_ then return end
    screenW_ = w
    screenH_ = h

    -- Lazy-load title logo (once per vg context)
    if titleImage_ < 0 then
        titleImage_ = nvgCreateImage(vg, "image/title_logo.png", 0)
    end

    -- Compute proportional sizes from screen dimensions
    local cx = w / 2
    local ballRadius = h * BALL_RADIUS_PCT
    local ballY = h * BALL_Y_PCT
    local ballOffsetX = w * BALL_OFFSET_PCT

    -- Ball positions with gentle bob animation
    local bobAmp   = 6
    local bobSpeed = 2.0
    local positions = {}
    for bi = 1, 2 do
        local bx = (bi == 1) and (cx - ballOffsetX) or (cx + ballOffsetX)
        local by = ballY + math.sin(elapsedTime_ * bobSpeed + BALL_DEFS[bi].bobPhase) * bobAmp
        positions[bi] = { x = bx, y = by }
    end

    -- 1. Dark background
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(BG_R, BG_G, BG_B, 255))
    nvgFill(vg)

    -- 2. Ball base color fills
    for bi = 1, 2 do
        local pos = positions[bi]
        local c   = BALL_DEFS[bi].color
        nvgBeginPath(vg)
        nvgCircle(vg, pos.x, pos.y, ballRadius)
        nvgFillColor(vg, nvgRGBA(c[1], c[2], c[3], 255))
        nvgFill(vg)
    end

    -- 3. Triangles inside both balls (via TriangleFill)
    for bi = 1, 2 do
        if ballFills_[bi] then
            ballFills_[bi]:RenderCircle(vg, positions[bi].x, positions[bi].y, ballRadius)
        end
    end

    -- 4. Mask: full-screen rect with two circle holes → clips triangle overflow
    TriangleFill.MaskCircles(vg, w, h,
        {
            { x = positions[1].x, y = positions[1].y, radius = ballRadius },
            { x = positions[2].x, y = positions[2].y, radius = ballRadius },
        },
        BG_R, BG_G, BG_B)

    -- 5. Expressions (follow mouse gaze)
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local mouseDesignX = input.mousePosition.x * w / physW
    local mouseDesignY = input.mousePosition.y * h / physH
    local maxShift = ballRadius * 0.12

    for bi = 1, 2 do
        local pos = positions[bi]
        local dx = mouseDesignX - pos.x
        local dy = mouseDesignY - pos.y
        local dist = math.sqrt(dx * dx + dy * dy)
        local shiftX, shiftY = 0, 0
        if dist > 1 then
            local normX, normY = dx / dist, dy / dist
            local factor = math.min(1, dist / (ballRadius * 3))
            shiftX = normX * maxShift * factor
            shiftY = normY * maxShift * factor
        end
        Expressions.Draw(vg, BALL_DEFS[bi].expression, pos.x + shiftX, pos.y + shiftY, ballRadius)
    end

    -- 6. Title logo image (aspect-ratio preserved)
    if titleImage_ >= 0 and titleImgW_ > 0 and titleImgH_ > 0 then
        local imgAspect = titleImgW_ / titleImgH_
        local maxW = w * LOGO_MAX_W
        local maxH = h * LOGO_MAX_H
        local logoW = maxW
        local logoH = logoW / imgAspect
        if logoH > maxH then
            logoH = maxH
            logoW = logoH * imgAspect
        end
        -- Horizontal stretch to 150%
        logoW = logoW * 1.5
        local logoX = cx - logoW / 2
        local logoY = h * LOGO_TOP

        local imgPaint = nvgImagePattern(vg, logoX, logoY, logoW, logoH, 0, titleImage_, 1)
        nvgBeginPath(vg)
        nvgRect(vg, logoX, logoY, logoW, logoH)
        nvgFillPaint(vg, imgPaint)
        nvgFill(vg)
    end
end

-- ============================================================================
-- Show (creates UI overlay with interactive buttons)
-- ============================================================================

---@param callbacks table { onBattle: function, onMultiplayer: function, onCultivation: function, onBattleRoyale: function }
function StartPage.Show(callbacks)
    active_ = true
    elapsedTime_ = 0

    -- Create per-ball TriangleFill instances (size proportional to ball radius)
    for bi = 1, 2 do
        local c = BALL_DEFS[bi].color
        ballFills_[bi] = TriangleFill.new({
            maxTriangles = 80,
            spawnRate    = 160,
            triLife      = 0.5,
            maxAlpha     = 128,
            sizeMin      = 30,
            sizeMax      = 110,
            colorOffset  = 30,
            baseColor    = { c[1], c[2], c[3] },
        })
    end

    -- UI overlay: three buttons in a horizontal row at the bottom
    local root = UI.Panel {
        width = "100%", height = "100%",
        justifyContent = "flex-end",
        alignItems = "center",
        paddingBottom = 120,
        children = {
            UI.Panel {
                flexDirection = "row",
                gap = 40,
                children = {
                    TriangleButton {
                        text = "联机对战",
                        variant = "outline",
                        width = 200, height = 52,
                        fontSize = 18,
                        onClick = function()
                            if callbacks and callbacks.onMultiplayer then
                                callbacks.onMultiplayer()
                            end
                        end,
                    },
                    TriangleButton {
                        text = "AI模拟",
                        variant = "primary",
                        width = 200, height = 52,
                        fontSize = 18,
                        onClick = function()
                            active_ = false
                            if callbacks and callbacks.onBattle then
                                callbacks.onBattle()
                            end
                        end,
                    },
                    TriangleButton {
                        text = "球球养成",
                        variant = "outline",
                        width = 200, height = 52,
                        fontSize = 18,
                        onClick = function()
                            active_ = false
                            if callbacks and callbacks.onCultivation then
                                callbacks.onCultivation()
                            end
                        end,
                    },
                    TriangleButton {
                        text = "吃鸡大战",
                        variant = "primary",
                        width = 200, height = 52,
                        fontSize = 18,
                        onClick = function()
                            active_ = false
                            if callbacks and callbacks.onBattleRoyale then
                                callbacks.onBattleRoyale()
                            end
                        end,
                    },
                },
            },
        },
    }
    UI.SetRoot(root)
end

-- ============================================================================
-- Hide
-- ============================================================================

function StartPage.Hide()
    active_ = false
    -- Reset image handle; vg context may be destroyed and recreated
    titleImage_ = -1
end

return StartPage
