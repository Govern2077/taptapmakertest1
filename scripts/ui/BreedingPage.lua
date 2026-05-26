-- ============================================================================
-- BreedingPage.lua - 球球养殖页面（含战斗系统）
-- 养殖场（可升级，内含弹跳球球）+ 战斗区域（拖拽球进入槽位开始战斗）
-- 球有等级系统：1-20级，HP递增(30~500)，2级+强化技能，3级+终结技能，血量阈值触发
-- 使用 NanoVG 渲染
-- ============================================================================

local BreedingPage = {}

local UI                = require("urhox-libs/UI")
local SkillRegistry     = require("game.SkillRegistry")
local SkillExecutor     = require("game.SkillExecutor")
local BallAI            = require("game.BallAI")
local BallCustomization = require("game.BallCustomization")
local Expressions       = require("game.Expressions")
local ArenaBattle       = require("ui.ArenaBattle")
local ArenaCloud        = require("game.ArenaCloud")
local CloudSave         = require("game.CloudSave")
local SaveSlotManager   = require("game.SaveSlotManager")
local DiamondManager    = require("game.DiamondManager")
local ShopManager       = require("game.ShopManager")

-- ============================================================================
-- State
-- ============================================================================

local active_ = false
local elapsedTime_ = 0

-- Economy
local gold_ = 0

-- Battle slots: 5 cols x 4 rows = 20 total, unlocked by farm level
local GRID_COLS = 5
local GRID_ROWS = 4
local MAX_SLOTS = GRID_COLS * GRID_ROWS
local INITIAL_UNLOCKED = 5
local slotsUnlocked_ = INITIAL_UNLOCKED

-- Farm: 16 upgrade levels (farm is always max size; upgrades unlock ball level cap + battle slots)
local MAX_FARM_LEVEL = 16
local farmLevel_ = 1
-- Farm upgrade costs calibrated so:
--   Lv1→2  ≈ 2 battles   (dead ball value × streak × 3, at Lv1: 10×1.5×3=45/battle → ~100 gold)
--   Lv15→16 ≈ 100 battles (at Lv15: 70000×1.5×3=315000/battle → ~30M gold)
-- Geometric progression ×2.3 per step between those anchors.
local FARM_COSTS = {
    100,        -- lv1→2   (~2 battles at lv1)
    300,        -- lv2→3   (~3 battles at lv2)
    1000,       -- lv3→4   (~4 battles at lv3)
    3000,       -- lv4→5   (~5 battles at lv4)
    12000,      -- lv5→6   (~7 battles at lv5)
    40000,      -- lv6→7   (~9 battles at lv6)
    130000,     -- lv7→8   (~12 battles at lv7)
    320000,     -- lv8→9   (~14 battles at lv8)
    700000,     -- lv9→10  (~19 battles at lv9)
    1400000,    -- lv10→11 (~25 battles at lv10)
    2700000,    -- lv11→12 (~34 battles at lv11)
    5000000,    -- lv12→13 (~45 battles at lv12)
    9500000,    -- lv13→14 (~60 battles at lv13)
    18000000,   -- lv14→15 (~80 battles at lv14)
    30000000,   -- lv15→16 (~100 battles at lv15)
}
local FARM_SCALE = { 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0 }

-- Farm balls (boids inside the farm)
local farmBalls_ = {}
local INITIAL_BALL_COUNT = 3

-- 球球唯一 ID 计数器（每次创建新球自增；存档恢复后同步到最大值）
local nextBallId_ = 1
local function GenBallId()
    local id = nextBallId_
    nextBallId_ = nextBallId_ + 1
    return id
end

-- Auto-spawn timer
local spawnTimer_ = 0
local SPAWN_INTERVAL = 5.0

-- Auto-save timer
local saveTimer_ = 0
local SAVE_INTERVAL = 30.0

-- Farm capacity per level (16 levels)
local FARM_CAPACITY = { 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 29, 30 }

-- Farm level restrictions: max ball level = farm level
-- New ball minimum level = max(1, farmLevel - 5)
-- Spawn interval decreases with level
local FARM_MAX_BALL_LEVEL = { 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 }
local FARM_NEW_BALL_LEVEL = { 1, 1, 1, 1, 1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }
local FARM_SPAWN_RATE     = { 5.0, 4.6, 4.2, 3.8, 3.4, 3.0, 2.7, 2.4, 2.1, 1.8, 1.6, 1.4, 1.2, 1.1, 1.0, 1.0 }

-- Battle slots unlocked per farm level: start with 5, each upgrade +1 (max 20)
local FARM_SLOTS_UNLOCKED = { 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }

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

-- Coin collect SFX (round-robin for "cascading coins" feel)
local COIN_SFX_FILES = {
    "audio/sfx/coin_collect_1.ogg",
    "audio/sfx/coin_collect_2.ogg",
    "audio/sfx/coin_collect_3.ogg",
    "audio/sfx/coin_collect_4.ogg",
    "audio/sfx/coin_collect_5.ogg",
}
local coinSfxSounds_ = {}   -- preloaded Sound resources
local coinSfxIndex_  = 1    -- round-robin index
local coinSfxScene_  = nil  -- scene reference for SoundSource

-- Wall bounce SFX
local wallBounceSnd_ = nil  -- preloaded Sound resource

-- Skill SFX mapping (skill id → sound file)
local SKILL_SFX_MAP = {
    water_ball    = "audio/sfx/skill_water_ball.ogg",
    fire_ball     = "audio/sfx/skill_fire_ball.ogg",
    leech         = "audio/sfx/skill_leech.ogg",
    split_bubble  = "audio/sfx/skill_split_bubble.ogg",
    water_pillar  = "audio/sfx/skill_water_pillar.ogg",
    inferno       = "audio/sfx/skill_inferno.ogg",
    blood_bat     = "audio/sfx/skill_blood_bat.ogg",
    water_dragon  = "audio/sfx/skill_water_dragon.ogg",
    meteorite     = "audio/sfx/skill_meteorite.ogg",
    -- 新技能（复用同类型音效）
    ice_spike     = "audio/sfx/skill_water_ball.ogg",
    poison_mist   = "audio/sfx/skill_split_bubble.ogg",
    arc_bolt      = "audio/sfx/skill_fire_ball.ogg",
    ice_pillar    = "audio/sfx/skill_water_pillar.ogg",
    thunder_bat   = "audio/sfx/skill_blood_bat.ogg",
    venom_flame   = "audio/sfx/skill_inferno.ogg",
    ice_dragon    = "audio/sfx/skill_water_dragon.ogg",
    thunder_meteor = "audio/sfx/skill_meteorite.ogg",
}
local skillSfxSounds_ = {}  -- preloaded: skillId → Sound

-- Battle event SFX
local BATTLE_SFX_FILES = {
    ball_collision  = "audio/sfx/ball_collision.ogg",
    projectile_hit  = "audio/sfx/projectile_hit.ogg",
    ball_death      = "audio/sfx/ball_death.ogg",
    battle_start    = "audio/sfx/battle_start.ogg",
    battle_victory  = "audio/sfx/battle_victory.ogg",
    battle_defeat   = "audio/sfx/battle_defeat.ogg",
}
local battleSfxSounds_ = {}  -- preloaded: eventName → Sound

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

--- Calculate gold particle animation timing based on total coin value.
--- Larger amounts produce longer, more dramatic animations.
--- @param totalValue number  total gold value of the coin being collected
--- @param particleCount number  number of mini-coin particles
--- @return number flightTime  how long each particle flies (seconds)
--- @return number staggerPer  delay between consecutive particle launches (seconds)
local function CalcCoinAnimTiming(totalValue, particleCount)
    -- Total animation duration scales logarithmically with value:
    --   10g → ~0.8s, 100g → ~1.3s, 1000g → ~2.0s, 10000g → ~2.7s, 100000g → ~3.3s
    local logVal = math.log(math.max(1, totalValue)) / math.log(10)
    local totalDuration = math.max(0.8, math.min(3.5, 0.3 + logVal * 0.6))
    -- Flight time: 40% of total, clamped 0.4-1.0s
    local flightTime = math.max(0.4, math.min(1.0, totalDuration * 0.4))
    -- Stagger window: remaining time spread across particles
    local staggerWindow = math.max(0.1, totalDuration - flightTime)
    local staggerPer = staggerWindow / math.max(1, particleCount - 1)
    return flightTime, staggerPer
end

-- ============================================================================
-- Ball Level & Experience System
-- ============================================================================

-- Level definitions: HP grows with diminishing returns, capping ~500
-- Skill trigger thresholds: normal always 100%, enhanced starts 60% and grows, ultimate starts 30% and grows
local LEVEL_DEFS = {
    -- HP curve: exponential, so damage (∝ HP) scales proportionally at every level.
    -- Lv1=30 baseline, Lv10≈1600 (53×), Lv16≈9200 (307×), Lv20≈26000 (867×)
    [1]  = { maxHp = 30,    expToNext = 50,   label = "Lv.1",  enhancedThreshold = 0.60, ultimateThreshold = 0.30 },
    [2]  = { maxHp = 65,    expToNext = 60,   label = "Lv.2",  enhancedThreshold = 0.60, ultimateThreshold = 0.30 },
    [3]  = { maxHp = 110,   expToNext = 80,   label = "Lv.3",  enhancedThreshold = 0.62, ultimateThreshold = 0.32 },
    [4]  = { maxHp = 175,   expToNext = 100,  label = "Lv.4",  enhancedThreshold = 0.64, ultimateThreshold = 0.34 },
    [5]  = { maxHp = 270,   expToNext = 120,  label = "Lv.5",  enhancedThreshold = 0.66, ultimateThreshold = 0.36 },
    [6]  = { maxHp = 400,   expToNext = 150,  label = "Lv.6",  enhancedThreshold = 0.68, ultimateThreshold = 0.38 },
    [7]  = { maxHp = 580,   expToNext = 180,  label = "Lv.7",  enhancedThreshold = 0.70, ultimateThreshold = 0.40 },
    [8]  = { maxHp = 820,   expToNext = 210,  label = "Lv.8",  enhancedThreshold = 0.72, ultimateThreshold = 0.42 },
    [9]  = { maxHp = 1150,  expToNext = 240,  label = "Lv.9",  enhancedThreshold = 0.74, ultimateThreshold = 0.44 },
    [10] = { maxHp = 1600,  expToNext = 280,  label = "Lv.10", enhancedThreshold = 0.76, ultimateThreshold = 0.46 },
    [11] = { maxHp = 2200,  expToNext = 320,  label = "Lv.11", enhancedThreshold = 0.78, ultimateThreshold = 0.48 },
    [12] = { maxHp = 3000,  expToNext = 360,  label = "Lv.12", enhancedThreshold = 0.80, ultimateThreshold = 0.50 },
    [13] = { maxHp = 4000,  expToNext = 400,  label = "Lv.13", enhancedThreshold = 0.82, ultimateThreshold = 0.52 },
    [14] = { maxHp = 5300,  expToNext = 450,  label = "Lv.14", enhancedThreshold = 0.84, ultimateThreshold = 0.54 },
    [15] = { maxHp = 7000,  expToNext = 500,  label = "Lv.15", enhancedThreshold = 0.86, ultimateThreshold = 0.56 },
    [16] = { maxHp = 9200,  expToNext = 550,  label = "Lv.16", enhancedThreshold = 0.88, ultimateThreshold = 0.58 },
    [17] = { maxHp = 12000, expToNext = 600,  label = "Lv.17", enhancedThreshold = 0.90, ultimateThreshold = 0.60 },
    [18] = { maxHp = 15500, expToNext = 660,  label = "Lv.18", enhancedThreshold = 0.92, ultimateThreshold = 0.62 },
    [19] = { maxHp = 20000, expToNext = 720,  label = "Lv.19", enhancedThreshold = 0.94, ultimateThreshold = 0.64 },
    [20] = { maxHp = 26000, expToNext = nil,  label = "Lv.20", enhancedThreshold = 0.95, ultimateThreshold = 0.65 },
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

-- Active breedings: one per slot (opposite-gender pairs)
-- activeBreedings_[slotIdx] = { ball1, ball2, phase, angle, orbitSpeed, timer, particles, babyBall, babyScale }
local activeBreedings_ = {}

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
-- Diamond reward per Arena win is now passed dynamically via onBattleEnd callback

-- Module-level gold animation state (shared across all slots, rendered in main Render)
local goldParticles_ = {}         -- gold particles flying toward gold button
local goldAnimating_ = false
local goldDisplayValue_ = 0       -- smoothly animated display value
local goldTargetValue_ = 0        -- target gold value
local goldShakeTimer_ = 0         -- gold button shake timer
local goldShakeIntensity_ = 0     -- gold button shake intensity
local goldBtnClickCount_ = 0     -- gold button click counter (5 clicks = +100M)
local goldBtnClickTimer_ = 0     -- reset counter if no click within 2 seconds

-- Persistent coins: coins that survive after battle slots are cleared
-- Each: { x, y (design coords), visible, collected, value, wobble, rotation, scale, radius, merged }
local persistentCoins_ = {}

-- Trash can facility (right side)
-- Sell value per color grade (1=白..16=红紫渐变)
local TRASH_SELL_VALUES = {
    10, 25, 60, 150, 400, 1000, 2500, 5000,
    8000, 12000, 18000, 25000, 35000, 50000, 70000, 100000,
}
local trashExplosions_ = {}  -- { x, y, particles = {}, timer }
local trashCoins_ = {}       -- { x, y, visible, collected, value, wobble, rotation, scale, radius, merged }
local hoverTrashCan_ = false
local trashLidShake_ = 0       -- wobble timer (>0 = wobbling)

-- Arena facility (left side) - framework placeholder
local hoverArena_ = false

-- Crown image handle (loaded once on first render)
local crownImgHandle_ = nil

-- Level-up celebration overlay state (nil = inactive)
-- Fields: ballColor{r,g,b}, level, timer, ballY, ballVY, swayPhase, bounceCount,
--         fireworks={}, hoverAdBtn, hoverDismissBtn, adBtnY, dismissBtnY
local levelUpCelebration_ = nil

-- Hand-drawn UI image handles (loaded once on first render)
local uiImgs_ = nil  -- table of NanoVG image handles
local function LoadUIImages(vg)
    if uiImgs_ then return end
    uiImgs_ = {
        bgPaper    = nvgCreateImage(vg, "image/UI/bg_paper.png", NVG_IMAGE_REPEATX + NVG_IMAGE_REPEATY),
        slotGrass  = nvgCreateImage(vg, "image/UI/slot_grass.png", 0),
        slotEmpty  = nvgCreateImage(vg, "image/UI/slot_empty.png", 0),
        panelPurple= nvgCreateImage(vg, "image/UI/panel_purple.png", 0),
        farmGrass  = nvgCreateImage(vg, "image/UI/farm_grass.png", NVG_IMAGE_REPEATX + NVG_IMAGE_REPEATY),
        btnCream   = nvgCreateImage(vg, "image/UI/btn_cream.png", 0),
        btnPurple  = nvgCreateImage(vg, "image/UI/btn_purple.png", 0),
        goldFrame  = nvgCreateImage(vg, "image/UI/gold_frame.png", 0),
        trashbin   = nvgCreateImage(vg, "image/UI/Mask group.png", 0),
        trashbinBg = nvgCreateImage(vg, "image/UI/Mask group-2.png", 0),
        coin       = nvgCreateImage(vg, "image/UI重置/39a37b5e-2a5b-43b3-b791-39246bdfeb1f.png", 0),
        aiOn       = nvgCreateImage(vg, "image/UI/ChatGPT Image 2026年5月12日 15_55_51.png", 0),
        aiOff      = nvgCreateImage(vg, "image/UI/ChatGPT Image 2026年5月12日 15_53_33.png", 0),
    }
    -- 同步预加载擂台赛背景图（避免首帧延迟加载导致图片不显示）
    ArenaBattle.Preload(vg)
end

-- Helper: draw coin image with pseudo-rotation (squash width by rotation angle)
local function DrawCoinImg(vg, cx, cy, radius, rotation, alpha)
    local img = uiImgs_ and uiImgs_.coin
    if not img or img <= 0 then return end
    -- 不做 squash 压缩，始终保持正方形显示，避免图像被压缩变形
    local w = radius * 2
    local h = radius * 2
    local x = cx - w / 2
    local y = cy - h / 2
    local a = math.max(0, math.min(1, (alpha or 255) / 255))
    local pat = nvgImagePattern(vg, x, y, w, h, 0, img, a)
    nvgBeginPath(vg)
    nvgRect(vg, x, y, w, h)
    nvgFillPaint(vg, pat)
    nvgFill(vg)
end

-- Helper: draw coin image without rotation (static icon)
local function DrawCoinIcon(vg, cx, cy, radius, alpha)
    DrawCoinImg(vg, cx, cy, radius, 0, alpha or 255)
end

-- ============================================================
-- Hand-drawn style rounded-rect (sketchy wobble border)
-- seed 保证同一按钮每帧抖动一致（静态手绘感），传 nil 则用 elapsedTime_ 产生动态微颤
-- ============================================================
local function HandDrawnRoundedRect(vg, x, y, w, h, r, seed)
    local segments = 6          -- 每条边的分段数
    local jitter   = 1.8        -- 抖动幅度 (px)
    -- 简易伪随机：按 15 FPS 跳变，seed 用于区分不同按钮
    local frame15 = math.floor((elapsedTime_ or 0) * 15)
    local s = frame15 + (seed or 0)
    local function wobble(i, axis)
        local v = math.sin(i * 127.1 + axis * 311.7 + s * 43.7) * 43758.5453
        return (v - math.floor(v) - 0.5) * 2.0 * jitter
    end
    local idx = 0
    local function jx(bx) idx = idx + 1; return bx + wobble(idx, 0) end
    local function jy(by) idx = idx + 1; return by + wobble(idx, 1) end

    -- 四个圆角中心
    local lx, rx = x + r, x + w - r
    local ty, by_ = y + r, y + h - r

    nvgBeginPath(vg)
    -- 起点：左上圆角底部
    nvgMoveTo(vg, jx(x), jy(ty))

    -- 左上圆角 (弧线用贝塞尔近似)
    local k = 0.5522847498   -- 圆弧贝塞尔近似系数
    nvgBezierTo(vg, jx(x), jy(y + r * (1 - k)), jx(x + r * (1 - k)), jy(y), jx(lx), jy(y))

    -- 上边 (左→右, 分段 + 抖动)
    for i = 1, segments do
        local t = i / segments
        nvgLineTo(vg, jx(lx + (rx - lx) * t), jy(y))
    end

    -- 右上圆角
    nvgBezierTo(vg, jx(x + w - r * (1 - k)), jy(y), jx(x + w), jy(y + r * (1 - k)), jx(x + w), jy(ty))

    -- 右边 (上→下)
    for i = 1, segments do
        local t = i / segments
        nvgLineTo(vg, jx(x + w), jy(ty + (by_ - ty) * t))
    end

    -- 右下圆角
    nvgBezierTo(vg, jx(x + w), jy(y + h - r * (1 - k)), jx(x + w - r * (1 - k)), jy(y + h), jx(rx), jy(y + h))

    -- 下边 (右→左)
    for i = 1, segments do
        local t = i / segments
        nvgLineTo(vg, jx(rx + (lx - rx) * t), jy(y + h))
    end

    -- 左下圆角
    nvgBezierTo(vg, jx(x + r * (1 - k)), jy(y + h), jx(x), jy(y + h - r * (1 - k)), jx(x), jy(by_))

    -- 左边 (下→上)
    for i = 1, segments do
        local t = i / segments
        nvgLineTo(vg, jx(x), jy(by_ + (ty - by_) * t))
    end

    nvgClosePath(vg)
end

-- Helper: draw a hand-drawn rounded rect with fill + stroke (drop-in replacement)
-- Usage: DrawHandDrawnBtn(vg, x, y, w, h, r, fillColor, strokeColor, strokeWidth, seed)
local function DrawHandDrawnBtn(vg, x, y, w, h, r, fillColor, strokeColor, strokeWidth, seed)
    -- fill
    HandDrawnRoundedRect(vg, x, y, w, h, r, seed)
    nvgFillColor(vg, fillColor)
    nvgFill(vg)
    -- stroke (re-draw path with slight offset for extra sketchiness)
    HandDrawnRoundedRect(vg, x, y, w, h, r, (seed or 0) + 0.5)
    nvgStrokeColor(vg, strokeColor)
    nvgStrokeWidth(vg, strokeWidth)
    nvgStroke(vg)
end

local function DrawUIImage(vg, imgHandle, x, y, w, h, alpha)
    if not imgHandle or imgHandle <= 0 then return end
    alpha = alpha or 1.0
    local pat = nvgImagePattern(vg, x, y, w, h, 0, imgHandle, alpha)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, 0)
    nvgFillPaint(vg, pat)
    nvgFill(vg)
