-- ============================================================================
-- ParticleTitle.lua - 粒子文字标题效果
-- 游戏风格球球聚集成文字，鼠标滑过时散开，离开后重新聚集
-- 每个球有渐变、高光，大小不一
-- 支持多行文本（用 \n 分隔）
-- 特性：15% 色彩偏差 + 10% 大小偏差
-- ============================================================================

local ParticleTitle = {}

-- ============================================================================
-- 配置
-- ============================================================================

local CONFIG = {
    GRID_SPACING   = 10,     -- 点阵间距
    SPRING         = 0.04,   -- 弹簧系数（回归力度）
    DAMPING        = 0.82,   -- 阻尼
    MOUSE_RADIUS   = 120,    -- 鼠标排斥半径
    MOUSE_FORCE    = 12,     -- 鼠标排斥力度
    RANDOM_OFFSET  = 0.3,    -- 随机扰动
    INIT_SCATTER   = 400,    -- 初始散开范围
    RADIUS_MIN     = 6,      -- 球最小半径
    RADIUS_MAX     = 14,     -- 球最大半径

    -- 偏差参数
    COLOR_VARIANCE = 0.15,   -- 15% 色彩偏差
    SIZE_VARIANCE  = 0.10,   -- 10% 大小偏差
}

-- ============================================================================
-- 5x7 英文点阵字体
-- ============================================================================

