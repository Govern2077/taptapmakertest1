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
local ParticleTitle = require("effects.ParticleTitle")
local DiamondManager = require("game.DiamondManager")

local StartPage = {}

-- ============================================================================
-- State
-- ============================================================================

local active_ = false
local elapsedTime_ = 0
local devButtonsVisible_ = false   -- 隐藏按钮（TAB 切换）
local callbacks_ = nil             -- 缓存回调，用于重建 UI
local inputBlocked_ = false        -- 外部加载画面阻止按钮输入

-- Per-ball TriangleFill instances
local ballFills_ = {}

-- Title logo image
local titleImage_ = -1
local titleImgW_  = 1379   -- actual image width (fixed, not queried at runtime)
local titleImgH_  = 724    -- actual image height

-- Background image
local bgImage_ = -1
local BG_IMG_W = 1536      -- actual image width
local BG_IMG_H = 1024      -- actual image height

-- Breeding button (wooden board image as button)
local breedBtnBgImage_ = -1
local BREED_IMG_W = 1300   -- actual image width (approx)
local BREED_IMG_H = 400    -- actual image height (approx)
local BREED_BTN_W = 336    -- display width (design coords, 420*0.8)
local BREED_BTN_H = 104    -- display height (design coords, 130*0.8)
-- Computed button rect (updated in Render, used in Update for hit-test)
local breedBtnRect_ = { x = 0, y = 0, w = 0, h = 0 }
local breedBtnHover_ = false

-- Additional wooden board buttons (shop, settings)
local shopBtnRect_ = { x = 0, y = 0, w = 0, h = 0 }
local shopBtnHover_ = false
local settingsBtnRect_ = { x = 0, y = 0, w = 0, h = 0 }
local settingsBtnHover_ = false

-- Screen dimensions (design coords)
local screenW_ = 1920
local screenH_ = 1080

-- Mouse tracking (updated via MouseMove event, works on hover without button press)
local mousePhysX_ = 0
local mousePhysY_ = 0
local mouseTrackSubscribed_ = false

-- Profile panel data (loaded on Show)
local profileData_ = nil   -- { bestBall, bestStreak, gold, ballCount }
local profileRetryTimer_ = 0  -- retry timer for loading profile data
local playerId_ = ""       -- player ID string
local playerNickname_ = nil -- player nickname (fetched async)

-- Level color table (mirrored from BreedingPage for display, 16 grades)
local LEVEL_BASE_COLORS = {
    [1]  = { r = 230, g = 230, b = 235 },  -- 白
    [2]  = { r = 160, g = 230, b = 140 },  -- 浅绿
    [3]  = { r = 60,  g = 190, b = 80  },  -- 绿
    [4]  = { r = 70,  g = 150, b = 255 },  -- 蓝
    [5]  = { r = 170, g = 80,  b = 230 },  -- 紫
    [6]  = { r = 255, g = 160, b = 40  },  -- 橙
    [7]  = { r = 240, g = 60,  b = 60  },  -- 红
    [8]  = { r = 255, g = 215, b = 50  },  -- 金
    [9]  = { r = 0,   g = 220, b = 220 },  -- 青
    [10] = { r = 180, g = 230, b = 50  },  -- 黄绿渐变
    [11] = { r = 0,   g = 200, b = 255 },  -- 青蓝渐变
    [12] = { r = 255, g = 100, b = 50  },  -- 红橙渐变
    [13] = { r = 180, g = 180, b = 180 },  -- 黑白渐变
    [14] = { r = 120, g = 80,  b = 255 },  -- 蓝紫渐变
    [15] = { r = 255, g = 150, b = 130 },  -- 粉橙渐变
    [16] = { r = 220, g = 50,  b = 180 },  -- 红紫渐变
}
local GRADE_NAMES = { "白", "浅绿", "绿", "蓝", "紫", "橙", "红", "金",
                      "青", "黄绿", "青蓝", "红橙", "黑白", "蓝紫", "粉橙", "红紫" }

local function GetColorGrade(level)
    return math.min(math.max(level, 1), 16)
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

