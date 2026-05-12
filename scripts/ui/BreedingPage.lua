-- ============================================================================
-- BreedingPage.lua - 球球养殖页面（含战斗系统）
-- 养殖场（可升级，内含弹跳球球）+ 战斗区域（拖拽球进入槽位开始战斗）
-- 球有等级系统：1-20级，HP递增(30~500)，2级+强化技能，3级+终结技能，血量阈值触发
-- 使用 NanoVG 渲染
-- ============================================================================

local BreedingPage = {}

local SkillRegistry     = require("game.SkillRegistry")
local SkillExecutor     = require("game.SkillExecutor")
local BallAI            = require("game.BallAI")
local BallCustomization = require("game.BallCustomization")
local Expressions       = require("game.Expressions")
local ArenaBattle       = require("ui.ArenaBattle")
local ArenaCloud        = require("game.ArenaCloud")
local CloudSave         = require("game.CloudSave")

-- ============================================================================
-- State
-- ============================================================================

local active_ = false
local elapsedTime_ = 0

-- Economy
local gold_ = 1000000

-- Battle slots: 5 cols x 4 rows = 20 total, start with 5 unlocked
local GRID_COLS = 5
local GRID_ROWS = 4
local MAX_SLOTS = GRID_COLS * GRID_ROWS
local INITIAL_UNLOCKED = 5
local slotsUnlocked_ = INITIAL_UNLOCKED

-- Slot unlock costs
local SLOT_COSTS = {
    3000, 5000, 8000, 12000, 18000,
    28000, 42000, 60000, 85000, 120000,
    170000, 240000, 330000, 450000, 600000,
}

-- Farm: 7 upgrade levels
local MAX_FARM_LEVEL = 8
local farmLevel_ = 1
local FARM_COSTS = { 5000, 15000, 40000, 80000, 160000, 300000, 500000 }
local FARM_SCALE = { 0.35, 0.45, 0.55, 0.65, 0.75, 0.85, 0.92, 1.0 }

-- Farm balls (boids inside the farm)
local farmBalls_ = {}
local INITIAL_BALL_COUNT = 3

-- Auto-spawn timer
local spawnTimer_ = 0
local SPAWN_INTERVAL = 5.0

-- Auto-save timer
local saveTimer_ = 0
local SAVE_INTERVAL = 30.0

-- Farm capacity per level
local FARM_CAPACITY = { 8, 12, 18, 25, 35, 45, 55, 70 }

-- Farm level restrictions: max ball level, new ball starting level, spawn interval
-- Farm lv1: max ball lv1, new ball lv1, spawn 5s
-- Farm lv8: max ball lv7, new ball lv3, spawn 1s
-- Linearly interpolated between
local FARM_MAX_BALL_LEVEL = { 1, 2, 3, 4, 5, 5, 6, 7 }
local FARM_NEW_BALL_LEVEL = { 1, 1, 1, 2, 2, 2, 3, 3 }
local FARM_SPAWN_RATE     = { 5.0, 4.4, 3.8, 3.1, 2.5, 2.0, 1.5, 1.0 }

-- Mouse position
local mouseLocalX_ = -9999
local mouseLocalY_ = -9999
local mouseDesignX_ = -9999
local mouseDesignY_ = -9999

-- Boids parameters
local BOIDS = {
    separationDist = 30,
    separationWeight = 120,
    alignmentWeight = 0.3,
    cohesionWeight = 0.8,
    neighborDist = 80,
    maxSpeed = 60,
    minSpeed = 15,
    mouseAvoidDist = 120,
    mouseAvoidWeight = 200,
    wallMargin = 15,
    wallWeight = 150,
}

-- Random name generator (甜品 + 球)
local DESSERT_NAMES = {
    "提拉米苏", "马卡龙", "舒芙蕾", "布丁", "慕斯",
    "泡芙", "可丽露", "千层", "蛋挞", "奶冻",
    "芝士", "抹茶", "焦糖", "蜜桃", "草莓",
    "芒果", "蓝莓", "樱桃", "柠檬", "椰奶",
    "红豆", "芋泥", "黑糖", "桂花", "玫瑰",
    "香草", "巧克力", "杏仁", "榛果", "开心果",
    "棉花糖", "太妃糖", "牛轧糖", "雪媚娘", "大福",
    "铜锣烧", "华夫饼", "可颂", "麻薯", "糯米糍",
    "冰淇淋", "奶昔", "果冻", "年糕", "汤圆",
    "豆花", "双皮奶", "杨枝甘露", "班戟", "拿破仑",
}