end

-- Helper: draw image with "cover" mode (maintain aspect ratio, fill rect, clip overflow)
local function DrawUIImageCover(vg, imgHandle, x, y, w, h, alpha, radius)
    if not imgHandle or imgHandle <= 0 then return end
    alpha = alpha or 1.0
    radius = radius or 0
    local imgW, imgH = nvgImageSize(vg, imgHandle)
    if imgW <= 0 or imgH <= 0 then return end
    local imgAspect = imgW / imgH
    local rectAspect = w / h
    local drawW, drawH
    if imgAspect > rectAspect then
        -- Image is wider: match height, overflow width
        drawH = h
        drawW = h * imgAspect
    else
        -- Image is taller: match width, overflow height
        drawW = w
        drawH = w / imgAspect
    end
    local drawX = x + (w - drawW) / 2
    local drawY = y + (h - drawH) / 2
    nvgSave(vg)
    nvgBeginPath(vg)
    nvgRoundedRect(vg, x, y, w, h, radius)
    nvgScissor(vg, x, y, w, h)
    local pat = nvgImagePattern(vg, drawX, drawY, drawW, drawH, 0, imgHandle, alpha)
    nvgFillPaint(vg, pat)
    nvgFill(vg)
    nvgRestore(vg)
end

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
-- Level-based color system (16 grades, 1:1 mapping)
-- Lv1=白, Lv2=浅绿, Lv3=绿, Lv4=蓝, Lv5=紫, Lv6=橙, Lv7=红, Lv8=金,
-- Lv9=青, Lv10=黄绿渐变, Lv11=青蓝渐变, Lv12=红橙渐变, Lv13=黑白渐变,
-- Lv14=蓝紫渐变, Lv15=粉橙渐变, Lv16=红紫渐变
-- ============================================================================

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
    -- Grades 10-16: gradient colors (two-color animated, handled in render)
    [10] = { r = 180, g = 230, b = 50  },  -- 黄绿渐变 (placeholder)
    [11] = { r = 0,   g = 200, b = 255 },  -- 青蓝渐变 (placeholder)
    [12] = { r = 255, g = 100, b = 50  },  -- 红橙渐变 (placeholder)
    [13] = { r = 180, g = 180, b = 180 },  -- 黑白渐变 (placeholder)
    [14] = { r = 120, g = 80,  b = 255 },  -- 蓝紫渐变 (placeholder)
    [15] = { r = 255, g = 150, b = 130 },  -- 粉橙渐变 (placeholder)
    [16] = { r = 220, g = 50,  b = 180 },  -- 红紫渐变 (placeholder)
}

-- Gradient color pairs for grades 10-16 (animated two-color cycling)
local GRADIENT_COLOR_PAIRS = {
    [10] = { { r = 220, g = 255, b = 50 },  { r = 50,  g = 200, b = 50  } },  -- 黄绿
    [11] = { { r = 0,   g = 230, b = 200 }, { r = 40,  g = 100, b = 255 } },  -- 青蓝
    [12] = { { r = 255, g = 60,  b = 40 },  { r = 255, g = 180, b = 40  } },  -- 红橙
    [13] = { { r = 30,  g = 30,  b = 40 },  { r = 240, g = 240, b = 250 } },  -- 黑白
    [14] = { { r = 60,  g = 120, b = 255 }, { r = 200, g = 60,  b = 255 } },  -- 蓝紫
    [15] = { { r = 255, g = 140, b = 180 }, { r = 255, g = 180, b = 60  } },  -- 粉橙
    [16] = { { r = 255, g = 30,  b = 80 },  { r = 180, g = 40,  b = 255 } },  -- 红紫
}

--- Get the color grade (1-16) for a given ball level (1:1 mapping, capped at 16)
local function GetColorGrade(level)
    return math.min(math.max(level, 1), 16)
end

--- Generate 3 vivid random colors for a rainbow ball, each biased toward a random hue
local function GenerateRainbowPalette()
    -- Pick 3 well-separated hue anchors with random saturation/value offsets
    local hueStart = math.random() * 360
    local palette = {}
    for i = 1, 3 do
        local hue = (hueStart + (i - 1) * (100 + math.random() * 40)) % 360
        local sat = 0.75 + math.random() * 0.25  -- 0.75-1.0
        local val = 0.85 + math.random() * 0.15  -- 0.85-1.0
        -- HSV to RGB
        local h = hue / 60
        local c = val * sat
        local x = c * (1 - math.abs(h % 2 - 1))
        local m = val - c
        local r, g, b = 0, 0, 0
        if h < 1 then r, g, b = c, x, 0
        elseif h < 2 then r, g, b = x, c, 0
        elseif h < 3 then r, g, b = 0, c, x
        elseif h < 4 then r, g, b = 0, x, c
        elseif h < 5 then r, g, b = x, 0, c
        else r, g, b = c, 0, x end
        palette[i] = {
            r = math.floor((r + m) * 255),
            g = math.floor((g + m) * 255),
            b = math.floor((b + m) * 255),
        }
    end
    return palette
end

--- Compute the current cycling color for a rainbow ball
--- @param rainbowData table  { palette = {3 colors}, period = number, phaseOffset = number }
--- @param elapsed number  current elapsed time
--- @return table  { r, g, b }
local function ComputeRainbowColor(rainbowData, elapsed)
    local palette = rainbowData.palette
    local period = rainbowData.period
    local offset = rainbowData.phaseOffset or 0
    -- t cycles 0..3 over one full period
    local t = ((elapsed + offset) % period) / period * 3.0
    -- Determine which two colors to interpolate
    local idx = math.floor(t) -- 0, 1, 2
    local frac = t - idx
    -- Smooth interpolation (ease in-out)
    frac = frac * frac * (3 - 2 * frac)
    local c1 = palette[(idx % 3) + 1]
    local c2 = palette[((idx + 1) % 3) + 1]
    local cr = math.floor(c1.r + (c2.r - c1.r) * frac)
    local cg = math.floor(c1.g + (c2.g - c1.g) * frac)
    local cb = math.floor(c1.b + (c2.b - c1.b) * frac)
    return cr, cg, cb
end

--- Get color for a ball based on its level, with small random offset
--- Grades 10-16 use gradient animation (two-color cycling)
--- If a skin is equipped, overrides the base color (gradient grades still use gradient effect)
local function GetLevelColor(level, randomSeed)
    local grade = GetColorGrade(level)

    -- Skin color override: only apply to non-gradient grades (1-9)
    if grade <= 9 then
        local skinColor = ShopManager.GetSkinColorForGrade(grade)
        if skinColor then
            local seed = randomSeed or math.random(0, 1000)
            math.randomseed(math.floor(seed))
            local offR = math.random(-15, 15)
            local offG = math.random(-15, 15)
            local offB = math.random(-15, 15)
            math.randomseed(math.floor(os.clock() * 100000) + math.random(1, 99999))
            return {
                r = math.max(0, math.min(255, skinColor.r + offR)),
                g = math.max(0, math.min(255, skinColor.g + offG)),
                b = math.max(0, math.min(255, skinColor.b + offB)),
                gradient = false,
            }
        end
    end

    -- Grades 10-16: gradient color animation (two-color cycling)
    if grade >= 10 then
        local pair = GRADIENT_COLOR_PAIRS[grade]
        if pair then
            local period = 2.0 + (randomSeed or math.random(0, 1000)) % 20 * 0.1  -- 2.0~4.0s
            local phaseOffset = (randomSeed or math.random(0, 1000)) % 100 * 0.1   -- 0~10.0
            return {
                r = pair[1].r, g = pair[1].g, b = pair[1].b,
                gradient = true,
                gradientData = {
                    color1 = pair[1],
                    color2 = pair[2],
                    period = period,
                    phaseOffset = phaseOffset,
                },
            }
        end
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
        gradient = false,
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

local FARM_BALL_RADIUS = 20  -- base radius for level 1 (Lv1=20, Lv16=50)
local FARM_BALL_COLOR = { r = 230, g = 230, b = 240 }

--- Compute farm ball radius from level (level 1→20, level 16→50)
local function GetFarmBallRadius(level)
    return FARM_BALL_RADIUS + (level - 1) * 2.0
end

--- Compute damage multiplier from level (level 1→1.0x, level 16→4.0x)
local function GetLevelDamageMult(level)
    -- Damage scales proportionally with HP: same level fights last equal # of hits
    local def = LEVEL_DEFS[math.max(1, math.min(20, level or 1))]
    return (def and def.maxHp or 30) / 30.0
end

--- Compute cooldown multiplier from level (level 1→1.0x, level 16→0.4x)
local function GetLevelCdMult(level)
    return math.max(0.4, 1.0 - (level - 1) * 0.04)
end

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
        -- 新增：年龄、性别（1=♂ 2=♀）、已生育次数、谱系 ID
        age        = ball.age        or 0,
        gender     = ball.gender     or math.random(2),
        breedCount = ball.breedCount or 0,
        id         = ball.id         or nil,
        parentIds  = ball.parentIds  or nil,
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

local function SaveBreedingData(forceCloud)
    local TutorialSystem = require("ui.TutorialSystem")
    local data = {
        gold = gold_,
        farmLevel = farmLevel_,
        slotsUnlocked = slotsUnlocked_,
        aiLevel = aiLevel_,
        aiEnabled = aiEnabled_,
        bestStreak = bestStreak_,
        tutorial = TutorialSystem.GetSaveData(),
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
    CloudSave.Save(data, nil, forceCloud)
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
    local angle = math.random() * 2 * math.pi
    local speed = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
    -- New ball level based on farm level
    local newLevel = FARM_NEW_BALL_LEVEL[farmLevel_] or 1
    local lvlDef = LEVEL_DEFS[newLevel] or LEVEL_DEFS[1]
    -- Color based on level
    local color = GetLevelColor(newLevel)
    -- Radius scales with level
    local r = GetFarmBallRadius(newLevel)
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
        age        = 0,
        gender     = math.random(2),  -- 1=♂  2=♀
        breedCount = 0,
        id         = GenBallId(),
        parentIds  = nil,             -- {父id, 母id}，繁殖出生时赋值
    }
end