--- 构建/重建 UI 布局
local function RebuildUI()
    if not callbacks_ then return end
    local callbacks = callbacks_

    -- 球球养殖按钮改用 NanoVG 木板图片渲染，不再使用 UI 组件
    local children = {}

    -- TAB 呼出的隐藏按钮
    if devButtonsVisible_ then
        local devRow = UI.Panel {
            flexDirection = "row",
            gap = 40,
            marginTop = 30,
            children = {
                TriangleButton {
                    text = "联机对战",
                    variant = "outline",
                    width = 200, height = 52,
                    fontSize = 18,
                    onClick = function()
                        if callbacks.onMultiplayer then
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
                        if callbacks.onBattle then
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
                        if callbacks.onCultivation then
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
                        if callbacks.onBattleRoyale then
                            callbacks.onBattleRoyale()
                        end
                    end,
                },
            },
        }
        table.insert(children, devRow)
    end

    if #children > 0 then
        local root = UI.Panel {
            width = "100%", height = "100%",
            justifyContent = "flex-end",
            alignItems = "center",
            paddingBottom = 60,
            children = children,
        }
        UI.SetRoot(root)
    else
        -- No UI children (dev buttons hidden), clear UI
        local root = UI.Panel { width = 0, height = 0 }
        UI.SetRoot(root)
    end
end