local function GenerateRandomName()
    local d = DESSERT_NAMES[math.random(1, #DESSERT_NAMES)]
    return d .. "球"
end

-- Callbacks
local callbacks_ = nil

-- Input hover state
local hoverSlotBtn_ = false
local hoverFarmBtn_ = false
local hoverBackBtn_ = false
local hoverAiBtn_ = false

-- Best streak record (persisted)
local bestStreak_ = 0

-- AI auto-match system
local MAX_AI_LEVEL = 10
local aiLevel_ = 0     -- 0 = not purchased, 1-10 = active levels
local aiEnabled_ = false  -- toggle on/off (only meaningful when aiLevel_ > 0)
local aiTimer_ = 0
local hoverAiUpgrade_ = false  -- hover on upgrade text below AI button
local AI_COSTS = { 5000, 8000, 12000, 18000, 25000, 35000, 50000, 70000, 100000 }
-- Interval decreases: 5s at level 1, down to 1s at level 10
local function GetAiInterval()
    if aiLevel_ <= 0 then return 999 end
    -- 5.0 → 1.0 linearly over 10 levels
    return math.max(1.0, 5.0 - (aiLevel_ - 1) * (4.0 / 9))
end

-- ============================================================================
-- Ball Level & Experience System
-- ============================================================================

-- Level definitions: HP grows with diminishing returns, capping ~500
-- Skill trigger thresholds: normal always 100%, enhanced starts 60% and grows, ultimate starts 30% and grows
local LEVEL_DEFS = {
    [1]  = { maxHp = 30,   expToNext = 50,   label = "Lv.1",  enhancedThreshold = 0.60, ultimateThreshold = 0.30 },
    [2]  = { maxHp = 60,   expToNext = 60,   label = "Lv.2",  enhancedThreshold = 0.60, ultimateThreshold = 0.30 },
    [3]  = { maxHp = 100,  expToNext = 80,   label = "Lv.3",  enhancedThreshold = 0.62, ultimateThreshold = 0.32 },
    [4]  = { maxHp = 150,  expToNext = 100,  label = "Lv.4",  enhancedThreshold = 0.64, ultimateThreshold = 0.34 },
    [5]  = { maxHp = 200,  expToNext = 120,  label = "Lv.5",  enhancedThreshold = 0.66, ultimateThreshold = 0.36 },
    [6]  = { maxHp = 250,  expToNext = 150,  label = "Lv.6",  enhancedThreshold = 0.68, ultimateThreshold = 0.38 },
    [7]  = { maxHp = 300,  expToNext = 180,  label = "Lv.7",  enhancedThreshold = 0.70, ultimateThreshold = 0.40 },
    [8]  = { maxHp = 340,  expToNext = 210,  label = "Lv.8",  enhancedThreshold = 0.72, ultimateThreshold = 0.42 },
    [9]  = { maxHp = 370,  expToNext = 240,  label = "Lv.9",  enhancedThreshold = 0.74, ultimateThreshold = 0.44 },
    [10] = { maxHp = 395,  expToNext = 280,  label = "Lv.10", enhancedThreshold = 0.76, ultimateThreshold = 0.46 },
    [11] = { maxHp = 415,  expToNext = 320,  label = "Lv.11", enhancedThreshold = 0.78, ultimateThreshold = 0.48 },
    [12] = { maxHp = 430,  expToNext = 360,  label = "Lv.12", enhancedThreshold = 0.80, ultimateThreshold = 0.50 },
    [13] = { maxHp = 445,  expToNext = 400,  label = "Lv.13", enhancedThreshold = 0.82, ultimateThreshold = 0.52 },
    [14] = { maxHp = 458,  expToNext = 450,  label = "Lv.14", enhancedThreshold = 0.84, ultimateThreshold = 0.54 },
    [15] = { maxHp = 468,  expToNext = 500,  label = "Lv.15", enhancedThreshold = 0.86, ultimateThreshold = 0.56 },
    [16] = { maxHp = 477,  expToNext = 550,  label = "Lv.16", enhancedThreshold = 0.88, ultimateThreshold = 0.58 },
    [17] = { maxHp = 484,  expToNext = 600,  label = "Lv.17", enhancedThreshold = 0.90, ultimateThreshold = 0.60 },
    [18] = { maxHp = 490,  expToNext = 660,  label = "Lv.18", enhancedThreshold = 0.92, ultimateThreshold = 0.62 },
    [19] = { maxHp = 495,  expToNext = 720,  label = "Lv.19", enhancedThreshold = 0.94, ultimateThreshold = 0.64 },
    [20] = { maxHp = 500,  expToNext = nil,  label = "Lv.20", enhancedThreshold = 0.95, ultimateThreshold = 0.65 },
}
local MAX_LEVEL = 20

-- ============================================================================
-- Battle System
-- ============================================================================

-- Battle slots: each slot can hold multiple balls for battle
-- slotBalls_[slotIdx] = { ball1, ball2, ... } or {}
local slotBalls_ = {}

-- Active battles: one per slot
-- activeBattles_[slotIdx] = { balls={...}, aiStates={...}, projectiles={...}, ... } or nil
local activeBattles_ = {}

-- Battle arena constants (within each slot)
-- Use 400 to match SkillExecutor's Settings.Arena.Size for full skill effects
local BATTLE_ARENA_SIZE = 400
local BATTLE_BALL_RADIUS = 20   -- match Settings.Ball.Radius
local BATTLE_BALL_SPEED = 150
local BATTLE_SPEED_CAP = 300
local BATTLE_COLLISION_DMG = 1
local BATTLE_EXP_WIN = 30  -- experience gained on win

-- Drag state: dragging a ball from farm to battle slot
local dragBall_ = nil  -- { farmIndex=int, ball=ref, curX, curY } or nil
local dragFromSlot_ = nil  -- { slotIdx=int, ballIdx=int, ball=ref, curX, curY }

-- Battle projectiles are now managed by SkillExecutor per slot via seState snapshots
local PROJ_SPEED = 500  -- for AI lead prediction only

-- Victory celebration constants
local VICTORY_DURATION = 5.5      -- total celebration time before clearing slot
local VICTORY_ENLARGE_TIME = 0.5  -- time to grow to enlarged size
local VICTORY_BOUNCE_SPEED = 350  -- winner bounce speed
local VICTORY_COIN_REWARD = 10    -- gold reward per win

-- Module-level gold animation state (shared across all slots, rendered in main Render)
local goldParticles_ = {}         -- gold particles flying toward gold button
local goldAnimating_ = false
local goldDisplayValue_ = 0       -- smoothly animated display value
local goldTargetValue_ = 0        -- target gold value
local goldShakeTimer_ = 0         -- gold button shake timer
local goldShakeIntensity_ = 0     -- gold button shake intensity

-- Persistent coins: coins that survive after battle slots are cleared
-- Each: { x, y (design coords), visible, collected, value, wobble, rotation, scale, radius, merged }
local persistentCoins_ = {}

-- Trash can facility (right side)
-- Sell value per color grade (1=white..7=rainbow)
local TRASH_SELL_VALUES = { 10, 40, 150, 500, 1500, 5000, 10000 }
local trashExplosions_ = {}  -- { x, y, particles = {}, timer }
local trashCoins_ = {}       -- { x, y, visible, collected, value, wobble, rotation, scale, radius, merged }
local hoverTrashCan_ = false
local trashLidAngle_ = 0       -- lid open angle in radians (0=closed, ~1.2=open)
local trashLidShake_ = 0       -- shake timer (>0 = shaking)

-- Arena facility (left side) - framework placeholder
local hoverArena_ = false

-- Crown image handle (loaded once on first render)
local crownImgHandle_ = nil

-- Streak battle system
local STREAK_COUNTDOWN = 5.0         -- seconds to wait for challenger
local STREAK_BASE_REWARD = 10        -- base gold reward (multiplied by streakCount)
local streakFireParticles_ = {}      -- fire particles for streak visual effect

-- Multi-ball streak battles: max balls by streak count
local function GetMaxBattleBalls(streakCount)
    if not streakCount or streakCount < 4 then return 2 end
    return math.min(5, 2 + math.floor((streakCount - 2) / 2))
end

--- Find a farm ball with level closest to targetLevel (within maxDiff).
--- @param targetLevel number
--- @param maxDiff number
--- @return number|nil  farm ball index
local function FindLevelMatchBall(targetLevel, maxDiff)
    if #farmBalls_ == 0 then return nil end
    local bestIdx = nil
    local bestDiff = math.huge
    for fi = 1, #farmBalls_ do
        local diff = math.abs((farmBalls_[fi].level or 1) - targetLevel)
        if diff < bestDiff then
            bestDiff = diff
            bestIdx = fi
        end
    end
    if bestIdx and bestDiff <= maxDiff then return bestIdx end
    return bestIdx  -- fallback to closest
end

-- ============================================================================
-- Level-based color system (7 grades)
-- Lv1=White, Lv2=Green, Lv3=Blue, Lv4=Purple, Lv5=Orange, Lv6=Red, Lv7=Rainbow
-- Levels 8+ cycle back (lv8=white, lv9=green...) but keep their actual level
-- ============================================================================

local LEVEL_BASE_COLORS = {
    [1] = { r = 230, g = 230, b = 235 },  -- White
    [2] = { r = 80,  g = 210, b = 100 },  -- Green
    [3] = { r = 70,  g = 150, b = 255 },  -- Blue
    [4] = { r = 170, g = 80,  b = 230 },  -- Purple
    [5] = { r = 255, g = 160, b = 40  },  -- Orange
    [6] = { r = 240, g = 60,  b = 60  },  -- Red
    [7] = { r = 255, g = 255, b = 255 },  -- Rainbow (placeholder, handled in render)
}

--- Get the color grade (1-7) for a given ball level
local function GetColorGrade(level)
    return ((level - 1) % 7) + 1
end

--- Get color for a ball based on its level, with small random offset
--- For level 7 (rainbow), returns a cycling color based on elapsed time
local function GetLevelColor(level, randomSeed)
    local grade = GetColorGrade(level)
    if grade == 7 then
        -- Rainbow: return white as base, rendering handles the cycle
        return { r = 255, g = 255, b = 255, rainbow = true }
    end
    local base = LEVEL_BASE_COLORS[grade]
    -- Small random offset (±15) seeded from randomSeed or random
    local seed = randomSeed or math.random(0, 1000)
    math.randomseed(math.floor(seed))
    local offR = math.random(-15, 15)
    local offG = math.random(-15, 15)
    local offB = math.random(-15, 15)
    -- Restore random state with integer seed
    math.randomseed(math.floor(os.clock() * 100000) + math.random(1, 99999))
    return {
        r = math.max(0, math.min(255, base.r + offR)),
        g = math.max(0, math.min(255, base.g + offG)),
        b = math.max(0, math.min(255, base.b + offB)),
        rainbow = false,
    }
end

-- Legacy fallback for old saves without level-based color
local BALL_COLORS = {
    { r = 255, g = 120, b = 40  },
    { r = 60,  g = 200, b = 255 },
    { r = 255, g = 80,  b = 120 },
    { r = 120, g = 255, b = 100 },
    { r = 255, g = 220, b = 50  },
    { r = 180, g = 100, b = 255 },
    { r = 255, g = 160, b = 180 },
    { r = 100, g = 220, b = 200 },
}

-- ============================================================================
-- Farm Ball Definitions
-- ============================================================================

local FARM_BALL_RADIUS = 8
local FARM_BALL_COLOR = { r = 230, g = 230, b = 240 }

-- ============================================================================
-- Persistence: save/load farm ball state
-- ============================================================================

local BREEDING_SAVE_FILE = "breeding_data.json"

--- Serialize a ball's persistent fields
local function SerializeBall(ball)
    return {
        color = ball.color,
        name = ball.name,
        expression = ball.expression,
        level = ball.level,
        exp = ball.exp,
        hp = ball.hp,
        maxHp = ball.maxHp,
        skill = ball.skill,
        enhancedSkill = ball.enhancedSkill,
        ultimateSkill = ball.ultimateSkill,
        radius = ball.radius,
    }
end

--- Collect all player balls (farm + slots) serialized for cloud upload
local function GetUploadableBalls()
    -- Only balls that have been placed into arena battles count for the character pool
    -- Farm balls are NOT included
    local out = {}
    local added = {}  -- track by name to avoid duplicates

    -- 1) Balls in slot battles (mini arena)
    for idx = 1, MAX_SLOTS do
        if slotBalls_[idx] then
            for _, ball in ipairs(slotBalls_[idx]) do
                local s = SerializeBall(ball)
                out[#out + 1] = s
                if s.name then added[s.name] = true end
            end
        end
    end

    -- 2) Ball currently in the fullscreen arena battle
    local arenaFarmBall = ArenaBattle.GetPlayerFarmBall()
    if arenaFarmBall and arenaFarmBall.name and not added[arenaFarmBall.name] then
        out[#out + 1] = SerializeBall(arenaFarmBall)
    end

    return out
end

local function SaveBreedingData()
    local data = {
        gold = gold_,
        farmLevel = farmLevel_,
        slotsUnlocked = slotsUnlocked_,
        aiLevel = aiLevel_,
        aiEnabled = aiEnabled_,
        bestStreak = bestStreak_,
        balls = {},
        slotBalls = {},  -- balls placed in battle slots (not in farm)
        persistentCoins = {},  -- coins that persist across battles
    }
    -- Save persistent coins
    for _, coin in ipairs(persistentCoins_) do
        if coin.visible and not coin.collected then
            table.insert(data.persistentCoins, {
                x = coin.x, y = coin.y, value = coin.value,
                radius = coin.radius, merged = coin.merged,
            })
        end
    end
    -- Save farm balls
    for _, ball in ipairs(farmBalls_) do
        table.insert(data.balls, SerializeBall(ball))
    end
    -- Save arena battle state
    data.arena = ArenaBattle.GetSaveData()

    -- Save slot balls (waiting or in active battle)
    for idx = 1, MAX_SLOTS do
        local slotData = {}
        -- If a battle is active in this slot, save the living battle balls' farmBall refs
        local battle = activeBattles_ and activeBattles_[idx]
        if battle and battle.balls then
            for _, bb in ipairs(battle.balls) do
                if bb.alive and bb.farmBall then
                    table.insert(slotData, SerializeBall(bb.farmBall))
                end
            end
        elseif slotBalls_[idx] then
            -- No active battle: save the waiting balls directly
            for _, ball in ipairs(slotBalls_[idx]) do
                table.insert(slotData, SerializeBall(ball))
            end
        end
        if #slotData > 0 then
            data.slotBalls[tostring(idx)] = slotData
        end
    end
    local json = cjson.encode(data)
    local file = File(BREEDING_SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(json)
        file:Close()
        print(string.format("[Breeding] Saved breeding data (%d farm balls, slots with balls saved)", #data.balls))
    end

    -- Also save to cloud (async, non-blocking)
    CloudSave.Save(data)
end

local function LoadBreedingData()
    if not fileSystem:FileExists(BREEDING_SAVE_FILE) then
        return nil
    end
    local file = File(BREEDING_SAVE_FILE, FILE_READ)
    if not file:IsOpen() then return nil end
    local str = file:ReadString()
    file:Close()
    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then
        print("[Breeding] ERROR: Failed to parse breeding save")
        return nil
    end
    return data
end

-- Get the normal skill from customization page (or fallback to random)
local function GetConfiguredNormalSkill()
    local custom = BallCustomization.Load()
    if custom and custom.skills and custom.skills.normal then
        return custom.skills.normal
    end
    -- Fallback: random basic skill
    local basics = SkillRegistry.GetByTier("normal")
    if #basics > 0 then
        return basics[math.random(1, #basics)].id
    end
    return "water_ball"
end

-- Get the enhanced skill from customization page (or fallback to random)
local function GetConfiguredEnhancedSkill()
    local custom = BallCustomization.Load()
    if custom and custom.skills and custom.skills.enhanced then
        return custom.skills.enhanced
    end
    -- Fallback: random enhanced skill
    local enhanced = SkillRegistry.GetByTier("enhanced")
    if #enhanced > 0 then
        return enhanced[math.random(1, #enhanced)].id
    end
    return "water_pillar"
end

-- Get the ultimate skill (random from ultimate tier)
local function GetConfiguredUltimateSkill()
    local ultimates = SkillRegistry.GetByTier("ultimate")
    if #ultimates > 0 then
        return ultimates[math.random(1, #ultimates)].id
    end
    return "water_dragon"
end

-- Pick a random expression id
local function RandomExpression()
    local list = Expressions.list
    return list[math.random(1, #list)].id
end

local function CreateFarmBall(farmW, farmH)
    local r = FARM_BALL_RADIUS
    local angle = math.random() * 2 * math.pi
    local speed = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
    -- New ball level based on farm level
    local newLevel = FARM_NEW_BALL_LEVEL[farmLevel_] or 1
    local lvlDef = LEVEL_DEFS[newLevel] or LEVEL_DEFS[1]
    -- Color based on level
    local color = GetLevelColor(newLevel)
    return {
        x = r + math.random() * math.max(1, farmW - r * 2),
        y = r + math.random() * math.max(1, farmH - r * 2),
        vx = math.cos(angle) * speed,
        vy = math.sin(angle) * speed,
        radius = r,
        color = color,
        -- Identity
        name = GenerateRandomName(),
        expression = RandomExpression(),
        -- Level system
        level = newLevel,
        exp = 0,
        hp = lvlDef.maxHp,
        maxHp = lvlDef.maxHp,
        skill = GetConfiguredNormalSkill(),
        enhancedSkill = newLevel >= 2 and GetConfiguredEnhancedSkill() or nil,
        ultimateSkill = newLevel >= 3 and GetConfiguredUltimateSkill() or nil,
    }
end

-- Restore a saved ball into the farm (with physics init)
local function RestoreFarmBall(farmW, farmH, savedBall)
    local r = savedBall.radius or FARM_BALL_RADIUS
    local angle = math.random() * 2 * math.pi
    local speed = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
    local lvl = savedBall.level or 1
    local lvlDef = LEVEL_DEFS[lvl] or LEVEL_DEFS[1]
    return {
        x = r + math.random() * math.max(1, farmW - r * 2),
        y = r + math.random() * math.max(1, farmH - r * 2),
        vx = math.cos(angle) * speed,
        vy = math.sin(angle) * speed,
        radius = r,
        color = GetLevelColor(lvl),
        name = savedBall.name or GenerateRandomName(),
        expression = savedBall.expression or RandomExpression(),
        level = lvl,
        exp = savedBall.exp or 0,
        hp = savedBall.hp or lvlDef.maxHp,
        maxHp = lvlDef.maxHp,
        skill = savedBall.skill or GetConfiguredNormalSkill(),
        enhancedSkill = savedBall.enhancedSkill,
        ultimateSkill = savedBall.ultimateSkill,
    }
end

local function InitFarmBalls(farmW, farmH)
    farmBalls_ = {}
    local count = INITIAL_BALL_COUNT + (farmLevel_ - 1) * 2
    for _ = 1, count do
        table.insert(farmBalls_, CreateFarmBall(farmW, farmH))
    end
end

local function GetFarmDimensions(designW, designH)
    local maxW = designW * 0.7
    local maxH = designH * 0.22
    local scale = FARM_SCALE[farmLevel_] or 1.0
    return maxW * scale, maxH * scale
end

-- ============================================================================
-- Slot Layout Helper
-- ============================================================================

local function GetSlotLayout(designW, designH)
    local slotSize = 165
    local slotGap = 14
    local gridW = GRID_COLS * slotSize + (GRID_COLS - 1) * slotGap
    local gridH = GRID_ROWS * slotSize + (GRID_ROWS - 1) * slotGap
    local labelW = 80
    local gridX = (designW - gridW) / 2 + labelW / 2
    local gridY = 80
    return {
        slotSize = slotSize, slotGap = slotGap,
        gridW = gridW, gridH = gridH,
        labelW = labelW, gridX = gridX, gridY = gridY,
    }
end

local function GetSlotRect(layout, slotIdx)
    local row = math.floor((slotIdx - 1) / GRID_COLS)
    local col = (slotIdx - 1) % GRID_COLS
    local sx = layout.gridX + col * (layout.slotSize + layout.slotGap)
    local sy = layout.gridY + row * (layout.slotSize + layout.slotGap)
    return sx, sy, layout.slotSize, layout.slotSize
end

local function GetFarmLayout(designW, designH, layout)
    local farmW, farmH = GetFarmDimensions(designW, designH)
    local farmAreaTop = layout.gridY + layout.gridH + 60
    local farmX = (designW - farmW) / 2 + layout.labelW / 2
    local farmY = farmAreaTop + 10
    return farmX, farmY, farmW, farmH
end

-- ============================================================================
-- Battle Logic: create a battle within a slot
-- ============================================================================

local function StartBattle(slotIdx)
    local balls = slotBalls_[slotIdx]
    if not balls or #balls < 2 then return end

    -- Already battling?
    if activeBattles_[slotIdx] then return end

    local battleBalls = {}
    local aiStates = {}

    for i, farmBall in ipairs(balls) do
        local lvlDef = LEVEL_DEFS[farmBall.level] or LEVEL_DEFS[1]
        -- Spread balls in the arena
        local angle = (i - 1) / #balls * math.pi * 2
        local dist = BATTLE_ARENA_SIZE * 0.3
        local bx = BATTLE_ARENA_SIZE / 2 + math.cos(angle) * dist
        local by = BATTLE_ARENA_SIZE / 2 + math.sin(angle) * dist
        local va = math.random() * math.pi * 2

        -- Higher level balls are progressively larger in battle (capped growth)
        local sizeGrowth = math.min((farmBall.level - 1) * 2, 30)  -- max +30 radius
        local battleRadius = BATTLE_BALL_RADIUS + sizeGrowth

        table.insert(battleBalls, {
            farmBall = farmBall,  -- reference to original farm ball
            x = bx, y = by,
            vx = math.cos(va) * BATTLE_BALL_SPEED * 0.5,
            vy = math.sin(va) * BATTLE_BALL_SPEED * 0.5,
            hp = lvlDef.maxHp,
            maxHp = lvlDef.maxHp,
            alive = true,
            radius = battleRadius,
            color = farmBall.color,
            level = farmBall.level,
            skill = farmBall.skill,
            enhancedSkill = farmBall.enhancedSkill,
            ultimateSkill = farmBall.ultimateSkill,
            -- Cooldowns
            skillCd = 0,
            enhancedCd = 0,
            ultimateCd = 0,
            -- Status effects
            slowTimer = 0,
            slowFactor = 1.0,
            stunTimer = 0,
            knockbackTimer = 0,
            pendingWallSlamDmg = 0,
        })
        table.insert(aiStates, BallAI.CreateState())
    end

    -- Initialize SkillExecutor state for this battle slot
    SkillExecutor.Clear()
    local seState = SkillExecutor.SaveState()

    activeBattles_[slotIdx] = {
        balls = battleBalls,
        aiStates = aiStates,
        seState = seState,  -- SkillExecutor state snapshot per slot
        damagePopups = {},
        bloodSplatters = {},  -- blood splatter visual effects
        finished = false,
        winnerIdx = nil,
        finishTimer = 0,
        battleElapsed = 0,   -- total fighting time (for timeout abort)
        -- Abort animation state (set when X clicked after 20s timeout)
        aborting = nil,  -- { timer, duration, coins[], phase }
        -- Victory celebration state
        victory = nil,  -- populated on finish: { fireworks, shakeOffset, coins[], goldAwarded }
    }

    print(string.format("[Breeding] Battle started in slot %d with %d balls!", slotIdx, #balls))
end

--- Trigger a streak battle: clear old victory, rebuild slot with winner + challenger(s), start battle.
--- @param slotIdx number
--- @param newBalls table|table  A single farm ball or array of farm balls to add as challengers
--- @return number|nil  New streakCount if successful, nil on failure
local function TriggerStreakBattle(slotIdx, newBalls)
    local battle = activeBattles_[slotIdx]
    if not battle or not battle.finished or not battle.victory
       or not battle.victory.waitingChallenger then
        return nil
    end
    local v = battle.victory
    local streakCount = (v.streakCount or 1) + 1
    -- Track best streak
    if streakCount > bestStreak_ then
        bestStreak_ = streakCount
    end
    local winnerBattleBall = battle.winnerIdx and battle.balls[battle.winnerIdx]
    if not winnerBattleBall then return nil end

    local winnerFarmBall = winnerBattleBall.farmBall
    local winnerHp = winnerBattleBall.hp or 1
    local winnerMaxHp = winnerBattleBall.maxHp or 1

    -- Transfer remaining coins to persistent
    if v.coins then
        local layout2 = GetSlotLayout(1920, 1080)
        local csx, csy, csw, csh = GetSlotRect(layout2, slotIdx)
        local scaleF = math.min(csw, csh) / BATTLE_ARENA_SIZE
        for _, coin in ipairs(v.coins) do
            if coin.visible and not coin.collected and not coin.merged then
                table.insert(persistentCoins_, {
                    x = csx + coin.x * scaleF,
                    y = csy + coin.y * scaleF,
                    visible = true, collected = false,
                    value = coin.value, wobble = coin.wobble,
                    rotation = coin.rotation, scale = coin.scale,
                    spawnDelay = 0, radius = coin.radius, merged = false,
                })
            end
        end
    end

    -- Clear old battle and rebuild
    activeBattles_[slotIdx] = nil
    slotBalls_[slotIdx] = {}

    -- Add winner
    if winnerFarmBall then
        winnerFarmBall.hp = math.max(1, math.floor(winnerFarmBall.maxHp * (winnerHp / winnerMaxHp)))
        table.insert(slotBalls_[slotIdx], winnerFarmBall)
    end

    -- Add challenger(s): support single ball or array
    if newBalls.color then
        -- Single ball (has .color field = farm ball)
        table.insert(slotBalls_[slotIdx], newBalls)
    else
        -- Array of balls
        for _, b in ipairs(newBalls) do
            table.insert(slotBalls_[slotIdx], b)
        end
    end

    -- Start new battle
    StartBattle(slotIdx)
    if activeBattles_[slotIdx] then
        activeBattles_[slotIdx].streakCount = streakCount
        -- Track the streak champion: must be the same farmBall winning consecutively
        activeBattles_[slotIdx].streakWinnerFarmBall = winnerFarmBall
        -- Restore winner's HP ratio in the new battle
        if winnerFarmBall and activeBattles_[slotIdx].balls[1] then
            local wb = activeBattles_[slotIdx].balls[1]
            wb.hp = math.max(1, math.floor(wb.maxHp * (winnerHp / winnerMaxHp)))
        end
    end
    return streakCount
end

--- Inject a new ball into an active streak battle mid-fight.
--- @param slotIdx number
--- @param farmBall table
--- @return boolean
local function InjectBallIntoBattle(slotIdx, farmBall)
    local battle = activeBattles_[slotIdx]
    if not battle or battle.finished then return false end

    local streakCount = battle.streakCount or 1
    local maxBalls = GetMaxBattleBalls(streakCount)

    local aliveCount = 0
    for _, b in ipairs(battle.balls) do
        if b.alive then aliveCount = aliveCount + 1 end
    end
    if aliveCount >= maxBalls then return false end

    local lvlDef = LEVEL_DEFS[farmBall.level] or LEVEL_DEFS[1]
    local sizeGrowth = math.min((farmBall.level - 1) * 2, 30)
    local battleRadius = BATTLE_BALL_RADIUS + sizeGrowth

    -- Spawn at random arena edge
    local side = math.random(1, 4)
    local bx, by
    local margin = battleRadius
    if side == 1 then
        bx = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
        by = margin
    elseif side == 2 then
        bx = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
        by = BATTLE_ARENA_SIZE - margin
    elseif side == 3 then
        bx = margin
        by = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
    else
        bx = BATTLE_ARENA_SIZE - margin
        by = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
    end

    local va = math.random() * math.pi * 2
    table.insert(battle.balls, {
        farmBall = farmBall,
        x = bx, y = by,
        vx = math.cos(va) * BATTLE_BALL_SPEED * 0.5,
        vy = math.sin(va) * BATTLE_BALL_SPEED * 0.5,
        hp = lvlDef.maxHp,
        maxHp = lvlDef.maxHp,
        alive = true,
        radius = battleRadius,
        color = farmBall.color,
        level = farmBall.level,
        skill = farmBall.skill,
        enhancedSkill = farmBall.enhancedSkill,
        ultimateSkill = farmBall.ultimateSkill,
        skillCd = 1.0,
        enhancedCd = 2.0,
        ultimateCd = 3.0,
        slowTimer = 0, slowFactor = 1.0,
        stunTimer = 0,
        knockbackTimer = 0, pendingWallSlamDmg = 0,
    })
    table.insert(battle.aiStates, BallAI.CreateState())
    table.insert(slotBalls_[slotIdx], farmBall)

    print(string.format("[Breeding] Ball injected into active streak battle slot %d! Now %d balls.", slotIdx, #battle.balls))
    return true
end

--- Abort a timed-out battle: trigger squish animation → explode → spawn coins.
--- Coin value = sum of TRASH_SELL_VALUES for all alive balls in the battle.
--- @param slotIdx number
local function AbortBattle(slotIdx)
    local battle = activeBattles_[slotIdx]
    if not battle or battle.finished or battle.aborting then return end

    -- Calculate total coin value from all alive balls
    local totalValue = 0
    for _, ball in ipairs(battle.balls) do
        if ball.alive then
            local grade = GetColorGrade(ball.level)
            totalValue = totalValue + (TRASH_SELL_VALUES[grade] or 10)
        end
    end

    -- Create coins to spawn after animation
    local coinCount = math.max(3, math.min(12, math.floor(math.log(totalValue + 1) / math.log(10) * 3)))
    local perCoin = totalValue / coinCount
    local coins = {}
    for ci = 1, coinCount do
        local margin = 60
        local cx = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
        local cy = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
        local coinR = math.max(12, math.min(26, 10 + math.log(perCoin + 1) / math.log(10) * 5))
        table.insert(coins, {
            x = cx, y = cy,
            value = perCoin,
            spawnDelay = (ci - 1) * 0.06,
            radius = coinR,
        })
    end

    battle.aborting = {
        timer = 0,
        duration = 0.4,  -- squish phase duration
        phase = "squish",
        coins = coins,
        totalValue = totalValue,
        explosionParticles = {},
    }

    print(string.format("[Breeding] Battle abort triggered in slot %d! Total coin value: %d", slotIdx, totalValue))
end

-- Fire a projectile from a battle ball using SkillExecutor
-- NOTE: SkillExecutor state must be restored before calling this!
local function BattleFireProjectile(battle, shooterIdx, targetIdx)
    local shooter = battle.balls[shooterIdx]
    local target = battle.balls[targetIdx]
    if not shooter or not target then return end
    if not shooter.alive or not target.alive then return end

    local dx = target.x - shooter.x
    local dy = target.y - shooter.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end

    -- Lead prediction
    local skillDef = SkillRegistry.Get(shooter.skill)
    local projSpeed = skillDef and skillDef.projSpeed or PROJ_SPEED
    local tof = dist / projSpeed
    dx = dx + (target.vx or 0) * tof * 0.3
    dy = dy + (target.vy or 0) * tof * 0.3
    dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end

    local dirX, dirY = dx / dist, dy / dist

    -- HP percentage based skill selection (priority: ultimate > enhanced > normal)
    local hpPct = shooter.hp / shooter.maxHp
    local lvlDef = LEVEL_DEFS[shooter.level] or LEVEL_DEFS[1]
    local enhThreshold = lvlDef.enhancedThreshold or 0.60
    local ultThreshold = lvlDef.ultimateThreshold or 0.30

    -- Try ultimate skill first (low HP triggers finisher)
    if shooter.ultimateSkill and shooter.ultimateCd <= 0 and hpPct <= ultThreshold then
        local ultDef = SkillRegistry.Get(shooter.ultimateSkill)
        if ultDef then
            local cd = SkillExecutor.Fire(ultDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.ultimateCd = (cd or 5.0) * 0.5
            return
        end
    end

    -- Try enhanced skill (medium HP threshold)
    if shooter.enhancedSkill and shooter.enhancedCd <= 0 and hpPct <= enhThreshold then
        local enhDef = SkillRegistry.Get(shooter.enhancedSkill)
        if enhDef then
            local cd = SkillExecutor.Fire(enhDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.enhancedCd = (cd or 3.0) * 0.5
            return
        end
    end

    -- Fallback: basic skill (always available at any HP)
    if skillDef then
        local cd = SkillExecutor.Fire(skillDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
        shooter.skillCd = (cd or 1.5) * 0.4
    end
end

-- Helper: spawn blood splatter particles at a hit location
local function SpawnBloodSplatters(battle, x, y, count, color)
    for _ = 1, (count or 6) do
        local angle = math.random() * math.pi * 2
        local speed = 40 + math.random() * 120
        table.insert(battle.bloodSplatters, {
            x = x, y = y,
            vx = math.cos(angle) * speed,
            vy = math.sin(angle) * speed,
            radius = 1.5 + math.random() * 2.5,
            life = 0.4 + math.random() * 0.4,
            elapsed = 0,
            color = color or { r = 200, g = 30, b = 30 },
        })
    end
end

-- Update a single battle
local function UpdateBattle(slotIdx, dt)
    local battle = activeBattles_[slotIdx]

    -- Handle abort animation (squish → explode → coins)
    if battle and battle.aborting then
        local ab = battle.aborting
        ab.timer = ab.timer + dt
        local t = math.min(1, ab.timer / ab.duration)

        if ab.phase == "squish" then
            -- Squish phase: square → line (0.4s)
            if t >= 1 then
                -- Transition to explode phase
                ab.phase = "explode"
                ab.timer = 0
                ab.duration = 0.3
                -- Create explosion particles from each ball
                ab.explosionParticles = {}
                for _, ball in ipairs(battle.balls) do
                    if ball.alive then
                        local c = ball.color
                        for pi = 1, 16 do
                            local angle = (pi - 1) / 16 * math.pi * 2 + math.random() * 0.4
                            local speed = 150 + math.random() * 250
                            table.insert(ab.explosionParticles, {
                                x = ball.x, y = ball.y,
                                vx = math.cos(angle) * speed,
                                vy = math.sin(angle) * speed,
                                life = 0.5 + math.random() * 0.4,
                                elapsed = 0,
                                r = c.r, g = c.g, b = c.b,
                                size = 3 + math.random() * 5,
                            })
                        end
                        ball.alive = false
                    end
                end
            end
        elseif ab.phase == "explode" then
            -- Explode phase: particles fly out (0.3s)
            for _, p in ipairs(ab.explosionParticles) do
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.elapsed = p.elapsed + dt
            end
            if t >= 1 then
                -- Transition to coin phase: spawn coins and clean up
                ab.phase = "done"
                -- Spawn coins as persistent coins (in design coords)
                local layout2 = GetSlotLayout(1920, 1080)
                local csx, csy, csw, csh = GetSlotRect(layout2, slotIdx)
                local scaleF = math.min(csw, csh) / BATTLE_ARENA_SIZE
                local margin = 8
                local drawSize = math.min(csw, csh) - margin * 2
                local coinOX = csx + (csw - drawSize) / 2
                local coinOY = csy + (csh - drawSize) / 2
                for _, coin in ipairs(ab.coins) do
                    table.insert(persistentCoins_, {
                        x = coinOX + coin.x * scaleF,
                        y = coinOY + coin.y * scaleF,
                        visible = true, collected = false,
                        value = coin.value,
                        wobble = math.random() * math.pi * 2,
                        rotation = math.random() * math.pi * 2,
                        scale = 0,
                        spawnDelay = coin.spawnDelay or 0,
                        radius = coin.radius or 14,
                        merged = false,
                    })
                end
                -- Return surviving farm balls to farm with 1 HP
                for _, ball in ipairs(battle.balls) do
                    if ball.farmBall then
                        local fb = ball.farmBall
                        fb.hp = 0  -- dead
                        -- Don't return dead balls to farm
                    end
                end
                slotBalls_[slotIdx] = {}
                activeBattles_[slotIdx] = nil
                SaveBreedingData()
                print(string.format("[Breeding] Battle in slot %d aborted after timeout! Coins spawned.", slotIdx))
            end
        end
        return  -- Skip normal update during abort
    end

    if not battle or battle.finished then
        -- Post-battle: victory celebration
        if battle and battle.finished then
            battle.finishTimer = battle.finishTimer + dt

            -- Initialize victory state on first frame
            if not battle.victory then
                local winner = battle.winnerIdx and battle.balls[battle.winnerIdx]
                local initSpeed = VICTORY_BOUNCE_SPEED
                local va = math.random() * math.pi * 2
                -- Scatter coins randomly inside the battle arena (rewards scale with streak)
                local coins = {}
                local currentStreak = battle.streakCount or 1

                -- Streak identity check: streak only continues if SAME ball keeps winning
                if currentStreak >= 2 and battle.streakWinnerFarmBall then
                    local winnerFB = winner and winner.farmBall
                    if winnerFB ~= battle.streakWinnerFarmBall then
                        -- Different ball won → streak breaks!
                        print(string.format("[Breeding] Streak broken in slot %d! Champion changed.", slotIdx))
                        currentStreak = 1
                    end
                end
                local totalReward = STREAK_BASE_REWARD * currentStreak
                local COIN_COUNT = math.min(4 + currentStreak, 10)
                local coinValue = totalReward / COIN_COUNT
                for ci = 1, COIN_COUNT do
                    local margin = 40
                    local cx = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
                    local cy = margin + math.random() * (BATTLE_ARENA_SIZE - margin * 2)
                    table.insert(coins, {
                        x = cx, y = cy,           -- arena-local position
                        visible = true,
                        collected = false,
                        value = coinValue,
                        wobble = math.random() * math.pi * 2,
                        rotation = math.random() * math.pi * 2,
                        scale = 0,                -- animate in
                        spawnDelay = (ci - 1) * 0.08,  -- stagger appearance
                        radius = 14,              -- small coin radius
                        merged = false,            -- becomes true when absorbed into another coin
                    })
                end
                -- Track best streak
                if currentStreak > bestStreak_ then
                    bestStreak_ = currentStreak
                end
                battle.victory = {
                    fireworks = {},
                    shakeTimer = 0,
                    shakeOffsetX = 0,
                    shakeOffsetY = 0,
                    coins = coins,
                    totalGold = totalReward,
                    goldAwarded = 0,              -- gold already collected
                    winnerOrigRadius = winner and winner.radius or BATTLE_BALL_RADIUS,
                    -- Streak battle fields
                    streakCount = currentStreak,
                    countdown = STREAK_COUNTDOWN,    -- 5s countdown for next challenger
                    waitingChallenger = true,         -- accepting new balls during countdown
                    fireParticles = {},               -- fire border effect particles
                    streakShakeTimer = 0,             -- persistent streak shake
                }
                -- Give winner a big speed boost to start bouncing wildly
                if winner and winner.alive then
                    winner.vx = math.cos(va) * initSpeed
                    winner.vy = math.sin(va) * initSpeed
                end
            end

            local v = battle.victory
            local winner = battle.winnerIdx and battle.balls[battle.winnerIdx]

            -- 1. Winner ball enlargement (grow by one full circle = +radius)
            if winner and winner.alive then
                local targetR = v.winnerOrigRadius + v.winnerOrigRadius  -- double radius
                local t = math.min(1, battle.finishTimer / VICTORY_ENLARGE_TIME)
                -- Smooth ease-out
                local eased = 1 - (1 - t) * (1 - t)
                winner.radius = v.winnerOrigRadius + v.winnerOrigRadius * eased

                -- 2. Winner bounces wildly
                winner.x = winner.x + winner.vx * dt
                winner.y = winner.y + winner.vy * dt

                local r = winner.radius
                local hitWall = false
                if winner.x - r < 0 then
                    winner.x = r; winner.vx = math.abs(winner.vx); hitWall = true
                elseif winner.x + r > BATTLE_ARENA_SIZE then
                    winner.x = BATTLE_ARENA_SIZE - r; winner.vx = -math.abs(winner.vx); hitWall = true
                end
                if winner.y - r < 0 then
                    winner.y = r; winner.vy = math.abs(winner.vy); hitWall = true
                elseif winner.y + r > BATTLE_ARENA_SIZE then
                    winner.y = BATTLE_ARENA_SIZE - r; winner.vy = -math.abs(winner.vy); hitWall = true
                end

                -- 3. Fireworks on wall collision
                if hitWall then
                    -- Spawn firework burst
                    local fw = {
                        x = winner.x, y = winner.y,
                        particles = {},
                        elapsed = 0,
                        life = 1.0,
                    }
                    local fwCount = 15 + math.random(10)
                    for _ = 1, fwCount do
                        local angle = math.random() * math.pi * 2
                        local speed = 60 + math.random() * 200
                        table.insert(fw.particles, {
                            x = 0, y = 0,
                            vx = math.cos(angle) * speed,
                            vy = math.sin(angle) * speed,
                            r = math.random(150, 255),
                            g = math.random(100, 255),
                            b = math.random(50, 255),
                            radius = 1.5 + math.random() * 2.5,
                            trail = {},  -- sparkle trail
                        })
                    end
                    table.insert(v.fireworks, fw)

                    -- 4. Room shake on impact
                    v.shakeTimer = 0.3
                end
            end

            -- Update room shake
            if v.shakeTimer > 0 then
                v.shakeTimer = v.shakeTimer - dt
                local intensity = v.shakeTimer * 25
                v.shakeOffsetX = (math.random() * 2 - 1) * intensity
                v.shakeOffsetY = (math.random() * 2 - 1) * intensity
            else
                v.shakeOffsetX = 0
                v.shakeOffsetY = 0
            end

            -- Update firework particles
            local fi = 1
            while fi <= #v.fireworks do
                local fw = v.fireworks[fi]
                fw.elapsed = fw.elapsed + dt
                if fw.elapsed >= fw.life then
                    table.remove(v.fireworks, fi)
                else
                    for _, p in ipairs(fw.particles) do
                        p.x = p.x + p.vx * dt
                        p.y = p.y + p.vy * dt
                        p.vx = p.vx * 0.95
                        p.vy = p.vy * 0.95
                    end
                    fi = fi + 1
                end
            end

            -- 5. Update scattered coins (wobble, rotation, scale-in, merge)
            local coins = v.coins
            for _, c in ipairs(coins) do
                if c.visible and not c.collected and not c.merged then
                    if c.spawnDelay > 0 then
                        c.spawnDelay = c.spawnDelay - dt
                    else
                        c.wobble = c.wobble + dt * 3.5
                        c.rotation = c.rotation + dt * 4.0
                        c.scale = math.min(1.0, c.scale + dt * 3.0)
                    end
                end
            end

            -- Merge nearby coins: if 3+ coins within 60px cluster, merge into one bigger coin
            local MERGE_DIST = 60
            local MIN_MERGE_COUNT = 3
            -- Simple cluster detection: for each coin, count neighbors
            for i = 1, #coins do
                local a = coins[i]
                if a.visible and not a.collected and not a.merged and a.scale >= 0.8 then
                    local cluster = { i }
                    for j = i + 1, #coins do
                        local b = coins[j]
                        if b.visible and not b.collected and not b.merged and b.scale >= 0.8 then
                            local dx = a.x - b.x
                            local dy = a.y - b.y
                            if dx * dx + dy * dy < MERGE_DIST * MERGE_DIST then
                                table.insert(cluster, j)
                            end
                        end
                    end
                    if #cluster >= MIN_MERGE_COUNT then
                        -- Merge: absorb all into coin 'a'
                        local totalValue = 0
                        local avgX, avgY = 0, 0
                        for _, ci2 in ipairs(cluster) do
                            local c2 = coins[ci2]
                            totalValue = totalValue + c2.value
                            avgX = avgX + c2.x
                            avgY = avgY + c2.y
                        end
                        avgX = avgX / #cluster
                        avgY = avgY / #cluster
                        -- Mark others as merged
                        for k = 2, #cluster do
                            coins[cluster[k]].merged = true
                            coins[cluster[k]].visible = false
                        end
                        -- Upgrade coin 'a' to big coin
                        a.x = avgX
                        a.y = avgY
                        a.value = totalValue
                        a.radius = math.min(28, 14 + totalValue * 1.2)  -- grow radius with value
                        a.scale = 0.6  -- re-animate scale
                        break  -- one merge per frame to avoid index issues
                    end
                end
            end

            -- Let SkillExecutor effects fade out during finish
            SkillExecutor.RestoreState(battle.seState)
            local seBalls = {}
            for bi, bb in ipairs(battle.balls) do
                seBalls[bi] = { x = bb.x, y = bb.y, vx = bb.vx, vy = bb.vy, hp = bb.hp }
            end
            SkillExecutor.Update(dt, seBalls, {})
            SkillExecutor.UpdateDots(dt, seBalls, {})
            SkillExecutor.UpdateVisuals(dt, seBalls)
            battle.seState = SkillExecutor.SaveState()

            -- Update blood splatters
            local si = 1
            while si <= #battle.bloodSplatters do
                local sp = battle.bloodSplatters[si]
                sp.elapsed = sp.elapsed + dt
                if sp.elapsed >= sp.life then
                    table.remove(battle.bloodSplatters, si)
                else
                    sp.x = sp.x + sp.vx * dt
                    sp.y = sp.y + sp.vy * dt
                    sp.vx = sp.vx * 0.92
                    sp.vy = sp.vy * 0.92
                    si = si + 1
                end
            end

            -- Update damage popups during finish
            local dpi = 1
            while dpi <= #battle.damagePopups do
                local p = battle.damagePopups[dpi]
                p.elapsed = p.elapsed + dt
                p.y = p.y - 30 * dt
                if p.elapsed >= p.duration then
                    table.remove(battle.damagePopups, dpi)
                else
                    dpi = dpi + 1
                end
            end

            -- Update streak countdown
            if v.waitingChallenger then
                v.countdown = v.countdown - dt
                -- Update fire particles for streak effect (streakCount >= 2)
                if v.streakCount >= 2 then
                    v.streakShakeTimer = v.streakShakeTimer + dt
                    -- Spawn fire particles along border
                    local spawnRate = 3 + v.streakCount * 2  -- more particles with higher streak
                    if math.random() < spawnRate * dt then
                        local side = math.random(1, 4)
                        local px, py, pvx, pvy
                        if side == 1 then -- bottom
                            px = math.random() * BATTLE_ARENA_SIZE
                            py = BATTLE_ARENA_SIZE
                            pvx = (math.random() - 0.5) * 30
                            pvy = -60 - math.random() * 80
                        elseif side == 2 then -- top
                            px = math.random() * BATTLE_ARENA_SIZE
                            py = 0
                            pvx = (math.random() - 0.5) * 30
                            pvy = 60 + math.random() * 80
                        elseif side == 3 then -- left
                            px = 0
                            py = math.random() * BATTLE_ARENA_SIZE
                            pvx = 60 + math.random() * 80
                            pvy = (math.random() - 0.5) * 30
                        else -- right
                            px = BATTLE_ARENA_SIZE
                            py = math.random() * BATTLE_ARENA_SIZE
                            pvx = -60 - math.random() * 80
                            pvy = (math.random() - 0.5) * 30
                        end
                        table.insert(v.fireParticles, {
                            x = px, y = py, vx = pvx, vy = pvy,
                            life = 0.5 + math.random() * 0.5,
                            elapsed = 0,
                            size = 4 + math.random() * 6 + v.streakCount,
                        })
                    end
                    -- Update existing fire particles
                    local fpi = 1
                    while fpi <= #v.fireParticles do
                        local fp = v.fireParticles[fpi]
                        fp.elapsed = fp.elapsed + dt
                        if fp.elapsed >= fp.life then
                            table.remove(v.fireParticles, fpi)
                        else
                            fp.x = fp.x + fp.vx * dt
                            fp.y = fp.y + fp.vy * dt
                            fp.vx = fp.vx * 0.96
                            fp.vy = fp.vy * 0.96
                            fpi = fpi + 1
                        end
                    end
                end
            end

            -- End streak: countdown expired with no challenger → return winner to farm
            if v.waitingChallenger and v.countdown <= 0 then
                v.waitingChallenger = false
                -- Return winner to farm
                if battle.winnerIdx then
                    local wb = battle.balls[battle.winnerIdx]
                    if wb and wb.farmBall then
                        local fb = wb.farmBall
                        -- Award experience (doubled per streak: 1x, 2x, 4x, 8x...)
                        local streakCount = v.streakCount or 1
                        local streakMult = math.floor(2 ^ (streakCount - 1))  -- 1,2,4,8,16...
                        local expReward = BATTLE_EXP_WIN * streakMult

                        -- Level difference penalty: higher level vs lower level = less exp
                        local winnerLevel = fb.level or 1
                        local maxLoserLevel = 0
                        for _, bb in ipairs(battle.balls) do
                            if bb ~= battle.balls[battle.winnerIdx] then
                                local ll = bb.level or 1
                                if ll > maxLoserLevel then maxLoserLevel = ll end
                            end
                        end
                        if maxLoserLevel > 0 then
                            local levelDiff = winnerLevel - maxLoserLevel  -- positive = winner higher
                            if levelDiff > 0 then
                                -- Reduce exp: 1 level diff → 70%, 2 → 50%, 3 → 30%, 4+ → 20%
                                local reductionFactors = { 0.7, 0.5, 0.3, 0.2 }
                                local factor = reductionFactors[math.min(levelDiff, #reductionFactors)]
                                expReward = math.max(1, math.floor(expReward * factor))
                                print(string.format("[Breeding] Exp reduced: winner Lv%d vs loser Lv%d, factor=%.1f, exp=%d",
                                    winnerLevel, maxLoserLevel, factor, expReward))
                            end
                        end

                        fb.exp = fb.exp + expReward
                        print(string.format("[Breeding] Awarded %d exp (streak x%d, mult %d)", expReward, streakCount, streakMult))

                        -- Check level up (may level up multiple times if enough exp)
                        local farmMaxLvl = FARM_MAX_BALL_LEVEL[farmLevel_] or 7
                        local didLevelUp = false
                        while fb.level < MAX_LEVEL and fb.level < farmMaxLvl do
                            local lvlDef = LEVEL_DEFS[fb.level]
                            if not lvlDef or not lvlDef.expToNext then break end
                            if fb.exp < lvlDef.expToNext then break end
                            fb.exp = fb.exp - lvlDef.expToNext
                            fb.level = fb.level + 1
                            didLevelUp = true
                            if fb.level == 2 and not fb.enhancedSkill then
                                fb.enhancedSkill = GetConfiguredEnhancedSkill()
                            end
                            if fb.level == 3 and not fb.ultimateSkill then
                                fb.ultimateSkill = GetConfiguredUltimateSkill()
                            end
                            print(string.format("[Breeding] Ball leveled up to %d!", fb.level))
                        end
                        if didLevelUp then
                            fb.radius = FARM_BALL_RADIUS + math.min((fb.level - 1) * 1.5, 15)
                            fb.color = GetLevelColor(fb.level)
                        end
                        -- Update maxHp from new level
                        local winLvlDef = LEVEL_DEFS[fb.level] or LEVEL_DEFS[1]
                        fb.maxHp = winLvlDef.maxHp
                        -- Level up → full HP; otherwise preserve battle HP ratio
                        if didLevelUp then
                            fb.hp = fb.maxHp
                            print(string.format("[Breeding] Level up! HP fully restored to %d", fb.maxHp))
                        else
                            local wb2 = battle.balls[battle.winnerIdx]
                            if wb2 then
                                local hpRatio = wb2.hp / wb2.maxHp
                                fb.hp = math.max(1, math.floor(fb.maxHp * hpRatio))
                            end
                        end
                        local retFarmW, retFarmH = GetFarmDimensions(1920, 1080)
                        local retAngle = math.random() * 2 * math.pi
                        local retSpeed = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
                        fb.x = fb.radius + math.random() * math.max(1, retFarmW - fb.radius * 2)
                        fb.y = fb.radius + math.random() * math.max(1, retFarmH - fb.radius * 2)
                        fb.vx = math.cos(retAngle) * retSpeed
                        fb.vy = math.sin(retAngle) * retSpeed
                        table.insert(farmBalls_, fb)
                    end
                end
                -- Transfer uncollected victory coins to persistent list
                if battle.victory and battle.victory.coins then
                    local designW2 = 1920
                    local designH2 = 1080
                    local layout2 = GetSlotLayout(designW2, designH2)
                    local sx, sy, sw, sh = GetSlotRect(layout2, slotIdx)
                    local scaleF = math.min(sw, sh) / BATTLE_ARENA_SIZE
                    for _, coin in ipairs(battle.victory.coins) do
                        if coin.visible and not coin.collected and not coin.merged then
                            table.insert(persistentCoins_, {
                                x = sx + coin.x * scaleF,
                                y = sy + coin.y * scaleF,
                                visible = true, collected = false,
                                value = coin.value, wobble = coin.wobble,
                                rotation = coin.rotation, scale = coin.scale,
                                spawnDelay = 0, radius = coin.radius, merged = false,
                            })
                        end
                    end
                end
                if v.streakCount > 1 then
                    print(string.format("[Breeding] Streak of %d ended in slot %d! Total reward: %d gold",
                        v.streakCount, slotIdx, STREAK_BASE_REWARD * v.streakCount))
                end
                slotBalls_[slotIdx] = {}
                activeBattles_[slotIdx] = nil
                SaveBreedingData()
            end
        end
        return
    end

    -- Increment battle elapsed timer (active fighting only)
    battle.battleElapsed = (battle.battleElapsed or 0) + dt

    local balls = battle.balls

    -- Count alive balls
    local aliveCount = 0
    local lastAlive = nil
    for i, b in ipairs(balls) do
        if b.alive then
            aliveCount = aliveCount + 1
            lastAlive = i
        end
    end

    -- Check win condition
    if aliveCount <= 1 then
        battle.finished = true
        battle.winnerIdx = lastAlive
        battle.finishTimer = 0
        if lastAlive then
            print(string.format("[Breeding] Battle in slot %d won by ball %d!", slotIdx, lastAlive))
        end
        return
    end

    -- Restore SkillExecutor state for this battle slot
    SkillExecutor.RestoreState(battle.seState)

    -- AI + Physics for each alive ball
    for i, ball in ipairs(balls) do
        if ball.alive then
            -- Update cooldowns
            if ball.skillCd > 0 then ball.skillCd = ball.skillCd - dt end
            if ball.enhancedCd > 0 then ball.enhancedCd = ball.enhancedCd - dt end
            if ball.ultimateCd and ball.ultimateCd > 0 then ball.ultimateCd = ball.ultimateCd - dt end
            if ball.stunTimer > 0 then ball.stunTimer = ball.stunTimer - dt end
            if ball.slowTimer > 0 then
                ball.slowTimer = ball.slowTimer - dt
                if ball.slowTimer <= 0 then ball.slowFactor = 1.0 end
            end
            if ball.knockbackTimer > 0 then ball.knockbackTimer = ball.knockbackTimer - dt end

            -- Find nearest alive opponent
            local nearestDist = math.huge
            local nearestIdx = nil
            for j, other in ipairs(balls) do
                if j ~= i and other.alive then
                    local dx = other.x - ball.x
                    local dy = other.y - ball.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d < nearestDist then
                        nearestDist = d
                        nearestIdx = j
                    end
                end
            end

            if nearestIdx and ball.stunTimer <= 0 then
                local opponent = balls[nearestIdx]

                -- AI movement
                local ai = BallAI.Update(
                    battle.aiStates[i],
                    { x = ball.x, y = ball.y, vx = ball.vx, vy = ball.vy, hp = ball.hp },
                    { x = opponent.x, y = opponent.y, vx = opponent.vx, vy = opponent.vy },
                    0, PROJ_SPEED, dt
                )

                -- Scale AI movement to battle arena
                local moveScale = BATTLE_BALL_SPEED / 150
                local lerpFactor = 0.15
                ball.vx = ball.vx + (ai.moveVX * moveScale - ball.vx) * lerpFactor
                ball.vy = ball.vy + (ai.moveVY * moveScale - ball.vy) * lerpFactor

                -- AI shooting (SkillExecutor state is already restored)
                if ai.shoot and ball.skillCd <= 0 then
                    BattleFireProjectile(battle, i, nearestIdx)
                end
            end

            -- Physics movement
            local factor = ball.slowFactor
            ball.x = ball.x + ball.vx * factor * dt
            ball.y = ball.y + ball.vy * factor * dt

            -- Speed cap
            local spd = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
            if spd > BATTLE_SPEED_CAP then
                ball.vx = ball.vx * BATTLE_SPEED_CAP / spd
                ball.vy = ball.vy * BATTLE_SPEED_CAP / spd
            end

            -- Wall bounce (within battle arena)
            local r = ball.radius
            local hitWall = false
            if ball.x - r < 0 then
                ball.x = r; ball.vx = math.abs(ball.vx) * 0.9; hitWall = true
            elseif ball.x + r > BATTLE_ARENA_SIZE then
                ball.x = BATTLE_ARENA_SIZE - r; ball.vx = -math.abs(ball.vx) * 0.9; hitWall = true
            end
            if ball.y - r < 0 then
                ball.y = r; ball.vy = math.abs(ball.vy) * 0.9; hitWall = true
            elseif ball.y + r > BATTLE_ARENA_SIZE then
                ball.y = BATTLE_ARENA_SIZE - r; ball.vy = -math.abs(ball.vy) * 0.9; hitWall = true
            end

            -- Wall slam damage
            if ball.knockbackTimer > 0 and hitWall and ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                SpawnBloodSplatters(battle, ball.x, ball.y, 8, { r = 255, g = 60, b = 60 })
                table.insert(battle.damagePopups, {
                    x = ball.x, y = ball.y - ball.radius - 5,
                    damage = ball.pendingWallSlamDmg,
                    color = { r = 255, g = 100, b = 50 },
                    elapsed = 0, duration = 0.8,
                    isEnhanced = true,
                })
                ball.knockbackTimer = 0
                ball.pendingWallSlamDmg = 0
            end
        end
    end

    -- Ball-ball collision (alive balls only)
    for i = 1, #balls do
        if balls[i].alive then
            for j = i + 1, #balls do
                if balls[j].alive then
                    local a, b = balls[i], balls[j]
                    local dx = b.x - a.x
                    local dy = b.y - a.y
                    local dist = math.sqrt(dx * dx + dy * dy)
                    local minDist = a.radius + b.radius
                    if dist < minDist and dist > 0.01 then
                        local nx, ny = dx / dist, dy / dist
                        local overlap = minDist - dist
                        a.x = a.x - nx * overlap * 0.5
                        a.y = a.y - ny * overlap * 0.5
                        b.x = b.x + nx * overlap * 0.5
                        b.y = b.y + ny * overlap * 0.5
                        local dvx = a.vx - b.vx
                        local dvy = a.vy - b.vy
                        local dvDotN = dvx * nx + dvy * ny
                        if dvDotN > 0 then
                            a.vx = a.vx - dvDotN * nx * 0.85
                            a.vy = a.vy - dvDotN * ny * 0.85
                            b.vx = b.vx + dvDotN * nx * 0.85
                            b.vy = b.vy + dvDotN * ny * 0.85
                            -- Collision damage
                            a.hp = a.hp - BATTLE_COLLISION_DMG
                            b.hp = b.hp - BATTLE_COLLISION_DMG
                        end
                    end
                end
            end
        end
    end

    -- Build seBalls table for SkillExecutor (indexed by ball index = team)
    local seBalls = {}
    for bi, bb in ipairs(balls) do
        seBalls[bi] = { x = bb.x, y = bb.y, vx = bb.vx, vy = bb.vy, hp = bb.hp }
    end

    -- SkillExecutor callbacks
    local seCallbacks = {
        onHit = function(targetTeam, damage, kx, ky, hitType, skillId, proj)
            local tgt = balls[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.hp = tgt.hp - damage
            -- Apply knockback
            if kx ~= 0 or ky ~= 0 then
                tgt.vx = tgt.vx + kx
                tgt.vy = tgt.vy + ky
                -- Wall slam setup for beam/water_pillar/water_dragon knockbacks
                if hitType == "beam" or hitType == "meteor_hit" then
                    tgt.knockbackTimer = 0.3
                    tgt.pendingWallSlamDmg = math.floor(damage * 0.5)
                end
            end
            -- Blood splatter at hit location
            local skillDef = SkillRegistry.Get(skillId)
            local hitColor = (skillDef and skillDef.color) or { r = 200, g = 30, b = 30 }
            SpawnBloodSplatters(battle, tgt.x, tgt.y, 5 + math.floor(damage * 0.5), hitColor)
            -- Damage popup
            table.insert(battle.damagePopups, {
                x = tgt.x, y = tgt.y - tgt.radius - 5,
                damage = damage,
                color = hitColor,
                elapsed = 0, duration = 0.7,
                isEnhanced = (hitType ~= "splash" and hitType ~= "wall_splash"),
            })
        end,
        onDot = function(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            SkillExecutor.AddDot(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
        end,
        onDotTick = function(targetTeam, sourceTeam, dmgTick, healTick)
            local tgt = balls[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.hp = tgt.hp - dmgTick
            -- Heal source
            if healTick > 0 then
                local src = balls[sourceTeam]
                if src and src.alive then
                    src.hp = math.min(src.maxHp, src.hp + healTick)
                end
            end
            -- Small blood splatter for DOT tick
            SpawnBloodSplatters(battle, tgt.x, tgt.y, 2, { r = 180, g = 50, b = 50 })
        end,
        onStun = function(targetTeam, duration)
            local tgt = balls[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.stunTimer = math.max(tgt.stunTimer, duration)
        end,
        onSlow = function(targetTeam, factor, duration)
            local tgt = balls[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.slowFactor = math.min(tgt.slowFactor, factor)
            tgt.slowTimer = math.max(tgt.slowTimer, duration)
        end,
    }

    -- Run SkillExecutor physics + hit detection
    SkillExecutor.Update(dt, seBalls, seCallbacks)
    SkillExecutor.UpdateDots(dt, seBalls, seCallbacks)
    SkillExecutor.UpdateVisuals(dt, seBalls)

    -- Save SkillExecutor state back to battle slot
    battle.seState = SkillExecutor.SaveState()

    -- Update blood splatters
    local si = 1
    while si <= #battle.bloodSplatters do
        local sp = battle.bloodSplatters[si]
        sp.elapsed = sp.elapsed + dt
        if sp.elapsed >= sp.life then
            table.remove(battle.bloodSplatters, si)
        else
            sp.x = sp.x + sp.vx * dt
            sp.y = sp.y + sp.vy * dt
            sp.vx = sp.vx * 0.92
            sp.vy = sp.vy * 0.92
            si = si + 1
        end
    end

    -- Update damage popups
    local di = 1
    while di <= #battle.damagePopups do
        local p = battle.damagePopups[di]
        p.elapsed = p.elapsed + dt
        p.y = p.y - 30 * dt
        if p.elapsed >= p.duration then
            table.remove(battle.damagePopups, di)
        else
            di = di + 1
        end
    end

    -- Check deaths
    for _, ball in ipairs(balls) do
        if ball.alive and ball.hp <= 0 then
            ball.alive = false
            ball.hp = 0
        end
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

function BreedingPage.Show(cbs)
    active_ = true
    elapsedTime_ = 0
    spawnTimer_ = 0
    saveTimer_ = 0
    mouseLocalX_ = -9999
    mouseLocalY_ = -9999
    mouseDesignX_ = -9999
    mouseDesignY_ = -9999
    callbacks_ = cbs
    hoverSlotBtn_ = false
    hoverFarmBtn_ = false
    hoverBackBtn_ = false
    hoverAiBtn_ = false
    hoverAiUpgrade_ = false
    hoverTrashCan_ = false
    hoverArena_ = false
    trashLidAngle_ = 0
    trashLidShake_ = 0
    aiTimer_ = 0
    persistentCoins_ = {}
    trashExplosions_ = {}
    trashCoins_ = {}
    dragBall_ = nil
    dragFromSlot_ = nil

    -- Initialize gold animation state
    goldDisplayValue_ = gold_
    goldTargetValue_ = gold_
    goldParticles_ = {}
    goldAnimating_ = false
    goldShakeTimer_ = 0
    goldShakeIntensity_ = 0

    -- Init slot balls (empty)
    slotBalls_ = {}
    activeBattles_ = {}
    for i = 1, MAX_SLOTS do
        slotBalls_[i] = {}
    end

    -- Restore game state from a save data table
    local function RestoreFromData(saved, source)
        source = source or "local"
        local farmW, farmH = GetFarmDimensions(1920, 1080)

        gold_ = saved.gold or gold_
        goldDisplayValue_ = gold_
        goldTargetValue_ = gold_
        farmLevel_ = saved.farmLevel or farmLevel_
        slotsUnlocked_ = saved.slotsUnlocked or slotsUnlocked_
        aiLevel_ = saved.aiLevel or 0
        aiEnabled_ = (saved.aiEnabled == true) and (aiLevel_ > 0)
        bestStreak_ = saved.bestStreak or bestStreak_
        farmW, farmH = GetFarmDimensions(1920, 1080)

        -- Restore persistent coins
        persistentCoins_ = {}
        if saved.persistentCoins and type(saved.persistentCoins) == "table" then
            for _, sc in ipairs(saved.persistentCoins) do
                table.insert(persistentCoins_, {
                    x = sc.x, y = sc.y, visible = true, collected = false,
                    value = sc.value or 1, wobble = math.random() * math.pi * 2,
                    rotation = math.random() * math.pi * 2, scale = 1.0,
                    spawnDelay = 0, radius = sc.radius or 14, merged = sc.merged or false,
                })
            end
        end

        farmBalls_ = {}
        for _, sb in ipairs(saved.balls) do
            table.insert(farmBalls_, RestoreFarmBall(farmW, farmH, sb))
        end

        -- Restore slot balls
        for i = 1, MAX_SLOTS do
            slotBalls_[i] = {}
        end
        if saved.slotBalls then
            for idxStr, slotData in pairs(saved.slotBalls) do
                local idx = tonumber(idxStr)
                if idx and idx >= 1 and idx <= MAX_SLOTS and type(slotData) == "table" then
                    slotBalls_[idx] = {}
                    for _, sb in ipairs(slotData) do
                        local lvl = sb.level or 1
                        local lvlDef = LEVEL_DEFS[lvl] or LEVEL_DEFS[1]
                        table.insert(slotBalls_[idx], {
                            color = sb.color or BALL_COLORS[math.random(1, #BALL_COLORS)],
                            name = sb.name or GenerateRandomName(),
                            expression = sb.expression or RandomExpression(),
                            level = lvl,
                            exp = sb.exp or 0,
                            hp = sb.hp or lvlDef.maxHp,
                            maxHp = lvlDef.maxHp,
                            skill = sb.skill or GetConfiguredNormalSkill(),
                            enhancedSkill = sb.enhancedSkill,
                            radius = sb.radius or FARM_BALL_RADIUS,
                        })
                    end
                end
            end
        end

        -- Restore arena data
        if saved.arena then
            ArenaBattle.LoadSaveData(saved.arena)
        end

        local slotCount = 0
        for idx = 1, MAX_SLOTS do
            if slotBalls_[idx] and #slotBalls_[idx] > 0 then
                slotCount = slotCount + #slotBalls_[idx]
            end
        end
        print(string.format("[Breeding] Restored %d farm balls + %d slot balls from %s save", #farmBalls_, slotCount, source))
    end

    -- Try to load saved breeding data (local first, then cloud async)
    local saved = LoadBreedingData()

    if saved and saved.balls then
        RestoreFromData(saved, "local")
    else
        -- First time: fresh init
        local farmW, farmH = GetFarmDimensions(1920, 1080)
        InitFarmBalls(farmW, farmH)
    end

    -- Async cloud load: if cloud has data, override local state
    CloudSave.Load(function(cloudData, err)
        if not active_ then return end  -- page already closed
        if cloudData and cloudData.balls and #cloudData.balls > 0 then
            -- Compare ball count: use whichever has more data (simple heuristic)
            local localBallCount = #farmBalls_
            local cloudBallCount = #cloudData.balls
            if cloudBallCount >= localBallCount then
                print("[Breeding] Cloud save has data, restoring from cloud")
                RestoreFromData(cloudData, "cloud")
            else
                print(string.format("[Breeding] Local save has more balls (%d vs %d), keeping local", localBallCount, cloudBallCount))
            end
        elseif not err then
            print("[Breeding] No cloud save found, using local data")
        end
    end)

    -- Initialize ArenaBattle module with callbacks
    ArenaBattle.Init({
        onBattleEnd = function(isWin, goldEarned)
            if isWin and goldEarned > 0 then
                gold_ = gold_ + goldEarned
                goldTargetValue_ = gold_
            end
            SaveBreedingData()
        end,
        onGoldIncrement = function(amount)
            -- Called when a gold particle arrives at gold button (per-particle)
            gold_ = gold_ + amount
            goldTargetValue_ = gold_
            goldShakeTimer_ = 0.15
            goldShakeIntensity_ = 3
            goldAnimating_ = true
        end,
        getColorGrade = GetColorGrade,
        getLevelColor = GetLevelColor,
        drawFarmBall = DrawFarmBall,
        drawBallTooltip = DrawBallTooltip,
        getPlayerMaxLevel = function()
            local maxLv = 1
            for _, ball in ipairs(farmBalls_) do
                if ball.level and ball.level > maxLv then
                    maxLv = ball.level
                end
            end
            for idx = 1, MAX_SLOTS do
                if slotBalls_[idx] then
                    for _, ball in ipairs(slotBalls_[idx]) do
                        if ball.level and ball.level > maxLv then
                            maxLv = ball.level
                        end
                    end
                end
            end
            return maxLv
        end,
        getUploadableBalls = GetUploadableBalls,
    })

    -- Restore arena save data if available (for initial local load)
    -- Note: cloud restore also calls LoadSaveData inside RestoreFromData
    if saved and saved.arena then
        ArenaBattle.LoadSaveData(saved.arena)
    end
end

function BreedingPage.Hide()
    -- Save all ball state before leaving
    SaveBreedingData()
    active_ = false
    callbacks_ = nil
    dragBall_ = nil
    dragFromSlot_ = nil
end

function BreedingPage.IsActive()
    return active_
end

-- ============================================================================
-- Update (called every frame)
-- ============================================================================

function BreedingPage.Update(dt, mx, my)
    if not active_ then return end
    elapsedTime_ = elapsedTime_ + dt
    mouseDesignX_ = mx or -9999
    mouseDesignY_ = my or -9999

    local designW = 1920
    local designH = 1080
    local layout = GetSlotLayout(designW, designH)
    local farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)

    if mx and my then
        mouseLocalX_ = mx - farmX
        mouseLocalY_ = my - farmY
    end

    -- Update ArenaBattle (always, handles its own state)
    ArenaBattle.Update(dt)
    ArenaBattle.UpdatePool()

    -- Mouse wheel for arena pool scrolling
    if ArenaBattle.IsPoolOpen() then
        local wheel = input:GetMouseMoveWheel()
        if wheel ~= 0 then
            ArenaBattle.HandlePoolScroll(wheel)
        end
    end

    -- Panel enemy drag tracking (IDLE state only)
    do
        local mouseDown = input:GetMouseButtonDown(MOUSEB_LEFT)
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.gridY + (layout.gridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end
        ArenaBattle.UpdatePanelDrag(mouseDown, mx or -9999, my or -9999, arenaX, arenaY)
    end

    -- When arena battle is fully active, skip breeding-specific updates
    if ArenaBattle.IsActive() then
        -- Still handle arena battle input
        local pressed = input:GetMouseButtonPress(MOUSEB_LEFT)
        local mouseDown = input:GetMouseButtonDown(MOUSEB_LEFT)
        ArenaBattle.ProcessBattleInput(pressed, mouseDown, mx or -9999, my or -9999, designW, designH)

        -- Still do periodic save
        saveTimer_ = saveTimer_ + dt
        if saveTimer_ >= SAVE_INTERVAL then
            saveTimer_ = saveTimer_ - SAVE_INTERVAL
            SaveBreedingData()
        end
        return
    end

    -- Auto-spawn
    local cap = FARM_CAPACITY[farmLevel_] or 70
    local curSpawnInterval = FARM_SPAWN_RATE[farmLevel_] or SPAWN_INTERVAL
    spawnTimer_ = spawnTimer_ + dt
    if spawnTimer_ >= curSpawnInterval then
        spawnTimer_ = spawnTimer_ - curSpawnInterval
        if #farmBalls_ < cap then
            local newBall = CreateFarmBall(farmW, farmH)
            table.insert(farmBalls_, newBall)
        end
    end

    -- Periodic auto-save
    saveTimer_ = saveTimer_ + dt
    if saveTimer_ >= SAVE_INTERVAL then
        saveTimer_ = saveTimer_ - SAVE_INTERVAL
        SaveBreedingData()
    end

    -- ===== Farm passive healing (balls heal slowly while in farm) =====
    for _, ball in ipairs(farmBalls_) do
        if ball.hp and ball.maxHp and ball.hp < ball.maxHp then
            ball.hp = math.min(ball.maxHp, ball.hp + ball.maxHp * 0.05 * dt)  -- 5% maxHP per second
        end
    end

    -- ===== Boids algorithm =====
    local B = BOIDS
    local count = #farmBalls_

    for i = 1, count do
        local ball = farmBalls_[i]
        local sepX, sepY = 0, 0
        local alignX, alignY = 0, 0
        local cohX, cohY = 0, 0
        local neighborCount = 0

        for j = 1, count do
            if i ~= j then
                local other = farmBalls_[j]
                local dx = ball.x - other.x
                local dy = ball.y - other.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist < B.neighborDist and dist > 0.01 then
                    neighborCount = neighborCount + 1
                    alignX = alignX + other.vx
                    alignY = alignY + other.vy
                    cohX = cohX + other.x
                    cohY = cohY + other.y
                    if dist < B.separationDist then
                        local factor = (B.separationDist - dist) / B.separationDist
                        sepX = sepX + (dx / dist) * factor * B.separationWeight
                        sepY = sepY + (dy / dist) * factor * B.separationWeight
                    end
                end
            end
        end

        local ax, ay = sepX, sepY
        if neighborCount > 0 then
            alignX = alignX / neighborCount
            alignY = alignY / neighborCount
            ax = ax + (alignX - ball.vx) * B.alignmentWeight
            ay = ay + (alignY - ball.vy) * B.alignmentWeight
            cohX = cohX / neighborCount
            cohY = cohY / neighborCount
            ax = ax + (cohX - ball.x) * B.cohesionWeight
            ay = ay + (cohY - ball.y) * B.cohesionWeight
        end

        local mdx = ball.x - mouseLocalX_
        local mdy = ball.y - mouseLocalY_
        local mDist = math.sqrt(mdx * mdx + mdy * mdy)
        if mDist < B.mouseAvoidDist and mDist > 0.01 then
            local mFactor = (B.mouseAvoidDist - mDist) / B.mouseAvoidDist
            ax = ax + (mdx / mDist) * mFactor * B.mouseAvoidWeight
            ay = ay + (mdy / mDist) * mFactor * B.mouseAvoidWeight
        end

        local wm = B.wallMargin + ball.radius
        if ball.x < wm then ax = ax + B.wallWeight * (wm - ball.x) / wm
        elseif ball.x > farmW - wm then ax = ax + B.wallWeight * (farmW - wm - ball.x) / wm end
        if ball.y < wm then ay = ay + B.wallWeight * (wm - ball.y) / wm
        elseif ball.y > farmH - wm then ay = ay + B.wallWeight * (farmH - wm - ball.y) / wm end

        ball.vx = ball.vx + ax * dt
        ball.vy = ball.vy + ay * dt

        local spd = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        if spd > B.maxSpeed then
            ball.vx = ball.vx * B.maxSpeed / spd
            ball.vy = ball.vy * B.maxSpeed / spd
        elseif spd < B.minSpeed and spd > 0.01 then
            ball.vx = ball.vx * B.minSpeed / spd
            ball.vy = ball.vy * B.minSpeed / spd
        end

        ball.x = ball.x + ball.vx * dt
        ball.y = ball.y + ball.vy * dt

        if ball.x - ball.radius < 0 then
            ball.x = ball.radius; ball.vx = math.abs(ball.vx) * 0.5
        elseif ball.x + ball.radius > farmW then
            ball.x = farmW - ball.radius; ball.vx = -math.abs(ball.vx) * 0.5
        end
        if ball.y - ball.radius < 0 then
            ball.y = ball.radius; ball.vy = math.abs(ball.vy) * 0.5
        elseif ball.y + ball.radius > farmH then
            ball.y = farmH - ball.radius; ball.vy = -math.abs(ball.vy) * 0.5
        end
    end

    -- Ball-ball elastic collision in farm
    for i = 1, count do
        local a = farmBalls_[i]
        for j = i + 1, count do
            local b = farmBalls_[j]
            local dx = b.x - a.x
            local dy = b.y - a.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local minDist = a.radius + b.radius
            if dist < minDist and dist > 0.01 then
                local nx = dx / dist
                local ny = dy / dist
                local overlap = minDist - dist
                a.x = a.x - nx * overlap * 0.5
                a.y = a.y - ny * overlap * 0.5
                b.x = b.x + nx * overlap * 0.5
                b.y = b.y + ny * overlap * 0.5
                local dvx = a.vx - b.vx
                local dvy = a.vy - b.vy
                local dvDotN = dvx * nx + dvy * ny
                if dvDotN > 0 then
                    a.vx = a.vx - dvDotN * nx * 0.85
                    a.vy = a.vy - dvDotN * ny * 0.85
                    b.vx = b.vx + dvDotN * nx * 0.85
                    b.vy = b.vy + dvDotN * ny * 0.85
                end
            end
        end
    end

    -- Update all active battles
    for idx = 1, MAX_SLOTS do
        if activeBattles_[idx] then
            UpdateBattle(idx, dt)
        end
    end

    -- Auto-start battles: if a slot has 2+ balls and no active battle, start one
    for idx = 1, slotsUnlocked_ do
        if slotBalls_[idx] and #slotBalls_[idx] >= 2 and not activeBattles_[idx] then
            StartBattle(idx)
        end
    end

    -- === AI Auto-Match System ===
    if aiEnabled_ and aiLevel_ > 0 and #farmBalls_ > 0 then
        aiTimer_ = aiTimer_ + dt
        local interval = GetAiInterval()
        if aiTimer_ >= interval then
            aiTimer_ = aiTimer_ - interval

            -- Helper: find highest-level ball index in farm
            local function findHighestLevelBall()
                local bestIdx = 1
                local bestLvl = farmBalls_[1].level or 1
                for fi = 2, #farmBalls_ do
                    local lvl = farmBalls_[fi].level or 1
                    if lvl > bestLvl then
                        bestLvl = lvl
                        bestIdx = fi
                    end
                end
                return bestIdx
            end

            -- Priority 1: fill empty unlocked slots (prefer highest-level ball)
            local placed = false
            for idx = 1, slotsUnlocked_ do
                if not activeBattles_[idx] and (not slotBalls_[idx] or #slotBalls_[idx] == 0) then
                    if #farmBalls_ > 0 then
                        local pick = findHighestLevelBall()
                        local ball = table.remove(farmBalls_, pick)
                        slotBalls_[idx] = slotBalls_[idx] or {}
                        table.insert(slotBalls_[idx], ball)
                        placed = true
                        break  -- one action per tick
                    end
                end
            end

            -- Priority 2: fill slots that have exactly 1 ball (prefer highest-level ball)
            if not placed and #farmBalls_ > 0 then
                for idx = 1, slotsUnlocked_ do
                    if not activeBattles_[idx] and slotBalls_[idx] and #slotBalls_[idx] == 1 then
                        local pick = findHighestLevelBall()
                        local ball = table.remove(farmBalls_, pick)
                        table.insert(slotBalls_[idx], ball)
                        placed = true
                        break  -- one action per tick
                    end
                end
            end

            -- Priority 3: trigger streak battle during waitingChallenger countdown
            -- Skip if winner HP <= 50% — let the tired ball return to farm
            if not placed and #farmBalls_ > 0 then
                for idx = 1, slotsUnlocked_ do
                    local battle = activeBattles_[idx]
                    if battle and battle.finished and battle.victory
                       and battle.victory.waitingChallenger then
                        local winnerBB = battle.winnerIdx and battle.balls[battle.winnerIdx]
                        if winnerBB then
                            local hpRatio = (winnerBB.maxHp and winnerBB.maxHp > 0)
                                and (winnerBB.hp / winnerBB.maxHp) or 1
                            if hpRatio <= 0.5 then
                                -- HP too low, skip — let winner return to farm
                            else
                                local winnerLevel = winnerBB.level or 1
                                local pick = FindLevelMatchBall(winnerLevel, 2)
                                if pick then
                                    local newBall = table.remove(farmBalls_, pick)
                                    local sc = TriggerStreakBattle(idx, newBall)
                                    if sc then
                                        print(string.format("[Breeding] AI STREAK x%d triggered in slot %d!", sc, idx))
                                        placed = true
                                        break
                                    else
                                        table.insert(farmBalls_, newBall)
                                    end
                                end
                            end
                        end
                    end
                end
            end

            -- Priority 4: inject extra ball into active high-streak battle (streakCount >= 4)
            -- Skip if streak winner HP <= 50%
            if not placed and #farmBalls_ > 0 then
                for idx = 1, slotsUnlocked_ do
                    local battle = activeBattles_[idx]
                    if battle and not battle.finished
                       and battle.streakCount and battle.streakCount >= 4 then
                        -- Check streak winner HP before injecting more opponents
                        local skipLowHp = false
                        if battle.streakWinnerFarmBall then
                            for _, b in ipairs(battle.balls) do
                                if b.alive and b.farmBall == battle.streakWinnerFarmBall then
                                    local hr = (b.maxHp and b.maxHp > 0) and (b.hp / b.maxHp) or 1
                                    if hr <= 0.5 then skipLowHp = true end
                                    break
                                end
                            end
                        end
                        if not skipLowHp then
                            local maxBalls = GetMaxBattleBalls(battle.streakCount)
                            local aliveCount = 0
                            local totalLvl = 0
                            for _, b in ipairs(battle.balls) do
                                if b.alive then
                                    aliveCount = aliveCount + 1
                                    totalLvl = totalLvl + (b.level or 1)
                                end
                            end
                            if aliveCount < maxBalls then
                                local avgLevel = aliveCount > 0 and math.floor(totalLvl / aliveCount) or 1
                                local pick = FindLevelMatchBall(avgLevel, 2)
                                if pick then
                                    local ball = table.remove(farmBalls_, pick)
                                    if InjectBallIntoBattle(idx, ball) then
                                        placed = true
                                        break
                                    else
                                        table.insert(farmBalls_, ball)
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    -- === Victory coin hover detection (scattered coins inside slots) ===
    local designW2 = 1920
    local designH2 = 1080
    local layout2 = GetSlotLayout(designW2, designH2)
    for idx = 1, slotsUnlocked_ do
        local battle = activeBattles_[idx]
        if battle and battle.finished and battle.victory then
            local v = battle.victory
            local sx, sy, sw, sh = GetSlotRect(layout2, idx)
            -- Scale from arena coords to slot pixel coords
            local scaleF = math.min(sw, sh) / BATTLE_ARENA_SIZE

            for _, coin in ipairs(v.coins) do
                if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.5 then
                    -- Convert arena-local coin pos to design coords
                    local coinDesignX = sx + coin.x * scaleF
                    local coinDesignY = sy + coin.y * scaleF
                    local coinR = coin.radius * coin.scale * scaleF
                    local cdx = mouseDesignX_ - coinDesignX
                    local cdy = mouseDesignY_ - coinDesignY
                    if cdx * cdx + cdy * cdy < (coinR + 8) * (coinR + 8) then
                        -- Hover over coin -> collect! Split into mini coins flying to gold button
                        coin.visible = false
                        coin.collected = true
                        local goldBtnCX = designW2 - 30 - 200 / 2
                        local goldBtnCY = 22 + 42 / 2
                        local miniCount = math.max(3, math.floor(coin.value * 2))
                        -- Flight time scales with coin value: ~0.5s for small, ~1.0s for 1000, capped at 1.5s
                        local baseFlightTime = math.max(0.5, math.min(1.5, coin.value / 1000))
                        local perParticleGold = coin.value / miniCount
                        for ci = 1, miniCount do
                            local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                            local spreadDist = 10 + math.random() * 15
                            local delay = (ci - 1) * 0.02 + math.random() * 0.02
                            table.insert(goldParticles_, {
                                x = coinDesignX + math.cos(angle) * spreadDist,
                                y = coinDesignY + math.sin(angle) * spreadDist,
                                startX = coinDesignX + math.cos(angle) * spreadDist,
                                startY = coinDesignY + math.sin(angle) * spreadDist,
                                targetX = goldBtnCX,
                                targetY = goldBtnCY,
                                radius = 6 + math.random() * 3,
                                elapsed = -delay,
                                flightTime = baseFlightTime + math.random() * 0.15,
                                rotation = math.random() * math.pi * 2,
                                trail = {},
                                arrived = false,
                                goldValue = perParticleGold,
                            })
                        end
                        -- Gold is now added when each particle arrives (not here)
                        v.goldAwarded = v.goldAwarded + coin.value
                        goldAnimating_ = true
                        break  -- one coin per frame to avoid multi-collect glitch
                    end
                end
            end
        end
    end

    -- === Update persistent coins (animation, merge, hover collection) ===
    for _, coin in ipairs(persistentCoins_) do
        if coin.visible and not coin.collected and not coin.merged then
            coin.wobble = coin.wobble + dt * 3.0
            coin.rotation = coin.rotation + dt * 4.0
            -- Scale in
            if coin.scale < 1.0 then
                coin.scale = math.min(1.0, coin.scale + dt * 3.0)
            end
        end
    end

    -- Merge nearby persistent coins
    local PERSIST_MERGE_DIST = 60
    local PERSIST_MIN_MERGE = 3
    for i = 1, #persistentCoins_ do
        local a = persistentCoins_[i]
        if a.visible and not a.collected and not a.merged and a.scale >= 0.8 then
            local cluster = { i }
            for j = i + 1, #persistentCoins_ do
                local b = persistentCoins_[j]
                if b.visible and not b.collected and not b.merged and b.scale >= 0.8 then
                    local dx = a.x - b.x; local dy = a.y - b.y
                    if dx * dx + dy * dy < PERSIST_MERGE_DIST * PERSIST_MERGE_DIST then
                        table.insert(cluster, j)
                    end
                end
            end
            if #cluster >= PERSIST_MIN_MERGE then
                local sumX, sumY, sumVal = 0, 0, 0
                local maxR = a.radius
                for _, ci in ipairs(cluster) do
                    local c = persistentCoins_[ci]
                    sumX = sumX + c.x; sumY = sumY + c.y
                    sumVal = sumVal + c.value
                    if c.radius > maxR then maxR = c.radius end
                end
                a.x = sumX / #cluster; a.y = sumY / #cluster
                a.value = sumVal
                a.radius = math.min(28, maxR + 2)
                a.scale = 0.5  -- re-animate
                for ci = 2, #cluster do
                    persistentCoins_[cluster[ci]].merged = true
                    persistentCoins_[cluster[ci]].visible = false
                end
                break  -- one merge per frame
            end
        end
    end

    -- Hover collection for persistent coins
    for _, coin in ipairs(persistentCoins_) do
        if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.5 then
            local coinR = coin.radius * coin.scale
            local cdx = mouseDesignX_ - coin.x
            local cdy = mouseDesignY_ - coin.y
            if cdx * cdx + cdy * cdy < (coinR + 8) * (coinR + 8) then
                coin.visible = false
                coin.collected = true
                local goldBtnCX = designW2 - 30 - 200 / 2
                local goldBtnCY = 22 + 42 / 2
                local miniCount = math.max(3, math.floor(coin.value * 2))
                local baseFlightTime = math.max(0.5, math.min(1.5, coin.value / 1000))
                local perParticleGold = coin.value / miniCount
                for ci = 1, miniCount do
                    local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                    local spreadDist = 10 + math.random() * 15
                    local delay = (ci - 1) * 0.02 + math.random() * 0.02
                    table.insert(goldParticles_, {
                        x = coin.x + math.cos(angle) * spreadDist,
                        y = coin.y + math.sin(angle) * spreadDist,
                        startX = coin.x + math.cos(angle) * spreadDist,
                        startY = coin.y + math.sin(angle) * spreadDist,
                        targetX = goldBtnCX, targetY = goldBtnCY,
                        radius = 6 + math.random() * 3,
                        elapsed = -delay,
                        flightTime = baseFlightTime + math.random() * 0.15,
                        rotation = math.random() * math.pi * 2,
                        trail = {}, arrived = false,
                        goldValue = perParticleGold,
                    })
                end
                goldAnimating_ = true
                break  -- one coin per frame
            end
        end
    end

    -- === Update trash can lid animation ===
    do
        local lidTarget = 0
        if hoverTrashCan_ and dragBall_ then
            lidTarget = 1.2  -- open wide when hovering with a ball
        end
        -- Smooth interpolation
        local lidSpeed = 6.0
        if trashLidAngle_ < lidTarget then
            trashLidAngle_ = math.min(lidTarget, trashLidAngle_ + dt * lidSpeed)
        elseif trashLidAngle_ > lidTarget then
            trashLidAngle_ = math.max(lidTarget, trashLidAngle_ - dt * lidSpeed * 0.7)
        end
        -- Shake decay
        if trashLidShake_ > 0 then
            trashLidShake_ = trashLidShake_ - dt
            if trashLidShake_ < 0 then trashLidShake_ = 0 end
        end
    end

    -- === Update trash explosions ===
    local tei = 1
    while tei <= #trashExplosions_ do
        local exp = trashExplosions_[tei]
        exp.timer = exp.timer + dt
        local allDead = true
        for _, p in ipairs(exp.particles) do
            if p.life > 0 then
                allDead = false
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.vy = p.vy + 200 * dt  -- gravity
                p.vx = p.vx * 0.97
                p.life = p.life - dt
                p.size = p.size * 0.98
            end
        end
        if allDead then
            table.remove(trashExplosions_, tei)
        else
            tei = tei + 1
        end
    end

    -- === Update trash coins (animation + hover collection) ===
    for _, coin in ipairs(trashCoins_) do
        if coin.visible and not coin.collected and not coin.merged then
            if coin.spawnDelay and coin.spawnDelay > 0 then
                coin.spawnDelay = coin.spawnDelay - dt
            else
                coin.wobble = coin.wobble + dt * 3.0
                coin.rotation = coin.rotation + dt * 4.0
                if coin.scale < 1.0 then
                    coin.scale = math.min(1.0, coin.scale + dt * 3.0)
                end
            end
        end
    end

    -- Hover collection for trash coins
    do
        for _, coin in ipairs(trashCoins_) do
            if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.5 then
                local coinR = coin.radius * coin.scale
                local cdx = mouseDesignX_ - coin.x
                local cdy = mouseDesignY_ - coin.y
                if cdx * cdx + cdy * cdy < (coinR + 8) * (coinR + 8) then
                    coin.visible = false
                    coin.collected = true
                    local goldBtnCX = designW2 - 30 - 200 / 2
                    local goldBtnCY = 22 + 42 / 2
                    local miniCount = math.max(3, math.floor(coin.value / 5))
                    miniCount = math.min(miniCount, 20)
                    local baseFlightTime = math.max(0.5, math.min(1.5, coin.value / 1000))
                    local perParticleGold = coin.value / miniCount
                    for ci = 1, miniCount do
                        local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                        local spreadDist = 10 + math.random() * 15
                        local delay = (ci - 1) * 0.02 + math.random() * 0.02
                        table.insert(goldParticles_, {
                            x = coin.x + math.cos(angle) * spreadDist,
                            y = coin.y + math.sin(angle) * spreadDist,
                            startX = coin.x + math.cos(angle) * spreadDist,
                            startY = coin.y + math.sin(angle) * spreadDist,
                            targetX = goldBtnCX, targetY = goldBtnCY,
                            radius = 6 + math.random() * 3,
                            elapsed = -delay,
                            flightTime = baseFlightTime + math.random() * 0.15,
                            rotation = math.random() * math.pi * 2,
                            trail = {}, arrived = false,
                            goldValue = perParticleGold,
                        })
                    end
                    goldAnimating_ = true
                    break  -- one coin per frame
                end
            end
        end
    end

    -- === Update gold mini-coins ===
    local gpi = 1
    while gpi <= #goldParticles_ do
        local gp = goldParticles_[gpi]
        gp.elapsed = gp.elapsed + dt

        if gp.elapsed < 0 then
            -- Still waiting (staggered launch delay)
            gpi = gpi + 1
        elseif gp.elapsed >= gp.flightTime then
            -- Arrived at gold button — add gold NOW (not on collection)
            if not gp.arrived then
                gp.arrived = true
                goldShakeTimer_ = 0.15
                goldShakeIntensity_ = 3
                if gp.goldValue and gp.goldValue > 0 then
                    gold_ = gold_ + gp.goldValue
                    goldTargetValue_ = gold_
                end
            end
            table.remove(goldParticles_, gpi)
        else
            -- Flying toward target with ease-in-out curve
            local t = gp.elapsed / gp.flightTime  -- 0→1
            -- Smooth ease-in-out: slow start, fast middle, slow end
            local eased = t < 0.5 and (2 * t * t) or (1 - 2 * (1 - t) * (1 - t))
            -- Arc: add a slight upward arc in the middle of flight
            local arcY = -math.sin(t * math.pi) * 60
            gp.x = gp.startX + (gp.targetX - gp.startX) * eased
            gp.y = gp.startY + (gp.targetY - gp.startY) * eased + arcY

            -- Spin the mini coin
            gp.rotation = gp.rotation + dt * 12

            -- Record trail (keep last 8 positions)
            table.insert(gp.trail, { x = gp.x, y = gp.y })
            if #gp.trail > 8 then
                table.remove(gp.trail, 1)
            end

            gpi = gpi + 1
        end
    end

    -- Update gold display value (tracks gold_ which now increases gradually via particle arrivals)
    if goldAnimating_ then
        local diff = goldTargetValue_ - goldDisplayValue_
        if math.abs(diff) < 0.5 then
            goldDisplayValue_ = goldTargetValue_
            if #goldParticles_ == 0 then
                goldAnimating_ = false
            end
        else
            -- Fast linear chase: catch up within ~0.1s of each particle arrival
            local speed = math.max(math.abs(diff) * 15, 50)
            if diff > 0 then
                goldDisplayValue_ = math.min(goldTargetValue_, goldDisplayValue_ + speed * dt)
            else
                goldDisplayValue_ = math.max(goldTargetValue_, goldDisplayValue_ - speed * dt)
            end
        end
    else
        goldDisplayValue_ = gold_
    end

    -- Update gold button shake
    if goldShakeTimer_ > 0 then
        goldShakeTimer_ = goldShakeTimer_ - dt
    end
end

-- ============================================================================
-- Input Processing
-- ============================================================================

function BreedingPage.ProcessInput(mx, my, pressed)
    if not active_ then return end
    if ArenaBattle.IsActive() then return end

    local designW = 1920
    local designH = 1080
    local layout = GetSlotLayout(designW, designH)
    local farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)

    -- Arena panel enemy click (tooltip)
    if pressed and not dragBall_ then
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.gridY + (layout.gridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end
        ArenaBattle.ProcessPanelClick(mx, my, pressed, arenaX, arenaY)
    end

    -- Back button
    local backW, backH = 140, 44
    local backX, backY = 30, 30
    hoverBackBtn_ = (mx >= backX and mx <= backX + backW and my >= backY and my <= backY + backH)

    if pressed and hoverBackBtn_ then
        if callbacks_ and callbacks_.onBack then
            callbacks_.onBack()
        end
        return
    end

    -- Slot upgrade button
    local slotBtnW, slotBtnH = 140, 44
    local slotBtnX = layout.gridX + layout.gridW + 30
    local slotBtnY = layout.gridY + layout.gridH - slotBtnH
    hoverSlotBtn_ = (mx >= slotBtnX and mx <= slotBtnX + slotBtnW and my >= slotBtnY and my <= slotBtnY + slotBtnH)

    -- Trash can hover detection (same position as in Render)
    do
        local trashW, trashH = 120, 150
        local trashX = layout.gridX + layout.gridW + 30
        local trashY = layout.gridY + (layout.gridH - trashH) / 2
        hoverTrashCan_ = (mx >= trashX and mx <= trashX + trashW and my >= trashY and my <= trashY + trashH)
    end

    if pressed and hoverSlotBtn_ and slotsUnlocked_ < MAX_SLOTS then
        local costIdx = slotsUnlocked_ - INITIAL_UNLOCKED + 1
        local cost = SLOT_COSTS[costIdx]
        if cost and gold_ >= cost then
            gold_ = gold_ - cost
            slotsUnlocked_ = slotsUnlocked_ + 1
        end
        return
    end

    -- Farm upgrade button
    local farmBtnW, farmBtnH = 140, 44
    local farmBtnX = farmX + farmW + 30
    local farmBtnY = farmY + farmH - farmBtnH
    hoverFarmBtn_ = (mx >= farmBtnX and mx <= farmBtnX + farmBtnW and my >= farmBtnY and my <= farmBtnY + farmBtnH)

    if pressed and hoverFarmBtn_ and farmLevel_ < MAX_FARM_LEVEL then
        local costIdx = farmLevel_
        local cost = FARM_COSTS[costIdx]
        if cost and gold_ >= cost then
            gold_ = gold_ - cost
            farmLevel_ = farmLevel_ + 1
            local newFarmW, newFarmH = GetFarmDimensions(designW, designH)
            for _ = 1, 2 do
                table.insert(farmBalls_, CreateFarmBall(newFarmW, newFarmH))
            end
            for _, ball in ipairs(farmBalls_) do
                if ball.x + ball.radius > newFarmW then ball.x = newFarmW - ball.radius end
                if ball.y + ball.radius > newFarmH then ball.y = newFarmH - ball.radius end
            end
        end
        return
    end

    -- AI auto-match button (left side of battle grid)
    local aiBtnSize = 56
    local aiBtnX = layout.gridX - 50 - aiBtnSize / 2
    local aiBtnY = layout.gridY + layout.gridH - aiBtnSize - 10
    hoverAiBtn_ = (mx >= aiBtnX and mx <= aiBtnX + aiBtnSize and my >= aiBtnY and my <= aiBtnY + aiBtnSize)

    -- Upgrade button hitbox (prominent button below AI toggle)
    local upgBtnW, upgBtnH = 70, 26
    local upgBtnX = aiBtnX + aiBtnSize / 2 - upgBtnW / 2
    local upgBtnY = aiBtnY + aiBtnSize + 22
    hoverAiUpgrade_ = (aiLevel_ > 0 and aiLevel_ < MAX_AI_LEVEL
        and mx >= upgBtnX and mx <= upgBtnX + upgBtnW
        and my >= upgBtnY and my <= upgBtnY + upgBtnH)

    if pressed and hoverAiUpgrade_ then
        -- Click upgrade button: spend gold to level up AI
        local nextCost = AI_COSTS[aiLevel_] or 0
        if nextCost > 0 and gold_ >= nextCost then
            gold_ = gold_ - nextCost
            aiLevel_ = aiLevel_ + 1
            aiTimer_ = 0
            print(string.format("[Breeding] AI upgraded to level %d! Interval: %.1fs", aiLevel_, GetAiInterval()))
        end
        return
    end

    if pressed and hoverAiBtn_ then
        if aiLevel_ == 0 then
            -- First purchase: buy AI level 1 and enable
            local cost = AI_COSTS[1]
            if cost and gold_ >= cost then
                gold_ = gold_ - cost
                aiLevel_ = 1
                aiEnabled_ = true
                aiTimer_ = 0
                print(string.format("[Breeding] AI purchased and enabled! Interval: %.1fs", GetAiInterval()))
            end
        else
            -- Toggle on/off
            aiEnabled_ = not aiEnabled_
            if aiEnabled_ then aiTimer_ = 0 end
            print(string.format("[Breeding] AI %s (Lv.%d)", aiEnabled_ and "ENABLED" or "DISABLED", aiLevel_))
        end
        return
    end

    -- === Battle timeout X button click ===
    if pressed and not dragBall_ then
        for idx = 1, slotsUnlocked_ do
            local battle = activeBattles_[idx]
            if battle and not battle.finished and not battle.aborting
               and battle._abortBtnRect
               and (battle.battleElapsed or 0) >= 20 then
                local r = battle._abortBtnRect
                if mx >= r.x and mx <= r.x + r.w and my >= r.y and my <= r.y + r.h then
                    AbortBattle(idx)
                    return
                end
            end
        end
    end

    -- === Drag: start dragging from farm ===
    if pressed and not dragBall_ and not dragFromSlot_ then
        -- Check if clicking a farm ball
        for i = #farmBalls_, 1, -1 do
            local ball = farmBalls_[i]
            local bx = farmX + ball.x
            local by = farmY + ball.y
            local dx = mx - bx
            local dy = my - by
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < ball.radius + 10 then
                -- Only allow dragging basic balls (not ones in active battle)
                dragBall_ = {
                    farmIndex = i,
                    ball = ball,
                    curX = mx,
                    curY = my,
                }
                -- Remove from farm temporarily
                table.remove(farmBalls_, i)
                return
            end
        end
    end

    -- === Drag: update position ===
    if dragBall_ then
        dragBall_.curX = mx
        dragBall_.curY = my
    end

    -- === Drag: release ===
    if dragBall_ and not pressed then
        -- Check if input module says button is still down
        -- (ProcessInput is called on press, we need continuous check)
        -- We'll handle release in Update via mouse button state
    end
end

-- Continuous mouse tracking (called from Update, not just on press)
function BreedingPage.ProcessMouseRelease(mouseDown, mx, my)
    if not active_ then return end
    if ArenaBattle.IsActive() then return end
    if not dragBall_ then return end

    dragBall_.curX = mx
    dragBall_.curY = my

    if not mouseDown then
        -- Release: check if over a battle slot
        local designW = 1920
        local designH = 1080
        local layout = GetSlotLayout(designW, designH)

        local placed = false
        for idx = 1, slotsUnlocked_ do
            local sx, sy, sw, sh = GetSlotRect(layout, idx)
            if mx >= sx and mx <= sx + sw and my >= sy and my <= sy + sh then
                -- Check if slot accepts a new ball
                local battle = activeBattles_[idx]
                if not battle then
                    -- Empty slot: place ball normally
                    table.insert(slotBalls_[idx], dragBall_.ball)
                    placed = true
                    print(string.format("[Breeding] Ball placed in slot %d (total: %d)", idx, #slotBalls_[idx]))
                elseif not battle.finished and battle.streakCount
                       and battle.streakCount >= 4 then
                    -- Mid-battle injection for high streak
                    if InjectBallIntoBattle(idx, dragBall_.ball) then
                        placed = true
                        print(string.format("[Breeding] Drag-injected ball into streak x%d battle slot %d!", battle.streakCount, idx))
                    end
                elseif battle.finished and battle.victory and battle.victory.waitingChallenger then
                    -- Streak battle trigger via shared function
                    local sc = TriggerStreakBattle(idx, dragBall_.ball)
                    if sc then
                        placed = true
                        print(string.format("[Breeding] STREAK x%d triggered in slot %d!", sc, idx))
                    end
                end
                break
            end
        end

        -- Check arena panel drop → start arena battle
        if not placed then
            local apW, apH = ArenaBattle.GetPanelSize()
            local arenaX = layout.gridX - 70 - apW
            local arenaY = layout.gridY + (layout.gridH - apH) / 2
            if arenaX < 4 then arenaX = 4 end
            if mx >= arenaX and mx <= arenaX + apW and my >= arenaY and my <= arenaY + apH then
                if not ArenaBattle.IsActive() then
                    local ok = ArenaBattle.StartBattle(dragBall_.ball, { x = arenaX, y = arenaY, w = apW, h = apH })
                    if ok ~= false then
                        placed = true
                        -- 球被拖入擂台时上传到云端共享
                        ArenaCloud.UploadBall(SerializeBall(dragBall_.ball))
                        print(string.format("[Breeding] Ball dragged into arena! Starting arena battle wave %d, uploaded to cloud", ArenaBattle.GetCurrentWave()))
                    end
                end
            end
        end

        -- Check trash can drop
        if not placed then
            local trashW, trashH = 120, 150
            local trashX = layout.gridX + layout.gridW + 30
            local trashY = layout.gridY + (layout.gridH - trashH) / 2
            if mx >= trashX and mx <= trashX + trashW and my >= trashY and my <= trashY + trashH then
                placed = true
                local ball = dragBall_.ball
                local grade = GetColorGrade(ball.level)
                local sellValue = TRASH_SELL_VALUES[grade] or 10

                -- Create explosion at trash can center
                local expCX = trashX + trashW / 2
                local expCY = trashY + trashH * 0.4
                local particles = {}
                for pi = 1, 24 do
                    local angle = (pi - 1) / 24 * math.pi * 2 + math.random() * 0.3
                    local speed = 80 + math.random() * 160
                    local bc = ball.color or { r = 200, g = 200, b = 200 }
                    table.insert(particles, {
                        x = expCX, y = expCY,
                        vx = math.cos(angle) * speed,
                        vy = math.sin(angle) * speed - 50,
                        life = 0.6 + math.random() * 0.6,
                        maxLife = 0.6 + math.random() * 0.6,
                        r = bc.r or 200, g = bc.g or 200, b = bc.b or 200,
                        size = 3 + math.random() * 5,
                    })
                end
                table.insert(trashExplosions_, { x = expCX, y = expCY, particles = particles, timer = 0 })

                -- Trigger lid shake animation
                trashLidShake_ = 0.8
                trashLidAngle_ = 0.6  -- start partially open, will shake then close

                -- Spawn trash coins near the trash can
                local coinCount = math.max(2, math.min(8, math.floor(math.log(sellValue + 1) / math.log(10) * 2.5)))
                local perCoin = sellValue / coinCount
                for ci = 1, coinCount do
                    local cx = trashX + trashW / 2 + (math.random() - 0.5) * trashW * 0.8
                    local cy = trashY + trashH + 20 + math.random() * 40
                    local coinR = math.max(12, math.min(26, 10 + math.log(perCoin + 1) / math.log(10) * 5))
                    table.insert(trashCoins_, {
                        x = cx, y = cy, visible = true, collected = false,
                        value = perCoin, wobble = math.random() * math.pi * 2,
                        rotation = math.random() * math.pi * 2, scale = 0,
                        spawnDelay = (ci - 1) * 0.08, radius = coinR, merged = false,
                    })
                end

                print(string.format("[Trash] Sold Lv.%d ball (grade %d) for %d gold", ball.level, grade, sellValue))
            end
        end

        if not placed then
            -- Return to farm
            local farmW, farmH = GetFarmDimensions(designW, designH)
            local farmX, farmY
            farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)
            dragBall_.ball.x = math.max(dragBall_.ball.radius, math.min(farmW - dragBall_.ball.radius, mx - farmX))
            dragBall_.ball.y = math.max(dragBall_.ball.radius, math.min(farmH - dragBall_.ball.radius, my - farmY))
            table.insert(farmBalls_, dragBall_.ball)
        end

        dragBall_ = nil
    end
end

-- ============================================================================
-- Render
-- ============================================================================

function BreedingPage.Render(vg, w, h, fontId)
    if not active_ then return end

    local designW = w
    local designH = h
    local layout = GetSlotLayout(designW, designH)

    -- Background
    nvgBeginPath(vg); nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(40, 40, 48, 255)); nvgFill(vg)

    nvgFontFaceId(vg, fontId)

    -- Apply breeding UI fade-out when arena battle is transitioning/active
    local arenaFade = ArenaBattle.GetBreedingFadeOut()
    if arenaFade > 0 then
        nvgGlobalAlpha(vg, math.max(0, 1 - arenaFade))
    end

    -- Gold display (with shake + animated value)
    local goldBgW = 200
    local goldBgH = 42
    local goldBgX = designW - 30 - goldBgW
    local goldBgY = 22

    -- Apply shake offset when gold button is shaking
    local gShakeX, gShakeY = 0, 0
    if goldShakeTimer_ > 0 then
        local intensity = goldShakeIntensity_ * (goldShakeTimer_ / 0.5)
        gShakeX = math.sin(goldShakeTimer_ * 47) * intensity
        gShakeY = math.cos(goldShakeTimer_ * 53) * intensity * 0.7
    end

    local finalGoldX = goldBgX + gShakeX
    local finalGoldY = goldBgY + gShakeY

    -- Gold button glow when shaking
    if goldShakeTimer_ > 0 then
        local glowAlpha = math.floor(80 * (goldShakeTimer_ / 0.5))
        nvgBeginPath(vg); nvgRoundedRect(vg, finalGoldX - 4, finalGoldY - 4, goldBgW + 8, goldBgH + 8, 10)
        nvgFillColor(vg, nvgRGBA(255, 220, 50, glowAlpha)); nvgFill(vg)
    end

    -- Gold button background
    nvgBeginPath(vg); nvgRoundedRect(vg, finalGoldX, finalGoldY, goldBgW, goldBgH, 6)
    nvgFillColor(vg, nvgRGBA(240, 190, 40, 255)); nvgFill(vg)

    -- Animated gold value display
    local displayVal = math.floor(goldDisplayValue_ + 0.5)
    local goldText = string.format("%d¥", displayVal)
    nvgFontSize(vg, 28)
    nvgFillColor(vg, nvgRGBA(40, 30, 10, 255))
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgText(vg, finalGoldX + goldBgW / 2, finalGoldY + goldBgH / 2, goldText, nil)

    -- Draw gold mini-coins (simplified: no trail, no glow)
    for _, p in ipairs(goldParticles_) do
        if p.elapsed >= 0 then
            local mcR = p.radius
            nvgBeginPath(vg); nvgCircle(vg, p.x, p.y, mcR)
            nvgFillColor(vg, nvgRGBA(255, 225, 60, 240)); nvgFill(vg)
        end
    end

    -- Back button
    local backW, backH = 140, 44
    local backX, backY = 30, 30
    nvgBeginPath(vg); nvgRoundedRect(vg, backX, backY, backW, backH, 6)
    if hoverBackBtn_ then
        nvgFillColor(vg, nvgRGBA(80, 80, 100, 220))
    else
        nvgFillColor(vg, nvgRGBA(60, 60, 75, 200))
    end
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(180, 180, 200, 150)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    nvgFontSize(vg, 18)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(230, 230, 240, 240))
    nvgText(vg, backX + backW / 2, backY + backH / 2, "← 返回", nil)

    -- Hint text
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(180, 180, 200, 150))
    nvgText(vg, designW / 2, 30, "从养殖场拖拽球到战斗槽位，2个以上球开始自动战斗！", nil)

    -- "战斗区域" vertical label
    local labelX = layout.gridX - 50
    local labelCenterY = layout.gridY + layout.gridH / 2
    nvgFontSize(vg, 24)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(220, 220, 230, 230))
    local labelChars = { "战", "斗", "区", "域" }
    for ci, ch in ipairs(labelChars) do
        local cy = labelCenterY + (ci - 2.5) * 32
        nvgText(vg, labelX, cy, ch, nil)
    end

    -- AI auto-match button (left side, below vertical label)
    do
        local aiBtnSize = 56
        local aiBtnX = labelX - aiBtnSize / 2
        local aiBtnY = layout.gridY + layout.gridH - aiBtnSize - 10
        local aiBtnCX = aiBtnX + aiBtnSize / 2
        local aiBtnCY = aiBtnY + aiBtnSize / 2
        local isOwned = aiLevel_ > 0
        local isOn = isOwned and aiEnabled_
        local isMaxed = aiLevel_ >= MAX_AI_LEVEL

        -- Button background glow (only when ON)
        if isOn then
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 2.0)
            local glowR = aiBtnSize / 2 + 6 + pulse * 4
            nvgBeginPath(vg); nvgCircle(vg, aiBtnCX, aiBtnCY, glowR)
            local glowAlpha = math.floor(40 + pulse * 30)
            if isMaxed then
                nvgFillColor(vg, nvgRGBA(255, 200, 50, glowAlpha))
            else
                nvgFillColor(vg, nvgRGBA(80, 180, 255, glowAlpha))
            end
            nvgFill(vg)
        end

        -- Button circle
        nvgBeginPath(vg); nvgCircle(vg, aiBtnCX, aiBtnCY, aiBtnSize / 2)
        if hoverAiBtn_ then
            if isOn then
                nvgFillColor(vg, nvgRGBA(80, 130, 200, 240))
            elseif isOwned then
                nvgFillColor(vg, nvgRGBA(90, 90, 105, 240))  -- owned but off hover
            else
                nvgFillColor(vg, nvgRGBA(80, 80, 95, 240))
            end
        elseif isOn then
            if isMaxed then
                nvgFillColor(vg, nvgRGBA(180, 150, 40, 220))
            else
                nvgFillColor(vg, nvgRGBA(60, 110, 180, 220))
            end
        elseif isOwned then
            nvgFillColor(vg, nvgRGBA(60, 60, 72, 200))  -- owned but OFF: dim
        else
            nvgFillColor(vg, nvgRGBA(70, 70, 85, 200))   -- not purchased
        end
        nvgFill(vg)

        -- Border: green ring when ON, red/grey when OFF
        if isOn then
            nvgStrokeColor(vg, nvgRGBA(80, 220, 120, 200))
        elseif isOwned then
            nvgStrokeColor(vg, nvgRGBA(200, 80, 80, 180))
        else
            nvgStrokeColor(vg, nvgRGBA(180, 180, 210, 180))
        end
        nvgStrokeWidth(vg, 2.0)
        nvgStroke(vg)

        -- "OFF" slash overlay when owned but disabled
        if isOwned and not aiEnabled_ then
            nvgStrokeColor(vg, nvgRGBA(255, 80, 80, 160))
            nvgStrokeWidth(vg, 3.0)
            nvgBeginPath(vg)
            nvgMoveTo(vg, aiBtnCX - 14, aiBtnCY - 14)
            nvgLineTo(vg, aiBtnCX + 14, aiBtnCY + 14)
            nvgStroke(vg)
        end

        -- AI icon: brain/circuit pattern
        nvgSave(vg)
        nvgTranslate(vg, aiBtnCX, aiBtnCY)
        local iconAlpha = isOn and 240 or (isOwned and 120 or 200)
        local iconColor = isOn and nvgRGBA(255, 255, 255, iconAlpha) or nvgRGBA(160, 160, 180, iconAlpha)

        -- Central circle (brain core)
        nvgBeginPath(vg); nvgCircle(vg, 0, 0, 6)
        nvgFillColor(vg, iconColor); nvgFill(vg)

        -- Circuit lines radiating outward
        nvgStrokeColor(vg, iconColor)
        nvgStrokeWidth(vg, 2.0)
        local arms = 4
        for ai = 1, arms do
            local angle = (ai - 1) / arms * math.pi * 2 - math.pi / 4
            local r1 = 9
            local r2 = 17
            local ex = math.cos(angle)
            local ey = math.sin(angle)
            nvgBeginPath(vg)
            nvgMoveTo(vg, ex * r1, ey * r1)
            nvgLineTo(vg, ex * r2, ey * r2)
            nvgStroke(vg)
            nvgBeginPath(vg); nvgCircle(vg, ex * r2, ey * r2, 3)
            nvgFillColor(vg, iconColor); nvgFill(vg)
        end

        -- Connecting arcs
        nvgStrokeWidth(vg, 1.2)
        for ai = 1, arms do
            local a1 = (ai - 1) / arms * math.pi * 2 - math.pi / 4
            local a2 = ai / arms * math.pi * 2 - math.pi / 4
            local mx1 = math.cos(a1) * 17
            local my1 = math.sin(a1) * 17
            local mx2 = math.cos(a2) * 17
            local my2 = math.sin(a2) * 17
            local midA = (a1 + a2) / 2
            local ctrlX = math.cos(midA) * 22
            local ctrlY = math.sin(midA) * 22
            nvgBeginPath(vg)
            nvgMoveTo(vg, mx1, my1)
            nvgQuadTo(vg, ctrlX, ctrlY, mx2, my2)
            nvgStroke(vg)
        end
        nvgRestore(vg)

        -- Text below button: status line
        nvgFontSize(vg, 12)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        if not isOwned then
            -- Not purchased: show cost
            local cost = AI_COSTS[1] or 0
            local canAfford = gold_ >= cost
            nvgFillColor(vg, canAfford and nvgRGBA(200, 200, 220, 200) or nvgRGBA(140, 140, 150, 150))
            nvgText(vg, aiBtnCX, aiBtnY + aiBtnSize + 4, string.format("AI ¥%d", cost), nil)
        else
            -- On/Off indicator above button
            nvgFontSize(vg, 11)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
            if aiEnabled_ then
                nvgFillColor(vg, nvgRGBA(80, 220, 120, 200))
                nvgText(vg, aiBtnCX, aiBtnY - 4, "ON", nil)
            else
                nvgFillColor(vg, nvgRGBA(200, 80, 80, 180))
                nvgText(vg, aiBtnCX, aiBtnY - 4, "OFF", nil)
            end

            -- Level + interval info
            nvgFontSize(vg, 11)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            if isMaxed then
                nvgFillColor(vg, nvgRGBA(255, 220, 80, 220))
                nvgText(vg, aiBtnCX, aiBtnY + aiBtnSize + 4,
                    string.format("MAX Lv.%d", aiLevel_), nil)
            else
                nvgFillColor(vg, nvgRGBA(180, 190, 210, 200))
                nvgText(vg, aiBtnCX, aiBtnY + aiBtnSize + 4,
                    string.format("Lv.%d %.1fs", aiLevel_, GetAiInterval()), nil)
            end

            -- Prominent upgrade button (only when not maxed)
            if not isMaxed then
                local nextCost = AI_COSTS[aiLevel_] or 0
                local canAfford = gold_ >= nextCost
                local ubW, ubH = 70, 26
                local ubX = aiBtnCX - ubW / 2
                local ubY = aiBtnY + aiBtnSize + 22

                -- Button background with rounded rect
                nvgBeginPath(vg); nvgRoundedRect(vg, ubX, ubY, ubW, ubH, 6)
                if hoverAiUpgrade_ then
                    if canAfford then
                        nvgFillColor(vg, nvgRGBA(60, 180, 80, 240))
                    else
                        nvgFillColor(vg, nvgRGBA(150, 60, 60, 200))
                    end
                else
                    if canAfford then
                        -- Pulsing green glow to draw attention
                        local pulse = 0.7 + 0.3 * math.sin(elapsedTime_ * 3.0)
                        local g = math.floor(140 + 60 * pulse)
                        nvgFillColor(vg, nvgRGBA(40, g, 60, 220))
                    else
                        nvgFillColor(vg, nvgRGBA(80, 80, 90, 180))
                    end
                end
                nvgFill(vg)

                -- Button border
                nvgStrokeColor(vg, canAfford and nvgRGBA(100, 255, 120, 180) or nvgRGBA(120, 120, 130, 150))
                nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

                -- Arrow up icon + text
                nvgFontSize(vg, 13)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, canAfford and nvgRGBA(255, 255, 255, 240) or nvgRGBA(160, 160, 170, 180))
                nvgText(vg, aiBtnCX, ubY + ubH / 2, string.format("⬆¥%d", nextCost), nil)
            end
        end
    end

    -- Draw battle slots
    for row = 0, GRID_ROWS - 1 do
        for col = 0, GRID_COLS - 1 do
            local idx = row * GRID_COLS + col + 1
            local sx, sy, sw, sh = GetSlotRect(layout, idx)

            nvgBeginPath(vg); nvgRect(vg, sx, sy, sw, sh)
            nvgStrokeColor(vg, nvgRGBA(180, 180, 190, 140))
            nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

            if idx <= slotsUnlocked_ then
                -- Check if dragging over this slot
                local isHover = dragBall_ and not activeBattles_[idx]
                    and mouseDesignX_ >= sx and mouseDesignX_ <= sx + sw
                    and mouseDesignY_ >= sy and mouseDesignY_ <= sy + sh
                if isHover then
                    nvgFillColor(vg, nvgRGBA(80, 120, 80, 120))
                else
                    nvgFillColor(vg, nvgRGBA(50, 50, 60, 80))
                end
                nvgFill(vg)

                -- Draw battle if active
                local battle = activeBattles_[idx]
                if battle then
                    DrawBattle(vg, fontId, sx, sy, sw, sh, battle)
                else
                    -- Draw waiting balls in slot
                    local slotBalls = slotBalls_[idx]
                    if slotBalls and #slotBalls > 0 then
                        DrawSlotBalls(vg, fontId, sx, sy, sw, sh, slotBalls)
                    end
                end
            else
                -- Locked slot
                nvgFillColor(vg, nvgRGBA(45, 45, 55, 120)); nvgFill(vg)
                nvgBeginPath(vg)
                nvgMoveTo(vg, sx, sy); nvgLineTo(vg, sx + sw, sy + sh)
                nvgMoveTo(vg, sx + sw, sy); nvgLineTo(vg, sx, sy + sh)
                nvgStrokeColor(vg, nvgRGBA(160, 160, 170, 100))
                nvgStrokeWidth(vg, 1); nvgStroke(vg)
            end
        end
    end

    -- ---- Arena (擂台赛) - left side panel ----
    do
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.gridY + (layout.gridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end

        ArenaBattle.RenderPanel(vg, fontId, arenaX, arenaY, dragBall_ ~= nil, elapsedTime_)
    end

    -- ---- Trash Can (垃圾桶) - right side facility ----
    do
        local trashW, trashH = 120, 150
        local trashX = layout.gridX + layout.gridW + 30
        local trashY = layout.gridY + (layout.gridH - trashH) / 2

        -- Glow when dragging a ball
        if dragBall_ then
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 4)
            nvgBeginPath(vg); nvgRoundedRect(vg, trashX - 6, trashY - 6, trashW + 12, trashH + 12, 14)
            nvgFillColor(vg, nvgRGBA(255, 100, 60, math.floor(30 + pulse * 40))); nvgFill(vg)
        end

        -- Trash can body (bucket shape)
        nvgBeginPath(vg)
        nvgMoveTo(vg, trashX + 10, trashY + 40)
        nvgLineTo(vg, trashX + trashW - 10, trashY + 40)
        nvgLineTo(vg, trashX + trashW - 20, trashY + trashH)
        nvgLineTo(vg, trashX + 20, trashY + trashH)
        nvgClosePath(vg)
        if hoverTrashCan_ and dragBall_ then
            nvgFillColor(vg, nvgRGBA(100, 70, 50, 220))
        else
            nvgFillColor(vg, nvgRGBA(70, 55, 45, 200))
        end
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(160, 130, 100, 180))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)

        -- Lid (animated: opens when dragging, shakes after explosion)
        do
            local lidW = trashW - 8
            local lidH = 12
            local lidPivotX = trashX + 4            -- left hinge
            local lidPivotY = trashY + 32 + lidH    -- bottom of lid
            local finalAngle = -trashLidAngle_       -- negative = rotate upward/open
            -- Add shake wobble
            if trashLidShake_ > 0 then
                local shakeIntensity = trashLidShake_ / 0.8
                finalAngle = finalAngle - math.sin(trashLidShake_ * 25) * 0.3 * shakeIntensity
            end
            nvgSave(vg)
            nvgTranslate(vg, lidPivotX, lidPivotY)
            nvgRotate(vg, finalAngle)
            -- Lid body
            nvgBeginPath(vg)
            nvgRoundedRect(vg, 0, -lidH, lidW, lidH, 3)
            nvgFillColor(vg, nvgRGBA(120, 100, 80, 220)); nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(160, 130, 100, 180))
            nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
            -- Handle on lid
            nvgBeginPath(vg)
            nvgRoundedRect(vg, lidW / 2 - 15, -lidH - 8, 30, 10, 4)
            nvgFillColor(vg, nvgRGBA(140, 115, 90, 220)); nvgFill(vg)
            nvgRestore(vg)
        end

        -- Vertical ribs
        for li = 1, 3 do
            local lx = trashX + 10 + (trashW - 20) * li / 4
            nvgBeginPath(vg)
            nvgMoveTo(vg, lx, trashY + 44)
            nvgLineTo(vg, trashX + 20 + (trashW - 40) * li / 4, trashY + trashH - 4)
            nvgStrokeColor(vg, nvgRGBA(130, 105, 80, 100))
            nvgStrokeWidth(vg, 1); nvgStroke(vg)
        end

        -- Title
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(220, 200, 180, 220))
        nvgText(vg, trashX + trashW / 2, trashY + 6, "垃圾桶", nil)

        -- Sell hint
        nvgFontSize(vg, 11)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(180, 160, 140, 150))
        nvgText(vg, trashX + trashW / 2, trashY + trashH + 4, "拖入球球卖钱", nil)
    end

    -- ---- Draw trash explosions ----
    for _, exp in ipairs(trashExplosions_) do
        for _, p in ipairs(exp.particles) do
            if p.life > 0 then
                local alpha = math.floor(255 * (p.life / p.maxLife))
                nvgBeginPath(vg); nvgCircle(vg, p.x, p.y, p.size * (p.life / p.maxLife))
                nvgFillColor(vg, nvgRGBA(p.r, p.g, p.b, alpha)); nvgFill(vg)
            end
        end
    end

    -- ---- Draw trash coins (simplified: no glow, no gradient, no highlight) ----
    for _, coin in ipairs(trashCoins_) do
        if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.01 then
            local cs = coin.scale
            if not (coin.spawnDelay and coin.spawnDelay > 0) then
                local wobbleY = math.sin(coin.wobble) * 3 * cs
                local drawX = coin.x
                local drawY = coin.y + wobbleY
                local rotCos = math.cos(coin.rotation)
                local squash = math.abs(rotCos)
                local COIN_R = coin.radius * cs
                local coinW = COIN_R * math.max(0.15, squash)

                -- Edge
                nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW + 2, COIN_R + 2)
                nvgFillColor(vg, nvgRGBA(180, 130, 0, math.floor(220 * cs))); nvgFill(vg)
                -- Body
                nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW, COIN_R)
                nvgFillColor(vg, nvgRGBA(255, 225, 60, math.floor(250 * cs))); nvgFill(vg)
                -- Value label
                nvgFontFaceId(vg, fontId)
                nvgFontSize(vg, 11)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
                nvgText(vg, drawX, drawY + COIN_R + 3,
                    string.format("+%d", math.floor(coin.value)), nil)
            end
        end
    end

    -- Slot upgrade button
    local slotBtnW, slotBtnH = 140, 44
    local slotBtnX = layout.gridX + layout.gridW + 30
    local slotBtnY = layout.gridY + layout.gridH - slotBtnH
    if slotsUnlocked_ < MAX_SLOTS then
        local costIdx = slotsUnlocked_ - INITIAL_UNLOCKED + 1
        local cost = SLOT_COSTS[costIdx] or 0
        local canAfford = gold_ >= cost
        nvgBeginPath(vg); nvgRoundedRect(vg, slotBtnX, slotBtnY, slotBtnW, slotBtnH, 6)
        if hoverSlotBtn_ and canAfford then
            nvgFillColor(vg, nvgRGBA(220, 220, 230, 240))
        elseif canAfford then
            nvgFillColor(vg, nvgRGBA(200, 200, 210, 220))
        else
            nvgFillColor(vg, nvgRGBA(120, 120, 130, 180))
        end
        nvgFill(vg)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(40, 40, 50, 255))
        nvgText(vg, slotBtnX + slotBtnW / 2, slotBtnY + slotBtnH / 2,
            string.format("升级%d¥", cost), nil)
    else
        nvgFontSize(vg, 14)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(120, 255, 120, 200))
        nvgText(vg, slotBtnX + slotBtnW / 2, slotBtnY + slotBtnH / 2, "已满级", nil)
    end

    -- ---- Farm Area ----
    local farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)

    -- "养殖场" vertical label (matching arena style)
    local farmLabelX = farmX - 60
    local farmLabelCY = farmY + farmH / 2
    nvgFontSize(vg, 26)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(200, 230, 200, 230))
    local farmLabelChars = { "养", "殖", "场" }
    for ci, ch in ipairs(farmLabelChars) do
        local cy = farmLabelCY + (ci - 2) * 36
        nvgText(vg, farmLabelX, cy, ch, nil)
    end

    -- Farm panel (arena-like style: rounded rect, deep background, accent border)
    nvgBeginPath(vg); nvgRoundedRect(vg, farmX, farmY, farmW, farmH, 10)
    nvgFillColor(vg, nvgRGBA(40, 55, 45, 180)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(100, 200, 130, 140))
    nvgStrokeWidth(vg, 2); nvgStroke(vg)

    -- Top decorative accent bar
    nvgBeginPath(vg)
    nvgRoundedRect(vg, farmX + 10, farmY + 4, farmW - 20, 4, 2)
    nvgFillColor(vg, nvgRGBA(130, 220, 160, 160)); nvgFill(vg)

    -- Draw farm balls
    for _, ball in ipairs(farmBalls_) do
        DrawFarmBall(vg, fontId, farmX + ball.x, farmY + ball.y, ball)
    end

    -- Farm level + capacity
    local cap = FARM_CAPACITY[farmLevel_] or 70
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(160, 220, 180, 200))
    nvgText(vg, farmX + 10, farmY + farmH - 8,
        string.format("Lv.%d / %d  |  %d / %d", farmLevel_, MAX_FARM_LEVEL, #farmBalls_, cap), nil)

    -- Farm upgrade button
    local farmBtnW, farmBtnH = 140, 44
    local farmBtnX = farmX + farmW + 30
    local farmBtnY = farmY + farmH - farmBtnH
    if farmLevel_ < MAX_FARM_LEVEL then
        local costIdx = farmLevel_
        local cost = FARM_COSTS[costIdx] or 0
        local canAfford = gold_ >= cost
        nvgBeginPath(vg); nvgRoundedRect(vg, farmBtnX, farmBtnY, farmBtnW, farmBtnH, 6)
        if hoverFarmBtn_ and canAfford then
            nvgFillColor(vg, nvgRGBA(220, 220, 230, 240))
        elseif canAfford then
            nvgFillColor(vg, nvgRGBA(200, 200, 210, 220))
        else
            nvgFillColor(vg, nvgRGBA(120, 120, 130, 180))
        end
        nvgFill(vg)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(40, 40, 50, 255))
        nvgText(vg, farmBtnX + farmBtnW / 2, farmBtnY + farmBtnH / 2,
            string.format("升级%d¥", cost), nil)
    else
        nvgFontSize(vg, 14)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(120, 255, 120, 200))
        nvgText(vg, farmBtnX + farmBtnW / 2, farmBtnY + farmBtnH / 2, "已满级", nil)
    end

    -- Farm level info (below upgrade button)
    do
        local infoY = farmBtnY + farmBtnH + 6
        local maxBLvl = FARM_MAX_BALL_LEVEL[farmLevel_] or 7
        local newBLvl = FARM_NEW_BALL_LEVEL[farmLevel_] or 1
        local spawnRate = FARM_SPAWN_RATE[farmLevel_] or 5.0
        local gradeNames = { "白", "绿", "蓝", "紫", "橙", "红", "炫彩" }
        nvgFontSize(vg, 10)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(180, 190, 210, 180))
        local maxGradeName = gradeNames[GetColorGrade(maxBLvl)] or "?"
        nvgText(vg, farmBtnX + farmBtnW / 2, infoY,
            string.format("上限Lv%d(%s) 新球Lv%d %.1fs/个", maxBLvl, maxGradeName, newBLvl, spawnRate), nil)
    end

    -- === Draw victory gold coins scattered inside slots ===
    for idx = 1, slotsUnlocked_ do
        local battle = activeBattles_[idx]
        if battle and battle.finished and battle.victory then
            local v = battle.victory
            local sx2, sy2, sw2, sh2 = GetSlotRect(layout, idx)
            local scaleF = math.min(sw2, sh2) / BATTLE_ARENA_SIZE

            for _, coin in ipairs(v.coins) do
                if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.01 then
                    local cs = coin.scale
                    local coinDesignX = sx2 + coin.x * scaleF
                    local coinDesignY = sy2 + coin.y * scaleF
                    local wobbleY = math.sin(coin.wobble) * 3 * cs
                    local drawX = coinDesignX
                    local drawY = coinDesignY + wobbleY
                    local rotCos = math.cos(coin.rotation)
                    local squash = math.abs(rotCos)
                    local COIN_R = coin.radius * cs * scaleF
                    local coinW = COIN_R * math.max(0.15, squash)

                    -- Edge
                    nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW + 2, COIN_R + 2)
                    nvgFillColor(vg, nvgRGBA(180, 130, 0, math.floor(220 * cs))); nvgFill(vg)
                    -- Body
                    nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW, COIN_R)
                    nvgFillColor(vg, nvgRGBA(255, 225, 60, math.floor(250 * cs))); nvgFill(vg)
                    -- Value label
                    nvgFontFaceId(vg, fontId)
                    local valueFontSize = math.floor(math.max(9, 11 * scaleF))
                    nvgFontSize(vg, valueFontSize)
                    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                    nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
                    nvgText(vg, drawX, drawY + COIN_R + 3,
                        string.format("+%d", math.floor(coin.value)), nil)
                end
            end
        end
    end

    -- === Draw persistent coins (simplified: no glow, no gradient) ===
    for _, coin in ipairs(persistentCoins_) do
        if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.01 then
            local cs = coin.scale
            local wobbleY = math.sin(coin.wobble) * 3 * cs
            local drawX = coin.x
            local drawY = coin.y + wobbleY
            local rotCos = math.cos(coin.rotation)
            local squash = math.abs(rotCos)
            local COIN_R = coin.radius * cs
            local coinW = COIN_R * math.max(0.15, squash)

            -- Edge
            nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW + 2, COIN_R + 2)
            nvgFillColor(vg, nvgRGBA(180, 130, 0, math.floor(220 * cs))); nvgFill(vg)
            -- Body
            nvgBeginPath(vg); nvgEllipse(vg, drawX, drawY, coinW, COIN_R)
            nvgFillColor(vg, nvgRGBA(255, 225, 60, math.floor(250 * cs))); nvgFill(vg)
            -- Value label
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 11)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
            nvgText(vg, drawX, drawY + COIN_R + 3,
                string.format("+%d", math.floor(coin.value)), nil)
        end
    end

    -- Draw dragging ball + info tooltip (on top of everything)
    if dragBall_ then
        local ball = dragBall_.ball
        DrawFarmBall(vg, fontId, dragBall_.curX, dragBall_.curY, ball)
        -- Highlight ring
        nvgGlobalAlpha(vg, 0.5)
        nvgBeginPath(vg); nvgCircle(vg, dragBall_.curX, dragBall_.curY, ball.radius + 6)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 100, 180))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
        nvgGlobalAlpha(vg, 1.0)
        -- Show info tooltip while dragging
        DrawBallTooltip(vg, fontId, dragBall_.curX, dragBall_.curY, ball, w, h)
    end

    -- Restore alpha and render arena battle overlay (on top of everything)
    nvgGlobalAlpha(vg, 1.0)
    if ArenaBattle.IsActive() or arenaFade > 0 then
        ArenaBattle.RenderBattle(vg, fontId, designW, designH, elapsedTime_)
    end

    -- Re-draw gold display on top of arena battle overlay (user wants it always visible)
    if ArenaBattle.IsActive() then
        local goldBgW2 = 200
        local goldBgH2 = 42
        local goldBgX2 = designW - 30 - goldBgW2
        local goldBgY2 = 22
        nvgBeginPath(vg); nvgRoundedRect(vg, goldBgX2, goldBgY2, goldBgW2, goldBgH2, 6)
        nvgFillColor(vg, nvgRGBA(240, 190, 40, 255)); nvgFill(vg)
        local displayVal2 = math.floor(goldDisplayValue_ + 0.5)
        local goldText2 = string.format("%d¥", displayVal2)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 28)
        nvgFillColor(vg, nvgRGBA(40, 30, 10, 255))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg, goldBgX2 + goldBgW2 / 2, goldBgY2 + goldBgH2 / 2, goldText2, nil)
    end

    -- Render arena character pool overlay (Tab key panel, on top of everything)
    if ArenaBattle.IsPoolOpen() then
        ArenaBattle.RenderPool(vg, fontId, designW, designH, elapsedTime_)
    end
end

-- ============================================================================
-- Draw Helpers
-- ============================================================================

function DrawFarmBall(vg, fontId, bx, by, ball)
    local c = ball.color
    local r = ball.radius
    local lvl = ball.level
    local grade = GetColorGrade(lvl)
    local isRainbow = (c and c.rainbow) or (grade == 7)

    -- For rainbow balls, compute cycling color
    if isRainbow then
        local t = elapsedTime_ * 1.5
        local phase = t % 6.0
        local cr, cg, cb
        if phase < 1 then
            cr, cg, cb = 255, math.floor(phase * 255), 0
        elseif phase < 2 then
            cr, cg, cb = math.floor((2 - phase) * 255), 255, 0
        elseif phase < 3 then
            cr, cg, cb = 0, 255, math.floor((phase - 2) * 255)
        elseif phase < 4 then
            cr, cg, cb = 0, math.floor((4 - phase) * 255), 255
        elseif phase < 5 then
            cr, cg, cb = math.floor((phase - 4) * 255), 0, 255
        else
            cr, cg, cb = 255, 0, math.floor((6 - phase) * 255)
        end
        c = { r = cr, g = cg, b = cb, rainbow = true }
    end

    -- Single soft glow (grade 2+ only)
    if grade >= 2 then
        local glowSize = r * (1.6 + grade * 0.15)
        local glowAlpha = math.min(30 + grade * 8, 80)
        nvgBeginPath(vg); nvgCircle(vg, bx, by, glowSize)
        nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, r * 0.5, glowSize,
            nvgRGBA(c.r, c.g, c.b, glowAlpha), nvgRGBA(c.r, c.g, c.b, 0)))
        nvgFill(vg)
    end

    -- Ball body
    nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
    nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 230)); nvgFill(vg)

    -- Highlight
    nvgBeginPath(vg); nvgCircle(vg, bx - r * 0.25, by - r * 0.25, r * 0.35)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, isRainbow and 120 or 80)); nvgFill(vg)

    -- Grade ring
    if grade >= 2 then
        local gradeRingColors = {
            [2] = { r = 80,  g = 210, b = 100, a = 180 },
            [3] = { r = 70,  g = 150, b = 255, a = 200 },
            [4] = { r = 170, g = 80,  b = 230, a = 200 },
            [5] = { r = 255, g = 160, b = 40,  a = 220 },
            [6] = { r = 240, g = 60,  b = 60,  a = 230 },
            [7] = { r = c.r, g = c.g, b = c.b, a = 240 },
        }
        local rc = gradeRingColors[grade]
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r + 2)
        nvgStrokeColor(vg, nvgRGBA(rc.r, rc.g, rc.b, rc.a))
        nvgStrokeWidth(vg, 1.0 + grade * 0.3); nvgStroke(vg)
    end

    -- Expression face or level text
    if ball.expression then
        Expressions.Draw(vg, ball.expression, bx, by, r)
    else
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, math.max(8, r * 0.9))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
        nvgText(vg, bx, by, tostring(ball.level), nil)
    end

    -- Level badge
    if lvl >= 5 then
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, math.max(7, r * 0.55))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 180))
        nvgText(vg, bx, by - r - 6, string.format("Lv%d", lvl), nil)
    end

    -- Experience bar
    local lvlDef = LEVEL_DEFS[ball.level]
    if lvlDef and lvlDef.expToNext then
        local barW = r * 2
        local barH = 3
        local barX = bx - barW / 2
        local barY = by + r + 3
        local pct = math.min(1, ball.exp / lvlDef.expToNext)
        nvgBeginPath(vg); nvgRoundedRect(vg, barX, barY, barW, barH, 1)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 120)); nvgFill(vg)
        if pct > 0 then
            nvgBeginPath(vg); nvgRoundedRect(vg, barX, barY, barW * pct, barH, 1)
            nvgFillColor(vg, nvgRGBA(100, 255, 180, 200)); nvgFill(vg)
        end
    end