-- Restore a saved ball into the farm (with physics init)
local function RestoreFarmBall(farmW, farmH, savedBall)
    local lvl = savedBall.level or 1
    local r = GetFarmBallRadius(lvl)  -- always recalculate from level
    local angle = math.random() * 2 * math.pi
    local speed = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
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
        age        = savedBall.age        or 0,
        gender     = savedBall.gender     or math.random(2),
        breedCount = savedBall.breedCount or 0,
        id         = savedBall.id or GenBallId(),
        parentIds  = savedBall.parentIds or nil,
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
    -- 可见行数：已解锁格子所在行整行显示（含该行未解锁格子），最少1行
    -- 例如解锁6个 → 第2行不满 → 显示完整2行（10格，后4格显示锁定状态）
    local visibleRows = math.min(GRID_ROWS, math.ceil(slotsUnlocked_ / GRID_COLS))
    visibleRows = math.max(1, visibleRows)
    -- 确保每一可见行都完整渲染（后续渲染会区分解锁/锁定状态）
    local gridH = visibleRows * slotSize + (visibleRows - 1) * slotGap
    local labelW = 80
    local gridX = (designW - gridW) / 2 + labelW / 2
    -- 满4行时的固定尺寸，供养殖场/擂台赛/垃圾桶锚定位置使用
    local maxGridH = GRID_ROWS * slotSize + (GRID_ROWS - 1) * slotGap
    local gridAreaTop = 80
    local gridAreaH = designH * 0.55  -- 保留给槽位的区域高度
    local gridY = gridAreaTop + (gridAreaH - gridH) / 2
    gridY = math.max(gridAreaTop, gridY)
    -- 只有一排时战斗区域额外下移 100px；两排时居中并下移 100px
    if visibleRows == 1 then
        gridY = gridY + 100
    elseif visibleRows == 2 then
        gridY = gridY + 100
    end
    local maxGridY = gridAreaTop + (gridAreaH - maxGridH) / 2
    maxGridY = math.max(gridAreaTop, maxGridY)
    return {
        slotSize = slotSize, slotGap = slotGap,
        gridW = gridW, gridH = gridH,
        labelW = labelW, gridX = gridX, gridY = gridY,
        visibleRows = visibleRows,
        maxGridH = maxGridH, maxGridY = maxGridY,
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
    -- 始终使用满4行时的底部位置，保证养殖场位置不随行数变化
    local farmAreaTop = layout.maxGridY + layout.maxGridH + 20
    local farmX = (designW - farmW) / 2 + layout.labelW / 2
    local farmY = farmAreaTop + 10
    return farmX, farmY, farmW, farmH
end

-- ============================================================================
-- Breeding Logic: 一公一母 → 繁殖动画 → 新球球
-- ============================================================================

--- 判断两只球球性别是否相反（一公一母）
local function IsOppGender(b1, b2)
    return (b1.gender or 1) ~= (b2.gender or 1)
end

--- 根据父母生成后代球球（放在农场坐标系内）
local function BreedBall(farmW, farmH, p1, p2)
    local newLevel = math.ceil((p1.level + p2.level) / 2)
    newLevel = math.max(1, math.min(MAX_LEVEL, newLevel))
    local lvlDef = LEVEL_DEFS[newLevel] or LEVEL_DEFS[1]
    local r = GetFarmBallRadius(newLevel)
    local ang = math.random() * 2 * math.pi
    local spd = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5

    -- 继承父母技能（各自随机取一个）
    local normalPool, enhPool, ultPool = {}, {}, {}
    if p1.skill          then table.insert(normalPool, p1.skill) end
    if p2.skill          then table.insert(normalPool, p2.skill) end
    if p1.enhancedSkill  then table.insert(enhPool, p1.enhancedSkill) end
    if p2.enhancedSkill  then table.insert(enhPool, p2.enhancedSkill) end
    if p1.ultimateSkill  then table.insert(ultPool, p1.ultimateSkill) end
    if p2.ultimateSkill  then table.insert(ultPool, p2.ultimateSkill) end

    local normalSkill = #normalPool > 0 and normalPool[math.random(#normalPool)] or GetConfiguredNormalSkill()
    local enhSkill    = newLevel >= 2 and (#enhPool > 0 and enhPool[math.random(#enhPool)] or GetConfiguredEnhancedSkill()) or nil
    local ultSkill    = newLevel >= 3 and (#ultPool > 0 and ultPool[math.random(#ultPool)] or GetConfiguredUltimateSkill()) or nil

    return {
        x = farmW / 2 + (math.random() - 0.5) * 40,
        y = farmH / 2 + (math.random() - 0.5) * 40,
        vx = math.cos(ang) * spd,
        vy = math.sin(ang) * spd,
        radius = r,
        color  = GetLevelColor(newLevel),
        name        = GenerateRandomName(),
        expression  = RandomExpression(),
        level       = newLevel,
        exp         = 0,
        hp          = lvlDef.maxHp,
        maxHp       = lvlDef.maxHp,
        skill         = normalSkill,
        enhancedSkill = enhSkill,
        ultimateSkill = ultSkill,
        age        = 0,
        gender     = math.random(2),
        breedCount = 0,
        id         = GenBallId(),
        parentIds  = { p1.id, p2.id },  -- 记录父母 ID 形成谱系
    }
end

--- 启动繁殖动画
local function StartBreeding(slotIdx)
    local balls = slotBalls_[slotIdx]
    if not balls or #balls < 2 then return end
    if activeBreedings_[slotIdx] or activeBattles_[slotIdx] then return end
    slotBalls_[slotIdx] = {}   -- 从等候区移出
    activeBreedings_[slotIdx] = {
        ball1 = balls[1],
        ball2 = balls[2],
        phase = "circling",   -- "circling" → "burst" → "born"
        angle = 0,
        orbitSpeed  = 1.0,    -- rad/s，会加速
        orbitRadius = 40,     -- px，会缩小
        timer = 0,
        CIRCLE_DURATION = 2.5,
        BURST_DURATION  = 0.5,
        BORN_DURATION   = 0.8,
        particles = {},
        babyBall  = nil,
        babyScale = 0,
    }
    print(string.format("[Breeding] Breeding started in slot %d!", slotIdx))
end

--- 每帧更新繁殖动画
local function UpdateBreeding(slotIdx, dt)
    local br = activeBreedings_[slotIdx]
    if not br then return end
    br.timer = br.timer + dt

    if br.phase == "circling" then
        local t = math.min(1, br.timer / br.CIRCLE_DURATION)
        -- 绕圈速度 1→12 rad/s（二次加速）
        br.orbitSpeed  = 1.0 + 11.0 * (t * t)
        br.angle       = br.angle + br.orbitSpeed * dt
        -- 轨道半径从 40 缩到 12
        br.orbitRadius = 40 - 28 * t

        if br.timer >= br.CIRCLE_DURATION then
            br.phase = "burst"
            br.timer = 0
            -- 生成爆发粒子（颜色取自父母）
            local c1, c2 = br.ball1.color, br.ball2.color
            for pi = 1, 45 do
                local pa = math.random() * math.pi * 2
                local pv = 80 + math.random() * 220
                local useParent1 = (pi % 2 == 0)
                local pc = useParent1 and c1 or c2
                local maxLife = 0.3 + math.random() * 0.45
                table.insert(br.particles, {
                    x = 0, y = 0,
                    vx = math.cos(pa) * pv,
                    vy = math.sin(pa) * pv,
                    life    = maxLife,
                    maxLife = maxLife,
                    r  = math.random(3, 9),
                    cr = pc.r, cg = pc.g, cb = pc.b,
                })
            end
        end

    elseif br.phase == "burst" then
        for i = #br.particles, 1, -1 do
            local p = br.particles[i]
            p.x  = p.x + p.vx * dt
            p.y  = p.y + p.vy * dt
            p.vx = p.vx * 0.90
            p.vy = p.vy * 0.90
            p.life = p.life - dt
            if p.life <= 0 then table.remove(br.particles, i) end
        end
        if br.timer >= br.BURST_DURATION then
            br.phase = "born"
            br.timer = 0
            local farmW, farmH = GetFarmDimensions(1920, 1080)
            br.babyBall  = BreedBall(farmW, farmH, br.ball1, br.ball2)
            br.babyScale = 0
        end

    elseif br.phase == "born" then
        br.babyScale = math.min(1, br.timer / br.BORN_DURATION)
        -- 粒子继续运动
        for i = #br.particles, 1, -1 do
            local p = br.particles[i]
            p.x  = p.x + p.vx * dt
            p.y  = p.y + p.vy * dt
            p.life = p.life - dt
            if p.life <= 0 then table.remove(br.particles, i) end
        end
        if br.timer >= br.BORN_DURATION then
            -- 把宝宝和父母都放回农场
            local farmW, farmH = GetFarmDimensions(1920, 1080)
            local baby = br.babyBall
            baby.x = math.max(baby.radius, math.min(farmW - baby.radius, farmW / 2 + (math.random() - 0.5) * 60))
            baby.y = math.max(baby.radius, math.min(farmH - baby.radius, farmH / 2 + (math.random() - 0.5) * 60))
            table.insert(farmBalls_, baby)

            br.ball1.breedCount = (br.ball1.breedCount or 0) + 1
            br.ball2.breedCount = (br.ball2.breedCount or 0) + 1
            -- 给父母随机速度再放回
            local a1 = math.random() * math.pi * 2
            local a2 = math.random() * math.pi * 2
            local spd = BOIDS.minSpeed + math.random() * (BOIDS.maxSpeed - BOIDS.minSpeed) * 0.5
            br.ball1.vx = math.cos(a1) * spd;  br.ball1.vy = math.sin(a1) * spd
            br.ball2.vx = math.cos(a2) * spd;  br.ball2.vy = math.sin(a2) * spd
            table.insert(farmBalls_, br.ball1)
            table.insert(farmBalls_, br.ball2)

            activeBreedings_[slotIdx] = nil
            print(string.format("[Breeding] Baby born in slot %d! Level=%d  Parents breedCount=%d/%d",
                slotIdx, baby.level, br.ball1.breedCount, br.ball2.breedCount))
            SaveBreedingData(false)
        end
    end
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

        -- Higher level balls are progressively larger in battle
        local sizeGrowth = (farmBall.level - 1) * 2  -- level 1→0, level 16→+30
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
        -- 同步连胜数到 farmBall 自身（用于渲染星标）
        if winnerFarmBall then winnerFarmBall.winStreak = streakCount end
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
    local sizeGrowth = (farmBall.level - 1) * 2  -- level 1→0, level 16→+30
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
        local coinR = math.max(16, math.min(34, 14 + math.log(perCoin + 1) / math.log(10) * 7))
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

    -- Cooldown reduction based on level (higher level → faster attacks)
    local cdMult = GetLevelCdMult(shooter.level or 1)

    -- Try ultimate skill first (low HP triggers finisher)
    if shooter.ultimateSkill and shooter.ultimateCd <= 0 and hpPct <= ultThreshold then
        local ultDef = SkillRegistry.Get(shooter.ultimateSkill)
        if ultDef then
            local cd = SkillExecutor.Fire(ultDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.ultimateCd = (cd or 5.0) * 0.5 * cdMult
            return
        end
    end

    -- Try enhanced skill (medium HP threshold)
    if shooter.enhancedSkill and shooter.enhancedCd <= 0 and hpPct <= enhThreshold then
        local enhDef = SkillRegistry.Get(shooter.enhancedSkill)
        if enhDef then
            local cd = SkillExecutor.Fire(enhDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.enhancedCd = (cd or 3.0) * 0.5 * cdMult
            return
        end
    end

    -- Fallback: basic skill (always available at any HP)
    if skillDef then
        local cd = SkillExecutor.Fire(skillDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
        shooter.skillCd = (cd or 1.5) * 0.4 * cdMult
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
                        radius = coin.radius or 26,
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
                -- Find the loser (dead ball) to base reward on their value
                local loserLevel = 1
                for bi, bb in ipairs(battle.balls) do
                    if bi ~= battle.winnerIdx then
                        loserLevel = bb.level or 1
                        break
                    end
                end
                local loserGrade = math.max(1, math.min(16, loserLevel))
                local deadBallValue = TRASH_SELL_VALUES[loserGrade] or 10
                -- Cap streak multiplier at 2, reward = dead ball value × streak × 3
                local cappedStreak = math.min(currentStreak, 2)
                local totalReward = deadBallValue * cappedStreak * 3
                local COIN_COUNT = math.min(4 + currentStreak, 10)
                local coinValue = totalReward / COIN_COUNT
                -- 胜者头顶生成金币：以胜者头部上方为中心，向四周散开
                local spawnCX = winner and winner.x or (BATTLE_ARENA_SIZE / 2)
                local spawnCY = winner and (winner.y - winner.radius - 20) or (BATTLE_ARENA_SIZE / 2)
                -- 夹住边界，避免超出 arena
                spawnCX = math.max(30, math.min(BATTLE_ARENA_SIZE - 30, spawnCX))
                spawnCY = math.max(30, math.min(BATTLE_ARENA_SIZE - 30, spawnCY))
                for ci = 1, COIN_COUNT do
                    -- 以头顶为中心，在半径 60 范围内扇形散开
                    local angle = (ci - 1) / COIN_COUNT * math.pi * 2 + math.random() * 0.4
                    local dist = 20 + math.random() * 60
                    local cx = spawnCX + math.cos(angle) * dist
                    local cy = spawnCY + math.sin(angle) * dist
                    cx = math.max(20, math.min(BATTLE_ARENA_SIZE - 20, cx))
                    cy = math.max(20, math.min(BATTLE_ARENA_SIZE - 20, cy))
                    table.insert(coins, {
                        x = cx, y = cy,           -- arena-local position
                        visible = true,
                        collected = false,
                        value = coinValue,
                        wobble = math.random() * math.pi * 2,
                        rotation = math.random() * math.pi * 2,
                        scale = 0,                -- animate in
                        spawnDelay = (ci - 1) * 0.08,  -- stagger appearance
                        radius = 26,              -- small coin radius
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
                -- 更新 farmBall 连胜星标：胜者记录当前连胜数，败者清零
                if winner and winner.farmBall then
                    winner.farmBall.winStreak = currentStreak
                end
                for bi, bb in ipairs(battle.balls) do
                    if bi ~= battle.winnerIdx and bb.farmBall then
                        bb.farmBall.winStreak = 0
                    end
                end
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
                        a.radius = math.min(38, 18 + totalValue * 1.2)  -- grow radius with value
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
                            if fb.level >= 2 and not fb.enhancedSkill then
                                fb.enhancedSkill = GetConfiguredEnhancedSkill()
                            end
                            if fb.level >= 3 and not fb.ultimateSkill then
                                fb.ultimateSkill = GetConfiguredUltimateSkill()
                            end
                            print(string.format("[Breeding] Ball leveled up to %d!", fb.level))
                        end
                        if didLevelUp then
                            fb.radius = GetFarmBallRadius(fb.level)
                            fb.color = GetLevelColor(fb.level)
                        end
                        -- Update maxHp from new level
                        local winLvlDef = LEVEL_DEFS[fb.level] or LEVEL_DEFS[1]
                        fb.maxHp = winLvlDef.maxHp
                        -- Level up → full HP; otherwise preserve battle HP ratio
                        if didLevelUp then
                            fb.hp = fb.maxHp
                            print(string.format("[Breeding] Level up! HP fully restored to %d", fb.maxHp))
                            -- Trigger level-up celebration overlay
                            local c = fb.color or { r = 100, g = 200, b = 255 }
                            levelUpCelebration_ = {
                                ballColor  = { r = c.r or 100, g = c.g or 200, b = c.b or 255 },
                                level      = fb.level,
                                timer      = 0,
                                -- Ball enters from well below screen, bounces up to center
                                ballX      = 960,
                                ballY      = 1400,   -- start below screen
                                ballVY     = -2400,  -- strong upward velocity (px/s in design coords)
                                ballRadius = 200,    -- fixed large display radius
                                swayPhase  = 0,
                                bounceCount = 0,
                                targetY    = 520,    -- resting center Y (design coords)
                                settled    = false,
                                fireworks  = {},
                                fwTimer    = 0,
                                hoverAdBtn      = false,
                                hoverDismissBtn = false,
                                buttonsVisible  = false,  -- appear after ball settles
                                wavePhase  = 0,           -- 文字波浪动画相位
                            }
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
                        -- 教程回调：胜利球球已返回养殖场（此时可见经验条，传入球球引用供高亮用）
                        if callbacks_ and callbacks_.onBallReturnedToFarm then
                            callbacks_.onBallReturnedToFarm(slotIdx, fb)
                        end
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
                    print(string.format("[Breeding] Streak of %d ended in slot %d!",
                        v.streakCount, slotIdx))
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
        -- 教程回调：战斗结束
        if callbacks_ and callbacks_.onBattleFinished then
            callbacks_.onBattleFinished(slotIdx)
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
                            -- Collision damage scales with attacker level (same as skills)
                            a.hp = a.hp - BATTLE_COLLISION_DMG * GetLevelDamageMult(b.level or 1)
                            b.hp = b.hp - BATTLE_COLLISION_DMG * GetLevelDamageMult(a.level or 1)
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
            -- Scale damage by shooter level
            local shooter = proj and balls[proj.ownerTeam]
            local lvlMult = GetLevelDamageMult(shooter and shooter.level or 1)
            damage = math.floor(damage * lvlMult)
            tgt.hp = tgt.hp - damage
            -- Apply knockback (scaled by level)
            if kx ~= 0 or ky ~= 0 then
                local kbScale = math.sqrt(lvlMult)  -- softer scaling for knockback
                tgt.vx = tgt.vx + kx * kbScale
                tgt.vy = tgt.vy + ky * kbScale
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
            -- Scale DOT damage and heal by source level
            local src = balls[sourceTeam]
            local lvlMult = GetLevelDamageMult(src and src.level or 1)
            dmgTick = math.floor(dmgTick * lvlMult)
            healTick = math.floor(healTick * lvlMult)
            tgt.hp = tgt.hp - dmgTick
            -- Heal source
            if healTick > 0 then
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

-- Play next coin collect sound (round-robin for cascading effect)
local function PlayCoinCollectSfx(coinValue)
    if #coinSfxSounds_ == 0 then
        print("[Breeding] SFX skip: no sounds loaded")
        return
    end
    if not coinSfxScene_ then
        print("[Breeding] SFX skip: no scene ref")
        return
    end
    local snd = coinSfxSounds_[coinSfxIndex_]
    coinSfxIndex_ = (coinSfxIndex_ % #coinSfxSounds_) + 1
    -- Volume scales with coin value: small coins ~0.3, large coins up to 1.0
    local val = coinValue or 1
    local gain = math.max(0.3, math.min(1.0, 0.3 + val / 15))
    local node = coinSfxScene_:CreateChild("CoinSFX")
    local src = node:CreateComponent("SoundSource")
    src.soundType = SOUND_EFFECT
    src.gain = gain
    src.autoRemoveMode = REMOVE_NODE
    src:Play(snd)
    print(string.format("[Breeding] Coin SFX #%d played, gain=%.2f, coinValue=%s", coinSfxIndex_, gain, tostring(val)))
end

-- Play wall bounce sound (with speed-based volume)
local function PlayWallBounceSfx(speed)
    if not wallBounceSnd_ or not coinSfxScene_ then return end
    local gain = math.max(0.15, math.min(0.6, (speed or 100) / 400))
    local node = coinSfxScene_:CreateChild("WallSFX")
    local src = node:CreateComponent("SoundSource")
    src.soundType = SOUND_EFFECT
    src.gain = gain
    src.autoRemoveMode = REMOVE_NODE
    src:Play(wallBounceSnd_)
end

-- Play skill sound effect
local function PlaySkillSfx(skillId, tier)
    if not coinSfxScene_ then return end
    local snd = skillSfxSounds_[skillId]
    if not snd then return end
    local gain = 0.5
    if tier == "enhanced" then gain = 0.7
    elseif tier == "ultimate" then gain = 0.9 end
    local node = coinSfxScene_:CreateChild("SkillSFX")
    local src = node:CreateComponent("SoundSource")
    src.soundType = SOUND_EFFECT
    src.gain = gain
    src.autoRemoveMode = REMOVE_NODE
    src:Play(snd)
end

-- Play battle event sound effect
local function PlayBattleSfx(eventName, gain)
    if not coinSfxScene_ then return end
    local snd = battleSfxSounds_[eventName]
    if not snd then return end
    local node = coinSfxScene_:CreateChild("BattleSFX")
    local src = node:CreateComponent("SoundSource")
    src.soundType = SOUND_EFFECT
    src.gain = gain or 0.5
    src.autoRemoveMode = REMOVE_NODE
    src:Play(snd)
end

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
    -- Setup coin SFX
    coinSfxScene_ = cbs and cbs.scene or nil
    coinSfxIndex_ = 1
    if #coinSfxSounds_ == 0 and coinSfxScene_ then
        for _, path in ipairs(COIN_SFX_FILES) do
            local snd = cache:GetResource("Sound", path)
            if snd then
                table.insert(coinSfxSounds_, snd)
            end
        end
        print(string.format("[Breeding] Preloaded %d coin SFX", #coinSfxSounds_))
    end
    -- Preload wall bounce SFX
    if not wallBounceSnd_ and coinSfxScene_ then
        wallBounceSnd_ = cache:GetResource("Sound", "audio/sfx/wall_bounce.ogg")
    end
    -- Preload skill SFX
    if next(skillSfxSounds_) == nil and coinSfxScene_ then
        for skillId, path in pairs(SKILL_SFX_MAP) do
            local snd = cache:GetResource("Sound", path)
            if snd then skillSfxSounds_[skillId] = snd end
        end
        print(string.format("[Breeding] Preloaded %d skill SFX", #skillSfxSounds_))
    end
    -- Preload battle event SFX
    if next(battleSfxSounds_) == nil and coinSfxScene_ then
        for eventName, path in pairs(BATTLE_SFX_FILES) do
            local snd = cache:GetResource("Sound", path)
            if snd then battleSfxSounds_[eventName] = snd end
        end
        print(string.format("[Breeding] Preloaded %d battle SFX", #battleSfxSounds_))
    end
    hoverSlotBtn_ = false
    hoverFarmBtn_ = false
    hoverBackBtn_ = false
    hoverAiBtn_ = false
    hoverAiUpgrade_ = false
    hoverTrashCan_ = false
    hoverArena_ = false
    trashLidShake_ = 0
    aiTimer_ = 0
    persistentCoins_ = {}
    trashExplosions_ = {}
    trashCoins_ = {}
    dragBall_ = nil
    dragFromSlot_ = nil

    -- Reset core game state to defaults (fresh save values)
    gold_ = 0
    farmLevel_ = 1
    slotsUnlocked_ = INITIAL_UNLOCKED
    bestStreak_ = 0
    aiLevel_ = 0
    aiEnabled_ = false
    farmBalls_ = {}

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
    activeBreedings_ = {}
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
        -- Slots are determined by farm level (ignore saved slotsUnlocked for new system)
        slotsUnlocked_ = FARM_SLOTS_UNLOCKED[farmLevel_] or INITIAL_UNLOCKED
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
                    spawnDelay = 0, radius = sc.radius or 18, merged = sc.merged or false,
                })
            end
        end

        farmBalls_ = {}
        for _, sb in ipairs(saved.balls) do
            local fb = RestoreFarmBall(farmW, farmH, sb)
            -- 同步 ID 计数器，保证新球 ID 不重复
            if fb.id and fb.id >= nextBallId_ then nextBallId_ = fb.id + 1 end
            table.insert(farmBalls_, fb)
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
                        local restoredId = sb.id or GenBallId()
                        if restoredId >= nextBallId_ then nextBallId_ = restoredId + 1 end
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
                            ultimateSkill = sb.ultimateSkill,
                            radius = GetFarmBallRadius(lvl),
                            age        = sb.age        or 0,
                            gender     = sb.gender     or math.random(2),
                            breedCount = sb.breedCount or 0,
                            id         = restoredId,
                            parentIds  = sb.parentIds  or nil,
                        })
                    end
                end
            end
        end

        -- Restore arena data
        if saved.arena then
            ArenaBattle.LoadSaveData(saved.arena)
        end

        -- 恢复教程状态
        -- 云端二次恢复时，若教程已由本地存档激活，跳过，避免重复初始化覆盖进行中的教程
        if saved.tutorial then
            local TutorialSystem = require("ui.TutorialSystem")
            if source == "local" or not TutorialSystem.IsActive() then
                TutorialSystem.Restore(saved.tutorial)
            end
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
        onBattleEnd = function(isWin, goldEarned, diamondEarned)
            if isWin and goldEarned > 0 then
                gold_ = gold_ + goldEarned
                goldTargetValue_ = gold_
                goldShakeTimer_ = 0.3
                goldShakeIntensity_ = 4
                goldAnimating_ = true
            end
            -- Award tiered diamonds on Arena win (10/20/30...100 based on wave)
            if isWin and diamondEarned and diamondEarned > 0 then
                DiamondManager.Add(diamondEarned)
                print(string.format("[Breeding] Arena diamond reward: +%d", diamondEarned))
            end
            -- Return the player's ball to the farm (win) or remove it (lose/death)
            local returnedBall = ArenaBattle.GetPlayerFarmBall()
            if returnedBall then
                if isWin then
                    -- Ball survives: restore it back to farmBalls_
                    local farmW, farmH = GetFarmDimensions(1920, 1080)
                    local restored = RestoreFarmBall(farmW, farmH, returnedBall)
                    table.insert(farmBalls_, restored)
                    print("[Breeding] Ball returned to farm after arena win!")
                else
                    -- Ball dies: do not add back
                    print("[Breeding] Ball died in arena battle (loss).")
                end
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
        onDiamondIncrement = function(amount)
            -- Called when a diamond particle arrives at diamond button (per-particle)
            DiamondManager.Add(math.floor(amount + 0.5))
        end,
        onCoinCollect = function(coinValue)
            PlayCoinCollectSfx(coinValue)
        end,
        onWallBounce = function(speed)
            PlayWallBounceSfx(speed)
        end,
        onSkillFire = function(skillId, tier)
            PlaySkillSfx(skillId, tier)
        end,
        onBallCollision = function(speed)
            PlayBattleSfx("ball_collision", math.max(0.2, math.min(0.6, (speed or 100) / 300)))
        end,
        onProjectileHit = function(damage)
            PlayBattleSfx("projectile_hit", math.max(0.3, math.min(0.8, (damage or 5) / 15)))
        end,
        onBallDeath = function()
            PlayBattleSfx("ball_death", 0.7)
        end,
        onBattleStart = function()
            PlayBattleSfx("battle_start", 0.6)
        end,
        onBattleVictory = function()
            PlayBattleSfx("battle_victory", 0.7)
        end,
        onBattleDefeat = function()
            PlayBattleSfx("battle_defeat", 0.6)
        end,
        onFirstBallDropped = function()
            if callbacks_ and callbacks_.onFirstBallDroppedToArena then
                callbacks_.onFirstBallDroppedToArena()
            end
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
    -- Save all ball state before leaving (force cloud upload on exit)
    SaveBreedingData(true)
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

    -- Gold button click detection (5 clicks = +100,000,000)
    do
        local goldBgW = 200
        local goldBgH = 42
        local currencyGap = 10
        local totalCurrencyW = goldBgW * 2 + currencyGap
        local goldBgX = (designW - totalCurrencyW) / 2
        local goldBgY = 22
        local pressed = (UI.GetTopOverlay() == nil) and input:GetMouseButtonPress(MOUSEB_LEFT) or false
        if pressed and mx and my
            and mx >= goldBgX and mx <= goldBgX + goldBgW
            and my >= goldBgY and my <= goldBgY + goldBgH then
            goldBtnClickCount_ = goldBtnClickCount_ + 1
            goldBtnClickTimer_ = 2.0
            if goldBtnClickCount_ >= 5 then
                gold_ = gold_ + 100000000
                goldTargetValue_ = gold_
                goldShakeTimer_ = 0.5
                goldShakeIntensity_ = 6
                goldBtnClickCount_ = 0
            end
        end
        if goldBtnClickTimer_ > 0 then
            goldBtnClickTimer_ = goldBtnClickTimer_ - dt
            if goldBtnClickTimer_ <= 0 then
                goldBtnClickCount_ = 0
            end
        end
    end

    -- Panel enemy drag tracking (IDLE state only)
    do
        local uiBlocked = (UI.GetTopOverlay() ~= nil)
        local mouseDown = (not uiBlocked) and input:GetMouseButtonDown(MOUSEB_LEFT) or false
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.maxGridY + (layout.maxGridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end
        ArenaBattle.UpdatePanelDrag(mouseDown, mx or -9999, my or -9999, arenaX, arenaY)
    end

    -- When arena battle is fully active, skip breeding-specific updates
    if ArenaBattle.IsActive() then
        -- Still handle arena battle input
        local uiBlocked = (UI.GetTopOverlay() ~= nil)
        local pressed = (not uiBlocked) and input:GetMouseButtonPress(MOUSEB_LEFT) or false
        local mouseDown = (not uiBlocked) and input:GetMouseButtonDown(MOUSEB_LEFT) or false
        ArenaBattle.ProcessBattleInput(pressed, mouseDown, mx or -9999, my or -9999, designW, designH)

        -- Still do periodic save
        saveTimer_ = saveTimer_ + dt
        if saveTimer_ >= SAVE_INTERVAL then
            saveTimer_ = saveTimer_ - SAVE_INTERVAL
            SaveBreedingData()
        end
        return
    end

    -- Auto-spawn disabled

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

    -- Update all active breedings
    for idx = 1, MAX_SLOTS do
        if activeBreedings_[idx] then
            UpdateBreeding(idx, dt)
        end
    end

    -- Auto-start battles or breedings:
    -- 同性 → 战斗；异性（一公一母）→ 繁殖
    for idx = 1, slotsUnlocked_ do
        if slotBalls_[idx] and #slotBalls_[idx] >= 2
                and not activeBattles_[idx] and not activeBreedings_[idx] then
            local b1, b2 = slotBalls_[idx][1], slotBalls_[idx][2]
            if IsOppGender(b1, b2) then
                StartBreeding(idx)
            else
                StartBattle(idx)
            end
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

            -- Priority 1: fill empty unlocked slots (prefer ball with most accumulated exp)
            local placed = false
            for idx = 1, slotsUnlocked_ do
                if not activeBattles_[idx] and (not slotBalls_[idx] or #slotBalls_[idx] == 0) then
                    if #farmBalls_ > 0 then
                        -- Pick the ball with the highest exp (most progress toward next level)
                        local bestIdx = 1
                        local bestExp = farmBalls_[1].exp or 0
                        for fi = 2, #farmBalls_ do
                            local e = farmBalls_[fi].exp or 0
                            if e > bestExp then
                                bestExp = e
                                bestIdx = fi
                            end
                        end
                        local ball = table.remove(farmBalls_, bestIdx)
                        slotBalls_[idx] = slotBalls_[idx] or {}
                        table.insert(slotBalls_[idx], ball)
                        placed = true
                        break  -- one action per tick
                    end
                end
            end

            -- Priority 2: fill slots that have exactly 1 ball
            -- 优先选与槽内球同性的球（触发战斗），找不到时才选任意最高级球（触发繁殖）
            if not placed and #farmBalls_ > 0 then
                for idx = 1, slotsUnlocked_ do
                    if not activeBattles_[idx] and not activeBreedings_[idx]
                            and slotBalls_[idx] and #slotBalls_[idx] == 1 then
                        local existing = slotBalls_[idx][1]
                        -- 先尝试找同性最高级球
                        local sameGenderPick = nil
                        local sameGenderLevel = -1
                        for fi = 1, #farmBalls_ do
                            local fb = farmBalls_[fi]
                            local sameGen = (fb.gender or 1) == (existing.gender or 1)
                            if sameGen and (fb.level or 1) > sameGenderLevel then
                                sameGenderLevel = fb.level or 1
                                sameGenderPick  = fi
                            end
                        end
                        local pick = sameGenderPick or findHighestLevelBall()
                        local ball = table.remove(farmBalls_, pick)
                        table.insert(slotBalls_[idx], ball)
                        placed = true
                        break  -- one action per tick
                    end
                end
            end

            -- Priority 3: trigger streak battle during waitingChallenger countdown
            -- Skip if winner HP <= 30% — let the tired ball return to farm
            if not placed and #farmBalls_ > 0 then
                for idx = 1, slotsUnlocked_ do
                    local battle = activeBattles_[idx]
                    if battle and battle.finished and battle.victory
                       and battle.victory.waitingChallenger then
                        local winnerBB = battle.winnerIdx and battle.balls[battle.winnerIdx]
                        if winnerBB then
                            local hpRatio = (winnerBB.maxHp and winnerBB.maxHp > 0)
                                and (winnerBB.hp / winnerBB.maxHp) or 1
                            if hpRatio <= 0.3 then
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
            -- Skip if streak winner HP <= 30%
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
                                    if hr <= 0.3 then skipLowHp = true end
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
                        PlayCoinCollectSfx(coin.value)
                        local goldBtnCX = (designW2 - (200 * 2 + 10)) / 2 + 200 / 2
                        local goldBtnCY = 22 + 42 / 2
                        local miniCount = math.max(3, math.min(15, math.floor(coin.value * 2)))
                        local baseFlightTime, staggerPer = CalcCoinAnimTiming(coin.value, miniCount)
                        local perParticleGold = coin.value / miniCount
                        for ci = 1, miniCount do
                            local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                            local spreadDist = 10 + math.random() * 15
                            local delay = (ci - 1) * staggerPer + math.random() * staggerPer * 0.3
                            table.insert(goldParticles_, {
                                x = coinDesignX + math.cos(angle) * spreadDist,
                                y = coinDesignY + math.sin(angle) * spreadDist,
                                startX = coinDesignX + math.cos(angle) * spreadDist,
                                startY = coinDesignY + math.sin(angle) * spreadDist,
                                targetX = goldBtnCX,
                                targetY = goldBtnCY,
                                radius = 6 + math.random() * 3,
                                elapsed = -delay,
                                flightTime = baseFlightTime + math.random() * 0.1,
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
                a.radius = math.min(38, maxR + 2)
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
                PlayCoinCollectSfx(coin.value)
                local goldBtnCX = (designW2 - (200 * 2 + 10)) / 2 + 200 / 2
                local goldBtnCY = 22 + 42 / 2
                local miniCount = math.max(3, math.min(15, math.floor(coin.value * 2)))
                local baseFlightTime, staggerPer = CalcCoinAnimTiming(coin.value, miniCount)
                local perParticleGold = coin.value / miniCount
                for ci = 1, miniCount do
                    local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                    local spreadDist = 10 + math.random() * 15
                    local delay = (ci - 1) * staggerPer + math.random() * staggerPer * 0.3
                    table.insert(goldParticles_, {
                        x = coin.x + math.cos(angle) * spreadDist,
                        y = coin.y + math.sin(angle) * spreadDist,
                        startX = coin.x + math.cos(angle) * spreadDist,
                        startY = coin.y + math.sin(angle) * spreadDist,
                        targetX = goldBtnCX, targetY = goldBtnCY,
                        radius = 6 + math.random() * 3,
                        elapsed = -delay,
                        flightTime = baseFlightTime + math.random() * 0.1,
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

    -- === Update trash can wobble animation ===
    do
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
                    PlayCoinCollectSfx(coin.value)
                    local goldBtnCX = (designW2 - (200 * 2 + 10)) / 2 + 200 / 2
                    local goldBtnCY = 22 + 42 / 2
                    local miniCount = math.max(3, math.min(20, math.floor(coin.value / 5)))
                    local baseFlightTime, staggerPer = CalcCoinAnimTiming(coin.value, miniCount)
                    local perParticleGold = coin.value / miniCount
                    for ci = 1, miniCount do
                        local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                        local spreadDist = 10 + math.random() * 15
                        local delay = (ci - 1) * staggerPer + math.random() * staggerPer * 0.3
                        table.insert(goldParticles_, {
                            x = coin.x + math.cos(angle) * spreadDist,
                            y = coin.y + math.sin(angle) * spreadDist,
                            startX = coin.x + math.cos(angle) * spreadDist,
                            startY = coin.y + math.sin(angle) * spreadDist,
                            targetX = goldBtnCX, targetY = goldBtnCY,
                            radius = 6 + math.random() * 3,
                            elapsed = -delay,
                            flightTime = baseFlightTime + math.random() * 0.1,
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
            -- Smooth exponential chase: display value gradually catches up over the
            -- full particle animation window (~0.8-3.5s depending on amount).
            -- Using diff*3 gives ~0.3s time-constant per arrival batch, and the
            -- minimum speed of 15/s prevents the last few digits from stalling.
            local speed = math.max(math.abs(diff) * 3, 15)
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

    -- -----------------------------------------------------------------------
    -- Level-up celebration overlay animation
    -- -----------------------------------------------------------------------
    if levelUpCelebration_ then
        local cel = levelUpCelebration_
        cel.timer = cel.timer + dt

        -- Hover detection for buttons (using design coords)
        local btnW, btnH = 480, 70
        local btnX = 960 - btnW / 2
        local adBtnY = 800
        local dismissBtnY = 884
        cel.adBtnY = adBtnY
        cel.dismissBtnY = dismissBtnY
        cel.btnW = btnW
        cel.btnH = btnH
        if cel.buttonsVisible then
            cel.hoverAdBtn      = (mx >= btnX and mx <= btnX + btnW and my >= adBtnY and my <= adBtnY + btnH)
            cel.hoverDismissBtn = (mx >= btnX and mx <= btnX + btnW and my >= dismissBtnY and my <= dismissBtnY + btnH)
        end

        -- Ball floor-bounce physics:
        -- Ball shoots up from below screen, overshoots targetY, gravity pulls it back,
        -- then bounces off the "floor" at targetY with damping until it settles.
        if not cel.settled then
            cel.ballY  = cel.ballY + cel.ballVY * dt
            cel.ballVY = cel.ballVY + 2600 * dt   -- gravity (design px/s²)

            -- Bounce off floor at targetY when falling down (ballVY > 0)
            if cel.ballY >= cel.targetY and cel.ballVY > 0 then
                cel.ballY  = cel.targetY
                cel.ballVY = -math.abs(cel.ballVY) * 0.52
                cel.bounceCount = cel.bounceCount + 1
                if math.abs(cel.ballVY) < 130 then
                    cel.settled = true
                    cel.ballVY = 0
                    cel.buttonsVisible = true
                end
            end
        end

        -- Sway animation (once settled)
        if cel.settled then
            cel.swayPhase = cel.swayPhase + dt * 2.5
        end

        -- Wave text animation (always running)
        cel.wavePhase = cel.wavePhase + dt * 4.5

        -- Firework spawning
        cel.fwTimer = cel.fwTimer + dt
        local spawnInterval = 0.22
        if cel.fwTimer >= spawnInterval then
            cel.fwTimer = cel.fwTimer - spawnInterval
            -- Spawn a firework burst
            local c = cel.ballColor
            local fw = {
                x = 200 + math.random() * 1520,
                y = 100 + math.random() * 600,
                particles = {},
                age = 0,
            }
            for pi = 1, 20 do
                local angle = (pi / 20) * math.pi * 2 + math.random() * 0.4
                local speed = 180 + math.random() * 200
                table.insert(fw.particles, {
                    x = fw.x, y = fw.y,
                    vx = math.cos(angle) * speed,
                    vy = math.sin(angle) * speed,
                    alpha = 1.0,
                    -- Color variation around ball color
                    r = math.min(255, c.r + math.random(-40, 40)),
                    g = math.min(255, c.g + math.random(-40, 40)),
                    b = math.min(255, c.b + math.random(-40, 40)),
                    size = 3 + math.random() * 4,
                })
            end
            table.insert(cel.fireworks, fw)
        end

        -- Update firework particles
        local i = 1
        while i <= #cel.fireworks do
            local fw = cel.fireworks[i]
            fw.age = fw.age + dt
            for _, p in ipairs(fw.particles) do
                p.x = p.x + p.vx * dt
                p.y = p.y + p.vy * dt
                p.vy = p.vy + 300 * dt  -- gravity
                p.alpha = math.max(0, 1 - fw.age / 1.2)
            end
            if fw.age >= 1.2 then
                table.remove(cel.fireworks, i)
            else
                i = i + 1
            end
        end
    end
end

-- ============================================================================
-- Input Processing
-- ============================================================================

function BreedingPage.ProcessInput(mx, my, pressed)
    if not active_ then return end
    if ArenaBattle.IsActive() then return end

    -- Level-up celebration overlay intercepts all input
    if levelUpCelebration_ then
        local cel = levelUpCelebration_
        if pressed and cel.buttonsVisible then
            local btnW = cel.btnW or 480
            local btnH = cel.btnH or 70
            local btnX = 960 - btnW / 2
            -- "观看广告再获得一个" button
            if mx >= btnX and mx <= btnX + btnW
               and my >= cel.adBtnY and my <= cel.adBtnY + btnH then
                -- TODO: show rewarded ad; for now give extra ball of same level immediately
                levelUpCelebration_ = nil
                print("[Breeding] LevelUp celebration: ad button pressed (ad not available, skip)")
            end
            -- "残忍拒绝" button
            if mx >= btnX and mx <= btnX + btnW
               and my >= cel.dismissBtnY and my <= cel.dismissBtnY + btnH then
                levelUpCelebration_ = nil
            end
        end
        return  -- block all other input while celebration is active
    end

    local designW = 1920
    local designH = 1080
    local layout = GetSlotLayout(designW, designH)
    local farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)

    -- Arena panel enemy click (tooltip)
    if pressed and not dragBall_ then
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.maxGridY + (layout.maxGridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end
        ArenaBattle.ProcessPanelClick(mx, my, pressed, arenaX, arenaY)
    end

    -- Back button (enlarged, match Render)
    local backW, backH = 180, 56
    local backX, backY = 24, 24
    hoverBackBtn_ = (mx >= backX and mx <= backX + backW and my >= backY and my <= backY + backH)

    if pressed and hoverBackBtn_ then
        if callbacks_ and callbacks_.onBack then
            callbacks_.onBack()
        end
        return
    end

    -- Slot upgrade button (enlarged)
    local slotBtnW, slotBtnH = 170, 52
    local slotBtnX = layout.gridX + layout.gridW + 30
    local slotBtnY = layout.gridY + layout.gridH - slotBtnH
    hoverSlotBtn_ = (mx >= slotBtnX and mx <= slotBtnX + slotBtnW and my >= slotBtnY and my <= slotBtnY + slotBtnH)

    -- Trash can hover detection (same position as in Render)
    do
        local trashSize = 300
        local trashW, trashH = trashSize, trashSize
        local trashX = layout.gridX + layout.gridW + 30 - (trashSize - 120) / 2 + 50 + 150 - 50
        local trashY = layout.maxGridY + (layout.maxGridH - trashH) / 2
        hoverTrashCan_ = (mx >= trashX and mx <= trashX + trashW and my >= trashY and my <= trashY + trashH)
    end

    -- Slot unlocking is now automatic via farm level upgrade (no manual purchase)


    -- Farm upgrade button (enlarged)
    local farmBtnW, farmBtnH = 170, 52
    local farmBtnX = farmX + farmW + 30
    local farmBtnY = farmY + farmH - farmBtnH
    hoverFarmBtn_ = (mx >= farmBtnX and mx <= farmBtnX + farmBtnW and my >= farmBtnY and my <= farmBtnY + farmBtnH)

    if pressed and hoverFarmBtn_ and farmLevel_ < MAX_FARM_LEVEL then
        local costIdx = farmLevel_
        local cost = FARM_COSTS[costIdx]
        if cost and gold_ >= cost then
            gold_ = gold_ - cost
            farmLevel_ = farmLevel_ + 1
            -- 通知教程系统：养殖场已升级，隐藏任务标记
            require("ui.TutorialSystem").OnFarmUpgraded()
            -- Unlock battle slots based on farm level
            slotsUnlocked_ = FARM_SLOTS_UNLOCKED[farmLevel_] or slotsUnlocked_
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

    -- AI auto-match button (above farm upgrade button)
    local farmBtnW_ai, farmBtnH_ai = 170, 52
    local farmBtnX_ai = farmX + farmW + 30
    local farmBtnY_ai = farmY + farmH - farmBtnH_ai
    local aiBtnSize = 56
    local upgBtnW, upgBtnH = 70, 26
    -- 升级按钮紧贴养殖场升级按钮上方
    local upgBtnX = farmBtnX_ai + (farmBtnW_ai - upgBtnW) / 2
    local upgBtnY = farmBtnY_ai - upgBtnH - 8
    -- AI 图标在升级按钮上方；满级时直接贴养殖场升级按钮
    local aiBtnCX = farmBtnX_ai + farmBtnW_ai / 2
    local aiBtnY = (aiLevel_ > 0 and aiLevel_ < MAX_AI_LEVEL)
        and (upgBtnY - aiBtnSize - 6)
        or  (farmBtnY_ai - aiBtnSize - 8)
    local aiBtnX = aiBtnCX - aiBtnSize / 2
    hoverAiBtn_ = (mx >= aiBtnX and mx <= aiBtnX + aiBtnSize and my >= aiBtnY and my <= aiBtnY + aiBtnSize)

    -- Upgrade button hitbox
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
                    -- 教程回调：球被放入槽位
                    if callbacks_ and callbacks_.onBallDroppedToSlot then
                        callbacks_.onBallDroppedToSlot(idx)
                    end
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
            local arenaY = layout.maxGridY + (layout.maxGridH - apH) / 2
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
            local trashSize = 300
            local trashW, trashH = trashSize, trashSize
            local trashX = layout.gridX + layout.gridW + 30 - (trashSize - 120) / 2 + 50 + 150 - 50
            local trashY = layout.maxGridY + (layout.maxGridH - trashH) / 2
            if mx >= trashX and mx <= trashX + trashW and my >= trashY and my <= trashY + trashH then
                placed = true
                local ball = dragBall_.ball
                local grade = GetColorGrade(ball.level)
                local sellValue = math.floor((TRASH_SELL_VALUES[grade] or 10) * 0.5)

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

                -- Trigger wobble animation
                trashLidShake_ = 0.6

                -- Spawn trash coins near the trash can
                local coinCount = math.max(2, math.min(8, math.floor(math.log(sellValue + 1) / math.log(10) * 2.5)))
                local perCoin = sellValue / coinCount
                for ci = 1, coinCount do
                    local cx = trashX + trashW / 2 + (math.random() - 0.5) * trashW * 0.8
                    local cy = trashY + trashH + 20 + math.random() * 40
                    local coinR = math.max(22, math.min(46, 20 + math.log(perCoin + 1) / math.log(10) * 9))
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
    local farmX, farmY, farmW, farmH = GetFarmLayout(designW, designH, layout)

    -- Load UI images (once)
    LoadUIImages(vg)

    -- Background: drawn by Standalone.lua (full-screen grass tile, no black bars)

    nvgFontFaceId(vg, fontId)

    -- Apply breeding UI fade-out when arena battle is transitioning/active
    local arenaFade = ArenaBattle.GetBreedingFadeOut()
    if arenaFade > 0 then
        nvgGlobalAlpha(vg, math.max(0, 1 - arenaFade))
    end

    -- Gold & Diamond display (top-center, side by side)
    local goldBgW = 200
    local goldBgH = 42
    local currencyGap = 10
    local totalCurrencyW = goldBgW * 2 + currencyGap
    local goldBgX = (designW - totalCurrencyW) / 2
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
        nvgBeginPath(vg); nvgRoundedRect(vg, finalGoldX - 4, finalGoldY - 4, goldBgW + 8, goldBgH + 8, 14)
        nvgFillColor(vg, nvgRGBA(255, 200, 50, glowAlpha)); nvgFill(vg)
    end

    -- Gold button background (solid color)
    nvgBeginPath(vg); nvgRoundedRect(vg, finalGoldX, finalGoldY, goldBgW, goldBgH, 10)
    nvgFillColor(vg, nvgRGBA(60, 45, 25, 200)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(200, 170, 80, 180)); nvgStrokeWidth(vg, 2); nvgStroke(vg)

    -- Coin icon (solid circle)
    local coinR = (goldBgH - 12) / 2
    local coinCX = finalGoldX + 6 + coinR
    local coinCY = finalGoldY + goldBgH / 2
    DrawCoinIcon(vg, coinCX, coinCY, coinR, 240)

    -- Animated gold value display
    local displayVal = math.floor(goldDisplayValue_ + 0.5)
    local goldText = string.format("%d¥", displayVal)
    nvgFontSize(vg, 28)
    nvgFillColor(vg, nvgRGBA(255, 225, 100, 255))
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgText(vg, finalGoldX + goldBgW / 2 + 10, finalGoldY + goldBgH / 2, goldText, nil)

    -- (gold mini-coins moved to end of Render for top-layer rendering)

    -- Diamond display bar (right of gold bar)
    do
        local diamBgW = goldBgW
        local diamBgH = goldBgH
        local diamBgX = finalGoldX + goldBgW + currencyGap
        local diamBgY = finalGoldY

        -- Background
        nvgBeginPath(vg); nvgRoundedRect(vg, diamBgX, diamBgY, diamBgW, diamBgH, 10)
        nvgFillColor(vg, nvgRGBA(30, 35, 60, 200)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(120, 160, 220, 180)); nvgStrokeWidth(vg, 2); nvgStroke(vg)

        -- Diamond icon (diamond shape)
        local dR = (diamBgH - 14) / 2
        local dCX = diamBgX + 6 + dR + 2
        local dCY = diamBgY + diamBgH / 2
        -- Top half (bright facet)
        nvgBeginPath(vg)
        nvgMoveTo(vg, dCX, dCY - dR)           -- top
        nvgLineTo(vg, dCX + dR, dCY - dR * 0.15) -- right shoulder
        nvgLineTo(vg, dCX, dCY + dR)            -- bottom point
        nvgLineTo(vg, dCX - dR, dCY - dR * 0.15) -- left shoulder
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(100, 180, 255, 240)); nvgFill(vg)
        -- Inner highlight
        nvgBeginPath(vg)
        nvgMoveTo(vg, dCX, dCY - dR + 3)
        nvgLineTo(vg, dCX + dR * 0.5, dCY - dR * 0.1)
        nvgLineTo(vg, dCX, dCY + dR * 0.3)
        nvgLineTo(vg, dCX - dR * 0.5, dCY - dR * 0.1)
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(200, 230, 255, 150)); nvgFill(vg)

        -- Diamond count text
        local diamondCount = DiamondManager.Get()
        local diamText = string.format("%d💎", diamondCount)
        nvgFontSize(vg, 28)
        nvgFillColor(vg, nvgRGBA(150, 210, 255, 255))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg, diamBgX + diamBgW / 2 + 10, diamBgY + diamBgH / 2, diamText, nil)
    end

    -- Back button (solid color)
    local backW, backH = 180, 56
    local backX, backY = 24, 24
    nvgBeginPath(vg); nvgRoundedRect(vg, backX, backY, backW, backH, 12)
    nvgFillColor(vg, hoverBackBtn_ and nvgRGBA(240, 220, 180, 240) or nvgRGBA(220, 200, 160, 220))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(160, 130, 80, 180)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    nvgFontSize(vg, 22)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(90, 60, 30, 240))
    nvgText(vg, backX + backW / 2, backY + backH / 2, "← 返回", nil)

    -- "战斗区域" vertical label (warm brown)
    local labelX = layout.gridX - 50
    local labelCenterY = layout.gridY + layout.gridH / 2
    nvgFontSize(vg, 24)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(120, 85, 50, 220))
    local labelChars = { "战", "斗", "区", "域" }
    for ci, ch in ipairs(labelChars) do
        local cy = labelCenterY + (ci - 2.5) * 32
        nvgText(vg, labelX, cy, ch, nil)
    end

    -- AI auto-match button (above farm upgrade button)
    do
        local aiBtnSize = 56
        local farmBtnW_r, farmBtnH_r = 170, 52
        local farmBtnX_r = farmX + farmW + 30
        local farmBtnY_r = farmY + farmH - farmBtnH_r
        local ubW_r, ubH_r = 70, 26
        -- AI 图标：满级时直接贴养殖场按钮上方；未满级时在升级按钮上方
        local aiBtnCX = farmBtnX_r + farmBtnW_r / 2
        local aiBtnY = (aiLevel_ > 0 and aiLevel_ < MAX_AI_LEVEL)
            and (farmBtnY_r - ubH_r - 8 - aiBtnSize - 6)
            or  (farmBtnY_r - aiBtnSize - 8)
        local aiBtnX = aiBtnCX - aiBtnSize / 2
        local aiBtnCY = aiBtnY + aiBtnSize / 2
        local isOwned = aiLevel_ > 0
        local isOn = isOwned and aiEnabled_
        local isMaxed = aiLevel_ >= MAX_AI_LEVEL

        -- AI button image (select based on state)
        local aiImg = (isOn and uiImgs_.aiOn) or uiImgs_.aiOff
        local imgAlpha = 1.0

        -- Hover: slight brightness boost via glow behind
        if hoverAiBtn_ then
            nvgBeginPath(vg); nvgRoundedRect(vg, aiBtnX - 3, aiBtnY - 3, aiBtnSize + 6, aiBtnSize + 6, 10)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 50))
            nvgFill(vg)
        end

        -- Glow effect when ON
        if isOn then
            local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 2.0)
            local glowPad = 4 + pulse * 3
            nvgBeginPath(vg); nvgRoundedRect(vg, aiBtnX - glowPad, aiBtnY - glowPad, aiBtnSize + glowPad * 2, aiBtnSize + glowPad * 2, 12)
            local glowAlpha = math.floor(30 + pulse * 25)
            if isMaxed then
                nvgFillColor(vg, nvgRGBA(255, 200, 50, glowAlpha))
            else
                nvgFillColor(vg, nvgRGBA(180, 220, 140, glowAlpha))
            end
            nvgFill(vg)
        end

        -- Dim when owned but disabled
        if isOwned and not aiEnabled_ then
            imgAlpha = 0.6
        elseif not isOwned then
            imgAlpha = 0.8
        end

        -- Draw the AI button image
        DrawUIImageCover(vg, aiImg, aiBtnX, aiBtnY, aiBtnSize, aiBtnSize, imgAlpha, 8)

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
                local ubY = farmBtnY_r - ubH - 8

                -- Button background with hand-drawn style
                local aiFill, aiStroke
                if hoverAiUpgrade_ then
                    aiFill = canAfford and nvgRGBA(60, 180, 80, 240) or nvgRGBA(150, 60, 60, 200)
                else
                    if canAfford then
                        local pulse = 0.7 + 0.3 * math.sin(elapsedTime_ * 3.0)
                        local g = math.floor(140 + 60 * pulse)
                        aiFill = nvgRGBA(40, g, 60, 220)
                    else
                        aiFill = nvgRGBA(80, 80, 90, 180)
                    end
                end
                aiStroke = canAfford and nvgRGBA(100, 255, 120, 180) or nvgRGBA(120, 120, 130, 150)
                DrawHandDrawnBtn(vg, ubX, ubY, ubW, ubH, 6, aiFill, aiStroke, 4.5, 3.0)

                -- Arrow up icon + text
                nvgFontSize(vg, 13)
                nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, canAfford and nvgRGBA(255, 255, 255, 240) or nvgRGBA(160, 160, 170, 180))
                nvgText(vg, aiBtnCX, ubY + ubH / 2, string.format("⬆¥%d", nextCost), nil)
            end
        end
    end

    -- Draw battle slots
    -- 只遍历可见行（根据已解锁槽位数动态决定显示行数）
    local visibleRows = layout.visibleRows or GRID_ROWS
    local _TutSys = require("ui.TutorialSystem")
    local _tutDragStep = 0  -- 0=无效, 2=第一次拖放(所有槽闪), 3=第二次拖放(仅有球槽闪)
    if dragBall_ and _TutSys.IsActive() then
        local s = _TutSys.GetSaveData().stepIndex
        if s == 2 or s == 3 then _tutDragStep = s end
    end
    for row = 0, visibleRows - 1 do
        for col = 0, GRID_COLS - 1 do
            local idx = row * GRID_COLS + col + 1
            local sx, sy, sw, sh = GetSlotRect(layout, idx)

            if idx <= slotsUnlocked_ then
                -- ---- 已解锁格子 ----
                -- Check if dragging over this slot
                local isHover = dragBall_ and not activeBattles_[idx] and not activeBreedings_[idx]
                    and mouseDesignX_ >= sx and mouseDesignX_ <= sx + sw
                    and mouseDesignY_ >= sy and mouseDesignY_ <= sy + sh

                -- Unlocked slot: hand-drawn grass card
                local battle    = activeBattles_[idx]
                local breeding  = activeBreedings_[idx]
                local slotBalls = slotBalls_[idx]
                local hasContent = battle or breeding or (slotBalls and #slotBalls > 0)

                if hasContent then
                    -- Active/waiting slot: grass background (cover to keep aspect ratio)
                    DrawUIImageCover(vg, uiImgs_ and uiImgs_.slotGrass, sx, sy, sw, sh, 1.0, 8)
                    nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                    nvgStrokeColor(vg, nvgRGBA(140, 110, 70, 160))
                    nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
                else
                    -- Empty unlocked slot: dashed card (cover to keep aspect ratio)
                    DrawUIImageCover(vg, uiImgs_ and uiImgs_.slotEmpty, sx, sy, sw, sh, 1.0, 8)
                    nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                    nvgStrokeColor(vg, nvgRGBA(180, 160, 130, 100))
                    nvgStrokeWidth(vg, 1.0); nvgStroke(vg)
                end

                -- Hover highlight
                if isHover then
                    nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                    nvgFillColor(vg, nvgRGBA(120, 180, 80, 80)); nvgFill(vg)
                end

                -- Tutorial: red pulsing overlay when dragging
                -- step 2: all unlocked slots glow
                -- step 3: only slots that already have a ball waiting
                local shouldGlow = (_tutDragStep == 2) or
                    (_tutDragStep == 3 and slotBalls and #slotBalls > 0)
                if shouldGlow then
                    local pulse = 0.5 + 0.5 * math.sin(elapsedTime_ * 4)
                    nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                    nvgFillColor(vg, nvgRGBA(255, 60, 60, math.floor(40 + pulse * 60)))
                    nvgFill(vg)
                end

                -- Draw battle / breeding / waiting balls
                if battle then
                    DrawBattle(vg, fontId, sx, sy, sw, sh, battle)
                elseif breeding then
                    DrawBreeding(vg, fontId, sx, sy, sw, sh, breeding)
                else
                    -- Draw waiting balls in slot
                    if slotBalls and #slotBalls > 0 then
                        DrawSlotBalls(vg, fontId, sx, sy, sw, sh, slotBalls)
                    end
                end
            else
                -- ---- 锁定格子（在可见行内但尚未解锁）----
                -- 半透明暗色底板，显示锁图标
                DrawUIImageCover(vg, uiImgs_ and uiImgs_.slotEmpty, sx, sy, sw, sh, 0.45, 8)
                -- 暗色遮罩
                nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                nvgFillColor(vg, nvgRGBA(30, 20, 10, 100)); nvgFill(vg)
                -- 边框
                nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, sw, sh, 8)
                nvgStrokeColor(vg, nvgRGBA(120, 100, 70, 80))
                nvgStrokeWidth(vg, 1.0); nvgStroke(vg)
                -- 锁图标（用 NanoVG 绘制简单锁形）
                local cx, cy = sx + sw / 2, sy + sh / 2
                local lockW, lockH = 28, 22
                local lockArcR = 10
                local lockBodyY = cy - 4
                -- 锁弓（上半圆弧）
                nvgBeginPath(vg)
                nvgArc(vg, cx, lockBodyY - lockH / 2 + 2, lockArcR, math.pi, 0, NVG_CW)
                nvgStrokeColor(vg, nvgRGBA(180, 160, 120, 160))
                nvgStrokeWidth(vg, 4); nvgStroke(vg)
                -- 锁体（圆角矩形）
                nvgBeginPath(vg)
                nvgRoundedRect(vg, cx - lockW / 2, lockBodyY, lockW, lockH, 5)
                nvgFillColor(vg, nvgRGBA(160, 140, 100, 160)); nvgFill(vg)
                nvgStrokeColor(vg, nvgRGBA(200, 180, 130, 180))
                nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
                -- 锁孔（小圆）
                nvgBeginPath(vg)
                nvgCircle(vg, cx, lockBodyY + lockH / 2 - 5, 3)
                nvgFillColor(vg, nvgRGBA(80, 60, 30, 200)); nvgFill(vg)
            end
        end
    end

    -- ---- Arena (擂台赛) - left side panel ----
    do
        local apW, apH = ArenaBattle.GetPanelSize()
        local arenaX = layout.gridX - 70 - apW
        local arenaY = layout.maxGridY + (layout.maxGridH - apH) / 2
        if arenaX < 4 then arenaX = 4 end

        ArenaBattle.RenderPanel(vg, fontId, arenaX, arenaY, dragBall_ ~= nil, elapsedTime_)


    end

    -- ---- Trash Can (垃圾桶) - right side facility ----
    do
        local trashSize = 300
        local trashW, trashH = trashSize, trashSize
        local trashX = layout.gridX + layout.gridW + 30 - (trashSize - 120) / 2 + 50 + 150 - 50
        local trashY = layout.maxGridY + (layout.maxGridH - trashH) / 2

        -- Background frame (Mask group-2.png) - slightly taller for the sign
        local bgW = trashW + 20
        local bgH = trashH + 30
        local bgX = trashX - 10
        local bgY = trashY - 20
        DrawUIImage(vg, uiImgs_ and uiImgs_.trashbinBg, bgX, bgY, bgW, bgH, 1.0)

        -- Trash can icon (等比 1.2x scaled, centered in the grass area)
        local iconW, iconH = 216, 216
        local iconX = trashX + (trashW - iconW) / 2
        local iconY = trashY + (trashH - iconH) / 2 + 10

        local trashAlpha = (hoverTrashCan_ and dragBall_) and 1.0 or 0.9
        local wobbleAngle = 0
        if trashLidShake_ > 0 then
            local intensity = trashLidShake_ / 0.6
            wobbleAngle = math.sin(trashLidShake_ * 28) * 0.15 * intensity
        end

        if wobbleAngle ~= 0 then
            nvgSave(vg)
            local pivotX = iconX + iconW / 2
            local pivotY = iconY + iconH
            nvgTranslate(vg, pivotX, pivotY)
            nvgRotate(vg, wobbleAngle)
            nvgTranslate(vg, -pivotX, -pivotY)
            DrawUIImage(vg, uiImgs_ and uiImgs_.trashbin, iconX, iconY, iconW, iconH, trashAlpha)
            nvgRestore(vg)
        else
            DrawUIImage(vg, uiImgs_ and uiImgs_.trashbin, iconX, iconY, iconW, iconH, trashAlpha)
        end
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
                local COIN_R = coin.radius * cs

                DrawCoinImg(vg, drawX, drawY, COIN_R, coin.rotation, math.floor(250 * cs))
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

    -- Slot info label (slots are unlocked by farm level, no manual purchase)
    do
        local slotInfoX = layout.gridX + layout.gridW + 30
        local slotInfoY = layout.gridY + layout.gridH - 30
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(180, 160, 120, 200))
        nvgText(vg, slotInfoX, slotInfoY,
            string.format("槽位 %d/%d (升级养殖场解锁)", slotsUnlocked_, MAX_SLOTS), nil)
    end

    -- ---- Farm Area ----
    -- farmX/farmY/farmW/farmH already declared at function top

    -- "养殖场" vertical label (matching arena style)
    local farmLabelX = farmX - 60
    local farmLabelCY = farmY + farmH / 2
    nvgFontSize(vg, 26)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(120, 85, 50, 220))
    local farmLabelChars = { "养", "殖", "场" }
    for ci, ch in ipairs(farmLabelChars) do
        local cy = farmLabelCY + (ci - 2) * 36
        nvgText(vg, farmLabelX, cy, ch, nil)
    end

    -- Farm panel (grass texture, tiled fill)
    if uiImgs_.farmGrass and uiImgs_.farmGrass > 0 then
        nvgBeginPath(vg); nvgRoundedRect(vg, farmX, farmY, farmW, farmH, 10)
        local grassPat = nvgImagePattern(vg, farmX, farmY, 256, 256, 0, uiImgs_.farmGrass, 1.0)
        nvgFillPaint(vg, grassPat); nvgFill(vg)
    else
        nvgBeginPath(vg); nvgRoundedRect(vg, farmX, farmY, farmW, farmH, 10)
        nvgFillColor(vg, nvgRGBA(60, 130, 50, 200)); nvgFill(vg)
    end
    nvgBeginPath(vg); nvgRoundedRect(vg, farmX, farmY, farmW, farmH, 10)
    nvgStrokeColor(vg, nvgRGBA(80, 60, 30, 160))
    nvgStrokeWidth(vg, 2.5); nvgStroke(vg)

    -- Draw farm ball shadows (deep green, bottom-right offset, rendered first)
    for _, ball in ipairs(farmBalls_) do
        local sx = farmX + ball.x + 4
        local sy = farmY + ball.y + 4
        local sr = ball.radius * 0.9
        nvgBeginPath(vg); nvgCircle(vg, sx, sy, sr)
        nvgFillColor(vg, nvgRGBA(15, 60, 20, 100)); nvgFill(vg)
    end

    -- Draw farm balls
    local tutorialHighlightBall = require("ui.TutorialSystem").GetWinnerHighlightBall()
    for _, ball in ipairs(farmBalls_) do
        local bx = farmX + ball.x
        local by = farmY + ball.y
        -- 教程高亮：胜利球球外圈发光
        if ball == tutorialHighlightBall then
            local pulse = 0.55 + 0.45 * math.sin(elapsedTime_ * 4.0)
            local glowAlpha = math.floor(90 * pulse)
            for gi = 1, 3 do
                local expand = gi * 7
                nvgBeginPath(vg)
                nvgCircle(vg, bx, by, ball.radius + expand)
                nvgStrokeColor(vg, nvgRGBA(255, 230, 60, math.floor(glowAlpha / gi)))
                nvgStrokeWidth(vg, 3.0)
                nvgStroke(vg)
            end
        end
        DrawFarmBall(vg, fontId, bx, by, ball)
        -- 教程箭头：在高亮球球上方画一个跳动的向下箭头
        if ball == tutorialHighlightBall then
            local arrowBounce = math.sin(elapsedTime_ * 4.5) * 5
            local ax = bx
            local ay = by - ball.radius - 22 - arrowBounce
            local aw = 18   -- 箭头半宽
            local ah = 16   -- 箭头高度
            -- 箭头填充
            nvgBeginPath(vg)
            nvgMoveTo(vg, ax,      ay + ah)  -- 尖端（向下）
            nvgLineTo(vg, ax - aw, ay)
            nvgLineTo(vg, ax - aw * 0.4, ay)
            nvgLineTo(vg, ax - aw * 0.4, ay - ah * 0.7)
            nvgLineTo(vg, ax + aw * 0.4, ay - ah * 0.7)
            nvgLineTo(vg, ax + aw,       ay)
            nvgClosePath(vg)
            local arrowAlpha = math.floor(200 + 55 * math.sin(elapsedTime_ * 4.5))
            nvgFillColor(vg, nvgRGBA(255, 220, 40, arrowAlpha))
            nvgFill(vg)
            -- 箭头描边
            nvgBeginPath(vg)
            nvgMoveTo(vg, ax,      ay + ah)
            nvgLineTo(vg, ax - aw, ay)
            nvgLineTo(vg, ax - aw * 0.4, ay)
            nvgLineTo(vg, ax - aw * 0.4, ay - ah * 0.7)
            nvgLineTo(vg, ax + aw * 0.4, ay - ah * 0.7)
            nvgLineTo(vg, ax + aw,       ay)
            nvgClosePath(vg)
            nvgStrokeColor(vg, nvgRGBA(200, 140, 0, 220))
            nvgStrokeWidth(vg, 2.0)
            nvgStroke(vg)
        end
    end

    -- Farm level + capacity
    local cap = FARM_CAPACITY[farmLevel_] or 70
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(100, 70, 30, 220))
    nvgText(vg, farmX + 10, farmY + farmH - 8,
        string.format("Lv.%d / %d  |  %d / %d", farmLevel_, MAX_FARM_LEVEL, #farmBalls_, cap), nil)

    -- Farm upgrade button (enlarged)
    local farmBtnW, farmBtnH = 170, 52
    local farmBtnX = farmX + farmW + 30
    local farmBtnY = farmY + farmH - farmBtnH
    if farmLevel_ < MAX_FARM_LEVEL then
        local costIdx = farmLevel_
        local cost = FARM_COSTS[costIdx] or 0
        local canAfford = gold_ >= cost
        local farmBtnAlpha = canAfford and 230 or 120
        DrawHandDrawnBtn(vg, farmBtnX, farmBtnY, farmBtnW, farmBtnH, 10,
            nvgRGBA(140, 90, 180, farmBtnAlpha),
            nvgRGBA(100, 60, 150, farmBtnAlpha), 6, 2.0)
        if hoverFarmBtn_ and canAfford then
            HandDrawnRoundedRect(vg, farmBtnX, farmBtnY, farmBtnW, farmBtnH, 10, 2.0)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 50)); nvgFill(vg)
        end
        nvgFontSize(vg, 18)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, canAfford and 255 or 160))
        nvgText(vg, farmBtnX + farmBtnW / 2, farmBtnY + farmBtnH / 2,
            string.format("升级%d¥", cost), nil)
    else
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(100, 170, 60, 220))
        nvgText(vg, farmBtnX + farmBtnW / 2, farmBtnY + farmBtnH / 2, "已满级", nil)
    end

    -- 教程任务标记：赚够50金币升级养殖场
    do
        local TutorialSystem = require("ui.TutorialSystem")
        if TutorialSystem.IsFarmTaskVisible() then
            local taskText = "任务：赚够50金币升级养殖场"
            local taskW = 240
            local taskH = 30
            local taskX = farmBtnX + (farmBtnW - taskW) / 2
            local taskY = farmBtnY - taskH - 8
            -- 橙色背景徽章
            nvgBeginPath(vg)
            nvgRoundedRect(vg, taskX, taskY, taskW, taskH, 8)
            nvgFillColor(vg, nvgRGBA(255, 140, 0, 220))
            nvgFill(vg)
            -- 白色描边
            nvgStrokeWidth(vg, 1.5)
            nvgStrokeColor(vg, nvgRGBA(255, 220, 100, 200))
            nvgStroke(vg)
            -- 任务文字
            nvgFontSize(vg, 13)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
            nvgText(vg, taskX + taskW / 2, taskY + taskH / 2, taskText, nil)
            -- 小箭头指向升级按钮
            nvgBeginPath(vg)
            nvgMoveTo(vg, taskX + taskW / 2 - 6, taskY + taskH)
            nvgLineTo(vg, taskX + taskW / 2 + 6, taskY + taskH)
            nvgLineTo(vg, taskX + taskW / 2, taskY + taskH + 7)
            nvgClosePath(vg)
            nvgFillColor(vg, nvgRGBA(255, 140, 0, 220))
            nvgFill(vg)
        end
    end

    -- Farm level info (below upgrade button)
    do
        local infoY = farmBtnY + farmBtnH + 6
        local maxBLvl = FARM_MAX_BALL_LEVEL[farmLevel_] or 7
        local newBLvl = FARM_NEW_BALL_LEVEL[farmLevel_] or 1
        local spawnRate = FARM_SPAWN_RATE[farmLevel_] or 5.0
        local gradeNames = { "白", "浅绿", "绿", "蓝", "紫", "橙", "红", "金",
                              "青", "黄绿", "青蓝", "红橙", "黑白", "蓝紫", "粉橙", "红紫" }
        nvgFontSize(vg, 10)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(120, 90, 50, 200))
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
                    local COIN_R = coin.radius * cs * scaleF

                    DrawCoinImg(vg, drawX, drawY, COIN_R, coin.rotation, math.floor(250 * cs))
                    -- Value label
                    nvgFontFaceId(vg, fontId)
                    local valueFontSize = math.floor(math.max(13, 18 * scaleF))
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
            local COIN_R = coin.radius * cs

            DrawCoinImg(vg, drawX, drawY, COIN_R, coin.rotation, math.floor(250 * cs))
            -- Value label
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 16)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
            nvgText(vg, drawX, drawY + COIN_R + 3,
                string.format("+%d", math.floor(coin.value)), nil)
        end
    end

    -- Draw dragging ball + lineage + info tooltip (on top of everything)
    if dragBall_ then
        local ball = dragBall_.ball
        -- 谱系连线（最底层，在球和 tooltip 之下）
        DrawLineage(vg, fontId, ball, dragBall_.curX, dragBall_.curY,
            farmX, farmY, designW, designH)
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
        local currencyGap2 = 10
        local totalCurrencyW2 = goldBgW2 * 2 + currencyGap2
        local goldBgX2 = (designW - totalCurrencyW2) / 2
        local goldBgY2 = 22
        nvgBeginPath(vg); nvgRoundedRect(vg, goldBgX2, goldBgY2, goldBgW2, goldBgH2, 10)
        nvgFillColor(vg, nvgRGBA(60, 45, 25, 200)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(200, 170, 80, 180)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
        -- Coin icon (solid circle)
        local coinR2 = (goldBgH2 - 12) / 2
        local coinCX2 = goldBgX2 + 6 + coinR2
        local coinCY2 = goldBgY2 + goldBgH2 / 2
        DrawCoinIcon(vg, coinCX2, coinCY2, coinR2, 240)
        local displayVal2 = math.floor(goldDisplayValue_ + 0.5)
        local goldText2 = string.format("%d¥", displayVal2)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 28)
        nvgFillColor(vg, nvgRGBA(255, 225, 100, 255))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg, goldBgX2 + goldBgW2 / 2 + 10, goldBgY2 + goldBgH2 / 2, goldText2, nil)

        -- Diamond bar (right of gold bar, arena overlay)
        local diamBgX2 = goldBgX2 + goldBgW2 + currencyGap2
        local diamBgY2 = goldBgY2
        nvgBeginPath(vg); nvgRoundedRect(vg, diamBgX2, diamBgY2, goldBgW2, goldBgH2, 10)
        nvgFillColor(vg, nvgRGBA(30, 35, 60, 200)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(120, 160, 220, 180)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
        -- Diamond icon
        local dR2 = (goldBgH2 - 14) / 2
        local dCX2 = diamBgX2 + 6 + dR2 + 2
        local dCY2 = diamBgY2 + goldBgH2 / 2
        nvgBeginPath(vg)
        nvgMoveTo(vg, dCX2, dCY2 - dR2)
        nvgLineTo(vg, dCX2 + dR2, dCY2 - dR2 * 0.15)
        nvgLineTo(vg, dCX2, dCY2 + dR2)
        nvgLineTo(vg, dCX2 - dR2, dCY2 - dR2 * 0.15)
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(100, 180, 255, 240)); nvgFill(vg)
        nvgBeginPath(vg)
        nvgMoveTo(vg, dCX2, dCY2 - dR2 + 3)
        nvgLineTo(vg, dCX2 + dR2 * 0.5, dCY2 - dR2 * 0.1)
        nvgLineTo(vg, dCX2, dCY2 + dR2 * 0.3)
        nvgLineTo(vg, dCX2 - dR2 * 0.5, dCY2 - dR2 * 0.1)
        nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(200, 230, 255, 150)); nvgFill(vg)
        -- Diamond text
        local diamText2 = string.format("%d💎", DiamondManager.Get())
        nvgFontSize(vg, 28)
        nvgFillColor(vg, nvgRGBA(150, 210, 255, 255))
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgText(vg, diamBgX2 + goldBgW2 / 2 + 10, diamBgY2 + goldBgH2 / 2, diamText2, nil)
    end

    -- Render arena character pool overlay (Tab key panel, on top of everything)
    if ArenaBattle.IsPoolOpen() then
        ArenaBattle.RenderPool(vg, fontId, designW, designH, elapsedTime_)
    end

    -- Draw gold mini-coins on TOP of everything (including arena overlay)
    for _, p in ipairs(goldParticles_) do
        if p.elapsed >= 0 then
            local mcR = p.radius
            DrawCoinImg(vg, p.x, p.y, mcR, (p.rotation or 0), 240)
        end
    end

    -- Render drag item overlay as the absolute last layer (on top of everything)
    if ArenaBattle.IsActive() then
        ArenaBattle.RenderDragOverlay(vg, fontId)
    end

    -- =========================================================================
    -- Level-up celebration overlay (drawn on top of everything, full-screen)
    -- =========================================================================
    if false and levelUpCelebration_ then  -- TEMP DISABLED
        local cel = levelUpCelebration_

        -- 使用物理分辨率确保全屏覆盖
        local physW = graphics:GetWidth()
        local physH = graphics:GetHeight()
        -- BreedingPage.Render 收到的 w/h 是设计坐标，换算比例
        local dsx   = w / 1920
        local dsy   = h / 1080
        local dsMin = math.min(dsx, dsy)
        -- 全屏像素尺寸（物理像素）
        local cw = physW
        local ch = physH
        -- 设计空间到物理像素的比例
        local psx = physW / 1920
        local psy = physH / 1080
        local psMin = math.min(psx, psy)

        nvgSave(vg)
        nvgGlobalAlpha(vg, 1.0)  -- 重置 arena-fade 残留的全局 alpha

        -- 1. 全屏暗色遮罩（物理像素覆盖，0.4s 淡入到 alpha 200）
        local overlayAlpha = math.min(200, math.floor(cel.timer / 0.4 * 200))
        nvgBeginPath(vg)
        nvgRect(vg, 0, 0, cw, ch)
        nvgFillColor(vg, nvgRGBA(0, 0, 15, overlayAlpha))
        nvgFill(vg)

        -- 2. 烟花粒子（设计坐标转物理像素）
        for _, fw in ipairs(cel.fireworks) do
            for _, p in ipairs(fw.particles) do
                local alpha = math.floor(p.alpha * 255)
                if alpha > 0 then
                    nvgBeginPath(vg)
                    nvgCircle(vg, p.x * psx, p.y * psy, p.size * psMin)
                    nvgFillColor(vg, nvgRGBA(p.r, p.g, p.b, alpha))
                    nvgFill(vg)
                end
            end
        end

        -- 3. 球球（带表情）
        local celC = cel.ballColor
        local bxD = cel.ballX   -- 设计坐标
        local byD = cel.ballY
        local br  = cel.ballRadius
        if cel.settled then
            bxD = bxD + math.sin(cel.swayPhase) * 18
        end
        -- 落地压扁/拉伸
        local ballSX, ballSY = 1.0, 1.0
        if not cel.settled and cel.ballVY > 0 then
            local squash = math.min(0.18, cel.ballVY / 5000)
            ballSX = 1 + squash
            ballSY = 1 - squash
        end

        local bxP = bxD * psx   -- 物理像素坐标
        local byP = byD * psy
        local brP = br  * psMin

        -- 光晕
        local glowR  = brP * 1.6
        local celGrad = nvgRadialGradient(vg, bxP, byP, brP * 0.3, glowR,
            nvgRGBA(celC.r, celC.g, celC.b, 130), nvgRGBA(celC.r, celC.g, celC.b, 0))
        nvgBeginPath(vg)
        nvgCircle(vg, bxP, byP, glowR)
        nvgFillPaint(vg, celGrad)
        nvgFill(vg)

        -- 球体（压扁变换在物理坐标下）
        nvgSave(vg)
        nvgTranslate(vg, bxP, byP)
        nvgScale(vg, ballSX, ballSY)

        -- 球体渐变（从亮到暗）
        local ballGrad = nvgRadialGradient(vg,
            -brP * 0.28, -brP * 0.32, brP * 0.12, brP * 1.35,
            nvgRGBA(math.min(255, celC.r + 80), math.min(255, celC.g + 60), math.min(255, celC.b + 40), 255),
            nvgRGBA(math.max(0, celC.r - 40),   math.max(0, celC.g - 40),   math.max(0, celC.b - 20),  255))
        nvgBeginPath(vg)
        nvgCircle(vg, 0, 0, brP)
        nvgFillPaint(vg, ballGrad)
        nvgFill(vg)
        -- 描边
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 120))
        nvgStrokeWidth(vg, 3 * psMin)
        nvgStroke(vg)
        -- 高光
        nvgBeginPath(vg)
        nvgCircle(vg, -brP * 0.25, -brP * 0.28, brP * 0.22)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 110))
        nvgFill(vg)

        -- ── 表情 ──
        -- 左眼白
        nvgBeginPath(vg); nvgEllipse(vg, -brP*0.28, -brP*0.08, brP*0.20, brP*0.22)
        nvgFillColor(vg, nvgRGBA(255,255,255,240)); nvgFill(vg)
        -- 右眼白
        nvgBeginPath(vg); nvgEllipse(vg,  brP*0.28, -brP*0.08, brP*0.20, brP*0.22)
        nvgFillColor(vg, nvgRGBA(255,255,255,240)); nvgFill(vg)
        -- 左瞳孔
        nvgBeginPath(vg); nvgCircle(vg, -brP*0.25, -brP*0.06, brP*0.12)
        nvgFillColor(vg, nvgRGBA(30,15,10,250)); nvgFill(vg)
        -- 右瞳孔
        nvgBeginPath(vg); nvgCircle(vg,  brP*0.25, -brP*0.06, brP*0.12)
        nvgFillColor(vg, nvgRGBA(30,15,10,250)); nvgFill(vg)
        -- 眼睛高光
        nvgBeginPath(vg); nvgCircle(vg, -brP*0.22, -brP*0.10, brP*0.045)
        nvgFillColor(vg, nvgRGBA(255,255,255,255)); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg,  brP*0.22, -brP*0.10, brP*0.045)
        nvgFillColor(vg, nvgRGBA(255,255,255,255)); nvgFill(vg)
        -- 嘴巴（弧线）
        nvgBeginPath(vg)
        nvgMoveTo(vg, -brP*0.30, brP*0.22)
        nvgBezierTo(vg, -brP*0.18, brP*0.42, brP*0.18, brP*0.42, brP*0.30, brP*0.22)
        nvgStrokeColor(vg, nvgRGBA(30,10,5,220))
        nvgStrokeWidth(vg, brP*0.065); nvgStroke(vg)
        -- 腮红
        nvgBeginPath(vg); nvgEllipse(vg, -brP*0.48, brP*0.18, brP*0.14, brP*0.08)
        nvgFillColor(vg, nvgRGBA(255,120,100,70)); nvgFill(vg)
        nvgBeginPath(vg); nvgEllipse(vg,  brP*0.48, brP*0.18, brP*0.14, brP*0.08)
        nvgFillColor(vg, nvgRGBA(255,120,100,70)); nvgFill(vg)

        nvgRestore(vg)

        -- 4. 博士帽
        local crownScale = brP * 0.058
        nvgSave(vg)
        nvgTranslate(vg, bxP, byP - brP * 1.20)
        nvgScale(vg, crownScale, crownScale)
        nvgBeginPath(vg)
        nvgMoveTo(vg, -18, 8); nvgLineTo(vg, -18, -4)
        nvgLineTo(vg, -10, 4); nvgLineTo(vg, 0, -14)
        nvgLineTo(vg, 10, 4); nvgLineTo(vg, 18, -4)
        nvgLineTo(vg, 18, 8); nvgClosePath(vg)
        nvgFillColor(vg, nvgRGBA(255, 215, 0, 240)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(200, 140, 0, 255))
        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, 0, -14, 3)
        nvgFillColor(vg, nvgRGBA(255, 80, 80, 255)); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, -10, 4, 2.5)
        nvgFillColor(vg, nvgRGBA(80, 180, 255, 255)); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, 10, 4, 2.5)
        nvgFillColor(vg, nvgRGBA(100, 255, 100, 255)); nvgFill(vg)
        nvgRestore(vg)

        -- 5. 波浪抖动文字（逐字渲染）
        local textCenterY = 200 * psy
        local fontSize    = 72  * psMin
        local waveAmp     = 10  * psMin   -- 波浪振幅（像素）
        local waveStep    = 0.55          -- 相邻字符相位差

        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, fontSize)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)

        local levelText = string.format("恭喜晋升，当前等级 LV%d", cel.level)

        -- 逐 UTF-8 字符迭代
        local chars = {}
        local si = 1
        while si <= #levelText do
            local byte = string.byte(levelText, si)
            local charLen = 1
            if byte >= 0xF0 then charLen = 4
            elseif byte >= 0xE0 then charLen = 3
            elseif byte >= 0xC0 then charLen = 2
            end
            table.insert(chars, string.sub(levelText, si, si + charLen - 1))
            si = si + charLen
        end

        -- 先测量总宽度（nvgTextBounds 直接返回宽度数字）
        local charWidths = {}
        local totalW = 0
        for ci, ch_str in ipairs(chars) do
            local cw_val = nvgTextBounds(vg, 0, 0, ch_str) or (fontSize * 0.62)
            if type(cw_val) ~= "number" or cw_val <= 0 then
                cw_val = fontSize * 0.62
            end
            charWidths[ci] = cw_val
            totalW = totalW + cw_val
        end

        -- 描边 + 主色逐字绘制
        local outlineW = math.max(3, math.floor(5 * psMin))
        local startX   = cw / 2 - totalW / 2
        local curX     = startX

        for ci, ch_str in ipairs(chars) do
            local waveY = textCenterY + math.sin(cel.wavePhase + (ci - 1) * waveStep) * waveAmp
            -- 红色描边
            nvgFillColor(vg, nvgRGBA(220, 30, 30, 240))
            for ox = -outlineW, outlineW, outlineW do
                for oy = -outlineW, outlineW, outlineW do
                    if ox ~= 0 or oy ~= 0 then
                        nvgText(vg, curX + ox, waveY + oy, ch_str, nil)
                    end
                end
            end
            -- 黄色主体
            nvgFillColor(vg, nvgRGBA(255, 240, 60, 255))
            nvgText(vg, curX, waveY, ch_str, nil)
            curX = curX + charWidths[ci]
        end

        -- 6. 按钮（球球稳定后出现）
        if cel.buttonsVisible then
            local btnW = (cel.btnW or 480) * psx
            local btnH = (cel.btnH or 70)  * psy
            local btnX = cw / 2 - btnW / 2
            local adBtnY      = (cel.adBtnY      or 800) * psy
            local dismissBtnY = (cel.dismissBtnY or 884) * psy
            local btnRadius   = 16 * psMin
            local btnFontSize = 26 * psMin

            -- 绿色：观看广告
            local adAlpha = cel.hoverAdBtn and 255 or 230
            local adBg    = cel.hoverAdBtn and nvgRGBA(60, 210, 90, adAlpha) or nvgRGBA(40, 185, 70, adAlpha)
            nvgBeginPath(vg); nvgRoundedRect(vg, btnX, adBtnY, btnW, btnH, btnRadius)
            nvgFillColor(vg, adBg); nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(100, 255, 130, 200))
            nvgStrokeWidth(vg, 2 * psMin); nvgStroke(vg)
            nvgFontSize(vg, btnFontSize)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(0, 60, 0, 160))
            nvgText(vg, cw / 2 + 1, adBtnY + btnH / 2 + 1, "观看广告再获得一个", nil)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
            nvgText(vg, cw / 2, adBtnY + btnH / 2, "观看广告再获得一个", nil)

            -- 白色：残忍拒绝
            local dismissAlpha = cel.hoverDismissBtn and 255 or 210
            local dismissBg    = cel.hoverDismissBtn and nvgRGBA(240, 240, 245, dismissAlpha) or nvgRGBA(210, 210, 220, dismissAlpha)
            nvgBeginPath(vg); nvgRoundedRect(vg, btnX, dismissBtnY, btnW, btnH, btnRadius)
            nvgFillColor(vg, dismissBg); nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(180, 180, 190, 200))
            nvgStrokeWidth(vg, 2 * psMin); nvgStroke(vg)
            nvgFontSize(vg, btnFontSize)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(80, 80, 100, 200))
            nvgText(vg, cw / 2, dismissBtnY + btnH / 2, "残忍拒绝", nil)
        end

        nvgRestore(vg)
    end