function StartPage.Update(dt)
    if not active_ then return end
    elapsedTime_ = elapsedTime_ + dt

    for bi = 1, 2 do
        if ballFills_[bi] then
            ballFills_[bi]:Update(dt)
        end
    end

    -- 如果 profileData_ 尚未加载到球球数据，定时重试（云端同步可能延迟）
    if not profileData_ or not profileData_.bestBall then
        profileRetryTimer_ = profileRetryTimer_ + dt
        if profileRetryTimer_ >= 0.5 then
            profileRetryTimer_ = 0
            local newData = BreedingPage.GetProfileData()
            if newData and newData.bestBall then
                profileData_ = newData
            end
        end
    end

    -- TAB 键切换隐藏按钮
    if input:GetKeyPress(KEY_TAB) then
        devButtonsVisible_ = not devButtonsVisible_
        RebuildUI()
    end

    -- 木板按钮点击/hover 检测
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local mouseDesignX = mousePhysX_ * screenW_ / physW
    local mouseDesignY = mousePhysY_ * screenH_ / physH

    -- 如果 UI 层有打开的弹窗（Modal/Confirm 等）或外部加载画面激活，跳过 NanoVG 自绘按钮的点击检测
    local uiBlocked = (UI.GetTopOverlay() ~= nil) or inputBlocked_

    local r = breedBtnRect_
    breedBtnHover_ = (not uiBlocked and r.w > 0 and r.h > 0
        and mouseDesignX >= r.x and mouseDesignX <= r.x + r.w
        and mouseDesignY >= r.y and mouseDesignY <= r.y + r.h)
    if breedBtnHover_ and input:GetMouseButtonPress(MOUSEB_LEFT) then
        if callbacks_ and callbacks_.onBreeding then
            callbacks_.onBreeding()
        end
    end

    -- Shop button hover/click detection
    local sr = shopBtnRect_
    shopBtnHover_ = (not uiBlocked and sr.w > 0 and sr.h > 0
        and mouseDesignX >= sr.x and mouseDesignX <= sr.x + sr.w
        and mouseDesignY >= sr.y and mouseDesignY <= sr.y + sr.h)
    if shopBtnHover_ and input:GetMouseButtonPress(MOUSEB_LEFT) then
        if callbacks_ and callbacks_.onShop then
            callbacks_.onShop()
        end
    end

    -- Settings button hover/click detection
    local str = settingsBtnRect_
    settingsBtnHover_ = (not uiBlocked and str.w > 0 and str.h > 0
        and mouseDesignX >= str.x and mouseDesignX <= str.x + str.w
        and mouseDesignY >= str.y and mouseDesignY <= str.y + str.h)
    if settingsBtnHover_ and input:GetMouseButtonPress(MOUSEB_LEFT) then
        if callbacks_ and callbacks_.onSettings then
            callbacks_.onSettings()
        end
    end

    -- 更新粒子标题（使用 MouseMove 事件追踪的鼠标位置，hover 即可触发）
    if ParticleTitle.IsActive() then
        ParticleTitle.Update(dt, mouseDesignX, mouseDesignY)
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
    -- 即使没有存档也显示面板（使用默认值）
    local hasBall = profileData_ and profileData_.bestBall
    local ball = hasBall and profileData_.bestBall or nil
    local ballLevel = ball and (ball.level or 1) or 1
    local ballName = ball and (ball.name or "???") or nil
    local streak = profileData_ and profileData_.bestStreak or 0
    local gold = profileData_ and profileData_.gold or 0
    local ballCount = profileData_ and profileData_.ballCount or 0
    local diamonds = profileData_ and profileData_.diamonds or 0
    local grade = GetColorGrade(ballLevel)
    local gradeColor = LEVEL_BASE_COLORS[grade]

    -- Panel dimensions
    local panelX = 24
    local panelY = 24
    local panelW = 320
    local panelH = 164
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
    local ballCY = panelY + padding + ballRadius + 4
    if hasBall then
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
    else
        -- 无存档时画一个灰色占位球
        nvgBeginPath(vg)
        nvgCircle(vg, ballCX, ballCY, ballRadius)
        nvgFillColor(vg, nvgRGBA(60, 60, 80, 150))
        nvgFill(vg)
        nvgBeginPath(vg)
        nvgCircle(vg, ballCX - ballRadius * 0.2, ballCY - ballRadius * 0.3, ballRadius * 0.25)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 30))
        nvgFill(vg)
    end

    -- Ball name + level below the ball
    nvgFontFace(vg, "sans")
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    local nameLabelY = ballCY + ballRadius + 6
    if ballName then
        nvgFontSize(vg, 12)
        nvgFillColor(vg, nvgRGBA(gc.r, gc.g, gc.b, 220))
        nvgText(vg, ballCX, nameLabelY, ballName .. " Lv." .. ballLevel, nil)
    else
        nvgFontSize(vg, 12)
        nvgFillColor(vg, nvgRGBA(120, 120, 140, 180))
        nvgText(vg, ballCX, nameLabelY, "暂无球球", nil)
    end

    -- Right section: text info
    local textX = panelX + padding + ballRadius * 2 + 20
    local textStartY = panelY + padding + 4
    local lineH = 24

    -- Row 1: Username (nickname)
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 20)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    local displayName = playerNickname_ or (playerId_ ~= "" and playerId_) or "玩家"
    nvgText(vg, textX, textStartY, displayName, nil)

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

    -- Row 4: Gold + Diamonds
    local row4Y = row3Y + lineH
    nvgFillColor(vg, nvgRGBA(255, 210, 80, 220))
    nvgText(vg, textX, row4Y, "💰 " .. math.floor(gold), nil)

    local goldEnd = textX + 90
    nvgFillColor(vg, nvgRGBA(120, 200, 255, 220))
    nvgText(vg, goldEnd, row4Y, "💎 " .. diamonds, nil)

    -- Row 5: Ball count
    local row5Y = row4Y + lineH
    nvgFillColor(vg, nvgRGBA(160, 200, 230, 200))
    nvgText(vg, textX, row5Y, "🔮 球球: " .. ballCount, nil)

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

    -- Lazy-load images (once per vg context)
    if titleImage_ < 0 then
        titleImage_ = nvgCreateImage(vg, "image/title_logo.png", 0)
    end
    if bgImage_ < 0 then
        bgImage_ = nvgCreateImage(vg, "image/UI/ChatGPT Image 2026\xe5\xb9\xb45\xe6\x9c\x8813\xe6\x97\xa5 15_48_07.png", 0)
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

    -- 1. Background image (Cover mode: no stretch, center crop)
    if bgImage_ >= 0 then
        local imgAspect = BG_IMG_W / BG_IMG_H
        local scrAspect = w / h
        local drawW, drawH
        if scrAspect > imgAspect then
            -- screen wider than image: match width, crop top/bottom
            drawW = w
            drawH = w / imgAspect
        else
            -- screen taller than image: match height, crop left/right
            drawH = h
            drawW = h * imgAspect
        end
        local drawX = (w - drawW) / 2
        local drawY = (h - drawH) / 2
        local bgPaint = nvgImagePattern(vg, drawX, drawY, drawW, drawH, 0, bgImage_, 1.0)
        nvgBeginPath(vg)
        nvgRect(vg, 0, 0, w, h)
        nvgFillPaint(vg, bgPaint)
        nvgFill(vg)
    else
        -- Fallback: solid dark background
        nvgBeginPath(vg)
        nvgRect(vg, 0, 0, w, h)
        nvgFillColor(vg, nvgRGBA(BG_R, BG_G, BG_B, 255))
        nvgFill(vg)
    end

    -- 2-5. Showcase balls (temporarily hidden)
    -- Ball rendering, triangle fills, mask, and expressions are skipped

    -- Mouse position for particle title
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local mouseDesignX = mousePhysX_ * w / physW
    local mouseDesignY = mousePhysY_ * h / physH

    -- 6. Wooden board buttons (NanoVG rendered)
    if breedBtnBgImage_ < 0 then
        breedBtnBgImage_ = nvgCreateImage(vg, "image/UI/wooden_sign_downloadable.png", 0)
        if breedBtnBgImage_ == 0 then breedBtnBgImage_ = -2 end
    end
    if breedBtnBgImage_ > 0 then
        local btnW = BREED_BTN_W
        local btnH = BREED_BTN_H
        local btnX = cx - btnW / 2
        local titleBottomY = h * (LOGO_TOP + LOGO_MAX_H * 0.45) + 150
        local btnGap = 16  -- vertical gap between buttons
        local startY = titleBottomY + 260

        -- Button definitions: { label, rectTable, hoverFlag, yIndex }
        local buttons = {
            { label = "\xe7\x90\x83\xe7\x90\x83\xe5\x85\xbb\xe6\xae\x96", rect = breedBtnRect_,    hover = breedBtnHover_,    idx = 0 },
            { label = "\xe5\x95\x86\xe5\xba\x97",                         rect = shopBtnRect_,      hover = shopBtnHover_,     idx = 1 },
            { label = "\xe8\xae\xbe\xe7\xbd\xae",                         rect = settingsBtnRect_,  hover = settingsBtnHover_, idx = 2 },
        }

        for _, btn in ipairs(buttons) do
            local by = startY + btn.idx * (btnH + btnGap)
            btn.rect.x = btnX
            btn.rect.y = by
            btn.rect.w = btnW
            btn.rect.h = btnH

            nvgSave(vg)
            if btn.hover then
                local scale = 1.06
                local scx = btnX + btnW / 2
                local scy = by + btnH / 2
                nvgTranslate(vg, scx, scy)
                nvgScale(vg, scale, scale)
                nvgTranslate(vg, -scx, -scy)
            end

            -- Board image
            local imgPaint = nvgImagePattern(vg, btnX, by, btnW, btnH, 0, breedBtnBgImage_, 1.0)
            nvgBeginPath(vg)
            nvgRect(vg, btnX, by, btnW, btnH)
            nvgFillPaint(vg, imgPaint)
            nvgFill(vg)

            -- Label text
            local textCX = btnX + btnW / 2
            local textCY = by + btnH / 2
            nvgFontFace(vg, "sans")
            nvgFontSize(vg, 37)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
            nvgText(vg, textCX + 2, textCY + 3, btn.label, nil)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 245))
            nvgText(vg, textCX, textCY, btn.label, nil)
            nvgRestore(vg)
        end
    end

    -- 7. Particle title (球球乱斗 formed by particles) — rendered ON TOP of the button
    if ParticleTitle.IsActive() then
        local titleCenterY = h * (LOGO_TOP + LOGO_MAX_H * 0.45) + 150
        ParticleTitle.SetCenter(cx, titleCenterY)
        ParticleTitle.RenderMouseIndicator(vg, mouseDesignX, mouseDesignY)
        ParticleTitle.Render(vg)
    elseif titleImage_ >= 0 and titleImgW_ > 0 and titleImgH_ > 0 then
        local imgAspect = titleImgW_ / titleImgH_
        local maxW = w * LOGO_MAX_W
        local maxH = h * LOGO_MAX_H
        local logoW = maxW
        local logoH = logoW / imgAspect
        if logoH > maxH then
            logoH = maxH
            logoW = logoH * imgAspect
        end
        logoW = logoW * 1.5
        local logoX = cx - logoW / 2
        local logoY = h * LOGO_TOP
        local imgPaint = nvgImagePattern(vg, logoX, logoY, logoW, logoH, 0, titleImage_, 1)
        nvgBeginPath(vg)
        nvgRect(vg, logoX, logoY, logoW, logoH)
        nvgFillPaint(vg, imgPaint)
        nvgFill(vg)
    end

    -- 8. Profile panel (top-left corner)
    RenderProfilePanel(vg, w, h, fontId)
