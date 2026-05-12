-- ============================================================================
-- BattleRoyaleMap.lua - 坦克大战风格地图生成 / 碰撞 / 渲染
-- ============================================================================
local Settings = require("config.Settings")

local BattleRoyaleMap = {}

local BR        = Settings.BattleRoyale
local MAP_SIZE  = BR.MapSize       -- 2400
local COLS      = BR.GridCols      -- 30
local ROWS      = BR.GridRows      -- 30
local CELL      = BR.CellSize      -- 80

local grid_ = {}   -- grid_[row][col] = true(wall) / false(empty),  1-based

-- ============================================================================
-- 地图生成
-- ============================================================================

--- 在网格内安全设墙
local function setWall(r, c)
    if r >= 1 and r <= ROWS and c >= 1 and c <= COLS then
        grid_[r][c] = true
    end
end

--- 生成地图并返回出生点列表
---@return table spawnPoints  { {x=, y=}, ... }  长度 = BallCount
function BattleRoyaleMap.Generate()
    -- 初始化空网格
    grid_ = {}
    for r = 1, ROWS do
        grid_[r] = {}
        for c = 1, COLS do
            grid_[r][c] = false
        end
    end

    math.randomseed(os.time())

    -- ---- 横墙段 (3-5 格长) ----
    for _ = 1, 10 do
        local r   = math.random(3, ROWS - 2)
        local c   = math.random(2, COLS - 4)
        local len = math.random(3, 5)
        for i = 0, len - 1 do
            setWall(r, c + i)
        end
    end

    -- ---- 竖墙段 (3-5 格长) ----
    for _ = 1, 10 do
        local c   = math.random(3, COLS - 2)
        local r   = math.random(2, ROWS - 4)
        local len = math.random(3, 5)
        for i = 0, len - 1 do
            setWall(r + i, c)
        end
    end

    -- ---- L 型拐角 ----
    for _ = 1, 6 do
        local r = math.random(3, ROWS - 3)
        local c = math.random(3, COLS - 3)
        local dir = math.random(1, 4)
        setWall(r, c)
        if dir == 1 then     setWall(r - 1, c); setWall(r, c + 1)
        elseif dir == 2 then setWall(r - 1, c); setWall(r, c - 1)
        elseif dir == 3 then setWall(r + 1, c); setWall(r, c + 1)
        else                  setWall(r + 1, c); setWall(r, c - 1)
        end
    end

    -- ---- 单柱 ----
    for _ = 1, 18 do
        local r = math.random(2, ROWS - 1)
        local c = math.random(2, COLS - 1)
        setWall(r, c)
    end

    -- ---- 生成出生点 (6x6 扇区) ----
    local sectorCols = 6
    local sectorRows = 6
    local sectorW = MAP_SIZE / sectorCols   -- 400
    local sectorH = MAP_SIZE / sectorRows   -- 400
    local sectors = {}
    for i = 1, sectorCols * sectorRows do sectors[i] = i end
    -- 洗牌
    for i = #sectors, 2, -1 do
        local j = math.random(1, i)
        sectors[i], sectors[j] = sectors[j], sectors[i]
    end

    local ballCount = BR.BallCount
    local spawnPoints = {}
    for t = 1, ballCount do
        local idx = sectors[((t - 1) % #sectors) + 1]
        local sr = math.floor((idx - 1) / sectorCols)
        local sc = (idx - 1) % sectorCols
        local sx = sc * sectorW + math.random(80, sectorW - 80)
        local sy = sr * sectorH + math.random(80, sectorH - 80)
        spawnPoints[t] = { x = sx, y = sy }

        -- 清除出生点周围 2 格墙壁
        local gc = math.floor(sx / CELL) + 1
        local gr = math.floor(sy / CELL) + 1
        for dr = -2, 2 do
            for dc = -2, 2 do
                local rr, cc = gr + dr, gc + dc
                if rr >= 1 and rr <= ROWS and cc >= 1 and cc <= COLS then
                    grid_[rr][cc] = false
                end
            end
        end
    end

    return spawnPoints
end

-- ============================================================================
-- 球 vs 墙格碰撞
-- ============================================================================

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

--- 检测并解决球与墙格碰撞（就地修改 ball.x/y/vx/vy）
function BattleRoyaleMap.ResolveBallCollision(ball, radius)
    local bounce = Settings.Ball.BounceRestitution

    -- 地图边界
    if ball.x - radius < 0 then
        ball.x = radius; ball.vx = math.abs(ball.vx) * bounce
    elseif ball.x + radius > MAP_SIZE then
        ball.x = MAP_SIZE - radius; ball.vx = -math.abs(ball.vx) * bounce
    end
    if ball.y - radius < 0 then
        ball.y = radius; ball.vy = math.abs(ball.vy) * bounce
    elseif ball.y + radius > MAP_SIZE then
        ball.y = MAP_SIZE - radius; ball.vy = -math.abs(ball.vy) * bounce
    end

    -- 球包围盒覆盖的格子范围
    local minC = math.max(1, math.floor((ball.x - radius) / CELL) + 1)
    local maxC = math.min(COLS, math.floor((ball.x + radius) / CELL) + 1)
    local minR = math.max(1, math.floor((ball.y - radius) / CELL) + 1)
    local maxR = math.min(ROWS, math.floor((ball.y + radius) / CELL) + 1)

    for r = minR, maxR do
        for c = minC, maxC do
            if grid_[r][c] then
                local cl = (c - 1) * CELL
                local ct = (r - 1) * CELL
                local cr = c * CELL
                local cb = r * CELL

                local closestX = clamp(ball.x, cl, cr)
                local closestY = clamp(ball.y, ct, cb)
                local dx = ball.x - closestX
                local dy = ball.y - closestY
                local dist2 = dx * dx + dy * dy

                if dist2 < radius * radius and dist2 > 0.0001 then
                    local dist = math.sqrt(dist2)
                    local nx, ny = dx / dist, dy / dist
                    -- 推出
                    ball.x = closestX + nx * (radius + 0.1)
                    ball.y = closestY + ny * (radius + 0.1)
                    -- 反弹
                    local dot = ball.vx * nx + ball.vy * ny
                    if dot < 0 then
                        ball.vx = (ball.vx - 2 * dot * nx) * bounce
                        ball.vy = (ball.vy - 2 * dot * ny) * bounce
                    end
                end
            end
        end
    end
end

-- ============================================================================
-- 绘制
-- ============================================================================

--- 绘制视口内可见的墙格
---@param vg userdata  NanoVG context
---@param viewL number 视口左边界(地图坐标)
---@param viewT number 视口上边界(地图坐标)
---@param viewSize number 视口尺寸
function BattleRoyaleMap.Draw(vg, viewL, viewT, viewSize)
    local viewR = viewL + viewSize
    local viewB = viewT + viewSize

    -- 可见格子范围
    local minC = math.max(1, math.floor(viewL / CELL) + 1)
    local maxC = math.min(COLS, math.floor(viewR / CELL) + 1)
    local minR = math.max(1, math.floor(viewT / CELL) + 1)
    local maxR = math.min(ROWS, math.floor(viewB / CELL) + 1)

    -- 地面背景 (深色)
    nvgBeginPath(vg)
    nvgRect(vg, viewL, viewT, viewSize, viewSize)
    nvgFillColor(vg, nvgRGBA(18, 22, 28, 255))
    nvgFill(vg)

    -- 淡网格线
    nvgStrokeWidth(vg, 0.5)
    nvgStrokeColor(vg, nvgRGBA(40, 48, 58, 120))
    for r = minR, maxR + 1 do
        local y = (r - 1) * CELL
        nvgBeginPath(vg); nvgMoveTo(vg, viewL, y); nvgLineTo(vg, viewR, y); nvgStroke(vg)
    end
    for c = minC, maxC + 1 do
        local x = (c - 1) * CELL
        nvgBeginPath(vg); nvgMoveTo(vg, x, viewT); nvgLineTo(vg, x, viewB); nvgStroke(vg)
    end

    -- 墙格 (砖色)
    for r = minR, maxR do
        for c = minC, maxC do
            if grid_[r][c] then
                local x = (c - 1) * CELL
                local y = (r - 1) * CELL
                -- 砖体
                nvgBeginPath(vg)
                nvgRect(vg, x + 1, y + 1, CELL - 2, CELL - 2)
                nvgFillColor(vg, nvgRGBA(140, 90, 50, 230))
                nvgFill(vg)
                -- 砖纹 (中间横线 + 竖线)
                nvgStrokeWidth(vg, 1.0)
                nvgStrokeColor(vg, nvgRGBA(100, 60, 30, 180))
                nvgBeginPath(vg)
                nvgMoveTo(vg, x + 2, y + CELL * 0.5)
                nvgLineTo(vg, x + CELL - 2, y + CELL * 0.5)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgMoveTo(vg, x + CELL * 0.5, y + 2)
                nvgLineTo(vg, x + CELL * 0.5, y + CELL * 0.5 - 1)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgMoveTo(vg, x + CELL * 0.25, y + CELL * 0.5 + 1)
                nvgLineTo(vg, x + CELL * 0.25, y + CELL - 2)
                nvgStroke(vg)
                nvgBeginPath(vg)
                nvgMoveTo(vg, x + CELL * 0.75, y + CELL * 0.5 + 1)
                nvgLineTo(vg, x + CELL * 0.75, y + CELL - 2)
                nvgStroke(vg)
                -- 高光边
                nvgStrokeWidth(vg, 1.0)
                nvgStrokeColor(vg, nvgRGBA(180, 130, 80, 100))
                nvgBeginPath(vg)
                nvgRect(vg, x + 2, y + 2, CELL - 4, CELL - 4)
                nvgStroke(vg)
            end
        end
    end

    -- 地图边界 (亮色框)
    nvgStrokeWidth(vg, 3)
    nvgStrokeColor(vg, nvgRGBA(200, 160, 60, 200))
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, MAP_SIZE, MAP_SIZE)
    nvgStroke(vg)
end

--- 判断某格是否是墙
function BattleRoyaleMap.IsWall(row, col)
    if row < 1 or row > ROWS or col < 1 or col > COLS then return true end
    return grid_[row][col] == true
end

--- 获取网格引用 (只读)
function BattleRoyaleMap.GetGrid()
    return grid_
end

return BattleRoyaleMap