end

-- ============================================================================
-- Draw Helpers
-- ============================================================================

--- Compute gradient color for grades 10-16 (two-color smooth cycling)
local function ComputeGradientColor(gradientData, elapsed)
    local c1 = gradientData.color1
    local c2 = gradientData.color2
    local period = gradientData.period or 3.0
    local offset = gradientData.phaseOffset or 0
    -- Smooth ping-pong between the two colors
    local t = ((elapsed + offset) % period) / period
    local frac = (math.cos(t * math.pi * 2) + 1) * 0.5  -- 0..1..0 smooth
    return
        math.floor(c1.r + (c2.r - c1.r) * frac),
        math.floor(c1.g + (c2.g - c1.g) * frac),
        math.floor(c1.b + (c2.b - c1.b) * frac)
end

function DrawFarmBall(vg, fontId, bx, by, ball)
    local c = ball.color
    local r = ball.radius
    local lvl = ball.level
    local grade = GetColorGrade(lvl)
    local isGradient = (c and c.gradient) or (grade >= 10)

    -- For gradient balls (grade 10-16), compute cycling color
    if isGradient then
        local gd = c and c.gradientData
        if gd then
            local cr, cg, cb = ComputeGradientColor(gd, elapsedTime_)
            c = { r = cr, g = cg, b = cb, gradient = true, gradientData = gd }
        else
            -- Fallback: generate gradient data
            local pair = GRADIENT_COLOR_PAIRS[grade]
            if pair then
                local gd2 = { color1 = pair[1], color2 = pair[2], period = 3.0, phaseOffset = 0 }
                local cr, cg, cb = ComputeGradientColor(gd2, elapsedTime_)
                c = { r = cr, g = cg, b = cb, gradient = true, gradientData = gd2 }
                ball.color.gradientData = gd2
            end
        end
    end

    -- Soft glow (grade 2+ only, intensity scales with grade)
    if grade >= 2 then
        local glowSize = r * (1.5 + grade * 0.1)
        local glowAlpha = math.min(25 + grade * 5, 120)
        nvgBeginPath(vg); nvgCircle(vg, bx, by, glowSize)
        nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, r * 0.5, glowSize,
            nvgRGBA(c.r, c.g, c.b, glowAlpha), nvgRGBA(c.r, c.g, c.b, 0)))
        nvgFill(vg)
    end

    -- Particle effects: scale count and intensity with level
    -- Grade 5+: small orbiting particles; grade 8+: more and brighter; grade 10+: even more
    if grade >= 5 then
        local particleCount
        if grade >= 14 then
            particleCount = 10
        elseif grade >= 10 then
            particleCount = 7
        elseif grade >= 8 then
            particleCount = 5
        else
            particleCount = 3
        end

        for pi = 1, particleCount do
            local pAngle = (elapsedTime_ * (0.6 + pi * 0.25)) + pi * (math.pi * 2 / particleCount)
            local pDist = r * (1.1 + 0.3 * math.sin(elapsedTime_ * 2.0 + pi))
            local px = bx + math.cos(pAngle) * pDist
            local py = by + math.sin(pAngle) * pDist
            local pAlpha = math.floor(80 + 60 * math.sin(elapsedTime_ * 3.0 + pi * 1.5))
            local pSize = 1.5 + 0.8 * math.sin(elapsedTime_ * 3.5 + pi * 2)
            -- For gradient grades, shift color per particle
            local pcr, pcg, pcb = c.r, c.g, c.b
            if isGradient and c.gradientData then
                pcr, pcg, pcb = ComputeGradientColor(c.gradientData, elapsedTime_ + pi * 0.4)
            end
            -- Make higher-grade particles bigger and brighter
            pSize = pSize + (grade - 5) * 0.15
            pAlpha = math.min(255, pAlpha + (grade - 5) * 10)
            nvgBeginPath(vg); nvgCircle(vg, px, py, pSize)
            nvgFillColor(vg, nvgRGBA(pcr, pcg, pcb, pAlpha)); nvgFill(vg)
        end
    end

    -- Ball body
    nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
    nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 230)); nvgFill(vg)

    -- Highlight
    nvgBeginPath(vg); nvgCircle(vg, bx - r * 0.25, by - r * 0.25, r * 0.35)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, isGradient and 100 or 80)); nvgFill(vg)

    -- Grade ring (grade 2+)
    if grade >= 2 then
        local rc = LEVEL_BASE_COLORS[grade]
        -- For gradient grades, use the live animated color for the ring
        if isGradient then
            rc = c
        end
        local ringAlpha = math.min(140 + grade * 8, 250)
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r + 2)
        nvgStrokeColor(vg, nvgRGBA(rc.r, rc.g, rc.b, ringAlpha))
        nvgStrokeWidth(vg, 1.0 + math.min(grade, 10) * 0.25); nvgStroke(vg)
    end

    -- Expression face (always draw if present)
    if ball.expression then
        Expressions.Draw(vg, ball.expression, bx, by, r)
    end

    -- Level number: always shown prominently on ball body
    do
        local lvlStr = tostring(ball.level)
        -- Position: centered when no expression, lower area when expression present
        local textY = ball.expression and (by + r * 0.48) or by
        local fontSize = ball.expression and math.max(7, r * 0.52) or math.max(8, r * 0.9)
        nvgFontFaceId(vg, fontId)
        -- Drop shadow
        nvgFontSize(vg, fontSize)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 140))
        nvgText(vg, bx + 1, textY + 1, lvlStr, nil)
        -- Main text
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 230))
        nvgText(vg, bx, textY, lvlStr, nil)
    end

    -- Win streak stars on ball (centered on ball body)
    local streak = ball.winStreak or 0
    if streak >= 1 then
        nvgFontFaceId(vg, fontId)
        local starY = by  -- 球球中心
        if streak <= 5 then
            -- Individual stars
            local starSize = math.max(8, r * 0.45)
            nvgFontSize(vg, starSize)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            local totalW = streak * starSize * 1.05
            local startSX = bx - totalW / 2 + starSize * 0.5
            for si = 1, streak do
                local sx = startSX + (si - 1) * starSize * 1.05
                nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
                nvgText(vg, sx + 1, starY + 1, "★", nil)
                nvgFillColor(vg, nvgRGBA(255, 220, 50, 240))
                nvgText(vg, sx, starY, "★", nil)
            end
        else
            -- Compact format: ★×N
            local starSize = math.max(8, r * 0.50)
            local label = string.format("★×%d", streak)
            nvgFontSize(vg, starSize)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, 120))
            nvgText(vg, bx + 1, starY + 1, label, nil)
            nvgFillColor(vg, nvgRGBA(255, 220, 50, 240))
            nvgText(vg, bx, starY, label, nil)
        end
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

    -- 性别图标（右上角小标）
    if ball.gender then
        local icon   = ball.gender == 1 and "♂" or "♀"
        local iconSz = math.max(6, r * 0.45)
        local iconX  = bx + r * 0.62
        local iconY  = by - r * 0.62
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, iconSz * 1.5)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        -- 阴影
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 140))
        nvgText(vg, iconX + 1, iconY + 1, icon, nil)
        -- 颜色：♂ 蓝，♀ 粉
        if ball.gender == 1 then
            nvgFillColor(vg, nvgRGBA(100, 180, 255, 230))
        else
            nvgFillColor(vg, nvgRGBA(255, 130, 190, 230))
        end
        nvgText(vg, iconX, iconY, icon, nil)
    end
