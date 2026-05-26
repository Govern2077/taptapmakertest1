-- BreedingLoadingScreen.lua
-- 进入球球养殖页面前的加载屏幕，预加载所有图片和字体
-- 使用手绘卡通风格展示进度

local BreedingLoadingScreen = {}

-- ============================================================
-- 私有状态
-- ============================================================
local active_       = false
local vg_           = nil
local fontId_       = -1
local onComplete_   = nil

-- 加载进度
local totalAssets_  = 0
local loadedAssets_ = 0
local loadDone_     = false

-- 动画状态
local animTime_     = 0
local fadeIn_       = 0      -- 0→1 淡入
local fadeOut_      = 0      -- 0→1 淡出（加载完成后）
local MIN_SHOW_TIME = 0.8    -- 最少展示时间（秒）
local showTimer_    = 0

-- 弹跳球动画
local NUM_BALLS     = 3
local ballPhase_    = {}     -- 每个球的相位偏移

-- 所有需要预加载的图片路径（与 BreedingPage.LoadUIImages 保持一致）
local IMAGE_PATHS = {
    "image/UI/bg_paper.png",
    "image/UI/slot_grass.png",
    "image/UI/slot_empty.png",
    "image/UI/panel_purple.png",
    "image/UI/farm_grass.png",
    "image/UI/btn_cream.png",
    "image/UI/btn_purple.png",
    "image/UI/gold_frame.png",
    "image/UI/Mask group.png",
    "image/UI/Mask group-2.png",
    "image/UI重置/39a37b5e-2a5b-43b3-b791-39246bdfeb1f.png",
    "image/UI/ChatGPT Image 2026年5月12日 15_55_51.png",
    "image/UI/ChatGPT Image 2026年5月12日 15_53_33.png",
    "image/crown.png",
    -- 养殖页全屏背景（Standalone.lua 使用）
    "image/擂台赛背景.png",
}

local preloadHandles_ = {}   -- 存储已加载句柄（避免GC释放）

-- ============================================================
-- 公共 API
-- ============================================================

--- 显示加载屏幕并开始预加载
---@param vg userdata  NanoVG context
---@param fontId number  字体句柄
---@param onComplete function  全部加载完成后回调
function BreedingLoadingScreen.Show(vg, fontId, onComplete)
    vg_          = vg
    fontId_      = fontId
    onComplete_  = onComplete
    active_      = true
    loadDone_    = false
    animTime_    = 0
    fadeIn_      = 0
    fadeOut_     = 0
    showTimer_   = 0

    -- 初始化弹跳球相位
    for i = 1, NUM_BALLS do
        ballPhase_[i] = (i - 1) * (math.pi * 2 / NUM_BALLS)
    end

    -- 统计总资源数
    totalAssets_  = #IMAGE_PATHS
    loadedAssets_ = 0
    preloadHandles_ = {}

    -- 同步加载所有图片（NanoVG 图片加载本身是同步的）
    for _, path in ipairs(IMAGE_PATHS) do
        local handle = nvgCreateImage(vg_, path, 0)
        preloadHandles_[path] = handle
        loadedAssets_ = loadedAssets_ + 1
    end

    -- 所有资源已加载（NanoVG 同步）
    loadDone_ = true

    print(string.format("[BreedingLoadingScreen] 预加载完成 %d 张图片", loadedAssets_))
end

--- 隐藏加载屏幕
--- 注意：preloadHandles_ 不清空，保留句柄防止 GC 回收已加载的图片
function BreedingLoadingScreen.Hide()
    active_ = false
    vg_     = nil
    -- preloadHandles_ 故意保留，让 NanoVG 图片句柄在整个 session 内有效
end

--- 是否正在显示
function BreedingLoadingScreen.IsActive()
    return active_
end

--- 每帧更新（在 HandleUpdate 中调用）
---@param dt number  帧间隔（秒）
function BreedingLoadingScreen.Update(dt)
    if not active_ then return end

    animTime_  = animTime_  + dt
    showTimer_ = showTimer_ + dt

    -- 淡入（前 0.3 秒）
    if fadeIn_ < 1 then
        fadeIn_ = math.min(1, animTime_ / 0.3)
    end

    -- 加载完成 + 最少展示时间到达 → 开始淡出
    if loadDone_ and showTimer_ >= MIN_SHOW_TIME and fadeOut_ == 0 then
        fadeOut_ = 0.001  -- 触发淡出开始
    end

    if fadeOut_ > 0 then
        fadeOut_ = fadeOut_ + dt / 0.35   -- 0.35 秒淡出
        if fadeOut_ >= 1 then
            fadeOut_ = 1
            active_ = false
            if onComplete_ then
                local cb = onComplete_
                onComplete_ = nil
                cb()
            end
        end
    end
end

