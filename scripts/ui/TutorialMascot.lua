-- TutorialMascot.lua
-- 教程引导吉祥物：左下角图片球球 + 对话气泡
-- 两种模式：
--   "question" - 初始询问是否需要教学（是/否按钮）
--   "dialog"   - 教程步骤对话（纯文字 + 点击提示）
--
-- 动画效果：
--   · 鼠标移动 → 整个图片轻微旋转（视差感）
--   · 文字出现时 → 球球短暂晃动（shake 动画）

local TutorialMascot = {}

-- ============================================================
-- 常量
-- ============================================================
local IMG_SIZE      = 560    -- 图片渲染基准尺寸（2x，设计坐标）
local BALL_R        = IMG_SIZE * 0.5
local HIDE_Y_OFFSET = IMG_SIZE + 10  -- 入场前完全藏在屏幕下方

-- 图片实际宽高（运行时由 nvgImageSize 获取，用于保持比例）
local imgNativeW_   = 0
local imgNativeH_   = 0

-- 气泡尺寸
local BUBBLE_W      = 400
local BUBBLE_H      = 210
local BUBBLE_R      = 22

-- 对话气泡稍高（容纳多行文字）
local DIALOG_W      = 440
local DIALOG_H      = 180

-- 按钮（question 模式）
local BTN_W         = 140
local BTN_H         = 52
local BTN_GAP       = 18

-- 动画参数
local SLIDE_IN_DUR  = 0.60
local SLIDE_OUT_DUR = 0.38

-- 旋转跟随参数
local ROT_MAX_DEG   = 8      -- 最大倾斜角度（度）
local ROT_LERP      = 4      -- 跟随平滑速率

-- 晃动动画参数（文字出现时触发）
local SHAKE_DUR     = 0.55   -- 总晃动时长
local SHAKE_FREQ    = 28     -- 晃动频率（Hz，每秒来回次数）
local SHAKE_AMP     = 14     -- 晃动振幅（像素）

-- ============================================================
-- 私有状态
-- ============================================================
local active_       = false
local phase_        = "idle"   -- "idle" | "slide_in" | "show" | "slide_out"
local bubbleMode_   = "question"  -- "question" | "dialog"
local timer_        = 0

local onYes_        = nil
local onNo_         = nil

local ballYOffset_  = 0
local animTime_     = 0
local hoverYes_     = false
local hoverNo_      = false

-- 对话模式内容
local dialogText_        = ""
local dialogShowHint_    = false
local dialogHintBlink_   = 0
local dialogHintVisible_ = true

-- 3 秒等待（click 触发类步骤）
local dialogReadyForClick_ = false
local dialogReadyTimer_    = 0
local onDialogClick_       = nil

-- 鼠标旋转（图片整体倾斜）
local rotAngle_     = 0      -- 当前旋转角度（度）
local rotTarget_    = 0      -- 目标旋转角度

-- 晃动状态
local shakeTimer_   = 0      -- > 0 时正在晃动
local shakeOffX_    = 0      -- 本帧晃动偏移量

-- NanoVG 图片句柄
local mascotImg_    = nil

-- ============================================================
-- 工具函数
-- ============================================================

local function easeOutBack(t)
    local c1 = 1.70158
    local c3 = c1 + 1
    return 1 + c3 * math.pow(t - 1, 3) + c1 * math.pow(t - 1, 2)
end

local function easeInQuad(t) return t * t end

local function lerp(a, b, t) return a + (b - a) * t end

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

-- 球心（左下角，底部贴屏）
local function BallCenter(designW, designH)
    local bx = BALL_R + 10
    local by = designH - BALL_R + ballYOffset_ - 10 + 50   -- 向下移动50像素
    return bx, by
end

-- 气泡左上角（question 模式）
local function BubbleOrigin(bx, by)
    local bbx = bx + BALL_R * 0.50 + 40 + 50 - 50   -- 向左50抵消
    local bby = by - BALL_R * 1.55 - 40 - 50 + 50    -- 向下50抵消
    return bbx, bby
end

-- 对话气泡左上角（dialog 模式）
local function DialogOrigin(bx, by)
    local bbx = bx + BALL_R * 0.42 + 40 + 50 - 50   -- 向左50抵消
    local bby = by - BALL_R * 1.50 - 40 - 50 + 50    -- 向下50抵消
    return bbx, bby
end

local function InRect(px, py, rx, ry, rw, rh)
    return px >= rx and px <= rx + rw and py >= ry and py <= ry + rh
end

-- 多行文字绘制
local function DrawWrappedText(vg, text, x, y, maxWidth, lineHeight)
    nvgTextBox(vg, x, y, maxWidth, text)