end

--- 渲染繁殖动画（在槽位矩形内绘制）
function DrawBreeding(vg, fontId, sx, sy, sw, sh, br)
    local cx = sx + sw / 2
    local cy = sy + sh / 2
    local scale = math.min(sw, sh) / 120  -- 把 [-60,60] 的坐标系映射到槽位

    nvgSave(vg)
    nvgScissor(vg, sx, sy, sw, sh)

    -- 背景心形提示
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 18)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 150, 200, 80))
    nvgText(vg, cx, sy + 14, "♥ 繁殖中 ♥", nil)

    if br.phase == "circling" then
        -- 两球绕中心对称旋转
        local orb = br.orbitRadius * scale
        local x1 = cx + math.cos(br.angle) * orb
        local y1 = cy + math.sin(br.angle) * orb
        local x2 = cx - math.cos(br.angle) * orb
        local y2 = cy - math.sin(br.angle) * orb
        -- 运动轨迹（淡圆圈）
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, orb)
        nvgStrokeColor(vg, nvgRGBA(255, 180, 220, 40))
        nvgStrokeWidth(vg, 1); nvgStroke(vg)
        -- 父球1（♂）
        DrawFarmBall(vg, fontId, x1, y1, br.ball1)
        -- 父球2（♀）
        DrawFarmBall(vg, fontId, x2, y2, br.ball2)
        -- 爱心粒子（偶发）
        local heartAlpha = math.floor(120 + 80 * math.sin(elapsedTime_ * 6))
        nvgFontSize(vg, 11)
        nvgFillColor(vg, nvgRGBA(255, 100, 160, heartAlpha))
        nvgText(vg, cx, cy, "♥", nil)

    elseif br.phase == "burst" or br.phase == "born" then
        -- 粒子爆发
        for _, p in ipairs(br.particles) do
            local alpha = math.floor(220 * (p.life / p.maxLife))
            nvgBeginPath(vg)
            nvgCircle(vg, cx + p.x * scale, cy + p.y * scale, p.r * scale)
            nvgFillColor(vg, nvgRGBA(p.cr, p.cg, p.cb, alpha))
            nvgFill(vg)
        end
        -- "born" 阶段：新球球缩放出现
        if br.phase == "born" and br.babyBall and br.babyScale > 0 then
            local baby = br.babyBall
            local eased = br.babyScale * br.babyScale * (3 - 2 * br.babyScale)  -- smoothstep
            -- 辉光
            local glowR = baby.radius * scale * eased * 2.5
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, glowR)
            local bc = baby.color
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, 0, glowR,
                nvgRGBA(bc.r, bc.g, bc.b, math.floor(80 * eased)),
                nvgRGBA(bc.r, bc.g, bc.b, 0)))
            nvgFill(vg)
            -- 球体
            nvgSave(vg)
            nvgTranslate(vg, cx, cy)
            nvgScale(vg, eased, eased)
            DrawFarmBall(vg, fontId, 0, 0, baby)
            nvgRestore(vg)
            -- "新生!" 文字
            local textAlpha = math.floor(255 * eased)
            nvgFontSize(vg, 13)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 230, 80, textAlpha))
            nvgText(vg, cx, cy - baby.radius * scale * eased - 12, "新生!", nil)
        end
    end

    nvgRestore(vg)
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
        -- Gradient color cycling for slot balls (grade 10-16)
        if c and c.gradient then
            local gd = c.gradientData
            if gd then
                local cr, cg, cb = ComputeGradientColor(gd, elapsedTime_)
                c = { r = cr, g = cg, b = cb }
            end
        end
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
    local waitLabel
    if count >= 2 then
        local twoOpp = IsOppGender(slotBalls[1], slotBalls[2])
        waitLabel = twoOpp and "♥ 即将繁殖..." or "即将开战..."
        nvgFillColor(vg, twoOpp and nvgRGBA(255, 150, 200, 180) or nvgRGBA(180, 180, 200, 150))
    else
        waitLabel = "等待对手..."
        nvgFillColor(vg, nvgRGBA(180, 180, 200, 150))
    end
    nvgText(vg, sx + sw / 2, sy + sh - 8, waitLabel, nil)
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

            -- Border rect with squish (no dark fill)
            nvgBeginPath(vg)
            nvgRoundedRect(vg, drawOX, drawOY, drawW, drawH, 4 * scaleY)
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

    -- Battle area - clip to slot, draw border with shake
    nvgSave(vg)
    nvgScissor(vg, sx, sy, sw, sh)

    -- NOTE: grass background is drawn once at fixed position in slot rendering (line ~3370)
    -- Do NOT draw it again here to avoid it shaking with battle content

    nvgBeginPath(vg); nvgRect(vg, ox + shakeX, oy + shakeY, drawSize, drawSize)
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

            -- Gradient color cycling for battle balls (grade 10-16)
            local isGradientBattle = c and c.gradient
            if isGradientBattle then
                local gd = c.gradientData
                if gd then
                    local cr, cg, cb = ComputeGradientColor(gd, elapsedTime_)
                    c = { r = cr, g = cg, b = cb, gradient = true, gradientData = gd }
                end
            end

            -- Level tier for visual effects
            local blvl = ball.level
            local bgrade = GetColorGrade(blvl)
            local btier = blvl >= 20 and 6 or blvl >= 15 and 5 or blvl >= 10 and 4 or blvl >= 5 and 3 or blvl >= 2 and 2 or 1

            -- Winner glow
            if isWinner then
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br * 1.6)
                nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.5, br * 1.6,
                    nvgRGBA(255, 215, 0, 50), nvgRGBA(255, 215, 0, 0)))
                nvgFill(vg)
            end

            -- Gradient glow + particles for grade 5+ in battle
            if bgrade >= 5 and ball.alive then
                -- Colored glow
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br * 1.5)
                nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.3, br * 1.5,
                    nvgRGBA(c.r, c.g, c.b, 40 + bgrade * 2), nvgRGBA(c.r, c.g, c.b, 0)))
                nvgFill(vg)
                -- Orbiting particles (count scales with grade)
                local bpCount = bgrade >= 14 and 8 or bgrade >= 10 and 6 or bgrade >= 8 and 4 or 3
                for pi = 1, bpCount do
                    local pAngle = (elapsedTime_ * (0.7 + pi * 0.25)) + pi * (math.pi * 2 / bpCount)
                    local pDist = br * (1.1 + 0.25 * math.sin(elapsedTime_ * 2 + pi))
                    local px = bx + math.cos(pAngle) * pDist
                    local py = by + math.sin(pAngle) * pDist
                    local pAlpha = math.floor(80 + 50 * math.sin(elapsedTime_ * 3 + pi * 1.5))
                    local pSize = 1.2 + 0.6 * math.sin(elapsedTime_ * 3.5 + pi)
                    local pcr, pcg, pcb = c.r, c.g, c.b
                    if isGradientBattle and c.gradientData then
                        pcr, pcg, pcb = ComputeGradientColor(c.gradientData, elapsedTime_ + pi * 0.4)
                    end
                    pSize = pSize + (bgrade - 5) * 0.1
                    pAlpha = math.min(255, pAlpha + (bgrade - 5) * 8)
                    nvgBeginPath(vg); nvgCircle(vg, px, py, pSize)
                    nvgFillColor(vg, nvgRGBA(pcr, pcg, pcb, pAlpha)); nvgFill(vg)
                end
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
-- DrawLineage: 谱系连线（拖拽时显示直系亲属关系）
-- ============================================================================
--- 将农场坐标 (bx, by) 换算成屏幕坐标
local function BallScreenPos(ball, farmX, farmY, layout)
    -- 球在农场里（ball.x / ball.y 是农场局部坐标）
    if ball.x and ball.y then
        return farmX + ball.x, farmY + ball.y
    end
    return nil, nil