end

-- ============================================================================
-- Show (creates UI overlay with interactive buttons)
-- ============================================================================

---@param callbacks table { onBattle: function, onMultiplayer: function, onCultivation: function, onBattleRoyale: function }
function StartPage.Show(callbacks)
    active_ = true
    elapsedTime_ = 0

    -- Ensure diamond data is loaded (global, cross-slot)
    DiamondManager.Load()

    -- Load profile data for display panel (may be nil if cloud sync hasn't completed yet)
    profileData_ = BreedingPage.GetProfileData()
    profileRetryTimer_ = 0
    -- Get player ID and nickname from clientCloud
    if clientCloud and clientCloud.userId then
        playerId_ = tostring(clientCloud.userId)
        -- Fetch nickname async (if not already cached)
        if not playerNickname_ then
            GetUserNickname({
                userIds = { clientCloud.userId },
                onSuccess = function(nicknames)
                    if nicknames and #nicknames > 0 then
                        playerNickname_ = nicknames[1].nickname or playerId_
                    end
                end,
                onError = function()
                    playerNickname_ = playerId_
                end,
            })
        end
    else
        playerId_ = ""
    end

    -- 订阅 MouseMove 事件（仅订阅一次），确保鼠标 hover 即可追踪位置
    if not mouseTrackSubscribed_ then
        SubscribeToEvent("MouseMove", function(eventType, eventData)
            mousePhysX_ = eventData:GetInt("X")
            mousePhysY_ = eventData:GetInt("Y")
        end)
        mouseTrackSubscribed_ = true
    end
    -- 初始化当前鼠标位置
    mousePhysX_ = input.mousePosition.x
    mousePhysY_ = input.mousePosition.y

    -- 初始化粒子标题（BALL BRAWL）
    local titleCenterX = screenW_ / 2
    local titleCenterY = screenH_ * (LOGO_TOP + LOGO_MAX_H * 0.45) + 150
    ParticleTitle.Init("BALL\nBRAWL", titleCenterX, titleCenterY, {
        gridSpacing = 28,
        mouseRadius = 260,
        radiusMin = 16,
        radiusMax = 24,
    })

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

    -- 缓存回调，初始化隐藏状态，构建 UI
    callbacks_ = callbacks
    devButtonsVisible_ = false
    RebuildUI()
end

-- ============================================================================
-- Hide
-- ============================================================================

function StartPage.Hide()
    active_ = false
    inputBlocked_ = false
    -- Reset image handles; vg context may be destroyed and recreated
    titleImage_ = -1
    bgImage_ = -1
    breedBtnBgImage_ = -1
    -- 销毁粒子标题
    ParticleTitle.Destroy()
end

--- Block/unblock button input (used by loading screen overlay)
---@param blocked boolean
function StartPage.SetInputBlocked(blocked)
    inputBlocked_ = blocked
end

return StartPage