end

function DrawSlotBalls(vg, fontId, sx, sy, sw, sh, slotBalls)
    -- Draw small ball icons waiting in the slot
    local count = #slotBalls
    local spacing = math.min(30, (sw - 20) / math.max(1, count))
    local startX = sx + sw / 2 - (count - 1) * spacing / 2
    local centerY = sy + sh / 2

    for i, ball in ipairs(slotBalls) do
        local bx = startX + (i - 1) * spacing
        local by = centerY
        local r = 10
        local c = ball.color
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 220)); nvgFill(vg)
        -- Level
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 9)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
        nvgText(vg, bx, by, tostring(ball.level), nil)
    end

    -- "等待中..." label
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(180, 180, 200, 150))
    nvgText(vg, sx + sw / 2, sy + sh - 8,
        count >= 2 and "即将开战..." or "等待对手...", nil)
end

function DrawBattle(vg, fontId, sx, sy, sw, sh, battle)
    -- Handle abort animation: draw squish + explosion then return early
    if battle.aborting then
        local ab = battle.aborting
        local margin = 8
        local fullSize = math.min(sw, sh) - margin * 2
        local centerX = sx + sw / 2
        local centerY = sy + sh / 2

        nvgSave(vg)
        nvgScissor(vg, sx, sy, sw, sh)

        if ab.phase == "squish" then
            local t = math.min(1, ab.timer / ab.duration)
            -- Elastic squish: ease-out-bounce feel
            local eased = t * t * (3 - 2 * t)  -- smoothstep
            local scaleY = 1.0 - eased * 0.95  -- vertical: 1.0 → 0.05
            local scaleX = 1.0 + eased * 0.3   -- horizontal: 1.0 → 1.3 (slight bulge)
            -- Q-bounce overshoot
            local bounce = math.sin(t * math.pi * 3) * (1 - t) * 0.15
            scaleY = scaleY + bounce
            scaleX = scaleX - bounce * 0.5

            local drawW = fullSize * scaleX
            local drawH = fullSize * math.max(0.02, scaleY)
            local drawOX = centerX - drawW / 2
            local drawOY = centerY - drawH / 2

            -- Background rect with squish
            nvgBeginPath(vg)
            nvgRoundedRect(vg, drawOX, drawOY, drawW, drawH, 4 * scaleY)
            nvgFillColor(vg, nvgRGBA(25, 25, 35, 200))
            nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(255, 80, 30, 220))
            nvgStrokeWidth(vg, 2)
            nvgStroke(vg)

            -- Draw balls squeezed vertically
            local arenaScale = fullSize / BATTLE_ARENA_SIZE
            for _, ball in ipairs(battle.balls) do
                if ball.alive then
                    local bx = drawOX + ball.x * arenaScale * scaleX
                    local by = centerY + (ball.y - BATTLE_ARENA_SIZE / 2) * arenaScale * scaleY
                    local br = ball.radius * arenaScale * math.max(0.3, scaleY)
                    nvgBeginPath(vg); nvgEllipse(vg, bx, by, br * scaleX, br * math.max(0.2, scaleY))
                    nvgFillColor(vg, nvgRGBA(ball.color.r, ball.color.g, ball.color.b, 200))
                    nvgFill(vg)
                end
            end

        elseif ab.phase == "explode" then
            local arenaScale = fullSize / BATTLE_ARENA_SIZE
            for _, p in ipairs(ab.explosionParticles) do
                local t = p.elapsed / p.life
                if t < 1 then
                    local alpha = math.floor(255 * (1 - t))
                    local px = centerX + (p.x - BATTLE_ARENA_SIZE / 2) * arenaScale + p.vx * p.elapsed * 0.3
                    local py = centerY + (p.y - BATTLE_ARENA_SIZE / 2) * arenaScale + p.vy * p.elapsed * 0.3
                    local pSize = p.size * (1 - t * 0.5)
                    nvgBeginPath(vg); nvgCircle(vg, px, py, pSize)
                    nvgFillColor(vg, nvgRGBA(p.r, p.g, p.b, alpha)); nvgFill(vg)
                    -- Bright core
                    nvgBeginPath(vg); nvgCircle(vg, px, py, pSize * 0.4)
                    nvgFillColor(vg, nvgRGBA(255, 255, 200, math.floor(alpha * 0.6))); nvgFill(vg)
                end
            end
            -- Flash effect at center
            local flashT = math.min(1, ab.timer / 0.15)
            if flashT < 1 then
                local flashAlpha = math.floor(200 * (1 - flashT))
                nvgBeginPath(vg); nvgCircle(vg, centerX, centerY, fullSize * 0.4 * (0.5 + flashT))
                nvgFillPaint(vg, nvgRadialGradient(vg, centerX, centerY, 0, fullSize * 0.4,
                    nvgRGBA(255, 255, 200, flashAlpha), nvgRGBA(255, 200, 50, 0)))
                nvgFill(vg)
            end
        end

        nvgRestore(vg)
        return  -- Don't draw normal battle during abort
    end

    -- Map battle arena (BATTLE_ARENA_SIZE) into slot rect
    local margin = 8
    local drawSize = math.min(sw, sh) - margin * 2
    local scale = drawSize / BATTLE_ARENA_SIZE
    local ox = sx + (sw - drawSize) / 2
    local oy = sy + (sh - drawSize) / 2

    local v = battle.victory  -- may be nil if not finished yet
    local isVictory = battle.finished and v

    -- Apply room shake offset to drawing origin
    local shakeX = isVictory and (v.shakeOffsetX * scale) or 0
    local shakeY = isVictory and (v.shakeOffsetY * scale) or 0

    -- Add streak shake (persistent vibration during streak)
    local streakCount = (isVictory and v.streakCount) or (battle.streakCount) or 1
    if isVictory and v.streakCount and v.streakCount >= 2 then
        local intensity = math.min(v.streakCount * 0.8, 5)
        shakeX = shakeX + math.sin(elapsedTime_ * 35) * intensity
        shakeY = shakeY + math.cos(elapsedTime_ * 28) * intensity * 0.7
    end

    -- Battle background (darker) - clip to slot area
    nvgSave(vg)
    nvgScissor(vg, sx, sy, sw, sh)

    nvgBeginPath(vg); nvgRect(vg, ox + shakeX, oy + shakeY, drawSize, drawSize)
    nvgFillColor(vg, nvgRGBA(25, 25, 35, 200)); nvgFill(vg)
    if isVictory then
        if v.streakCount and v.streakCount >= 2 then
            -- Fire-red border during streak
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 8)
            local r = math.floor(255)
            local g = math.floor(80 + 60 * pulse)
            local b = math.floor(20 + 20 * pulse)
            local borderAlpha = math.floor(180 + 70 * pulse)
            nvgStrokeColor(vg, nvgRGBA(r, g, b, borderAlpha))
            nvgStrokeWidth(vg, 2.5 + v.streakCount * 0.5)
        else
            -- Golden border during normal victory
            local pulse = 0.6 + 0.4 * math.sin(elapsedTime_ * 6)
            local borderAlpha = math.floor(120 + 100 * pulse)
            nvgStrokeColor(vg, nvgRGBA(255, 215, 0, borderAlpha))
            nvgStrokeWidth(vg, 2.5)
        end
    else
        -- Active battle border: red/orange for streak battles
        if streakCount >= 2 then
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 5)
            nvgStrokeColor(vg, nvgRGBA(255, math.floor(60 + 40 * pulse), 30, 200))
            nvgStrokeWidth(vg, 2.0)
        else
            nvgStrokeColor(vg, nvgRGBA(255, 100, 50, 120))
            nvgStrokeWidth(vg, 1.5)
        end
    end
    nvgStroke(vg)

    -- "胜利!" label if finished (in design coords, above arena)
    if isVictory and battle.winnerIdx then
        local winner = battle.balls[battle.winnerIdx]
        local c = winner.color
        nvgFontFaceId(vg, fontId)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if v.streakCount and v.streakCount >= 2 then
            -- Show streak victory label
            nvgFontSize(vg, 16)
            local pulse = 0.6 + 0.4 * math.sin(elapsedTime_ * 5)
            nvgFillColor(vg, nvgRGBA(255, math.floor(150 * pulse), 30, 255))
            nvgText(vg, sx + sw / 2, sy + 16, string.format("%d连胜!", v.streakCount), nil)
        else
            nvgFontSize(vg, 18)
            nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 255))
            nvgText(vg, sx + sw / 2, sy + 16, "胜利!", nil)
        end
    end

    -- Use NanoVG transform to scale 400x400 arena into slot visual area (with shake)
    nvgSave(vg)
    nvgTranslate(vg, ox + shakeX, oy + shakeY)
    nvgScale(vg, scale, scale)

    -- Restore SkillExecutor state and draw all skill effects
    SkillExecutor.RestoreState(battle.seState)
    SkillExecutor.Draw(vg, 0, 0)

    -- Draw firework particles (in arena coordinates, simplified: no glow)
    if isVictory then
        for _, fw in ipairs(v.fireworks) do
            local fwAlpha = 1 - fw.elapsed / fw.life
            for _, p in ipairs(fw.particles) do
                local pa = math.floor(255 * fwAlpha * fwAlpha)
                local pr = p.radius * (0.3 + 0.7 * fwAlpha)
                nvgBeginPath(vg); nvgCircle(vg, fw.x + p.x, fw.y + p.y, pr)
                nvgFillColor(vg, nvgRGBA(p.r, p.g, p.b, pa)); nvgFill(vg)
            end
        end
    end

    -- Draw blood splatters (in arena coordinates)
    for _, sp in ipairs(battle.bloodSplatters) do
        local t = 1 - sp.elapsed / sp.life
        local alpha = math.floor(200 * t * t)
        local c = sp.color
        nvgBeginPath(vg); nvgCircle(vg, sp.x, sp.y, sp.radius * (0.5 + 0.5 * t))
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, alpha)); nvgFill(vg)
    end

    -- Draw balls (in arena coordinates)
    for bi, ball in ipairs(battle.balls) do
        if ball.alive or (battle.finished and battle.winnerIdx) then
            local bx = ball.x
            local by = ball.y
            local br = ball.radius
            local c = ball.color
            local alpha = ball.alive and 230 or 60
            local isWinner = isVictory and bi == battle.winnerIdx and ball.alive

            -- Level tier for visual effects
            local blvl = ball.level
            local btier = blvl >= 20 and 6 or blvl >= 15 and 5 or blvl >= 10 and 4 or blvl >= 5 and 3 or blvl >= 2 and 2 or 1

            -- Winner glow
            if isWinner then
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br * 1.6)
                nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.5, br * 1.6,
                    nvgRGBA(255, 215, 0, 50), nvgRGBA(255, 215, 0, 0)))
                nvgFill(vg)
            end

            -- Tier ring (in battle, behind ball body)
            if ball.alive and btier >= 3 then
                local tierRingC = btier >= 6 and {255,150,255} or btier >= 5 and {150,200,255} or btier >= 4 and {255,220,50} or {200,210,220}
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br + 2)
                nvgStrokeColor(vg, nvgRGBA(tierRingC[1], tierRingC[2], tierRingC[3], 180))
                nvgStrokeWidth(vg, 1.0 + btier * 0.3); nvgStroke(vg)
            end

            -- Ball body
            nvgBeginPath(vg); nvgCircle(vg, bx, by, br)
            nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, alpha)); nvgFill(vg)

            -- Highlight
            if ball.alive then
                nvgBeginPath(vg); nvgCircle(vg, bx - br * 0.2, by - br * 0.2, br * 0.3)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 60)); nvgFill(vg)
            end

            -- Expression face: winner gets "smug", others keep their expression
            if ball.alive then
                if isWinner then
                    Expressions.Draw(vg, "smug", bx, by, br)
                else
                    local expr = ball.farmBall and ball.farmBall.expression
                    if expr then
                        Expressions.Draw(vg, expr, bx, by, br)
                    else
                        nvgFontFaceId(vg, fontId)
                        nvgFontSize(vg, math.max(14, br * 0.8))
                        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                        nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
                        nvgText(vg, bx, by, tostring(ball.level), nil)
                    end
                end
            end

            -- Crown image on winner's head
            if isWinner then
                -- Load crown image once
                if not crownImgHandle_ then
                    crownImgHandle_ = nvgCreateImage(vg, "image/crown.png", 0)
                end
                if crownImgHandle_ and crownImgHandle_ > 0 then
                    local crownSize = br * 2.0
                    local crownDrawX = bx - crownSize / 2
                    local crownDrawY = by - br - crownSize * 0.7
                    local imgPat = nvgImagePattern(vg, crownDrawX, crownDrawY, crownSize, crownSize, 0, crownImgHandle_, 1.0)
                    nvgBeginPath(vg)
                    nvgRect(vg, crownDrawX, crownDrawY, crownSize, crownSize)
                    nvgFillPaint(vg, imgPat)
                    nvgFill(vg)
                end
            end

            -- HP bar (only during active battle, not during victory for winner)
            if ball.alive and not isWinner then
                local hpW = br * 2.2
                local hpH = 6
                local hpX = bx - hpW / 2
                local hpY = by - br - 10
                local hpPct = math.max(0, ball.hp / ball.maxHp)
                nvgBeginPath(vg); nvgRoundedRect(vg, hpX, hpY, hpW, hpH, 2)
                nvgFillColor(vg, nvgRGBA(0, 0, 0, 150)); nvgFill(vg)
                if hpPct > 0 then
                    local hr = hpPct < 0.5 and 255 or math.floor(255 * (1 - hpPct) * 2)
                    local hg = hpPct > 0.5 and 255 or math.floor(255 * hpPct * 2)
                    nvgBeginPath(vg); nvgRoundedRect(vg, hpX, hpY, hpW * hpPct, hpH, 2)
                    nvgFillColor(vg, nvgRGBA(hr, hg, 80, 220)); nvgFill(vg)
                end
            end

            -- Stun indicator
            if ball.alive and ball.stunTimer > 0 and not isVictory then
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br + 4)
                nvgStrokeColor(vg, nvgRGBA(255, 255, 0, 150))
                nvgStrokeWidth(vg, 3); nvgStroke(vg)
                local starCount = 3
                for si = 1, starCount do
                    local sa = elapsedTime_ * 4 + (si - 1) * (math.pi * 2 / starCount)
                    local starX = bx + math.cos(sa) * (br + 10)
                    local starY = by + math.sin(sa) * (br + 10)
                    nvgFontFaceId(vg, fontId)
                    nvgFontSize(vg, 16)
                    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgFillColor(vg, nvgRGBA(255, 255, 50, 200))
                    nvgText(vg, starX, starY, "*", nil)
                end
            end

            -- Dead X mark
            if not ball.alive then
                nvgBeginPath(vg)
                nvgMoveTo(vg, bx - br * 0.5, by - br * 0.5)
                nvgLineTo(vg, bx + br * 0.5, by + br * 0.5)
                nvgMoveTo(vg, bx + br * 0.5, by - br * 0.5)
                nvgLineTo(vg, bx - br * 0.5, by + br * 0.5)
                nvgStrokeColor(vg, nvgRGBA(255, 50, 50, 180))
                nvgStrokeWidth(vg, 4); nvgStroke(vg)
            end
        end
    end

    -- Draw damage popups (in arena coordinates)
    for _, popup in ipairs(battle.damagePopups) do
        local t = 1 - popup.elapsed / popup.duration
        local alpha = math.floor(255 * t)
        local c = popup.color
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, popup.isEnhanced and 28 or 22)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, alpha))
        nvgText(vg, popup.x, popup.y, string.format("-%d", popup.damage), nil)
    end

    nvgRestore(vg)  -- restore arena transform

    -- === Streak visual effects (drawn in screen coords, inside scissor) ===
    if isVictory and v then
        local centerX = ox + drawSize / 2 + shakeX
        local centerY = oy + drawSize / 2 + shakeY

        -- 1. Countdown display
        if v.waitingChallenger and v.countdown > 0 then
            local countNum = math.ceil(v.countdown)
            local countStr = tostring(countNum)
            local frac = v.countdown - math.floor(v.countdown)
            local countScale = 1.0 + 0.3 * (1.0 - frac)
            local countAlpha = math.floor(180 + 75 * frac)
            nvgSave(vg)
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 48 * countScale)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(countAlpha * 0.5)))
            nvgText(vg, centerX + 2, centerY + 2, countStr, nil)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, countAlpha))
            nvgText(vg, centerX, centerY, countStr, nil)
            nvgFontSize(vg, 14)
            nvgFillColor(vg, nvgRGBA(255, 200, 100, math.floor(countAlpha * 0.7)))
            local nextMaxBalls = GetMaxBattleBalls((v.streakCount or 1) + 1)
            if nextMaxBalls > 2 then
                nvgText(vg, centerX, centerY + 35, string.format("等待挑战者...(下场最多%d球)", nextMaxBalls), nil)
            else
                nvgText(vg, centerX, centerY + 35, "等待挑战者...", nil)
            end
            nvgRestore(vg)
        end

        -- 2. Streak "XN" text
        if v.streakCount and v.streakCount >= 2 then
            local xnStr = string.format("X%d", v.streakCount)
            local baseSize = 60 + v.streakCount * 8
            local tremble = math.sin(elapsedTime_ * 20) * (1 + v.streakCount * 0.5)
            local trembleY = math.cos(elapsedTime_ * 17) * (1 + v.streakCount * 0.3)
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 6)
            local xnAlpha = math.floor(60 + 80 * pulse)
            nvgSave(vg)
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, baseSize)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 50, 20, xnAlpha))
            nvgText(vg, centerX + tremble, centerY - drawSize * 0.3 + trembleY, xnStr, nil)
            nvgFillColor(vg, nvgRGBA(255, 200, 50, math.floor(xnAlpha * 0.5)))
            nvgText(vg, centerX + tremble * 0.5, centerY - drawSize * 0.3 + trembleY * 0.5, xnStr, nil)
            nvgRestore(vg)
        end

        -- 3. Fire particles along border
        if v.fireParticles and #v.fireParticles > 0 then
            for _, fp in ipairs(v.fireParticles) do
                local t = fp.elapsed / fp.life
                local alpha = math.floor(255 * (1 - t))
                local fpx = ox + fp.x * scale + shakeX
                local fpy = oy + fp.y * scale + shakeY
                local fpSize = fp.size * scale * (1 - t * 0.5)
                local fr = 255
                local fg = math.floor(200 * (1 - t))
                local fb = math.floor(50 * (1 - t))
                nvgBeginPath(vg)
                nvgCircle(vg, fpx, fpy, fpSize)
                nvgFillColor(vg, nvgRGBA(fr, fg, fb, alpha))
                nvgFill(vg)
                -- Bright core
                nvgBeginPath(vg)
                nvgCircle(vg, fpx, fpy, fpSize * 0.4)
                nvgFillColor(vg, nvgRGBA(255, 255, 150, math.floor(alpha * 0.8)))
                nvgFill(vg)
            end
        end

        -- 4. Streak count indicator (top-right corner badge during active streak battle)
        if v.streakCount and v.streakCount >= 2 and not v.waitingChallenger then
            -- This shows during the actual fighting phase of a streak
        end
    end

    -- Active battle streak indicator (during fighting, not victory)
    if not battle.finished and streakCount >= 2 then
        local badgeStr = string.format("连战 X%d", streakCount)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 14)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        local pulse = 0.6 + 0.4 * math.sin(elapsedTime_ * 4)
        nvgFillColor(vg, nvgRGBA(255, 100, 30, math.floor(200 * pulse)))
        nvgText(vg, ox + drawSize / 2, sy + 3, badgeStr, nil)

        -- "可加球" blinking indicator for high-streak multi-ball battles
        if streakCount >= 4 then
            local maxB = GetMaxBattleBalls(streakCount)
            local curAlive = 0
            for _, b in ipairs(battle.balls) do
                if b.alive then curAlive = curAlive + 1 end
            end
            if curAlive < maxB then
                nvgFontSize(vg, 12)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                local blink = 0.5 + 0.5 * math.sin(elapsedTime_ * 5)
                nvgFillColor(vg, nvgRGBA(100, 255, 100, math.floor(180 * blink)))
                nvgText(vg, ox + drawSize / 2, sy + 18, string.format("可加球 %d/%d", curAlive, maxB), nil)
            end
        end
    end

    -- Timeout X button (shown after 20s of active fighting)
    if not battle.finished and not battle.aborting
       and (battle.battleElapsed or 0) >= 20 then
        local btnSize = 28
        local btnX = ox + drawSize - btnSize - 4
        local btnY = oy + 4
        local pulse = 0.6 + 0.4 * math.sin(elapsedTime_ * 3)
        local btnAlpha = math.floor(180 + 75 * pulse)

        -- Store button rect for click detection (in design coords)
        battle._abortBtnRect = { x = btnX, y = btnY, w = btnSize, h = btnSize }

        -- Button background (red circle)
        nvgBeginPath(vg)
        nvgCircle(vg, btnX + btnSize / 2, btnY + btnSize / 2, btnSize / 2)
        nvgFillColor(vg, nvgRGBA(200, 40, 40, btnAlpha))
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(255, 100, 100, btnAlpha))
        nvgStrokeWidth(vg, 1.5)
        nvgStroke(vg)

        -- X mark
        local xOff = btnSize * 0.22
        local cx, cy = btnX + btnSize / 2, btnY + btnSize / 2
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx - xOff, cy - xOff)
        nvgLineTo(vg, cx + xOff, cy + xOff)
        nvgMoveTo(vg, cx + xOff, cy - xOff)
        nvgLineTo(vg, cx - xOff, cy + xOff)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, btnAlpha))
        nvgStrokeWidth(vg, 2.5)
        nvgStroke(vg)
    end

    -- (Gold coin is drawn in main Render after all slots, to ensure it's on top)

    nvgRestore(vg)  -- restore scissor
end

-- ============================================================================
-- Draw Ball Info Tooltip (right-click popup)
-- ============================================================================

function DrawBallTooltip(vg, fontId, tipX, tipY, ball, screenW, screenH)
    nvgSave(vg)
    nvgFontFaceId(vg, fontId)

    -- Tooltip dimensions
    local popW = 280
    local popH = 220
    local arrowH = 12
    local cornerR = 12
    local pad = 16

    -- Position: popup appears above the click point, arrow points down
    local px = tipX - popW / 2
    local py = tipY - popH - arrowH - 8

    -- Clamp to screen
    if px < 10 then px = 10 end
    if px + popW > screenW - 10 then px = screenW - 10 - popW end
    if py < 10 then
        -- Show below instead
        py = tipY + arrowH + 8
    end

    -- Arrow X position (clamped to popup bounds)
    local arrowX = math.max(px + cornerR + 8, math.min(tipX, px + popW - cornerR - 8))

    -- Background (dark rounded rect with slight transparency)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, px, py, popW, popH, cornerR)
    nvgFillColor(vg, nvgRGBA(35, 35, 45, 240))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(120, 120, 140, 160))
    nvgStrokeWidth(vg, 1.5)
    nvgStroke(vg)

    -- Arrow (triangle pointing down toward the ball)
    local arrowDir = 1  -- 1 = arrow below popup, -1 = arrow above
    local arrowBaseY = py + popH
    if py > tipY then
        -- Popup is below click, arrow points up
        arrowDir = -1
        arrowBaseY = py
    end
    nvgBeginPath(vg)
    if arrowDir == 1 then
        nvgMoveTo(vg, arrowX - 8, arrowBaseY)
        nvgLineTo(vg, arrowX, arrowBaseY + arrowH)
        nvgLineTo(vg, arrowX + 8, arrowBaseY)
    else
        nvgMoveTo(vg, arrowX - 8, arrowBaseY)
        nvgLineTo(vg, arrowX, arrowBaseY - arrowH)
        nvgLineTo(vg, arrowX + 8, arrowBaseY)
    end
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(35, 35, 45, 240))
    nvgFill(vg)

    -- ---- Content layout ----
    local contentX = px + pad
    local contentY = py + pad

    -- Ball face (large circle with expression)
    local faceCx = contentX + 40
    local faceCy = contentY + 40
    local faceR = 36
    local c = ball.color

    -- Face glow
    nvgBeginPath(vg); nvgCircle(vg, faceCx, faceCy, faceR * 1.4)
    nvgFillPaint(vg, nvgRadialGradient(vg, faceCx, faceCy, faceR * 0.3, faceR * 1.4,
        nvgRGBA(c.r, c.g, c.b, 50), nvgRGBA(c.r, c.g, c.b, 0)))
    nvgFill(vg)

    -- Face body
    nvgBeginPath(vg); nvgCircle(vg, faceCx, faceCy, faceR)
    nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 240))
    nvgFill(vg)

    -- Highlight
    nvgBeginPath(vg); nvgCircle(vg, faceCx - faceR * 0.2, faceCy - faceR * 0.2, faceR * 0.3)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 70))
    nvgFill(vg)

    -- Level tier ring
    if ball.level >= 2 then
        local ttier = ball.level >= 20 and 6 or ball.level >= 15 and 5 or ball.level >= 10 and 4 or ball.level >= 5 and 3 or 2
        local tRingC = ttier >= 6 and {255,150,255} or ttier >= 5 and {150,200,255} or ttier >= 4 and {255,220,50} or ttier >= 3 and {200,210,220} or {205,150,50}
        nvgBeginPath(vg); nvgCircle(vg, faceCx, faceCy, faceR + 3)
        nvgStrokeColor(vg, nvgRGBA(tRingC[1], tRingC[2], tRingC[3], 220))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
    end

    -- Draw expression on face
    if ball.expression then
        Expressions.Draw(vg, ball.expression, faceCx, faceCy, faceR)
    end

    -- ---- Text info (right side of face) ----
    local infoX = faceCx + faceR + 16
    local infoY = contentY + 6

    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    -- Name
    nvgFontSize(vg, 20)
    nvgFillColor(vg, nvgRGBA(220, 220, 230, 255))
    local nameText = "姓名：" .. (ball.name or "???")
    nvgText(vg, infoX, infoY, nameText, nil)
    infoY = infoY + 28

    -- Level
    nvgFontSize(vg, 17)
    nvgFillColor(vg, nvgRGBA(200, 200, 215, 230))
    nvgText(vg, infoX, infoY, string.format("等级：%d级", ball.level), nil)
    infoY = infoY + 24

    -- HP
    local hp = ball.hp or 0
    local maxHp = ball.maxHp or 1
    local hpColor
    local hpPct = hp / maxHp
    if hpPct > 0.6 then
        hpColor = nvgRGBA(100, 255, 150, 240)
    elseif hpPct > 0.3 then
        hpColor = nvgRGBA(255, 220, 80, 240)
    else
        hpColor = nvgRGBA(255, 90, 80, 240)
    end
    nvgFillColor(vg, nvgRGBA(200, 200, 215, 230))
    nvgText(vg, infoX, infoY, "血量：", nil)
    -- HP value in color
    local hpLabelW = 50
    nvgFillColor(vg, hpColor)
    nvgText(vg, infoX + hpLabelW, infoY, string.format("%d/%d", math.floor(hp), math.floor(maxHp)), nil)

    -- ---- Skills section ----
    local skillY = contentY + 100
    local skillX = contentX
    local skillSize = 52
    local skillGap = 14
    local totalSkills = 3  -- normal, enhanced, ultimate

    local skillSlots = {
        { label = "技能1", id = ball.skill,         tier = "normal" },
        { label = "技能2", id = ball.enhancedSkill,  tier = "enhanced" },
        { label = "技能3", id = ball.ultimateSkill,    tier = "ultimate" },
    }

    for si, slot in ipairs(skillSlots) do
        local sx = skillX + (si - 1) * (skillSize + skillGap)
        local sy = skillY

        -- Skill slot background
        nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, skillSize, skillSize, 6)
        nvgStrokeColor(vg, nvgRGBA(140, 140, 160, 180))
        nvgStrokeWidth(vg, 1.5)
        nvgStroke(vg)

        if slot.id then
            -- Has skill: draw skill icon (colored square with name)
            local skillDef = SkillRegistry.Get(slot.id)
            if skillDef then
                local sc = skillDef.color
                -- Skill colored background
                nvgBeginPath(vg); nvgRoundedRect(vg, sx + 3, sy + 3, skillSize - 6, skillSize - 6, 4)
                nvgFillColor(vg, nvgRGBA(sc.r, sc.g, sc.b, 60))
                nvgFill(vg)

                -- Skill icon circle
                local iconR = 14
                nvgBeginPath(vg); nvgCircle(vg, sx + skillSize / 2, sy + skillSize / 2 - 4, iconR)
                nvgFillColor(vg, nvgRGBA(sc.r, sc.g, sc.b, 200))
                nvgFill(vg)

                -- Skill name below icon
                nvgFontSize(vg, 11)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                nvgFillColor(vg, nvgRGBA(220, 220, 240, 220))
                nvgText(vg, sx + skillSize / 2, sy + skillSize / 2 + 14, skillDef.name, nil)
            end
        else
            -- Empty/locked: draw X
            local locked = (slot.tier == "enhanced" and ball.level < 2) or (slot.tier == "ultimate")
            if locked then
                nvgBeginPath(vg); nvgRoundedRect(vg, sx + 2, sy + 2, skillSize - 4, skillSize - 4, 4)
                nvgFillColor(vg, nvgRGBA(60, 60, 70, 100))
                nvgFill(vg)
                -- X mark
                local xm = 12
                nvgBeginPath(vg)
                nvgMoveTo(vg, sx + skillSize / 2 - xm, sy + skillSize / 2 - xm)
                nvgLineTo(vg, sx + skillSize / 2 + xm, sy + skillSize / 2 + xm)
                nvgMoveTo(vg, sx + skillSize / 2 + xm, sy + skillSize / 2 - xm)
                nvgLineTo(vg, sx + skillSize / 2 - xm, sy + skillSize / 2 + xm)
                nvgStrokeColor(vg, nvgRGBA(160, 160, 180, 150))
                nvgStrokeWidth(vg, 2)
                nvgStroke(vg)
            end
        end

        -- Slot label
        nvgFontSize(vg, 12)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(160, 160, 180, 200))
        nvgText(vg, sx + skillSize / 2, sy + skillSize + 4, slot.label, nil)
    end

    nvgRestore(vg)