end

--- 在场的所有球（farmBalls_ + slotBalls_）汇聚成 id→{ball,sx,sy} 表
local function BuildBallIndex(farmX, farmY, designW, designH)
    local index = {}  -- [id] = { ball, sx, sy }
    local layout = GetSlotLayout(designW, designH)

    for _, ball in ipairs(farmBalls_) do
        if ball.id then
            local sx, sy = BallScreenPos(ball, farmX, farmY, layout)
            if sx then index[ball.id] = { ball = ball, sx = sx, sy = sy } end
        end
    end
    for slotIdx = 1, MAX_SLOTS do
        local slot = slotBalls_[slotIdx]
        if slot then
            local slotSx, slotSy, slotSw, slotSh = GetSlotRect(layout, slotIdx)
            local cx = slotSx + slotSw / 2
            local cy = slotSy + slotSh / 2
            for _, ball in ipairs(slot) do
                if ball.id then
                    index[ball.id] = { ball = ball, sx = cx, sy = cy }
                end
            end
        end
        -- 战斗中的球
        local battle = activeBattles_[slotIdx]
        if battle and battle.balls then
            local slotSx, slotSy, slotSw, slotSh = GetSlotRect(layout, slotIdx)
            for _, bb in ipairs(battle.balls) do
                local fb = bb.farmBall
                if fb and fb.id then
                    local bx = slotSx + (bb.x or 0) * math.min(slotSw, slotSh) / 400
                    local by = slotSy + (bb.y or 0) * math.min(slotSw, slotSh) / 400
                    index[fb.id] = { ball = fb, sx = bx, sy = by }
                end
            end
        end
    end
    return index
