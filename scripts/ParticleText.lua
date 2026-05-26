-- ============================================================================
-- 粒子文字效果 (Particle Text Effect)
-- 一群小球聚集成文字，鼠标靠近时散开，离开后重新聚集
-- ============================================================================

require "LuaScripts/Utilities/Sample"

-- ============================================================================
-- 全局变量
-- ============================================================================
local vg = nil
local fontId = -1

-- 粒子列表
local particles = {}

-- 配置
local CONFIG = {
    TEXT = "HELLO",             -- 显示的文字
    BALL_RADIUS = 4,            -- 球的半径
    GRID_SPACING = 12,          -- 采样网格间距（越小球越密）
    FONT_SIZE = 180,            -- 文字采样用的字号
    SPRING = 0.03,              -- 弹簧系数（回归目标的力度）
    DAMPING = 0.85,             -- 阻尼（速度衰减）
    MOUSE_RADIUS = 120,         -- 鼠标排斥半径
    MOUSE_FORCE = 8,            -- 鼠标排斥力度
    RANDOM_OFFSET = 0.5,        -- 每帧微小随机扰动
}

-- 点阵字体定义 (7x9 网格, 每个字符用字符串数组表示)
-- "#" 表示有球, "." 表示空
local BITMAP_FONT = {
    ["H"] = {
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    },
    ["E"] = {
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#####",
    },
    ["L"] = {
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#####",
    },
    ["O"] = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    },
    ["W"] = {
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#.#.#",
        "##.##",
        "#...#",
    },
    ["R"] = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
    },
    ["D"] = {
        "####.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "####.",
    },
    ["!"] = {
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        ".....",
        "..#..",
    },
    ["A"] = {
        ".###.",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
    },
    ["B"] = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#...#",
        "#...#",
        "####.",
    },
    ["C"] = {
        ".####",
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        ".####",
    },
    ["F"] = {
        "#####",
        "#....",
        "#....",
        "####.",
        "#....",
        "#....",
        "#....",
    },
    ["G"] = {
        ".###.",
        "#....",
        "#....",
        "#.###",
        "#...#",
        "#...#",
        ".###.",
    },
    ["I"] = {
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "#####",
    },
    ["J"] = {
        ".####",
        "...#.",
        "...#.",
        "...#.",
        "...#.",
        "#..#.",
        ".##..",
    },
    ["K"] = {
        "#...#",
        "#..#.",
        "#.#..",
        "##...",
        "#.#..",
        "#..#.",
        "#...#",
    },
    ["M"] = {
        "#...#",
        "##.##",
        "#.#.#",
        "#.#.#",
        "#...#",
        "#...#",
        "#...#",
    },
    ["N"] = {
        "#...#",
        "##..#",
        "##..#",
        "#.#.#",
        "#..##",
        "#..##",
        "#...#",
    },
    ["P"] = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#....",
        "#....",
        "#....",
    },
    ["Q"] = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#..#.",
        ".##.#",
    },
    ["S"] = {
        ".####",
        "#....",
        "#....",
        ".###.",
        "....#",
        "....#",
        "####.",
    },
    ["T"] = {
        "#####",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    },
    ["U"] = {
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
    },
    ["V"] = {
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".#.#.",
        ".#.#.",
        "..#..",
    },
    ["X"] = {
        "#...#",
        "#...#",
        ".#.#.",
        "..#..",
        ".#.#.",
        "#...#",
        "#...#",
    },
    ["Y"] = {
        "#...#",
        "#...#",
        ".#.#.",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
    },
    ["Z"] = {
        "#####",
        "....#",
        "...#.",
        "..#..",
        ".#...",
        "#....",
        "#####",
    },
    [" "] = {
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
        ".....",
    },
}

-- ============================================================================
-- 工具函数
-- ============================================================================