end

-- ============================================================================
-- Getters
-- ============================================================================

function BreedingPage.GetGold()
    return gold_
end

function BreedingPage.GetSlotsUnlocked()
    return slotsUnlocked_
end

function BreedingPage.GetFarmLevel()
    return farmLevel_
end

--- Load profile data from save file for display on StartPage.
--- Can be called without BreedingPage being active.
--- @return table|nil { bestBall={name,level,color,expression,...}, bestStreak=number, gold=number, ballCount=number }
function BreedingPage.GetProfileData()
    -- If breeding page is active, use live data
    if active_ and #farmBalls_ > 0 then
        -- Find highest-level ball
        local best = farmBalls_[1]
        for i = 2, #farmBalls_ do
            if (farmBalls_[i].level or 1) > (best.level or 1) then
                best = farmBalls_[i]
            end
        end
        -- Also check slot balls
        for idx = 1, MAX_SLOTS do
            if slotBalls_[idx] then
                for _, ball in ipairs(slotBalls_[idx]) do
                    if (ball.level or 1) > (best.level or 1) then
                        best = ball
                    end
                end
            end
        end
        return {
            bestBall = SerializeBall(best),
            bestStreak = bestStreak_,
            gold = gold_,
            ballCount = #farmBalls_,
        }
    end

    -- Otherwise, read from save file
    if not fileSystem:FileExists(BREEDING_SAVE_FILE) then
        return nil
    end
    local file = File(BREEDING_SAVE_FILE, FILE_READ)
    if not file:IsOpen() then return nil end
    local str = file:ReadString()
    file:Close()
    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then return nil end

    -- Find highest-level ball from saved data
    local best = nil
    local allBalls = data.balls or {}
    for _, b in ipairs(allBalls) do
        if not best or (b.level or 1) > (best.level or 1) then
            best = b
        end
    end
    -- Also check slot balls in save
    if data.slotBalls then
        for _, slotData in pairs(data.slotBalls) do
            if type(slotData) == "table" then
                for _, b in ipairs(slotData) do
                    if not best or (b.level or 1) > (best.level or 1) then
                        best = b
                    end
                end
            end
        end
    end

    return {
        bestBall = best,
        bestStreak = data.bestStreak or 0,
        gold = data.gold or 0,
        ballCount = #allBalls,
    }
end

return BreedingPage