end

--- 绘制一条从 (x1,y1) 到 (x2,y2) 的贝塞尔谱系连线
local function DrawLineageEdge(vg, x1, y1, x2, y2, r, g, b, alpha)
    local mx = (x1 + x2) / 2
    -- 控制点向上弯曲
    local cy1 = y1 - math.abs(y2 - y1) * 0.4 - 30
    local cy2 = y2 - math.abs(y2 - y1) * 0.4 - 30
    nvgBeginPath(vg)
    nvgMoveTo(vg, x1, y1)
    nvgBezierTo(vg, mx, cy1, mx, cy2, x2, y2)
    nvgStrokeColor(vg, nvgRGBA(r, g, b, alpha))
    nvgStrokeWidth(vg, 2.5)
    nvgStroke(vg)
    -- 终端小圆点
    nvgBeginPath(vg)
    nvgCircle(vg, x2, y2, 5)
    nvgFillColor(vg, nvgRGBA(r, g, b, alpha))
    nvgFill(vg)
end

--- 在亲属球旁绘制关系小标签
local function DrawLineageLabel(vg, fontId, sx, sy, label, r, g, b)
    nvgSave(vg)
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 13)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    -- 背景胶囊
    local tw = nvgTextBounds(vg, 0, 0, label, nil, nil)
    local pw, ph = tw + 10, 18
    nvgBeginPath(vg)
    nvgRoundedRect(vg, sx - pw / 2, sy - 34, pw, ph, 5)
    nvgFillColor(vg, nvgRGBA(30, 30, 40, 200))
    nvgFill(vg)
    nvgFillColor(vg, nvgRGBA(r, g, b, 230))
    nvgText(vg, sx, sy - 18, label, nil)
    nvgRestore(vg)