local CHAR_BITMAPS = {
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
    ["D"] = {
        "####.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "####.",
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
    ["H"] = {
        "#...#",
        "#...#",
        "#...#",
        "#####",
        "#...#",
        "#...#",
        "#...#",
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
    ["L"] = {
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#....",
        "#####",
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
    ["O"] = {
        ".###.",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        "#...#",
        ".###.",
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
    ["R"] = {
        "####.",
        "#...#",
        "#...#",
        "####.",
        "#.#..",
        "#..#.",
        "#...#",
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
    ["W"] = {
        "#...#",
        "#...#",
        "#...#",
        "#.#.#",
        "#.#.#",
        "##.##",
        "#...#",
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
    ["!"] = {
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        "..#..",
        ".....",
        "..#..",
    },
    [" "] = {
        "...",
        "...",
        "...",
        "...",
        "...",
        "...",
        "...",
    },
}

-- ============================================================================
-- 状态
-- ============================================================================

---@type table|nil
local state_ = nil

-- ============================================================================
-- 内部函数
-- ============================================================================

--- 获取字符点阵的宽度（列数）
local function getCharWidth(ch)
    local bitmap = CHAR_BITMAPS[ch]
    if not bitmap or #bitmap == 0 then return 0 end
    return #bitmap[1]
end

--- 获取字符点阵的高度（行数）
local function getCharHeight(ch)
    local bitmap = CHAR_BITMAPS[ch]
    if not bitmap then return 0 end
    return #bitmap
end

--- 将文本拆成单行字符列表
local function splitLineToChars(line)
    local chars = {}
    for _, code in utf8.codes(line) do
        table.insert(chars, utf8.char(code):upper())
    end
    return chars
end

--- 从多行文字生成目标位置（相对于整体中心）
local function generateRelativePositions(text)
    local spacing = CONFIG.GRID_SPACING
    local charGap = 1
    local lineGap = 3

    local lines = {}
    for seg in text:gmatch("[^\n]+") do
        table.insert(lines, seg)
    end

    local lineInfos = {}
    local maxLinePixelW = 0
    local charH = 7

    for li, line in ipairs(lines) do
        local chars = splitLineToChars(line)
        local lineGridW = 0
        for ci, ch in ipairs(chars) do
            local cw = getCharWidth(ch)
            if cw > 0 then
                if ci > 1 then lineGridW = lineGridW + charGap end
                lineGridW = lineGridW + cw
            end
            local ch2 = getCharHeight(ch)
            if ch2 > charH then charH = ch2 end
        end
        local linePixelW = lineGridW * spacing
        if linePixelW > maxLinePixelW then maxLinePixelW = linePixelW end
        lineInfos[li] = { chars = chars, gridW = lineGridW, pixelW = linePixelW }
    end

    local totalLines = #lines
    local totalPixelH = (totalLines * charH + (totalLines - 1) * lineGap) * spacing

    local positions = {}
    for li, info in ipairs(lineInfos) do
        local lineOffsetX = (maxLinePixelW - info.pixelW) / 2
        local lineOffsetY = ((li - 1) * (charH + lineGap)) * spacing

        local cursorX = 0
        for ci, ch in ipairs(info.chars) do
            local bitmap = CHAR_BITMAPS[ch]
            if bitmap then
                local cw = #bitmap[1]
                if ci > 1 then cursorX = cursorX + charGap end
                for row = 1, #bitmap do
                    local rowStr = bitmap[row]
                    for col = 1, #rowStr do
                        if rowStr:sub(col, col) == "#" then
                            local x = lineOffsetX + (cursorX + col - 1) * spacing
                            local y = lineOffsetY + (row - 1) * spacing
                            table.insert(positions, {
                                rx = x - maxLinePixelW / 2,
                                ry = y - totalPixelH / 2,
                            })
                        end
                    end
                end
                cursorX = cursorX + cw
            end
        end
    end

    return positions, maxLinePixelW, totalPixelH
end

--- 带偏差的颜色生成（基于基色 + 偏差百分比）
local function jitterColor(base, variance)
    local lo = math.max(0, math.floor(base * (1 - variance)))
    local hi = math.min(255, math.floor(base * (1 + variance)))
    if hi <= lo then return base end
    return lo + math.random(0, hi - lo)
end

--- 带偏差的半径生成
local function jitterRadius(baseRadius, variance)
    local lo = baseRadius * (1 - variance)
    local hi = baseRadius * (1 + variance)
    return lo + math.random() * (hi - lo)
end

--- 绘制单个球球
local function drawGameBall(vg, cx, cy, radius, cr, cg, cb)
    local innerColor = nvgRGBA(
        math.min(255, cr + 40),
        math.min(255, cg + 40),
        math.min(255, cb + 40), 255)
    local outerColor = nvgRGBA(
        math.max(0, cr - 50),
        math.max(0, cg - 50),
        math.max(0, cb - 50), 255)
    local grad = nvgRadialGradient(vg,
        cx - radius * 0.2, cy - radius * 0.25,
        radius * 0.1, radius * 1.0,
        innerColor, outerColor)

    nvgBeginPath(vg)
    nvgCircle(vg, cx, cy, radius)
    nvgFillPaint(vg, grad)
    nvgFill(vg)

    -- 高光
    nvgBeginPath(vg)
    nvgCircle(vg, cx - radius * 0.2, cy - radius * 0.3, radius * 0.25)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 60))
    nvgFill(vg)
end

-- ============================================================================
-- 公开接口
-- ============================================================================

--- 初始化粒子标题
function ParticleTitle.Init(text, centerX, centerY, options)
    options = options or {}

    if options.gridSpacing then CONFIG.GRID_SPACING = options.gridSpacing end
    if options.mouseRadius then CONFIG.MOUSE_RADIUS = options.mouseRadius end
    if options.radiusMin then CONFIG.RADIUS_MIN = options.radiusMin end
    if options.radiusMax then CONFIG.RADIUS_MAX = options.radiusMax end

    local positions, totalW, totalH = generateRelativePositions(text)

    -- 创建标题粒子（带 15% 色差和 10% 大小偏差）
    local particles = {}
    for _, p in ipairs(positions) do
        local angle = math.random() * math.pi * 2
        local dist = math.random() * CONFIG.INIT_SCATTER

        local baseRadius = CONFIG.RADIUS_MIN + math.random() * (CONFIG.RADIUS_MAX - CONFIG.RADIUS_MIN)
        local radius = jitterRadius(baseRadius, CONFIG.SIZE_VARIANCE)

        local v = CONFIG.COLOR_VARIANCE
        local cr = jitterColor(26, v)
        local cg = jitterColor(78, v)
        local cb = jitterColor(91, v)

        table.insert(particles, {
            x = centerX + math.cos(angle) * dist,
            y = centerY + math.sin(angle) * dist,
            rx = p.rx,
            ry = p.ry,
            vx = 0,
            vy = 0,
            radius = radius,
            cr = cr, cg = cg, cb = cb,
            bobPhase = math.random() * math.pi * 2,
        })
    end

    state_ = {
        particles = particles,
        centerX = centerX,
        centerY = centerY,
        totalW = totalW,
        totalH = totalH,
        elapsed = 0,
    }

    print("[ParticleTitle] Initialized with " .. #particles .. " game balls for: " .. text:gsub("\n", " "))
end

--- 更新中心位置
function ParticleTitle.SetCenter(centerX, centerY)
    if state_ then
        state_.centerX = centerX
        state_.centerY = centerY
    end
end

--- 更新粒子物理
function ParticleTitle.Update(dt, mouseX, mouseY)
    if not state_ then return end
    state_.elapsed = state_.elapsed + dt

    for _, p in ipairs(state_.particles) do
        local bobAmp = 2
        local bobY = math.sin(state_.elapsed * 1.5 + p.bobPhase) * bobAmp
        local targetX = state_.centerX + p.rx
        local targetY = state_.centerY + p.ry + bobY

        -- 弹簧力
        local dx = targetX - p.x
        local dy = targetY - p.y
        p.vx = p.vx + dx * CONFIG.SPRING
        p.vy = p.vy + dy * CONFIG.SPRING

        -- 鼠标排斥力
        local mx = p.x - mouseX
        local my = p.y - mouseY
        local dist = math.sqrt(mx * mx + my * my)
        if dist < CONFIG.MOUSE_RADIUS and dist > 0.1 then
            local force = (CONFIG.MOUSE_RADIUS - dist) / CONFIG.MOUSE_RADIUS * CONFIG.MOUSE_FORCE
            p.vx = p.vx + (mx / dist) * force
            p.vy = p.vy + (my / dist) * force
        end

        -- 随机扰动
        p.vx = p.vx + (math.random() - 0.5) * CONFIG.RANDOM_OFFSET
        p.vy = p.vy + (math.random() - 0.5) * CONFIG.RANDOM_OFFSET

        -- 阻尼
        p.vx = p.vx * CONFIG.DAMPING
        p.vy = p.vy * CONFIG.DAMPING

        p.x = p.x + p.vx
        p.y = p.y + p.vy
    end
end

--- 渲染所有球球
function ParticleTitle.Render(vg)
    if not state_ then return end

    local sorted = {}
    for i, p in ipairs(state_.particles) do
        sorted[i] = p
    end
    table.sort(sorted, function(a, b) return a.radius < b.radius end)

    -- 第一遍：绘制阴影
    local shadowOffX = 10
    local shadowOffY = 10
    for _, p in ipairs(sorted) do
        local sx = p.x + shadowOffX
        local sy = p.y + shadowOffY
        local sr = p.radius * 0.9
        nvgBeginPath(vg)
        nvgCircle(vg, sx, sy, sr)
        nvgFillColor(vg, nvgRGBA(15, 60, 20, 100))
        nvgFill(vg)
    end

    -- 第二遍：绘制球体本体
    for _, p in ipairs(sorted) do
        nvgSave(vg)
        drawGameBall(vg, p.x, p.y, p.radius, p.cr, p.cg, p.cb)
        nvgRestore(vg)
    end
end

--- 渲染鼠标排斥范围指示器
function ParticleTitle.RenderMouseIndicator(vg, mouseX, mouseY)
    nvgBeginPath(vg)
    nvgCircle(vg, mouseX, mouseY, CONFIG.MOUSE_RADIUS)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 15))
    nvgStrokeWidth(vg, 1)
    nvgStroke(vg)
end

--- 检查是否已初始化
function ParticleTitle.IsActive()
    return state_ ~= nil
end

--- 销毁
function ParticleTitle.Destroy()
    state_ = nil
end

return ParticleTitle