--- 渲染加载屏幕（在 NanoVGRender 中调用，已在 nvgBeginFrame 内）
---@param designW number
---@param designH number
function BreedingLoadingScreen.Render(designW, designH)
    if not active_ or not vg_ then return end

    local vg      = vg_
    local alpha   = fadeIn_ * (1 - math.max(0, fadeOut_ - 0.001))
    alpha = math.max(0, math.min(1, alpha))

    nvgSave(vg)
    nvgGlobalAlpha(vg, alpha)

    -- --------------------------------------------------------
    -- 1. 背景：草绿色渐变
    -- --------------------------------------------------------
    local bg = nvgLinearGradient(vg, 0, 0, 0, designH,
        nvgRGBA(120, 190, 80, 255),
        nvgRGBA(80, 150, 50, 255))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, designW, designH)
    nvgFillPaint(vg, bg)
    nvgFill(vg)

    -- --------------------------------------------------------
    -- 2. 中央白色圆角卡片
    -- --------------------------------------------------------
    local cardW = math.min(460, designW * 0.75)
    local cardH = 280
    local cardX = (designW - cardW) / 2
    local cardY = (designH - cardH) / 2 - 20

    -- 卡片阴影
    local shadow = nvgBoxGradient(vg,
        cardX + 4, cardY + 6, cardW, cardH, 20, 18,
        nvgRGBA(0, 60, 0, 80), nvgRGBA(0, 0, 0, 0))
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cardX + 4, cardY + 6, cardW, cardH, 20)
    nvgFillPaint(vg, shadow)
    nvgFill(vg)

    -- 卡片本体
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cardX, cardY, cardW, cardH, 20)
    nvgFillColor(vg, nvgRGBA(255, 252, 240, 245))
    nvgFill(vg)

    -- 卡片描边（手绘感）
    nvgStrokeColor(vg, nvgRGBA(180, 140, 80, 200))
    nvgStrokeWidth(vg, 3)
    nvgStroke(vg)

    -- --------------------------------------------------------
    -- 3. 标题文字：加载中...
    -- --------------------------------------------------------
    nvgFontFaceId(vg, fontId_)
    nvgFontSize(vg, 28)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(80, 50, 20, 255))
    nvgText(vg, designW / 2, cardY + 50, "准备进入养殖场...")

    -- --------------------------------------------------------
    -- 4. 弹跳球动画（3个彩色小球）
    -- --------------------------------------------------------
    local ballY_base = cardY + 130
    local ballSpacing = 44
    local ballR = 14
    local colors = {
        nvgRGBA(240, 100, 80,  255),   -- 红
        nvgRGBA(80,  180, 100, 255),   -- 绿
        nvgRGBA(80,  140, 230, 255),   -- 蓝
    }
    local startX = designW / 2 - ballSpacing

    for i = 1, NUM_BALLS do
        local phase  = ballPhase_[i]
        local t      = animTime_ * 4 + phase
        local bounce = math.abs(math.sin(t)) * 28  -- 弹跳幅度
        local bx     = startX + (i - 1) * ballSpacing
        local by     = ballY_base - bounce

        -- 球阴影（椭圆，随弹跳缩放）
        local shadowAlpha = math.floor(40 + (28 - bounce) * 1.5)
        shadowAlpha = math.max(20, math.min(70, shadowAlpha))
        local shadowScaleX = 0.6 + bounce / 80
        nvgBeginPath(vg)
        nvgEllipse(vg, bx, ballY_base + 8, ballR * shadowScaleX, 5)
        nvgFillColor(vg, nvgRGBA(0, 80, 0, shadowAlpha))
        nvgFill(vg)

        -- 球本体
        local grad = nvgRadialGradient(vg,
            bx - ballR * 0.3, by - ballR * 0.3,
            ballR * 0.2, ballR * 1.1,
            nvgRGBA(255, 255, 255, 200),
            colors[i])
        nvgBeginPath(vg)
        nvgCircle(vg, bx, by, ballR)
        nvgFillPaint(vg, grad)
        nvgFill(vg)

        -- 高光
        nvgBeginPath(vg)
        nvgCircle(vg, bx - ballR * 0.28, by - ballR * 0.28, ballR * 0.22)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 160))
        nvgFill(vg)
    end

    -- --------------------------------------------------------
    -- 5. 进度条
    -- --------------------------------------------------------
    local barW    = cardW - 60
    local barH    = 16
    local barX    = cardX + 30
    local barY    = cardY + cardH - 55
    local progress = totalAssets_ > 0 and (loadedAssets_ / totalAssets_) or 0

    -- 进度条背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, barX, barY, barW, barH, barH / 2)
    nvgFillColor(vg, nvgRGBA(200, 180, 140, 200))
    nvgFill(vg)

    -- 进度条填充（带波动动画）
    if progress > 0 then
        local fillW = math.max(barH, barW * progress)
        local grad2 = nvgLinearGradient(vg,
            barX, barY, barX + fillW, barY,
            nvgRGBA(120, 210, 80, 255),
            nvgRGBA(180, 240, 100, 255))
        nvgBeginPath(vg)
        nvgRoundedRect(vg, barX, barY, fillW, barH, barH / 2)
        nvgFillPaint(vg, grad2)
        nvgFill(vg)
    end

    -- 进度条描边
    nvgBeginPath(vg)
    nvgRoundedRect(vg, barX, barY, barW, barH, barH / 2)
    nvgStrokeColor(vg, nvgRGBA(160, 120, 60, 180))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- 进度文字
    nvgFontSize(vg, 18)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(80, 50, 20, 200))
    local pct = math.floor(progress * 100)
    nvgText(vg, designW / 2, barY + barH + 18, pct .. "%")

    nvgRestore(vg)
end

return BreedingLoadingScreen