end

--- 主函数：在拖拽球时绘制谱系连线
function DrawLineage(vg, fontId, dragBall, dragX, dragY, farmX, farmY, designW, designH)
    local ball = dragBall
    if not ball.id then return end

    local index = BuildBallIndex(farmX, farmY, designW, designH)

    -- 收集父母（parentIds 里的球）
    local parents = {}
    if ball.parentIds then
        for _, pid in ipairs(ball.parentIds) do
            if pid and index[pid] then
                table.insert(parents, index[pid])
            end
        end
    end

    -- 收集子女（所有在场球中 parentIds 含 ball.id 的球）
    local children = {}
    for bid, entry in pairs(index) do
        if bid ~= ball.id then
            local pids = entry.ball.parentIds
            if pids then
                for _, pid in ipairs(pids) do
                    if pid == ball.id then
                        table.insert(children, entry)
                        break
                    end
                end
            end
        end
    end

    if #parents == 0 and #children == 0 then return end  -- 无亲属，不渲染

    nvgSave(vg)

    -- 父母连线：金色
    for _, entry in ipairs(parents) do
        DrawLineageEdge(vg, dragX, dragY, entry.sx, entry.sy, 255, 210, 80, 200)
        local gIcon = (entry.ball.gender or 1) == 1 and "♂父" or "♀母"
        DrawLineageLabel(vg, fontId, entry.sx, entry.sy, gIcon, 255, 210, 80)
    end

    -- 子女连线：青色
    for _, entry in ipairs(children) do
        DrawLineageEdge(vg, dragX, dragY, entry.sx, entry.sy, 80, 220, 255, 200)
        DrawLineageLabel(vg, fontId, entry.sx, entry.sy, "子代", 80, 220, 255)
    end

    -- 被拖拽球：在中心画一个微弱的谱系光晕
    local relCount = #parents + #children
    if relCount > 0 then
        nvgBeginPath(vg)
        nvgCircle(vg, dragX, dragY, (dragBall.radius or 20) + 10)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 180, 80))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
        -- 亲属数量小角标
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 180, 220))
        nvgText(vg, dragX, dragY - (dragBall.radius or 20) - 18,
            string.format("谱系 %d 位亲属", relCount), nil)
    end

    nvgRestore(vg)
end

-- ============================================================================
-- Draw Ball Info Tooltip (right-click popup)
-- ============================================================================

function DrawBallTooltip(vg, fontId, tipX, tipY, ball, screenW, screenH)
    nvgSave(vg)
    nvgFontFaceId(vg, fontId)

    -- Tooltip dimensions
    local popW = 280
    local popH = 292   -- 增高以容纳年龄/性别/生育次数三行
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

    -- Gradient color cycling for tooltip
    local isGradientTip = c and c.gradient
    local tipGrade = GetColorGrade(ball.level)
    if isGradientTip then
        local gd = c.gradientData
        if gd then
            local cr, cg, cb = ComputeGradientColor(gd, elapsedTime_)
            c = { r = cr, g = cg, b = cb, gradient = true, gradientData = gd }
        end
    end

    -- Face glow
    nvgBeginPath(vg); nvgCircle(vg, faceCx, faceCy, faceR * 1.4)
    nvgFillPaint(vg, nvgRadialGradient(vg, faceCx, faceCy, faceR * 0.3, faceR * 1.4,
        nvgRGBA(c.r, c.g, c.b, tipGrade >= 10 and 80 or 50), nvgRGBA(c.r, c.g, c.b, 0)))
    nvgFill(vg)

    -- Particles around face in tooltip (grade 5+)
    if tipGrade >= 5 then
        local tipPCount = tipGrade >= 14 and 8 or tipGrade >= 10 and 6 or 4
        for pi = 1, tipPCount do
            local pAngle = (elapsedTime_ * (0.6 + pi * 0.2)) + pi * (math.pi * 2 / tipPCount)
            local pDist = faceR * (1.15 + 0.2 * math.sin(elapsedTime_ * 2 + pi))
            local ppx = faceCx + math.cos(pAngle) * pDist
            local ppy = faceCy + math.sin(pAngle) * pDist
            local pAlpha = math.floor(100 + 60 * math.sin(elapsedTime_ * 3 + pi * 1.3))
            local pSize = 2.0 + 0.8 * math.sin(elapsedTime_ * 3.5 + pi)
            local pcr, pcg, pcb = c.r, c.g, c.b
            if isGradientTip and c.gradientData then
                pcr, pcg, pcb = ComputeGradientColor(c.gradientData, elapsedTime_ + pi * 0.35)
            end
            pSize = pSize + (tipGrade - 5) * 0.1
            pAlpha = math.min(255, pAlpha + (tipGrade - 5) * 8)
            nvgBeginPath(vg); nvgCircle(vg, ppx, ppy, pSize)
            nvgFillColor(vg, nvgRGBA(pcr, pcg, pcb, pAlpha)); nvgFill(vg)
        end
    end

    -- Face body
    nvgBeginPath(vg); nvgCircle(vg, faceCx, faceCy, faceR)
    nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 240))
    nvgFill(vg)

    -- Highlight
    nvgBeginPath(vg); nvgCircle(vg, faceCx - faceR * 0.2, faceCy - faceR * 0.2, faceR * 0.3)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, isGradientTip and 100 or 70))
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
    infoY = infoY + 22

    -- ---- Age / Gender / BreedCount ----
    nvgFontSize(vg, 15)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    -- 年龄
    nvgFillColor(vg, nvgRGBA(200, 200, 215, 200))
    nvgText(vg, infoX, infoY, string.format("年龄：%d", ball.age or 0), nil)
    infoY = infoY + 20

    -- 性别
    local genderVal  = ball.gender or 1
    local genderIcon = genderVal == 1 and "♂" or "♀"
    local genderName = genderVal == 1 and "雄" or "雌"
    if genderVal == 1 then
        nvgFillColor(vg, nvgRGBA(100, 180, 255, 230))
    else
        nvgFillColor(vg, nvgRGBA(255, 130, 190, 230))
    end
    nvgText(vg, infoX, infoY, string.format("性别：%s %s", genderIcon, genderName), nil)
    infoY = infoY + 20

    -- 生育次数
    local bc = ball.breedCount or 0
    nvgFillColor(vg, bc > 0 and nvgRGBA(255, 200, 100, 220) or nvgRGBA(160, 160, 180, 180))
    nvgText(vg, infoX, infoY, string.format("生育：%d 次", bc), nil)

    -- ---- Skills section ----
    local skillY = contentY + 172   -- 向下偏移以腾出新字段空间
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
            local locked = (slot.tier == "enhanced" and ball.level < 2) or (slot.tier == "ultimate" and ball.level < 3)
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

--- Set the save file path (for multi-slot support)
---@param path string e.g. "breeding_data_1.json"
---@param slot number|nil slot number (1-3), extracted from path if not provided
function BreedingPage.SetSaveFile(path, slot)
    BREEDING_SAVE_FILE = path
    -- Sync cloud save slot
    if not slot then
        slot = tonumber(path:match("breeding_data_(%d+)%.json")) or 1
    end
    CloudSave.SetSlot(slot)
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
            diamonds = DiamondManager.Get(),
        }
    end

    -- Otherwise, scan all save slots for best profile data
    local profile = SaveSlotManager.GetBestProfileData()
    if profile then
        profile.diamonds = DiamondManager.Get()
    end
    return profile
end

--- 强制触发一次存档（供外部模块如 TutorialSystem 回调使用）
function BreedingPage.ForceSave()
    if active_ then
        SaveBreedingData(false)
    end
end

return BreedingPage