end

-- 触发晃动
local function TriggerShake()
    shakeTimer_ = SHAKE_DUR
end

-- ============================================================
-- 公共 API
-- ============================================================

--- 显示问题模式（是否需要教学）
function TutorialMascot.Show(onYes, onNo)
    onYes_       = onYes
    onNo_        = onNo
    active_      = true
    phase_       = "slide_in"
    bubbleMode_  = "question"
    timer_       = 0
    ballYOffset_ = HIDE_Y_OFFSET
    animTime_    = 0
    hoverYes_    = false
    hoverNo_     = false
    rotAngle_    = 0
    rotTarget_   = 0
    shakeTimer_  = 0
end

--- 设置对话模式文本（切换到 dialog 模式）
function TutorialMascot.SetDialogText(text, allowClick, onClickCb)
    dialogText_          = text or ""
    dialogShowHint_      = allowClick or false
    dialogReadyForClick_ = false
    dialogReadyTimer_    = 0
    dialogHintBlink_     = 0
    dialogHintVisible_   = true
    onDialogClick_       = onClickCb

    -- 文字出现时触发晃动
    TriggerShake()

    if active_ and phase_ == "show" then
        bubbleMode_ = "dialog"
    else
        active_      = true
        phase_       = "slide_in"
        bubbleMode_  = "dialog"
        timer_       = 0
        ballYOffset_ = HIDE_Y_OFFSET
        animTime_    = 0
        rotAngle_    = 0
        rotTarget_   = 0
    end
    print(string.format("[TutorialMascot] SetDialogText: phase=%s active=%s text=%.20s", phase_, tostring(active_), dialogText_))
end

function TutorialMascot.Dismiss()
    if not active_ then return end
    phase_ = "slide_out"
    timer_ = 0
end

function TutorialMascot.IsActive()
    return active_
end

function TutorialMascot.IsReadyForClick()
    return active_ and phase_ == "show"
        and bubbleMode_ == "dialog"
        and dialogShowHint_
        and dialogReadyForClick_
end

function TutorialMascot.Update(dt, mx, my, designW, designH)
    if not active_ then return end

    animTime_ = animTime_ + dt
    timer_    = timer_    + dt

    -- ── 晃动计时 ──
    if shakeTimer_ > 0 then
        shakeTimer_ = shakeTimer_ - dt
        if shakeTimer_ < 0 then shakeTimer_ = 0 end
        -- 衰减振幅：从 SHAKE_AMP 线性降到 0
        local progress = 1 - (shakeTimer_ / SHAKE_DUR)
        local amp = SHAKE_AMP * (1 - progress)
        shakeOffX_ = math.sin(shakeTimer_ * SHAKE_FREQ) * amp
    else
        shakeOffX_ = 0
    end

    if phase_ == "slide_in" then
        local t = clamp(timer_ / SLIDE_IN_DUR, 0, 1)
        ballYOffset_ = lerp(HIDE_Y_OFFSET, 0, easeOutBack(t))
        if timer_ >= SLIDE_IN_DUR then
            ballYOffset_ = 0
            phase_       = "show"
            timer_       = 0
        end

    elseif phase_ == "show" then
        -- ── 鼠标旋转目标 ──
        local bx, by = BallCenter(designW, designH)
        local dx = mx - bx
        local dy = my - by
        -- 用鼠标相对球心的水平偏移计算旋转（左右倾斜）
        local normX = clamp(dx / (designW * 0.5), -1, 1)
        rotTarget_ = normX * ROT_MAX_DEG

        -- 平滑插值旋转角度
        local lerpT = clamp(dt * ROT_LERP, 0, 1)
        rotAngle_ = lerp(rotAngle_, rotTarget_, lerpT)

        if bubbleMode_ == "question" then
            -- 按钮悬停检测
            local bbx, bby = BubbleOrigin(bx, by)
            local btnY     = bby + BUBBLE_H - BTN_H - 18
            local yesX     = bbx + (BUBBLE_W - BTN_W * 2 - BTN_GAP) / 2
            local noX      = yesX + BTN_W + BTN_GAP
            hoverYes_ = InRect(mx, my, yesX, btnY, BTN_W, BTN_H)
            hoverNo_  = InRect(mx, my, noX,  btnY, BTN_W, BTN_H)

        elseif bubbleMode_ == "dialog" then
            -- 3 秒等待计时
            if not dialogReadyForClick_ then
                dialogReadyTimer_ = dialogReadyTimer_ + dt
                if dialogReadyTimer_ >= 3.0 then
                    dialogReadyForClick_ = true
                end
            end
            -- "点击继续"提示闪烁
            if dialogShowHint_ and dialogReadyForClick_ then
                dialogHintBlink_ = dialogHintBlink_ + dt
                if dialogHintBlink_ >= 0.6 then
                    dialogHintBlink_ = 0
                    dialogHintVisible_ = not dialogHintVisible_
                end
            end
        end

    elseif phase_ == "slide_out" then
        local t = clamp(timer_ / SLIDE_OUT_DUR, 0, 1)
        ballYOffset_ = lerp(0, HIDE_Y_OFFSET, easeInQuad(t))
        if timer_ >= SLIDE_OUT_DUR then
            active_      = false
            phase_       = "idle"
            ballYOffset_ = HIDE_Y_OFFSET
        end
    end