--- 从文字生成目标位置列表
---@param text string
---@param screenW number
---@param screenH number
---@return table[] -- { {x, y}, ... }
local function generateTargetPositions(text, screenW, screenH)
    local positions = {}
    local spacing = CONFIG.GRID_SPACING
    local charW = 5  -- 每个字符 5 列
    local charH = 7  -- 每个字符 7 行
    local charSpacing = 1 -- 字符间距（格子数）

    -- 计算总宽度（以格子数计算）
    local totalGridW = #text * charW + (#text - 1) * charSpacing
    local totalPixelW = totalGridW * spacing
    local totalPixelH = charH * spacing

    -- 居中偏移
    local offsetX = (screenW - totalPixelW) / 2
    local offsetY = (screenH - totalPixelH) / 2

    for ci = 1, #text do
        local ch = text:sub(ci, ci):upper()
        local bitmap = BITMAP_FONT[ch]
        if bitmap then
            local charOffsetX = (ci - 1) * (charW + charSpacing) * spacing
            for row = 1, #bitmap do
                local line = bitmap[row]
                for col = 1, #line do
                    if line:sub(col, col) == "#" then
                        local x = offsetX + charOffsetX + (col - 1) * spacing
                        local y = offsetY + (row - 1) * spacing
                        table.insert(positions, { x = x, y = y })
                    end
                end
            end
        end
    end

    return positions
end

--- 创建粒子
---@param targetX number
---@param targetY number
---@param screenW number
---@param screenH number
---@return table
local function createParticle(targetX, targetY, screenW, screenH)
    -- 初始位置随机分布在屏幕各处
    local angle = math.random() * math.pi * 2
    local dist = math.random() * math.max(screenW, screenH) * 0.5
    return {
        x = screenW / 2 + math.cos(angle) * dist,
        y = screenH / 2 + math.sin(angle) * dist,
        targetX = targetX,
        targetY = targetY,
        vx = 0,
        vy = 0,
        -- 每个球一个随机颜色（HSL 色相不同）
        hue = math.random() * 360,
        radius = CONFIG.BALL_RADIUS + (math.random() - 0.5) * 2,
    }
end

--- HSL 转 RGB (简化版)
---@param h number 0-360
---@param s number 0-1
---@param l number 0-1
---@return number, number, number -- r, g, b (0-255)
local function hslToRgb(h, s, l)
    local c = (1 - math.abs(2 * l - 1)) * s
    local x = c * (1 - math.abs((h / 60) % 2 - 1))
    local m = l - c / 2
    local r, g, b = 0, 0, 0
    if h < 60 then r, g, b = c, x, 0
    elseif h < 120 then r, g, b = x, c, 0
    elseif h < 180 then r, g, b = 0, c, x
    elseif h < 240 then r, g, b = 0, x, c
    elseif h < 300 then r, g, b = x, 0, c
    else r, g, b = c, 0, x end
    return math.floor((r + m) * 255), math.floor((g + m) * 255), math.floor((b + m) * 255)
end

-- ============================================================================
-- 初始化
-- ============================================================================

local screenW_ = 0
local screenH_ = 0

