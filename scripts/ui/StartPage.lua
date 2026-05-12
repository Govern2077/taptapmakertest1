-- ============================================================================
-- StartPage.lua - Game start page with title logo + showcase balls
-- Layout strictly matches reference screenshot proportions
-- Uses TriangleFill module for reusable triangle rendering
-- ============================================================================

local UI = require("urhox-libs/UI")
local Expressions = require("game.Expressions")
local TriangleFill = require("effects.TriangleFill")
local TriangleButton = require("ui.TriangleButton")
local BreedingPage = require("ui.BreedingPage")

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

-- Profile panel data (loaded on Show)
local profileData_ = nil   -- { bestBall, bestStreak, gold, ballCount }
local playerId_ = ""       -- player ID string

-- Level color table (mirrored from BreedingPage for display)
local LEVEL_BASE_COLORS = {
    [1] = { r = 230, g = 230, b = 235 },  -- White
    [2] = { r = 80,  g = 210, b = 100 },  -- Green
    [3] = { r = 70,  g = 150, b = 255 },  -- Blue
    [4] = { r = 170, g = 80,  b = 230 },  -- Purple
    [5] = { r = 255, g = 160, b = 40  },  -- Orange
    [6] = { r = 240, g = 60,  b = 60  },  -- Red
    [7] = { r = 255, g = 255, b = 255 },  -- Rainbow
}
local GRADE_NAMES = { "白", "绿", "蓝", "紫", "橙", "红", "彩虹" }

local function GetColorGrade(level)
    return ((level - 1) % 7) + 1
end

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
-- Profile Panel Rendering (top-left)
-- ============================================================================

local function RenderProfileBall(vg, cx, cy, radius, ball)
    if not ball then return end
    local c = ball.color
    if not c then
        local grade = GetColorGrade(ball.level or 1)
        c = LEVEL_BASE_COLORS[grade]
    end
    local r = c.r or 200
    local g = c.g or 200
    local b = c.b or 200

    -- Ball body with gradient
    local innerColor = nvgRGBA(math.min(255, r + 40), math.min(255, g + 40), math.min(255, b + 40), 255)
    local outerColor = nvgRGBA(math.max(0, r - 30), math.max(0, g - 30), math.max(0, b - 30), 255)
    local grad = nvgRadialGradient(vg, cx - radius * 0.2, cy - radius * 0.25, radius * 0.1, radius * 1.0, innerColor, outerColor)
    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgFillPaint(vg, grad)
    nvgFill(vg)

    -- Highlight
    nvgBeginPath(vg)
    nvgCircle(vg, cx - radius * 0.2, cy - radius * 0.25, radius * 0.3)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 60))
    nvgFill(vg)

    -- Expression
    Expressions.Draw(vg, ball.expression or "happy", cx, cy, radius)
end

local function RenderProfilePanel(vg, w, h, fontId)
    if not profileData_ or not profileData_.bestBall then return end

    local ball = profileData_.bestBall
    local ballLevel = ball.level or 1
    local ballName = ball.name or "???"
    local streak = profileData_.bestStreak or 0
    local gold = profileData_.gold or 0
    local ballCount = profileData_.ballCount or 0
    local grade = GetColorGrade(ballLevel)
    local gradeColor = LEVEL_BASE_COLORS[grade]

    -- Panel dimensions
    local panelX = 24
    local panelY = 24
    local panelW = 320
    local panelH = 140
    local cornerR = 16
    local ballRadius = 36
    local padding = 16

    nvgSave(vg)

    -- Panel background (semi-transparent dark with border)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, panelX, panelY, panelW, panelH, cornerR)
    nvgFillColor(vg, nvgRGBA(10, 10, 30, 180))
    nvgFill(vg)

    -- Border glow using grade color
    local gc = gradeColor
    nvgBeginPath(vg)
    nvgRoundedRect(vg, panelX, panelY, panelW, panelH, cornerR)
    nvgStrokeWidth(vg, 1.5)
    nvgStrokeColor(vg, nvgRGBA(gc.r, gc.g, gc.b, 120))
    nvgStroke(vg)

    -- Left section: ball avatar
    local ballCX = panelX + padding + ballRadius
    local ballCY = panelY + panelH / 2
    RenderProfileBall(vg, ballCX, ballCY, ballRadius, ball)

    -- Level badge (bottom-right of ball)
    local badgeX = ballCX + ballRadius * 0.55
    local badgeY = ballCY + ballRadius * 0.55
    local badgeR = 14
    nvgBeginPath(vg)
    nvgCircle(vg, badgeX, badgeY, badgeR)
    nvgFillColor(vg, nvgRGBA(gc.r, gc.g, gc.b, 220))
    nvgFill(vg)
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
    nvgText(vg, badgeX, badgeY, tostring(ballLevel), nil)

    -- Right section: text info
    local textX = panelX + padding + ballRadius * 2 + 20
    local textStartY = panelY + padding + 4
    local lineH = 24

    -- Row 1: Ball name + grade tag
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 20)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    local nameEnd = nvgText(vg, textX, textStartY, ballName, nil)

    -- Grade tag
    local tagText = " Lv." .. ballLevel
    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(gc.r, gc.g, gc.b, 220))
    nvgText(vg, nameEnd + 6, textStartY + 3, tagText, nil)

    -- Row 2: Player ID
    local row2Y = textStartY + lineH + 2
    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(160, 170, 200, 200))
    if playerId_ and playerId_ ~= "" then
        nvgText(vg, textX, row2Y, "ID: " .. playerId_, nil)
    else
        nvgText(vg, textX, row2Y, "ID: ---", nil)
    end

    -- Row 3: Best streak
    local row3Y = row2Y + lineH
    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(200, 180, 100, 220))
    nvgText(vg, textX, row3Y, "🔥 最高连胜: " .. streak, nil)

    -- Row 4: Gold + ball count
    local row4Y = row3Y + lineH
    nvgFillColor(vg, nvgRGBA(255, 210, 80, 220))
    nvgText(vg, textX, row4Y, "💰 " .. math.floor(gold), nil)

    local goldEnd = textX + 90
    nvgFillColor(vg, nvgRGBA(160, 200, 230, 200))
    nvgText(vg, goldEnd, row4Y, "🔮 球球: " .. ballCount, nil)

    nvgRestore(vg)
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

    -- 7. Profile panel (top-left corner)
    RenderProfilePanel(vg, w, h, fontId)
end

-- ============================================================================
-- Show (creates UI overlay with interactive buttons)
-- ============================================================================

---@param callbacks table { onBattle: function, onMultiplayer: function, onCultivation: function, onBattleRoyale: function }
function StartPage.Show(callbacks)
    active_ = true
    elapsedTime_ = 0

    -- Load profile data for display panel
    profileData_ = BreedingPage.GetProfileData()
    -- Get player ID from clientCloud (may be nil if not yet authenticated)
    if clientCloud and clientCloud.userId then
        playerId_ = tostring(clientCloud.userId)
    else
        playerId_ = ""
    end

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
                        text = "技能搭配",
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
                    TriangleButton {
                        text = "球球养殖",
                        variant = "outline",
                        width = 200, height = 52,
                        fontSize = 18,
                        onClick = function()
                            if callbacks and callbacks.onBreeding then
                                callbacks.onBreeding()
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