end

--- 处理鼠标输入，返回 true 表示已消耗该点击
function TutorialMascot.ProcessInput(mx, my, pressed, designW, designH)
    if not active_ or phase_ ~= "show" then return false end
    if not pressed then return false end

    local bx, by = BallCenter(designW, designH)

    if bubbleMode_ == "question" then
        local bbx, bby = BubbleOrigin(bx, by)
        local btnY     = bby + BUBBLE_H - BTN_H - 18
        local yesX     = bbx + (BUBBLE_W - BTN_W * 2 - BTN_GAP) / 2
        local noX      = yesX + BTN_W + BTN_GAP

        if InRect(mx, my, yesX, btnY, BTN_W, BTN_H) then
            -- 不调用 Dismiss()：onYes_ 会通过 SetDialogText 无缝切换到对话模式
            -- 若先 Dismiss 再 SetDialogText，phase_="slide_out" 会导致吉祥物先消失再重新入场
            if onYes_ then
                local cb = onYes_; onYes_ = nil; onNo_ = nil; cb()
            end
            return true
        end

        if InRect(mx, my, noX, btnY, BTN_W, BTN_H) then
            TutorialMascot.Dismiss()
            if onNo_ then
                local cb = onNo_; onYes_ = nil; onNo_ = nil; cb()
            end
            return true
        end

        return false

    elseif bubbleMode_ == "dialog" then
        if dialogShowHint_ and dialogReadyForClick_ and onDialogClick_ then
            local cb = onDialogClick_
            onDialogClick_ = nil
            cb()
            return true
        end
        if dialogShowHint_ and not dialogReadyForClick_ then
            return true
        end
        return false
    end

    return false
end

-- ============================================================
-- 渲染
-- ============================================================

function TutorialMascot.Render(vg, designW, designH, fontId)
    if not active_ then return end

    -- 懒加载图片
    if mascotImg_ == nil then
        mascotImg_ = nvgCreateImage(vg, "image/UI重置/ChatGPT Image 2026年5月25日 14_12_19.png", 0)
        if not mascotImg_ or mascotImg_ < 0 then
            mascotImg_ = nil
        end
    end

    -- 获取图片原始尺寸（保持宽高比，只做一次）
    if mascotImg_ and mascotImg_ >= 0 and imgNativeW_ == 0 then
        imgNativeW_, imgNativeH_ = nvgImageSize(vg, mascotImg_)
        if not imgNativeW_ or imgNativeW_ <= 0 then
            imgNativeW_, imgNativeH_ = 1, 1
        end
    end

    local bx, by = BallCenter(designW, designH)
    -- 加上晃动偏移
    local drawX = bx + shakeOffX_

    -- 根据原始宽高比计算实际渲染尺寸（高度以 IMG_SIZE 为基准，宽度额外×2）
    local drawW, drawH
    if imgNativeW_ > 0 and imgNativeH_ > 0 then
        local aspect = imgNativeW_ / imgNativeH_
        if aspect >= 1 then
            drawH = IMG_SIZE / aspect
            drawW = IMG_SIZE * 1.5       -- 横向放大1.5倍
        else
            drawH = IMG_SIZE
            drawW = IMG_SIZE * aspect * 1.5  -- 横向放大1.5倍
        end
    else
        drawW = IMG_SIZE * 1.5
        drawH = IMG_SIZE
    end

    nvgSave(vg)

    -- --------------------------------------------------------
    -- 1. 底部投影（在旋转前绘制，保持水平）
    -- --------------------------------------------------------
    nvgBeginPath(vg)
    nvgEllipse(vg, drawX, designH - 6, drawW * 0.35, drawW * 0.04)
    nvgFillColor(vg, nvgRGBA(30, 30, 30, 45))
    nvgFill(vg)

    -- --------------------------------------------------------
    -- 2. 吉祥物图片（旋转绘制，保持原图宽高比）
    -- --------------------------------------------------------
    -- 以图片中心（视觉重心偏低约60%）为轴旋转
    nvgTranslate(vg, drawX, by)
    nvgRotate(vg, rotAngle_ * math.pi / 180)

    local halfW = drawW * 0.5
    local halfH = drawH * 0.5
    if mascotImg_ and mascotImg_ >= 0 then
        -- 用 ImagePattern 渲染带透明背景的 PNG，保持宽高比不拉伸
        local paint = nvgImagePattern(vg, -halfW, -halfH, drawW, drawH, 0, mascotImg_, 1.0)
        nvgBeginPath(vg)
        nvgRect(vg, -halfW, -halfH, drawW, drawH)
        nvgFillPaint(vg, paint)
        nvgFill(vg)
    else
        -- 图片加载失败时的备用红球
        nvgBeginPath(vg)
        nvgCircle(vg, 0, 0, BALL_R)
        nvgFillColor(vg, nvgRGBA(210, 50, 35, 230))
        nvgFill(vg)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 48)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
        nvgText(vg, 0, 0, "🎓")
    end

    -- 重置 transform 后绘制气泡（气泡不旋转）
    nvgRestore(vg)

    -- --------------------------------------------------------
    -- 3. 对话气泡
    -- --------------------------------------------------------
    nvgSave(vg)
    if phase_ == "show" or phase_ == "slide_in" then
        local bubbleAlpha = clamp((HIDE_Y_OFFSET - math.max(0, ballYOffset_)) / HIDE_Y_OFFSET, 0, 1)
        bubbleAlpha = bubbleAlpha * bubbleAlpha
        nvgGlobalAlpha(vg, bubbleAlpha)

        -- 气泡位置也跟随晃动偏移
        local bubbleBx = drawX

        if bubbleMode_ == "question" then
            RenderQuestionBubble(vg, bubbleBx, by, fontId)
        elseif bubbleMode_ == "dialog" then
            RenderDialogBubble(vg, bubbleBx, by, fontId)
        end

        nvgGlobalAlpha(vg, 1)
    end
    nvgRestore(vg)