local function initParticles()
    local w = graphics:GetWidth()
    local h = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    screenW_ = w / dpr
    screenH_ = h / dpr

    particles = {}
    local targets = generateTargetPositions(CONFIG.TEXT, screenW_, screenH_)
    for _, t in ipairs(targets) do
        table.insert(particles, createParticle(t.x, t.y, screenW_, screenH_))
    end
    print("Created " .. #particles .. " particles for text: " .. CONFIG.TEXT)
end

-- ============================================================================
-- 生命周期
-- ============================================================================

function Start()
    SampleStart()

    vg = nvgCreate(1)
    if not vg then
        print("ERROR: Failed to create NanoVG context")
        return
    end

    fontId = nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")

    SampleInitMouseMode(MM_FREE)

    initParticles()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent(vg, "NanoVGRender", "HandleNanoVGRender")

    print("=== Particle Text Effect Started ===")
    print("Move your mouse over the text to scatter the balls!")
end

function Stop()
    if vg then
        nvgDelete(vg)
        vg = nil
    end
end

-- ============================================================================
-- 更新逻辑
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    -- 检测屏幕尺寸变化
    local w = graphics:GetWidth()
    local h = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    local newW = w / dpr
    local newH = h / dpr
    if math.abs(newW - screenW_) > 1 or math.abs(newH - screenH_) > 1 then
        initParticles()
        return
    end

    -- 获取鼠标位置（逻辑坐标）
    local mouseX = input.mousePosition.x / dpr
    local mouseY = input.mousePosition.y / dpr

    -- 更新每个粒子
    for _, p in ipairs(particles) do
        -- 1. 弹簧力：拉回目标位置
        local dx = p.targetX - p.x
        local dy = p.targetY - p.y
        p.vx = p.vx + dx * CONFIG.SPRING
        p.vy = p.vy + dy * CONFIG.SPRING

        -- 2. 鼠标排斥力
        local mx = p.x - mouseX
        local my = p.y - mouseY
        local dist = math.sqrt(mx * mx + my * my)
        if dist < CONFIG.MOUSE_RADIUS and dist > 0.1 then
            local force = (CONFIG.MOUSE_RADIUS - dist) / CONFIG.MOUSE_RADIUS * CONFIG.MOUSE_FORCE
            p.vx = p.vx + (mx / dist) * force
            p.vy = p.vy + (my / dist) * force
        end

        -- 3. 微小随机扰动（增加活力感）
        p.vx = p.vx + (math.random() - 0.5) * CONFIG.RANDOM_OFFSET
        p.vy = p.vy + (math.random() - 0.5) * CONFIG.RANDOM_OFFSET

        -- 4. 阻尼
        p.vx = p.vx * CONFIG.DAMPING
        p.vy = p.vy * CONFIG.DAMPING

        -- 5. 更新位置
        p.x = p.x + p.vx
        p.y = p.y + p.vy

        -- 6. 缓慢变化色相（增加视觉趣味）
        p.hue = (p.hue + dt * 10) % 360
    end
end

-- ============================================================================
-- 渲染
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if not vg then return end

    local w = graphics:GetWidth()
    local h = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    local logicalW = w / dpr
    local logicalH = h / dpr

    nvgBeginFrame(vg, logicalW, logicalH, dpr)

    -- 背景
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, logicalW, logicalH)
    local bg = nvgLinearGradient(vg, 0, 0, 0, logicalH,
        nvgRGBA(15, 15, 30, 255),
        nvgRGBA(5, 5, 15, 255))
    nvgFillPaint(vg, bg)
    nvgFill(vg)

    -- 绘制鼠标排斥范围（淡淡的圆圈）
    local mouseX = input.mousePosition.x / dpr
    local mouseY = input.mousePosition.y / dpr
    nvgBeginPath(vg)
    nvgCircle(vg, mouseX, mouseY, CONFIG.MOUSE_RADIUS)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 20))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)

    -- 绘制所有粒子
    for _, p in ipairs(particles) do
        local r, g, b = hslToRgb(p.hue, 0.7, 0.6)

        -- 球体带发光效果
        nvgBeginPath(vg)
        nvgCircle(vg, p.x, p.y, p.radius)

        -- 径向渐变实现发光感
        local glow = nvgRadialGradient(vg, p.x, p.y, 0, p.radius,
            nvgRGBA(r, g, b, 240),
            nvgRGBA(r, g, b, 100))
        nvgFillPaint(vg, glow)
        nvgFill(vg)
    end

    -- 底部提示文字
    if fontId ~= -1 then
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 120))
        nvgText(vg, logicalW / 2, logicalH - 20,
            "Move your mouse over the text | 将鼠标移到文字上", nil)
    end

    nvgEndFrame(vg)
end