end

-- --------------------------------------------------------
-- 问题气泡（是否需要教学）
-- --------------------------------------------------------
function RenderQuestionBubble(vg, bx, by, fontId)
    local bbx, bby = BubbleOrigin(bx, by)

    -- 阴影
    local bShadow = nvgBoxGradient(vg,
        bbx + 5, bby + 7, BUBBLE_W, BUBBLE_H, BUBBLE_R, 16,
        nvgRGBA(80, 0, 0, 65), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx + 5, bby + 7, BUBBLE_W, BUBBLE_H, BUBBLE_R)
    nvgFillPaint(vg, bShadow)
    nvgFill(vg)

    -- 气泡本体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx, bby, BUBBLE_W, BUBBLE_H, BUBBLE_R)
    nvgFillColor(vg, nvgRGBA(255, 252, 248, 250))
    nvgFill(vg)

    -- 气泡描边
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx, bby, BUBBLE_W, BUBBLE_H, BUBBLE_R)
    nvgStrokeColor(vg, nvgRGBA(200, 80, 60, 200))
    nvgStrokeWidth(vg, 3)
    nvgStroke(vg)

    -- 尾巴
    RenderBubbleTail(vg, bx, by, bbx, bby, BUBBLE_H)

    -- 文字
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 26)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(60, 20, 10, 235))
    nvgText(vg, bbx + BUBBLE_W / 2, bby + 52, "是否需要教学？")

    nvgFontSize(vg, 18)
    nvgFillColor(vg, nvgRGBA(160, 60, 40, 180))
    nvgText(vg, bbx + BUBBLE_W / 2, bby + 85, "我来带你了解游戏玩法～")

    -- 按钮
    local btnY = bby + BUBBLE_H - BTN_H - 18
    local yesX = bbx + (BUBBLE_W - BTN_W * 2 - BTN_GAP) / 2
    local noX  = yesX + BTN_W + BTN_GAP

    -- "需要"
    local yesBg = hoverYes_
        and nvgRGBA(230, 60, 40, 255)
        or  nvgRGBA(210, 50, 35, 230)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, yesX, btnY, BTN_W, BTN_H, 12)
    nvgFillColor(vg, yesBg); nvgFill(vg)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, yesX, btnY, BTN_W, BTN_H, 12)
    nvgStrokeColor(vg, nvgRGBA(150, 20, 10, 200))
    nvgStrokeWidth(vg, 2.5); nvgStroke(vg)
    nvgFontSize(vg, 20)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 245))
    nvgText(vg, yesX + BTN_W / 2, btnY + BTN_H / 2, "需要")

    -- "不需要"
    local noBg = hoverNo_
        and nvgRGBA(200, 185, 170, 255)
        or  nvgRGBA(215, 200, 182, 220)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, noX, btnY, BTN_W, BTN_H, 12)
    nvgFillColor(vg, noBg); nvgFill(vg)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, noX, btnY, BTN_W, BTN_H, 12)
    nvgStrokeColor(vg, nvgRGBA(160, 130, 100, 180))
    nvgStrokeWidth(vg, 2.5); nvgStroke(vg)
    nvgFontSize(vg, 20)
    nvgFillColor(vg, nvgRGBA(70, 45, 25, 230))
    nvgText(vg, noX + BTN_W / 2, btnY + BTN_H / 2, "不需要")
end

-- --------------------------------------------------------
-- 对话气泡（教程步骤）
-- --------------------------------------------------------
function RenderDialogBubble(vg, bx, by, fontId)
    local bbx, bby = DialogOrigin(bx, by)
    local bw       = DIALOG_W
    local textPad  = 20
    local topPad   = 22
    local hintH    = 34
    local botPad   = 16

    -- 测量文字高度
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 26)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    local textW = bw - textPad * 2
    local bounds = nvgTextBoxBounds(vg, 0, 0, textW, dialogText_)
    local textH = 26
    if bounds and bounds[4] and bounds[2] then
        local measured = bounds[4] - bounds[2]
        if measured > 0 then textH = measured end
    end

    local bh = topPad + textH + hintH + botPad

    -- 阴影
    local bShadow = nvgBoxGradient(vg,
        bbx + 5, bby + 7, bw, bh, BUBBLE_R, 16,
        nvgRGBA(80, 0, 0, 65), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx + 5, bby + 7, bw, bh, BUBBLE_R)
    nvgFillPaint(vg, bShadow); nvgFill(vg)

    -- 气泡本体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx, bby, bw, bh, BUBBLE_R)
    nvgFillColor(vg, nvgRGBA(255, 250, 244, 252)); nvgFill(vg)

    -- 描边
    nvgBeginPath(vg)
    nvgRoundedRect(vg, bbx, bby, bw, bh, BUBBLE_R)
    nvgStrokeColor(vg, nvgRGBA(200, 80, 60, 200))
    nvgStrokeWidth(vg, 3); nvgStroke(vg)

    -- 尾巴
    RenderBubbleTail(vg, bx, by, bbx, bby, bh)

    -- 对话文字
    nvgFillColor(vg, nvgRGBA(55, 20, 10, 235))
    DrawWrappedText(vg, dialogText_, bbx + textPad, bby + topPad, textW, 34)

    -- "点击继续"提示
    if dialogShowHint_ then
        if dialogReadyForClick_ then
            if dialogHintVisible_ then
                nvgFontSize(vg, 18)
                nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
                nvgFillColor(vg, nvgRGBA(200, 70, 50, 200))
                nvgText(vg, bbx + bw - 14, bby + bh - botPad / 2, "点击继续 ▶")
            end
        else
            nvgFontSize(vg, 16)
            nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, nvgRGBA(180, 140, 120, 140))
            nvgText(vg, bbx + bw - 14, bby + bh - botPad / 2, "请阅读...")
        end
    end
end

-- --------------------------------------------------------
-- 气泡尾巴
-- --------------------------------------------------------
function RenderBubbleTail(vg, bx, by, bbx, bby, bubbleH)
    local tailTipX = bx + BALL_R * 0.30
    local tailTipY = bby + bubbleH + (by - bby - bubbleH) * 0.55
    local tailBX   = bbx + 22
    local tailBY   = bby + bubbleH - 1

    nvgBeginPath(vg)
    nvgMoveTo(vg, tailBX, tailBY)
    nvgLineTo(vg, tailBX + 26, tailBY)
    nvgLineTo(vg, tailTipX, tailTipY)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(255, 250, 244, 252)); nvgFill(vg)

    nvgBeginPath(vg)
    nvgMoveTo(vg, tailBX, tailBY)
    nvgLineTo(vg, tailTipX, tailTipY)
    nvgStrokeColor(vg, nvgRGBA(200, 80, 60, 200))
    nvgStrokeWidth(vg, 3); nvgStroke(vg)

    nvgBeginPath(vg)
    nvgMoveTo(vg, tailBX + 26, tailBY)
    nvgLineTo(vg, tailTipX, tailTipY)
    nvgStrokeColor(vg, nvgRGBA(200, 80, 60, 200))
    nvgStrokeWidth(vg, 3); nvgStroke(vg)
end

return TutorialMascot
