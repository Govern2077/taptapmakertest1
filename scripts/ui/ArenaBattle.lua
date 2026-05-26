-- ============================================================================
-- ArenaBattle.lua - 擂台赛系统（Arena Battle）
-- 模块化设计：由 BreedingPage 集成调用
-- 状态机: IDLE → TRANSITION_IN → COUNTDOWN → BATTLE → RESULT → TRANSITION_OUT
-- ============================================================================

local UI            = require("urhox-libs/UI")
local Settings      = require("config.Settings")
local BallAI        = require("game.BallAI")
local SkillRegistry = require("game.SkillRegistry")
local SkillExecutor = require("game.SkillExecutor")
local Expressions   = require("game.Expressions")
local ItemSystem    = require("game.ItemSystem")
local TriangleFill  = require("effects.TriangleFill")
local ArenaCloud    = require("game.ArenaCloud")

local ArenaBattle = {}

-- ============================================================================
-- Arena background image
-- ============================================================================
local arenaBgImg_ = nil  -- NanoVG image handle, loaded on first render
local coinStarImg_ = nil -- NanoVG image handle for coin_star.png

--- Draw image with aspect-ratio cover fitting, optional extra scale
local function DrawUIImageCover(vg, imgHandle, x, y, w, h, alpha, radius, extraScale)
    if not imgHandle or imgHandle <= 0 then return end
    alpha = alpha or 1.0
    radius = radius or 0
    extraScale = extraScale or 1.0
    local imgW, imgH = nvgImageSize(vg, imgHandle)
    if imgW <= 0 or imgH <= 0 then return end
    local imgAspect = imgW / imgH
    local rectAspect = w / h
    local drawW, drawH
    if imgAspect > rectAspect then
        drawH = h; drawW = h * imgAspect
    else
        drawW = w; drawH = w / imgAspect
    end
    -- Apply extra scale (enlarge from center)
    drawW = drawW * extraScale
    drawH = drawH * extraScale
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

--- Ensure arena background image is loaded (call once per frame, lazy init)
local function EnsureArenaBgLoaded(vg)
    if not arenaBgImg_ or arenaBgImg_ <= 0 then
        arenaBgImg_ = nvgCreateImage(vg, "image/UI/Group 37-2.png", 0)
    end
    if not coinStarImg_ or coinStarImg_ <= 0 then
        coinStarImg_ = nvgCreateImage(vg, "image/UI重置/39a37b5e-2a5b-43b3-b791-39246bdfeb1f.png", 0)
    end
end

--- Draw a coin image with pseudo-rotation (squash width by rotation angle)
--- @param vg userdata NanoVG context
--- @param cx number center X
--- @param cy number center Y
--- @param radius number coin half-height
--- @param rotation number rotation angle (radians) for squash effect
--- @param alpha number opacity 0-255
local function DrawCoinImg(vg, cx, cy, radius, rotation, alpha)
    local img = coinStarImg_
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

-- ============================================================================
-- Constants
-- ============================================================================

-- Grass area ratios within arena_bg.png (measured from image analysis)
-- These define where the battle zone sits inside the full image
local GRASS_LEFT_R   = 0.1     -- left margin / image width
local GRASS_TOP_R    = 0.16    -- top margin / image height (below wooden sign)
local GRASS_WIDTH_R  = 0.825   -- grass width / image width
local GRASS_HEIGHT_R = 0.71    -- grass height / image height

-- Debug: draw battle boundary
local DEBUG_DRAW_BOUNDARY = false

-- Panel dimensions in breeding page (square to match 1:1 image)
local PANEL_W = 336
local PANEL_H = 336

-- Panel grass area (battle zone) computed from image ratios
local PANEL_GRASS_X = math.floor(PANEL_W * GRASS_LEFT_R)    -- ~75
local PANEL_GRASS_Y = math.floor(PANEL_H * GRASS_TOP_R)     -- ~66
local PANEL_GRASS_W = math.floor(PANEL_W * GRASS_WIDTH_R)   -- ~139
local PANEL_GRASS_H = math.floor(PANEL_H * GRASS_HEIGHT_R)  -- ~142

-- Legacy aliases (used by many places)
local PANEL_ARENA_MARGIN = PANEL_GRASS_X
local PANEL_ARENA_TOP    = PANEL_GRASS_Y
local PANEL_ARENA_SIZE   = PANEL_GRASS_W   -- use width for legacy square references

-- Battle arena (reuse Settings values)
local ARENA_SIZE    = Settings.Arena.Size   -- 400
local BALL_RADIUS   = Settings.Ball.Radius  -- 20
local BALL_SPEED    = Settings.Ball.Speed or 150
local SPEED_CAP     = 300
local COLLISION_DMG = 1

-- Timing
local TRANSITION_DURATION = 0.8   -- seconds for panel→fullscreen
local COUNTDOWN_DURATION  = 5     -- countdown seconds
local RESULT_WIN_DURATION = 4.0   -- seconds to show win result
local RESULT_LOSE_DURATION = 2.5

-- Battle rendering in fullscreen (design 1920×1080)
-- Full image rect (the arena_bg.png is drawn at this size)
local BATTLE_IMG_W = 675
local BATTLE_IMG_H = 750
local BATTLE_IMG_X = math.floor((1920 - BATTLE_IMG_W) / 2)  -- centered
local BATTLE_IMG_Y = math.floor((1080 - BATTLE_IMG_H) / 2)  -- vertically centered
local BATTLE_UI_OFFSET_Y = -60  -- UI elements shifted up 60px relative to image

-- Grass area (battle zone) within the fullscreen image
local BATTLE_ARENA_X = BATTLE_IMG_X + math.floor(BATTLE_IMG_W * GRASS_LEFT_R)
local BATTLE_ARENA_Y = BATTLE_IMG_Y + math.floor(BATTLE_IMG_H * GRASS_TOP_R)
local BATTLE_ARENA_W = math.floor(BATTLE_IMG_W * GRASS_WIDTH_R)
local BATTLE_ARENA_H = math.floor(BATTLE_IMG_H * GRASS_HEIGHT_R)
local BATTLE_ARENA_SIZE = BATTLE_ARENA_W  -- legacy alias

-- Ball visual scale (1.0 = normal size)
local BALL_VISUAL_SCALE = 1.0

-- Bottom UI layout (below full image)
local HP_BAR_Y      = BATTLE_IMG_Y + BATTLE_IMG_H + 6
local SKILL_INFO_Y  = HP_BAR_Y + 24
local BOTTOM_BTN_Y  = SKILL_INFO_Y + 65

-- Item bar
local ITEM_BAR_Y = BOTTOM_BTN_Y
local ITEM_BAR_H = 60
local ITEM_SLOT_SIZE = 52
local ITEM_SLOT_GAP  = 12
local ITEM_SLOT_COUNT = 3

-- Bottom buttons
local BTN_W = 140
local BTN_H = 60

-- Screen-to-design coordinate conversion (self-contained, matching Standalone.lua)
local DESIGN_W = Settings.Arena.DesignWidth   -- 1920
local DESIGN_H = Settings.Arena.DesignHeight  -- 1080

local function ScreenToDesignArena(sx, sy)
    local physW = graphics:GetWidth()
    local physH = graphics:GetHeight()
    local curDpr = graphics:GetDPR()
    if curDpr <= 0 then curDpr = 1 end
    local logW = physW / curDpr
    local logH = physH / curDpr
    if logW <= 0 or logH <= 0 then logW, logH = DESIGN_W, DESIGN_H end
    local sc = math.min(logW / DESIGN_W, logH / DESIGN_H)
    if sc <= 0 then sc = 1 end
    local offX = (logW / sc - DESIGN_W) / 2
    local offY = (logH / sc - DESIGN_H) / 2
    return sx / curDpr / sc - offX, sy / curDpr / sc - offY
end

-- Portraits (removed, replaced by VS header and in-arena display)
local PORTRAIT_R = 80
local PLAYER_PORTRAIT_X = 180
local PLAYER_PORTRAIT_Y = 800
local ENEMY_PORTRAIT_X  = 1740
local ENEMY_PORTRAIT_Y  = 250

-- HP percentage for level-based HP
local LEVEL_HP = {
    30, 60, 100, 150, 200, 250, 300, 340, 370, 395,
    415, 430, 445, 458, 468, 477, 484, 490, 495, 500,
}
local MAX_LEVEL = 20

-- Wave configuration (base definition, modified by adaptive difficulty)
local WAVE_DEFS = {
    { count = 1, levelRange = {1, 2} },
    { count = 1, levelRange = {2, 3} },
    { count = 2, levelRange = {2, 4} },
    { count = 2, levelRange = {3, 5} },
    { count = 2, levelRange = {4, 6} },
    { count = 3, levelRange = {4, 7} },
    { count = 3, levelRange = {5, 8} },
    { count = 3, levelRange = {6, 10} },
    { count = 4, levelRange = {7, 12} },
    { count = 4, levelRange = {8, 15} },
}

-- Diamond rewards per wave (10, 20, 30, ... cap at 100)
local function GetWaveDiamondReward(wave)
    return math.min(100, wave * 10)
end

-- Gold rewards per wave: Wave1=20, Wave10=10000, exponential curve
-- 20 → 50 → 120 → 280 → 600 → 1200 → 2400 → 4500 → 7000 → 10000
local WAVE_GOLD_REWARDS = { 20, 50, 120, 280, 600, 1200, 2400, 4500, 7000, 10000 }

-- Skill pool for enemies
local ENEMY_SKILLS = nil  -- populated on first use from SkillRegistry

-- ============================================================================
-- State
-- ============================================================================

local state_ = "IDLE"  -- IDLE | TRANSITION_IN | COUNTDOWN | BATTLE | RESULT | TRANSITION_OUT

-- Panel state (breeding page view)
local panelEnemies_ = {}   -- enemies shown in the panel: { color, level, expression, radius, x, y, vx, vy }
local panelX_, panelY_ = 0, 0  -- panel position in design coords (set by BreedingPage)
local hoverPanel_ = false

-- Current wave
local currentWave_ = 1

-- Adaptive difficulty: consecutive losses on the current wave
local waveLoseStreak_ = 0
-- Difficulty modifiers applied to enemies (computed from waveLoseStreak_)
local diffMod_ = {
    levelReduction = 0,   -- reduce enemy level by this amount
    countReduction = 0,   -- reduce enemy count by this amount
    hpMultiplier = 1.0,   -- multiply enemy HP
    cdMultiplier = 1.0,   -- multiply enemy skill cooldowns (higher = slower)
    speedMultiplier = 1.0, -- multiply enemy movement speed
}

-- Transition animation
local transTimer_ = 0
local transFrom_ = { x = 0, y = 0, w = 0, h = 0 }  -- panel rect in design coords
local transTo_   = { x = BATTLE_IMG_X, y = BATTLE_IMG_Y, w = BATTLE_IMG_W, h = BATTLE_IMG_H }

-- Countdown
local countdownTimer_ = 0

-- Battle state
local battleBalls_   = {}  -- [1]=player, [2..n]=enemies
local aiStates_      = {}
local seState_       = nil  -- SkillExecutor state snapshot
local damagePopups_  = {}
local bloodSplatters_ = {}
local battleElapsed_ = 0
local battleFinished_ = false

-- Player ball reference (farm ball dragged in)
local playerFarmBall_ = nil

-- Result
local resultTimer_  = 0
local resultIsWin_  = false
local resultCoins_  = {}   -- coins spawned on win
local resultGoldAwarded_ = 0
local resultDiamondAwarded_ = 0

-- Gold particle system (auto-collect → fly to gold button)
local arenaGoldParticles_ = {}
local arenaMouseX_, arenaMouseY_ = -9999, -9999  -- mouse in design coords
local arenaDesignW_ = 1920  -- cached designW from ProcessBattleInput
local onGoldIncrement_ = nil  -- callback(amount): called when gold particle arrives
local onCoinCollect_   = nil  -- callback(): called when mouse touches a coin (for SFX)

-- Diamond coin + particle system (auto-collect → fly to diamond button)
local resultDiamondCoins_ = {}   -- diamond coins spawned on win
local arenaDiamondParticles_ = {}
local arenaDiamondCollected_ = 0
local onDiamondIncrement_ = nil  -- callback(amount): called when diamond particle arrives

-- Auto-collect timer
local autoCollectTimer_ = 0
local AUTO_COLLECT_DELAY = 1.2  -- seconds after spawn before auto-collecting starts
local AUTO_COLLECT_INTERVAL = 0.08  -- seconds between each auto-collect
local onWallBounce_    = nil  -- callback(speed): called when ball hits wall
local onSkillFire_     = nil  -- callback(skillId, tier): called when skill is fired
local onBallCollision_ = nil  -- callback(speed): called when balls collide
local onProjectileHit_ = nil  -- callback(damage): called when projectile hits
local onBallDeath_     = nil  -- callback(): called when a ball dies
local onBattleStart_   = nil  -- callback(): called when battle starts
local onBattleVictory_ = nil  -- callback(): called on victory
local onBattleDefeat_  = nil  -- callback(): called on defeat
local onFirstBallDropped_ = nil  -- callback(): 第一次把球放入擂台时触发（教程用）
local arenaGoldCollected_ = 0  -- total gold already collected via particles

-- Item drag state (within arena battle)
local dragItem_ = nil   -- { slot, curX, curY }

-- Item bar animation
local itemBarAnimTimer_ = 0     -- 0→1 slide-in animation
local ITEM_BAR_ANIM_DUR = 0.4  -- seconds to slide in

-- 倒计时暂停（教程用）
local countdownPaused_ = false

-- 道具栏发光（教程用）
local itemBarGlow_ = false

-- Portraits (TriangleFill instances)
local playerTriFill_ = nil
local enemyTriFills_ = {}

-- Elapsed time (for animations)
local elapsed_ = 0
local dragEnemy_ = nil  -- { enemy, curX, curY } dragging enemy in panel for tooltip

-- Callbacks (set by BreedingPage)
local onBattleEnd_ = nil  -- function(isWin, goldEarned)
local getColorGrade_ = nil
local getLevelColor_ = nil
local drawFarmBall_ = nil
local drawBallTooltip_ = nil
local getNameGenerator_ = nil
local getPlayerMaxLevel_ = nil  -- function() -> number: returns player's max ball level
local getUploadableBalls_ = nil -- function() -> table: returns serialized balls for cloud upload

-- AI takeover state
local aiTakeover_ = false        -- AI controls player ball when true

-- Character pool (角色池) state
local poolOpen_ = false          -- Tab key toggles
local poolScrollY_ = 0           -- scroll offset

-- Player identity (fetched on first battle)
local playerNickname_ = nil      -- cached player nickname
local playerUserId_ = nil        -- cached player userId


-- ============================================================================
-- Level helpers
-- ============================================================================

local function GetMaxHp(level)
    local lv = math.max(1, math.min(MAX_LEVEL, level))
    return LEVEL_HP[lv] or 500
end

local function GetColorGrade(level)
    return ((level - 1) % 7) + 1
end

--- Generate 3 vivid random colors for a rainbow ball
local function GenerateRainbowPalette()
    local hueStart = math.random() * 360
    local palette = {}
    for i = 1, 3 do
        local hue = (hueStart + (i - 1) * (100 + math.random() * 40)) % 360
        local sat = 0.75 + math.random() * 0.25
        local val = 0.85 + math.random() * 0.15
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

--- Compute cycling color for a rainbow ball
local function ComputeRainbowColor(rainbowData, elapsed)
    local palette = rainbowData.palette
    local period = rainbowData.period
    local offset = rainbowData.phaseOffset or 0
    local t = ((elapsed + offset) % period) / period * 3.0
    local idx = math.floor(t)
    local frac = t - idx
    frac = frac * frac * (3 - 2 * frac)
    local c1 = palette[(idx % 3) + 1]
    local c2 = palette[((idx + 1) % 3) + 1]
    return math.floor(c1.r + (c2.r - c1.r) * frac),
           math.floor(c1.g + (c2.g - c1.g) * frac),
           math.floor(c1.b + (c2.b - c1.b) * frac)
end

-- Ball-style name generator: (甜品)球 format，与养殖场球球命名一致
local DESSERT_NAMES_ARENA = {
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
local function GenerateBallStyleName()
    local d = DESSERT_NAMES_ARENA[math.random(1, #DESSERT_NAMES_ARENA)]
    return d .. "球"
end

-- Name generator for display nicknames（保留用于多样性，暂未使用）
local NAME_CUTE_PREFIX = {
    "奶盖", "糯米", "软糖", "泡芙", "布丁", "桃桃", "柚子", "橘子",
    "团团", "圆圆", "啵啵", "咕噜", "喵喵", "嘟嘟", "芝士", "奶茶",
}
local NAME_FUNNY_STATE = {
    "暴走", "迷路", "发呆", "躺平", "掉线", "开摆", "偷吃", "逃跑",
    "晕乎", "炸毛", "上头", "翻滚", "犯困", "摸鱼", "快乐", "社恐",
}
local NAME_BALL_WORDS = {
    "球球", "小球", "团子", "丸子", "泡泡", "弹珠", "雪球", "星球",
    "糖球", "毛球", "滚滚", "豆豆", "汤圆", "小丸子", "能量球",
}
local NAME_ANIMALS = {
    "猫猫", "小狗", "奶兔", "仓鼠", "企鹅", "小鹿", "狐狸", "熊猫",
    "海豹", "鸭鸭", "鲸鱼", "刺猬", "松鼠", "考拉", "兔叽",
}
local NAME_FOOD = {
    "奶茶", "可乐", "薯条", "汉堡", "披萨", "火锅", "蛋挞", "布丁",
    "泡芙", "曲奇", "雪糕", "芋圆", "草莓", "西瓜", "饭团",
}
local NAME_COOL_PREFIX = {
    "暗夜", "星河", "烈焰", "疾风", "雷霆", "极寒", "幻影", "银月",
    "黑曜", "破晓", "深渊", "龙魂", "孤影", "流光", "月蚀",
}
local NAME_TITLES = {
    "队长", "王者", "刺客", "骑士", "法师", "勇者", "领主", "魔王",
    "大佬", "萌王", "团长", "船长", "猎人", "咸鱼", "冠军",
}

local function NamePick(arr)
    return arr[math.random(1, #arr)]
end

local NAME_TEMPLATES = {
    function() return NamePick(NAME_CUTE_PREFIX)  .. NamePick(NAME_BALL_WORDS) end,
    function() return NamePick(NAME_FUNNY_STATE)  .. NamePick(NAME_ANIMALS)    end,
    function() return NamePick(NAME_FUNNY_STATE)  .. NamePick(NAME_FOOD)       end,
    function() return NamePick(NAME_COOL_PREFIX)  .. NamePick(NAME_TITLES)     end,
    function() return NamePick(NAME_CUTE_PREFIX)  .. NamePick(NAME_ANIMALS)    end,
    function() return NamePick(NAME_FOOD)         .. NamePick(NAME_TITLES)     end,
}

local function GenerateEnemyName()
    return NamePick(NAME_TEMPLATES)()
end

local ENEMY_EXPRESSIONS = {
    "angry", "determined", "cool", "smug", "surprised",
}

-- ============================================================================
-- Enemy Generation
-- ============================================================================

local function GetEnemySkills()
    if ENEMY_SKILLS then return ENEMY_SKILLS end
    ENEMY_SKILLS = {}
    -- Collect all basic skills from registry
    local all = SkillRegistry.GetAll and SkillRegistry.GetAll()
    if all then
        for _, def in ipairs(all) do
            if def.tier == "normal" or def.tier == nil then
                table.insert(ENEMY_SKILLS, def.id)
            end
        end
    end
    if #ENEMY_SKILLS == 0 then
        ENEMY_SKILLS = { "fireball" }  -- fallback
    end
    return ENEMY_SKILLS
end

local function GenerateEnemyBall(level)
    local skills = GetEnemySkills()
    local skill = skills[math.random(1, #skills)]
    local enhancedSkill = nil
    local ultimateSkill = nil
    if level >= 3 then
        local eSkills = SkillRegistry.GetByTier("enhanced")
        if #eSkills > 0 then
            enhancedSkill = eSkills[math.random(1, #eSkills)].id
        else
            enhancedSkill = skills[math.random(1, #skills)]
        end
    end
    if level >= 6 then
        local uSkills = SkillRegistry.GetByTier("ultimate")
        if #uSkills > 0 then
            ultimateSkill = uSkills[math.random(1, #uSkills)].id
        else
            ultimateSkill = skills[math.random(1, #skills)]
        end
    end

    -- Color from level (use callback if available, otherwise local logic)
    local color
    if getLevelColor_ then
        color = getLevelColor_(level)
    else
        local grade = GetColorGrade(level)
        if grade == 7 then
            local palette = GenerateRainbowPalette()
            local period = 2.0 + math.random() * 2.5
            local phaseOffset = math.random() * 10.0
            color = {
                r = palette[1].r, g = palette[1].g, b = palette[1].b,
                rainbow = true,
                rainbowData = { palette = palette, period = period, phaseOffset = phaseOffset },
            }
        else
            local baseColors = {
                { r = 230, g = 230, b = 235 },
                { r = 80,  g = 210, b = 100 },
                { r = 70,  g = 150, b = 255 },
                { r = 170, g = 80,  b = 230 },
                { r = 255, g = 160, b = 40  },
                { r = 240, g = 60,  b = 60  },
            }
            local base = baseColors[grade] or baseColors[1]
            color = {
                r = math.max(0, math.min(255, base.r + math.random(-15, 15))),
                g = math.max(0, math.min(255, base.g + math.random(-15, 15))),
                b = math.max(0, math.min(255, base.b + math.random(-15, 15))),
                rainbow = false,
            }
        end
    end

    return {
        color = color,
        level = level,
        name = GenerateBallStyleName(),      -- 战斗中球球名：(甜品)球格式
        expression = ENEMY_EXPRESSIONS[math.random(1, #ENEMY_EXPRESSIONS)],
        skill = skill,
        enhancedSkill = enhancedSkill,
        ultimateSkill = ultimateSkill,
        exp = 0,
        radius = 8,  -- panel display radius
        -- Panel physics
        x = 0, y = 0,
        vx = 0, vy = 0,
        -- AI enemy identification
        isAI = true,
        userId = tostring(math.random(10000000000, 99999999999)),
        nickname = GenerateEnemyName(),  -- VS header B侧：组合名格式
    }
end

--- Create an enemy from a cloud pool entry (real player data)
local function CreateEnemyFromCloud(entry)
    local ball = entry.ball or (entry.balls and entry.balls[1])
    if not ball then return nil end
    return {
        color = ball.color or { r = 200, g = 200, b = 200 },
        level = ball.level or 1,
        name = ball.name or "???",
        expression = ball.expression,
        skill = ball.skill,
        enhancedSkill = ball.enhancedSkill,
        ultimateSkill = ball.ultimateSkill,
        hp = ball.hp or ball.maxHp,
        maxHp = ball.maxHp,
        exp = 0,
        radius = 8,
        x = 0, y = 0,
        vx = 0, vy = 0,
        -- Real player identification
        isAI = false,
        userId = tostring(entry.userId or "???"),
        nickname = entry.nickname or tostring(entry.userId or "???"),
    }
end

--- Compute difficulty modifiers from waveLoseStreak_
local function UpdateDifficultyMod()
    local streak = waveLoseStreak_
    if streak <= 0 then
        diffMod_.levelReduction = 0
        diffMod_.countReduction = 0
        diffMod_.hpMultiplier   = 1.0
        diffMod_.cdMultiplier   = 1.0
        diffMod_.speedMultiplier = 1.0
    elseif streak == 1 then
        -- 第1次失败：敌人等级-1，CD变慢10%
        diffMod_.levelReduction = 1
        diffMod_.countReduction = 0
        diffMod_.hpMultiplier   = 1.0
        diffMod_.cdMultiplier   = 1.1
        diffMod_.speedMultiplier = 1.0
    elseif streak == 2 then
        -- 第2次失败：敌人等级-2，少1个敌人，HP×0.85，CD变慢20%
        diffMod_.levelReduction = 2
        diffMod_.countReduction = 1
        diffMod_.hpMultiplier   = 0.85
        diffMod_.cdMultiplier   = 1.2
        diffMod_.speedMultiplier = 0.95
    elseif streak == 3 then
        -- 第3次失败：敌人等级-3，少1个敌人，HP×0.70，CD变慢30%，速度-10%
        diffMod_.levelReduction = 3
        diffMod_.countReduction = 1
        diffMod_.hpMultiplier   = 0.70
        diffMod_.cdMultiplier   = 1.3
        diffMod_.speedMultiplier = 0.9
    else
        -- 4次及以上：敌人等级-4，少2个敌人，HP×0.55，CD变慢50%，速度-20%
        diffMod_.levelReduction = 4
        diffMod_.countReduction = 2
        diffMod_.hpMultiplier   = 0.55
        diffMod_.cdMultiplier   = 1.5
        diffMod_.speedMultiplier = 0.8
    end
    print(string.format("[Arena] Difficulty: streak=%d lvl-%d count-%d hp×%.2f cd×%.2f spd×%.2f",
        streak, diffMod_.levelReduction, diffMod_.countReduction,
        diffMod_.hpMultiplier, diffMod_.cdMultiplier, diffMod_.speedMultiplier))
end

local function SpawnPanelEnemies()
    -- Apply adaptive difficulty
    UpdateDifficultyMod()

    local waveDef = WAVE_DEFS[math.min(currentWave_, #WAVE_DEFS)]
    panelEnemies_ = {}

    -- Adjusted enemy count (at least 1)
    local enemyCount = math.max(1, waveDef.count - diffMod_.countReduction)

    -- Get player's max ball level to bias enemies lower
    local playerMaxLv = (getPlayerMaxLevel_ and getPlayerMaxLevel_()) or nil

    -- Try to use cloud pool entries first
    local pool = ArenaCloud.GetPool()
    local usedPoolIndices = {}

    for i = 1, enemyCount do
        local lo, hi = waveDef.levelRange[1], waveDef.levelRange[2]

        -- Apply level reduction from difficulty
        lo = math.max(1, lo - diffMod_.levelReduction)
        hi = math.max(lo, hi - diffMod_.levelReduction)

        if playerMaxLv and playerMaxLv >= 1 then
            hi = math.max(lo, math.min(hi, playerMaxLv - 1))
        end

        -- Try to find a matching cloud pool entry within level range
        local enemy = nil
        for pi, entry in ipairs(pool) do
            if not usedPoolIndices[pi] then
                local ball = entry.ball or (entry.balls and entry.balls[1])
                if ball and ball.level and ball.level >= lo and ball.level <= hi then
                    enemy = CreateEnemyFromCloud(entry)
                    if enemy then
                        usedPoolIndices[pi] = true
                        break
                    end
                end
            end
        end

        -- Fallback: generate AI enemy
        if not enemy then
            local lv = math.random(lo, hi)
            enemy = GenerateEnemyBall(lv)
        end

        -- Random position inside square arena area
        local r2 = 8
        enemy.x = PANEL_GRASS_X + r2 + math.random() * (PANEL_GRASS_W - r2 * 2)
        enemy.y = PANEL_GRASS_Y + r2 + math.random() * (PANEL_GRASS_H - r2 * 2)
        enemy.vx = (math.random() - 0.5) * 40
        enemy.vy = (math.random() - 0.5) * 40
        enemy.radius = 8
        table.insert(panelEnemies_, enemy)
    end
end

-- ============================================================================
-- Init / Reset
-- ============================================================================

--- 预加载擂台赛所需图片（在 LoadingScreen 或 LoadUIImages 阶段调用）
function ArenaBattle.Preload(vg)
    if not arenaBgImg_ or arenaBgImg_ <= 0 then
        arenaBgImg_ = nvgCreateImage(vg, "image/UI/Group 37-2.png", 0)
    end
    if not coinStarImg_ or coinStarImg_ <= 0 then
        coinStarImg_ = nvgCreateImage(vg, "image/UI重置/39a37b5e-2a5b-43b3-b791-39246bdfeb1f.png", 0)
    end
end

function ArenaBattle.Init(callbacks)
    onBattleEnd_      = callbacks.onBattleEnd
    onGoldIncrement_  = callbacks.onGoldIncrement
    onDiamondIncrement_ = callbacks.onDiamondIncrement
    onCoinCollect_    = callbacks.onCoinCollect
    onWallBounce_     = callbacks.onWallBounce
    onSkillFire_      = callbacks.onSkillFire
    onBallCollision_  = callbacks.onBallCollision
    onProjectileHit_  = callbacks.onProjectileHit
    onBallDeath_      = callbacks.onBallDeath
    onBattleStart_       = callbacks.onBattleStart
    onBattleVictory_     = callbacks.onBattleVictory
    onBattleDefeat_      = callbacks.onBattleDefeat
    onFirstBallDropped_  = callbacks.onFirstBallDropped
    getColorGrade_    = callbacks.getColorGrade or GetColorGrade
    getLevelColor_    = callbacks.getLevelColor
    drawFarmBall_     = callbacks.drawFarmBall
    drawBallTooltip_  = callbacks.drawBallTooltip
    getPlayerMaxLevel_ = callbacks.getPlayerMaxLevel
    getUploadableBalls_ = callbacks.getUploadableBalls

    state_ = "IDLE"
    currentWave_ = 1
    waveLoseStreak_ = 0
    elapsed_ = 0
    dragEnemy_ = nil
    panelEnemies_ = {}
    SpawnPanelEnemies()
end

function ArenaBattle.GetState()
    return state_
end

function ArenaBattle.IsActive()
    return state_ ~= "IDLE"
end

function ArenaBattle.GetCurrentWave()
    return currentWave_
end

--- Get the player's farm ball currently in the arena battle (nil if idle)
function ArenaBattle.GetPlayerFarmBall()
    return playerFarmBall_
end

-- ============================================================================
-- Save / Load
-- ============================================================================

function ArenaBattle.GetSaveData()
    return {
        currentWave = currentWave_,
        waveLoseStreak = waveLoseStreak_,
        enemies = panelEnemies_,
    }
end

function ArenaBattle.LoadSaveData(data)
    if not data then return end
    currentWave_ = data.currentWave or 1
    waveLoseStreak_ = data.waveLoseStreak or 0
    if data.enemies and #data.enemies > 0 then
        panelEnemies_ = data.enemies
    else
        SpawnPanelEnemies()
    end
end

-- ============================================================================
-- Start Battle (called when player drags ball into arena)
-- ============================================================================

function ArenaBattle.StartBattle(farmBall, panelRect)
    if state_ ~= "IDLE" then return false end

    dragEnemy_ = nil  -- clear tooltip
    aiTakeover_ = false  -- reset AI takeover
    playerFarmBall_ = farmBall

    -- Record full panel image rect for transition animation
    -- panelRect is {x, y, w, h} of the full panel (= full image rect)
    transFrom_.x = panelRect.x
    transFrom_.y = panelRect.y
    transFrom_.w = panelRect.w
    transFrom_.h = panelRect.h

    -- Create battle balls
    battleBalls_ = {}
    aiStates_ = {}
    damagePopups_ = {}
    bloodSplatters_ = {}
    battleElapsed_ = 0
    battleFinished_ = false
    resultCoins_ = {}
    resultGoldAwarded_ = 0
    resultDiamondAwarded_ = 0
    arenaGoldParticles_ = {}
    arenaGoldCollected_ = 0
    resultDiamondCoins_ = {}
    arenaDiamondParticles_ = {}
    arenaDiamondCollected_ = 0
    autoCollectTimer_ = 0
    dragItem_ = nil

    -- [1] = player ball (random initial velocity direction)
    local playerHp = GetMaxHp(farmBall.level)
    local sizeGrowth = math.min((farmBall.level - 1) * 2, 30)
    local pAngle = math.random() * math.pi * 2
    table.insert(battleBalls_, {
        farmBall = farmBall,
        x = ARENA_SIZE * 0.25,
        y = ARENA_SIZE / 2,
        vx = math.cos(pAngle) * BALL_SPEED,
        vy = math.sin(pAngle) * BALL_SPEED,
        hp = playerHp,
        maxHp = playerHp,
        alive = true,
        radius = BALL_RADIUS + sizeGrowth,
        color = farmBall.color,
        level = farmBall.level,
        skill = farmBall.skill,
        enhancedSkill = farmBall.enhancedSkill,
        ultimateSkill = farmBall.ultimateSkill,
        skillCd = 0, enhancedCd = 0, ultimateCd = 0,
        skillCdMax = 0, enhancedCdMax = 0, ultimateCdMax = 0,
        slowTimer = 0, slowFactor = 1.0,
        stunTimer = 0, knockbackTimer = 0, pendingWallSlamDmg = 0,
        team = 1,
        isPlayer = true,
    })
    table.insert(aiStates_, BallAI.CreateState())

    -- [2..n] = enemy balls (random initial velocity direction)
    -- Apply adaptive difficulty modifiers
    local hpMul = diffMod_.hpMultiplier
    local cdMul = diffMod_.cdMultiplier
    local spdMul = diffMod_.speedMultiplier
    local enemySpeed = BALL_SPEED * spdMul

    for i, enemy in ipairs(panelEnemies_) do
        local eHp = math.floor(GetMaxHp(enemy.level) * hpMul)
        if eHp < 1 then eHp = 1 end
        local eSizeGrowth = math.min((enemy.level - 1) * 2, 30)
        local eAngle = math.random() * math.pi * 2
        local posAngle = (i / (#panelEnemies_ + 1)) * math.pi * 2
        table.insert(battleBalls_, {
            farmBall = enemy,  -- enemy data used as farmBall reference
            x = ARENA_SIZE * 0.75 + math.cos(posAngle) * ARENA_SIZE * 0.1,
            y = ARENA_SIZE / 2 + math.sin(posAngle) * ARENA_SIZE * 0.1,
            vx = math.cos(eAngle) * enemySpeed,
            vy = math.sin(eAngle) * enemySpeed,
            hp = eHp,
            maxHp = eHp,
            alive = true,
            radius = BALL_RADIUS + eSizeGrowth,
            color = enemy.color,
            level = enemy.level,
            skill = enemy.skill,
            enhancedSkill = enemy.enhancedSkill,
            ultimateSkill = enemy.ultimateSkill,
            skillCd = 1.0 * cdMul, enhancedCd = 2.0 * cdMul, ultimateCd = 3.0 * cdMul,
            skillCdMax = 1.0 * cdMul, enhancedCdMax = 2.0 * cdMul, ultimateCdMax = 3.0 * cdMul,
            slowTimer = 0, slowFactor = 1.0,
            stunTimer = 0, knockbackTimer = 0, pendingWallSlamDmg = 0,
            team = 2,
            isPlayer = false,
            cdMultiplier = cdMul,  -- stored for ongoing CD scaling
            speedMultiplier = spdMul,  -- stored for speed cap
        })
        table.insert(aiStates_, BallAI.CreateState())
    end

    -- SkillExecutor: save global state, create fresh for this battle
    SkillExecutor.Clear()
    seState_ = SkillExecutor.SaveState()

    -- ItemSystem: init for this battle
    ItemSystem.Init()

    -- Create portrait TriangleFills
    local pc = farmBall.color
    playerTriFill_ = TriangleFill.new({
        maxTriangles = 40, spawnRate = 80, triLife = 0.6,
        maxAlpha = 100, sizeMin = 20, sizeMax = 60,
        baseColor = { pc.r, pc.g, pc.b },
    })

    enemyTriFills_ = {}
    for i, enemy in ipairs(panelEnemies_) do
        local ec = enemy.color
        enemyTriFills_[i] = TriangleFill.new({
            maxTriangles = 30, spawnRate = 60, triLife = 0.5,
            maxAlpha = 80, sizeMin = 15, sizeMax = 50,
            baseColor = { ec.r, ec.g, ec.b },
        })
    end

    -- Fetch player identity if not cached
    if not playerNickname_ and clientCloud and clientCloud.userId then
        playerUserId_ = tostring(clientCloud.userId)
        GetUserNickname({
            userIds = { clientCloud.userId },
            onSuccess = function(nicknames)
                if nicknames and #nicknames > 0 then
                    playerNickname_ = nicknames[1].nickname or playerUserId_
                end
            end,
            onError = function()
                playerNickname_ = playerUserId_
            end,
        })
    end

    -- Start transition
    state_ = "TRANSITION_IN"
    transTimer_ = 0
    countdownPaused_ = false  -- 每次开战重置

    -- 触发"首次放入球"教程回调
    if onFirstBallDropped_ then
        onFirstBallDropped_()
    end

    print(string.format("[Arena] Battle starting! Wave %d, Player Lv.%d vs %d enemies",
        currentWave_, farmBall.level, #panelEnemies_))
    return true
end

-- ============================================================================
-- Update
-- ============================================================================

function ArenaBattle.Update(dt)
    if state_ == "IDLE" then
        -- Update panel enemy bouncing
        UpdatePanelEnemies(dt)
        return
    end

    elapsed_ = elapsed_ + dt

    if state_ == "TRANSITION_IN" then
        transTimer_ = transTimer_ + dt
        if transTimer_ >= TRANSITION_DURATION then
            state_ = "COUNTDOWN"
            countdownTimer_ = COUNTDOWN_DURATION
        end

    elseif state_ == "COUNTDOWN" then
        if not countdownPaused_ then
            countdownTimer_ = countdownTimer_ - dt
        end
        if countdownTimer_ <= 0 then
            state_ = "BATTLE"
            battleElapsed_ = 0
            itemBarAnimTimer_ = 0  -- reset item bar slide-in animation
            if onBattleStart_ then onBattleStart_() end
        end

    elseif state_ == "BATTLE" then
        UpdateBattle(dt)

    elseif state_ == "RESULT" then
        resultTimer_ = resultTimer_ + dt
        UpdateResult(dt)
        local duration = resultIsWin_ and RESULT_WIN_DURATION or RESULT_LOSE_DURATION
        if resultTimer_ >= duration then
            state_ = "TRANSITION_OUT"
            transTimer_ = 0
        end

    elseif state_ == "TRANSITION_OUT" then
        transTimer_ = transTimer_ + dt
        if transTimer_ >= TRANSITION_DURATION then
            -- Battle done, return to idle
            -- Subtract gold/diamonds already collected via auto-collect particles
            local goldEarned = math.max(0, resultGoldAwarded_ - arenaGoldCollected_)
            local diamondEarned = math.max(0, resultDiamondAwarded_ - math.floor(arenaDiamondCollected_ + 0.5))
            local isWin = resultIsWin_

            state_ = "IDLE"

            if isWin then
                -- Win: reset lose streak, advance wave
                waveLoseStreak_ = 0
                currentWave_ = currentWave_ + 1
                SpawnPanelEnemies()
            else
                -- Loss: increment lose streak, re-spawn enemies with adjusted difficulty
                waveLoseStreak_ = waveLoseStreak_ + 1
                print(string.format("[Arena] Lose streak: %d — difficulty will be reduced next attempt", waveLoseStreak_))
                SpawnPanelEnemies()
            end

            -- Call onBattleEnd BEFORE clearing playerFarmBall_ so callback can retrieve it
            if onBattleEnd_ then
                onBattleEnd_(isWin, goldEarned, diamondEarned)
            end
            playerFarmBall_ = nil
        end
    end

    -- Update portrait effects
    if playerTriFill_ then playerTriFill_:Update(dt) end
    for _, tf in pairs(enemyTriFills_) do
        if tf then tf:Update(dt) end
    end
end

-- ============================================================================
-- Panel enemy bouncing (in IDLE state)
-- ============================================================================

function UpdatePanelEnemies(dt)
    for _, e in ipairs(panelEnemies_) do
        -- Skip bouncing while being dragged
        if dragEnemy_ and dragEnemy_.enemy == e then goto continue end
        e.x = e.x + e.vx * dt
        e.y = e.y + e.vy * dt
        local r = e.radius
        local minX = PANEL_GRASS_X
        local maxX = PANEL_GRASS_X + PANEL_GRASS_W
        local minY = PANEL_GRASS_Y
        local maxY = PANEL_GRASS_Y + PANEL_GRASS_H
        if e.x - r < minX then e.x = minX + r; e.vx = math.abs(e.vx) end
        if e.x + r > maxX then e.x = maxX - r; e.vx = -math.abs(e.vx) end
        if e.y - r < minY then e.y = minY + r; e.vy = math.abs(e.vy) end
        if e.y + r > maxY then e.y = maxY - r; e.vy = -math.abs(e.vy) end
        ::continue::
    end
end

-- ============================================================================
-- Battle Update (core combat logic, adapted from BreedingPage.UpdateBattle)
-- ============================================================================

function UpdateBattle(dt)
    battleElapsed_ = battleElapsed_ + dt

    -- Animate item bar slide-in
    if itemBarAnimTimer_ < ITEM_BAR_ANIM_DUR then
        itemBarAnimTimer_ = math.min(itemBarAnimTimer_ + dt, ITEM_BAR_ANIM_DUR)
    end

    -- Restore SkillExecutor state for this battle
    SkillExecutor.RestoreState(seState_)

    -- Build flat ball array for SkillExecutor
    local seBalls = {}
    for bi, bb in ipairs(battleBalls_) do
        seBalls[bi] = { x = bb.x, y = bb.y, vx = bb.vx, vy = bb.vy, hp = bb.hp }
    end

    -- Update items
    ItemSystem.Update(dt, seBalls)

    -- Sync item effects back to battleBalls
    for bi, bb in ipairs(battleBalls_) do
        if seBalls[bi] then
            bb.vx = seBalls[bi].vx or bb.vx
            bb.vy = seBalls[bi].vy or bb.vy
            bb.hp = seBalls[bi].hp or bb.hp
        end
    end

    -- AI + Physics for each ball
    for bi, ball in ipairs(battleBalls_) do
        if not ball.alive then goto continue_ball end

        -- Update status effects
        if ball.slowTimer > 0 then
            ball.slowTimer = ball.slowTimer - dt
            if ball.slowTimer <= 0 then ball.slowFactor = 1.0 end
        end
        if ball.stunTimer > 0 then
            ball.stunTimer = ball.stunTimer - dt
        end
        if ball.knockbackTimer > 0 then
            ball.knockbackTimer = ball.knockbackTimer - dt
        end

        -- Cooldowns
        if ball.skillCd > 0 then ball.skillCd = ball.skillCd - dt end
        if ball.enhancedCd > 0 then ball.enhancedCd = ball.enhancedCd - dt end
        if ball.ultimateCd > 0 then ball.ultimateCd = ball.ultimateCd - dt end

        -- Find target (for skill firing only, NOT for movement)
        local targetIdx = nil
        if ball.isPlayer then
            local bestDist = math.huge
            for ti = 2, #battleBalls_ do
                if battleBalls_[ti].alive then
                    local dx = battleBalls_[ti].x - ball.x
                    local dy = battleBalls_[ti].y - ball.y
                    local d = dx * dx + dy * dy
                    if d < bestDist then
                        bestDist = d
                        targetIdx = ti
                    end
                end
            end
        else
            if battleBalls_[1] and battleBalls_[1].alive then
                targetIdx = 1
            end
        end

        -- Default: balls move by their initial velocity + wall bouncing (no AI)
        -- Exception: if AI takeover is enabled, use BallAI for player ball
        if aiTakeover_ and ball.isPlayer and ball.stunTimer <= 0 and ball.knockbackTimer <= 0 and targetIdx then
            local target = battleBalls_[targetIdx]
            local aiState = aiStates_[bi]
            if aiState then
                local aiResult = BallAI.Update(aiState, ball, target, ball.skillCd, 500, dt)
                if aiResult then
                    ball.vx = aiResult.moveVX
                    ball.vy = aiResult.moveVY
                end
            end
        end

        -- Apply speed cap
        local speed = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        local effectiveCap = SPEED_CAP * ball.slowFactor
        if speed > effectiveCap then
            local s = effectiveCap / speed
            ball.vx = ball.vx * s
            ball.vy = ball.vy * s
        end

        -- Move
        ball.x = ball.x + ball.vx * dt
        ball.y = ball.y + ball.vy * dt

        -- Wall bouncing
        local r = ball.radius
        if ball.x - r < 0 then
            ball.x = r; ball.vx = math.abs(ball.vx)
            if onWallBounce_ then onWallBounce_(math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)) end
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        elseif ball.x + r > ARENA_SIZE then
            ball.x = ARENA_SIZE - r; ball.vx = -math.abs(ball.vx)
            if onWallBounce_ then onWallBounce_(math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)) end
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        end
        if ball.y - r < 0 then
            ball.y = r; ball.vy = math.abs(ball.vy)
            if onWallBounce_ then onWallBounce_(math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)) end
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        elseif ball.y + r > ARENA_SIZE then
            ball.y = ARENA_SIZE - r; ball.vy = -math.abs(ball.vy)
            if onWallBounce_ then onWallBounce_(math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)) end
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        end

        -- Fire projectile
        if targetIdx and ball.skillCd <= 0 and ball.stunTimer <= 0 then
            FireProjectile(bi, targetIdx)
        end

        ::continue_ball::
    end

    -- Ball-ball collision
    for i = 1, #battleBalls_ do
        local a = battleBalls_[i]
        if not a.alive then goto skip_col_i end
        for j = i + 1, #battleBalls_ do
            local b = battleBalls_[j]
            if not b.alive then goto skip_col_j end
            -- Only collide if different teams
            if a.team == b.team then goto skip_col_j end

            local dx = b.x - a.x
            local dy = b.y - a.y
            local dist = math.sqrt(dx * dx + dy * dy)
            local minDist = a.radius + b.radius
            if dist < minDist and dist > 0.1 then
                -- Separate
                local overlap = minDist - dist
                local nx, ny = dx / dist, dy / dist
                a.x = a.x - nx * overlap * 0.5
                a.y = a.y - ny * overlap * 0.5
                b.x = b.x + nx * overlap * 0.5
                b.y = b.y + ny * overlap * 0.5
                -- Bounce
                local relVx = a.vx - b.vx
                local relVy = a.vy - b.vy
                local relDot = relVx * nx + relVy * ny
                if relDot > 0 then
                    a.vx = a.vx - relDot * nx
                    a.vy = a.vy - relDot * ny
                    b.vx = b.vx + relDot * nx
                    b.vy = b.vy + relDot * ny
                end
                -- Collision damage
                a.hp = a.hp - COLLISION_DMG
                b.hp = b.hp - COLLISION_DMG
                -- Collision SFX
                if onBallCollision_ then
                    local colSpeed = math.sqrt(relVx * relVx + relVy * relVy)
                    onBallCollision_(colSpeed)
                end
                -- Blood splatter
                local cx = (a.x + b.x) / 2
                local cy = (a.y + b.y) / 2
                SpawnBlood(cx, cy, 4, a.color)
                SpawnBlood(cx, cy, 4, b.color)
            end
            ::skip_col_j::
        end
        ::skip_col_i::
    end

    -- SkillExecutor callbacks (adapted from BreedingPage)
    local seCallbacks = {
        onHit = function(targetTeam, damage, kx, ky, hitType, skillId, proj)
            local tgt = battleBalls_[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.hp = tgt.hp - damage
            -- Apply knockback
            if kx ~= 0 or ky ~= 0 then
                tgt.vx = tgt.vx + kx
                tgt.vy = tgt.vy + ky
                if hitType == "beam" or hitType == "meteor_hit" then
                    tgt.knockbackTimer = 0.3
                    tgt.pendingWallSlamDmg = math.floor(damage * 0.5)
                end
            end
            -- Projectile hit SFX
            if onProjectileHit_ then onProjectileHit_(damage) end
            -- Blood splatter
            local skillDef = SkillRegistry.Get(skillId)
            local hitColor = (skillDef and skillDef.color) or { r = 200, g = 30, b = 30 }
            SpawnBlood(tgt.x, tgt.y, 5 + math.floor(damage * 0.5), hitColor)
            -- Damage popup
            table.insert(damagePopups_, {
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
            local tgt = battleBalls_[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.hp = tgt.hp - dmgTick
            if healTick > 0 then
                local src = battleBalls_[sourceTeam]
                if src and src.alive then
                    src.hp = math.min(src.maxHp, src.hp + healTick)
                end
            end
            SpawnBlood(tgt.x, tgt.y, 2, { r = 180, g = 50, b = 50 })
        end,
        onStun = function(targetTeam, duration)
            local tgt = battleBalls_[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.stunTimer = math.max(tgt.stunTimer, duration)
        end,
        onSlow = function(targetTeam, factor, duration)
            local tgt = battleBalls_[targetTeam]
            if not tgt or not tgt.alive then return end
            tgt.slowFactor = math.min(tgt.slowFactor, factor)
            tgt.slowTimer = math.max(tgt.slowTimer, duration)
        end,
    }

    -- SkillExecutor update
    SkillExecutor.Update(dt, seBalls, seCallbacks)
    SkillExecutor.UpdateDots(dt, seBalls, seCallbacks)
    SkillExecutor.UpdateVisuals(dt, seBalls)

    seState_ = SkillExecutor.SaveState()

    -- Check deaths
    local playerAlive = false
    local enemiesAlive = 0
    for bi, bb in ipairs(battleBalls_) do
        if bb.alive and bb.hp <= 0 then
            bb.alive = false
            if onBallDeath_ then onBallDeath_() end
            SpawnBlood(bb.x, bb.y, 16, bb.color)
            table.insert(damagePopups_, {
                x = bb.x, y = bb.y - bb.radius - 10,
                text = "K.O.",
                elapsed = 0, duration = 1.5,
                color = { r = 255, g = 80, b = 80 },
            })
        end
        if bb.alive then
            if bb.isPlayer then
                playerAlive = true
            else
                enemiesAlive = enemiesAlive + 1
            end
        end
    end

    -- Check battle end
    if not playerAlive then
        -- Player lost
        battleFinished_ = true
        resultIsWin_ = false
        state_ = "RESULT"
        resultTimer_ = 0
        if onBattleDefeat_ then onBattleDefeat_() end
        print("[Arena] Player defeated!")
    elseif enemiesAlive == 0 then
        -- Player won
        battleFinished_ = true
        resultIsWin_ = true
        state_ = "RESULT"
        resultTimer_ = 0
        if onBattleVictory_ then onBattleVictory_() end
        -- Spawn reward: gold from wave table + tiered diamonds
        local waveIdx = math.min(currentWave_, #WAVE_GOLD_REWARDS)
        local reward = WAVE_GOLD_REWARDS[waveIdx] or 100
        resultGoldAwarded_ = reward
        resultDiamondAwarded_ = GetWaveDiamondReward(currentWave_)
        local coinCount = 10
        local perCoin = reward / coinCount
        -- 以玩家球头顶为中心生成金币，避免出现在球体上
        local playerBall = battleBalls_[1]
        local spawnCX = playerBall and playerBall.x or (ARENA_SIZE / 2)
        local spawnCY = playerBall and (playerBall.y - playerBall.radius - 25) or (ARENA_SIZE / 2)
        spawnCX = math.max(40, math.min(ARENA_SIZE - 40, spawnCX))
        spawnCY = math.max(40, math.min(ARENA_SIZE - 40, spawnCY))
        for ci = 1, coinCount do
            local angle = (ci - 1) / coinCount * math.pi * 2 + math.random() * 0.4
            local dist = 30 + math.random() * 80
            local cx = spawnCX + math.cos(angle) * dist
            local cy = spawnCY + math.sin(angle) * dist
            cx = math.max(30, math.min(ARENA_SIZE - 30, cx))
            cy = math.max(30, math.min(ARENA_SIZE - 30, cy))
            table.insert(resultCoins_, {
                x = cx, y = cy,
                visible = true, collected = false,
                value = perCoin,
                wobble = math.random() * math.pi * 2,
                rotation = math.random() * math.pi * 2,
                scale = 0,
                spawnDelay = (ci - 1) * 0.08,
                radius = math.max(30, math.min(52, 24 + math.log(perCoin + 1) / math.log(10) * 9)),
                merged = false,
            })
        end
        -- Spawn diamond coins (if diamonds awarded)
        if resultDiamondAwarded_ > 0 then
            local diamCount = math.min(8, resultDiamondAwarded_)
            local perDiam = resultDiamondAwarded_ / diamCount
            for di = 1, diamCount do
                table.insert(resultDiamondCoins_, {
                    x = 40 + math.random() * (ARENA_SIZE - 80),
                    y = 40 + math.random() * (ARENA_SIZE - 80),
                    visible = true, collected = false,
                    value = perDiam,
                    wobble = math.random() * math.pi * 2,
                    rotation = math.random() * math.pi * 2,
                    scale = 0,
                    spawnDelay = coinCount * 0.08 + (di - 1) * 0.1,
                    radius = math.max(20, math.min(36, 16 + math.log(perDiam + 1) / math.log(10) * 8)),
                })
            end
        end
        autoCollectTimer_ = 0
        print(string.format("[Arena] Victory! Wave %d cleared! Reward: %d gold + %d diamonds",
            currentWave_, reward, resultDiamondAwarded_))
    end

    -- Update blood splatters
    local si = 1
    while si <= #bloodSplatters_ do
        local sp = bloodSplatters_[si]
        sp.elapsed = sp.elapsed + dt
        if sp.elapsed >= sp.life then
            table.remove(bloodSplatters_, si)
        else
            sp.x = sp.x + sp.vx * dt
            sp.y = sp.y + sp.vy * dt
            sp.vx = sp.vx * 0.92
            sp.vy = sp.vy * 0.92
            si = si + 1
        end
    end

    -- Update damage popups
    local dpi = 1
    while dpi <= #damagePopups_ do
        local p = damagePopups_[dpi]
        p.elapsed = p.elapsed + dt
        p.y = p.y - 30 * dt
        if p.elapsed >= p.duration then
            table.remove(damagePopups_, dpi)
        else
            dpi = dpi + 1
        end
    end
end

-- ============================================================================
-- Fire projectile (adapted from BreedingPage.BattleFireProjectile)
-- ============================================================================

function FireProjectile(shooterIdx, targetIdx)
    local shooter = battleBalls_[shooterIdx]
    local target = battleBalls_[targetIdx]
    if not shooter or not target then return end
    if not shooter.alive or not target.alive then return end

    local dx = target.x - shooter.x
    local dy = target.y - shooter.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end

    -- Lead prediction
    local skillDef = SkillRegistry.Get(shooter.skill)
    local projSpeed = skillDef and skillDef.projSpeed or 500
    local tof = dist / projSpeed
    dx = dx + (target.vx or 0) * tof * 0.3
    dy = dy + (target.vy or 0) * tof * 0.3
    dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end

    local dirX, dirY = dx / dist, dy / dist

    -- Laser fires in random direction instead of aiming at target
    if skillDef and skillDef.projType == "laser_emitter" then
        local angle = math.random() * math.pi * 2
        dirX, dirY = math.cos(angle), math.sin(angle)
    end

    -- HP-based skill selection
    local hpPct = shooter.hp / shooter.maxHp
    -- Adaptive difficulty: enemies have slower cooldowns
    local cdScale = shooter.cdMultiplier or 1.0

    -- Thresholds based on level (simplified)
    local enhThreshold = 0.60 + math.min(shooter.level - 1, 19) * 0.018
    local ultThreshold = 0.30 + math.min(shooter.level - 1, 19) * 0.018

    -- Try ultimate
    if shooter.ultimateSkill and shooter.ultimateCd <= 0 and hpPct <= ultThreshold then
        local ultDef = SkillRegistry.Get(shooter.ultimateSkill)
        if ultDef then
            local cd = SkillExecutor.Fire(ultDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.ultimateCd = (cd or 5.0) * 0.5 * cdScale
            shooter.ultimateCdMax = shooter.ultimateCd
            if onSkillFire_ then onSkillFire_(ultDef.id or shooter.ultimateSkill, "ultimate") end
            return
        end
    end

    -- Try enhanced
    if shooter.enhancedSkill and shooter.enhancedCd <= 0 and hpPct <= enhThreshold then
        local enhDef = SkillRegistry.Get(shooter.enhancedSkill)
        if enhDef then
            local cd = SkillExecutor.Fire(enhDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.enhancedCd = (cd or 3.0) * 0.5 * cdScale
            shooter.enhancedCdMax = shooter.enhancedCd
            if onSkillFire_ then onSkillFire_(enhDef.id or shooter.enhancedSkill, "enhanced") end
            return
        end
    end

    -- Basic skill
    if skillDef then
        local cd = SkillExecutor.Fire(skillDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
        shooter.skillCd = (cd or 1.5) * 0.4 * cdScale
        shooter.skillCdMax = shooter.skillCd
        if onSkillFire_ then onSkillFire_(skillDef.id or shooter.skill, "normal") end
    end
end

-- ============================================================================
-- Blood splatters
-- ============================================================================

function SpawnBlood(x, y, count, color)
    for _ = 1, (count or 6) do
        local angle = math.random() * math.pi * 2
        local speed = 40 + math.random() * 120
        table.insert(bloodSplatters_, {
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

-- ============================================================================
-- Result update (coins wobble, etc.)
-- ============================================================================

function UpdateResult(dt)
    if not resultIsWin_ then return end

    local ax = BATTLE_ARENA_X
    local ay = BATTLE_ARENA_Y
    local scaleF = BATTLE_ARENA_W / ARENA_SIZE

    for _, c in ipairs(resultCoins_) do
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

    -- Update diamond coins animation
    for _, c in ipairs(resultDiamondCoins_) do
        if c.visible and not c.collected then
            if c.spawnDelay > 0 then
                c.spawnDelay = c.spawnDelay - dt
            else
                c.wobble = c.wobble + dt * 3.0
                c.rotation = c.rotation + dt * 3.5
                c.scale = math.min(1.0, c.scale + dt * 3.0)
            end
        end
    end

    -- Currency UI target positions (centered gold+diamond bars)
    local currBarW = 200
    local currGap = 10
    local totalBarW = currBarW * 2 + currGap
    local goldBtnCX = (arenaDesignW_ - totalBarW) / 2 + currBarW / 2
    local goldBtnCY = 22 + 42 / 2
    local diamBtnCX = (arenaDesignW_ - totalBarW) / 2 + currBarW + currGap + currBarW / 2
    local diamBtnCY = goldBtnCY

    -- Auto-collect timer
    autoCollectTimer_ = autoCollectTimer_ + dt

    -- Helper: collect a single coin and spawn flight particles
    local function collectCoin(coin, targetX, targetY, particleList, isDiamond)
        coin.visible = false
        coin.collected = true
        if not isDiamond and onCoinCollect_ then onCoinCollect_(coin.value) end
        local miniCount = math.max(3, math.min(8, math.floor(coin.value * 2)))
        local baseFlightTime = 0.7 + math.random() * 0.3
        local perVal = coin.value / miniCount
        local cx = ax + coin.x * scaleF
        local cy = ay + coin.y * scaleF
        for ci = 1, miniCount do
            local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
            local spreadDist = 10 + math.random() * 15
            local delay = (ci - 1) * 0.02 + math.random() * 0.02
            table.insert(particleList, {
                x = cx + math.cos(angle) * spreadDist,
                y = cy + math.sin(angle) * spreadDist,
                startX = cx + math.cos(angle) * spreadDist,
                startY = cy + math.sin(angle) * spreadDist,
                targetX = targetX, targetY = targetY,
                radius = 6 + math.random() * 3,
                elapsed = -delay,
                flightTime = baseFlightTime + math.random() * 0.15,
                rotation = math.random() * math.pi * 2,
                trail = {}, arrived = false,
                goldValue = perVal,
            })
        end
    end

    -- Auto-collect gold coins (staggered, one per interval)
    if autoCollectTimer_ >= AUTO_COLLECT_DELAY then
        local collected = false
        for _, coin in ipairs(resultCoins_) do
            if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.5 then
                collectCoin(coin, goldBtnCX, goldBtnCY, arenaGoldParticles_, false)
                collected = true
                break  -- one coin per interval
            end
        end
        -- Auto-collect diamond coins
        if not collected then
            for _, dc in ipairs(resultDiamondCoins_) do
                if dc.visible and not dc.collected and dc.scale > 0.5 then
                    collectCoin(dc, diamBtnCX, diamBtnCY, arenaDiamondParticles_, true)
                    break
                end
            end
        end
        -- Reset interval (but keep past AUTO_COLLECT_DELAY)
        if autoCollectTimer_ >= AUTO_COLLECT_DELAY + AUTO_COLLECT_INTERVAL then
            autoCollectTimer_ = AUTO_COLLECT_DELAY
        end
    end

    -- Update gold mini-coin particles (flight + arrival)
    local gpi = 1
    while gpi <= #arenaGoldParticles_ do
        local gp = arenaGoldParticles_[gpi]
        gp.elapsed = gp.elapsed + dt

        if gp.elapsed < 0 then
            gpi = gpi + 1
        elseif gp.elapsed >= gp.flightTime then
            if not gp.arrived then
                gp.arrived = true
                if gp.goldValue and gp.goldValue > 0 then
                    arenaGoldCollected_ = arenaGoldCollected_ + gp.goldValue
                    if onGoldIncrement_ then
                        onGoldIncrement_(gp.goldValue)
                    end
                end
            end
            table.remove(arenaGoldParticles_, gpi)
        else
            local t = gp.elapsed / gp.flightTime
            local eased = t < 0.5 and (2 * t * t) or (1 - 2 * (1 - t) * (1 - t))
            local arcY = -math.sin(t * math.pi) * 60
            gp.x = gp.startX + (gp.targetX - gp.startX) * eased
            gp.y = gp.startY + (gp.targetY - gp.startY) * eased + arcY
            gp.rotation = gp.rotation + dt * 12
            table.insert(gp.trail, { x = gp.x, y = gp.y })
            if #gp.trail > 8 then table.remove(gp.trail, 1) end
            gpi = gpi + 1
        end
    end

    -- Update diamond mini-gem particles (flight + arrival)
    local dpi = 1
    while dpi <= #arenaDiamondParticles_ do
        local dp = arenaDiamondParticles_[dpi]
        dp.elapsed = dp.elapsed + dt

        if dp.elapsed < 0 then
            dpi = dpi + 1
        elseif dp.elapsed >= dp.flightTime then
            if not dp.arrived then
                dp.arrived = true
                if dp.goldValue and dp.goldValue > 0 then
                    arenaDiamondCollected_ = arenaDiamondCollected_ + dp.goldValue
                    if onDiamondIncrement_ then
                        onDiamondIncrement_(dp.goldValue)
                    end
                end
            end
            table.remove(arenaDiamondParticles_, dpi)
        else
            local t = dp.elapsed / dp.flightTime
            local eased = t < 0.5 and (2 * t * t) or (1 - 2 * (1 - t) * (1 - t))
            local arcY = -math.sin(t * math.pi) * 50
            dp.x = dp.startX + (dp.targetX - dp.startX) * eased
            dp.y = dp.startY + (dp.targetY - dp.startY) * eased + arcY
            dp.rotation = dp.rotation + dt * 10
            table.insert(dp.trail, { x = dp.x, y = dp.y })
            if #dp.trail > 8 then table.remove(dp.trail, 1) end
            dpi = dpi + 1
        end
    end
end

-- ============================================================================
-- Input Processing
-- ============================================================================

--- Process click on panel (returns true if click consumed)
function ArenaBattle.ProcessPanelClick(mx, my, pressed, px, py)
    if state_ ~= "IDLE" then return false end

    -- Start dragging an enemy ball on press
    if pressed and not dragEnemy_ then
        for i = #panelEnemies_, 1, -1 do
            local e = panelEnemies_[i]
            local ex = px + e.x
            local ey = py + e.y
            local dx = mx - ex
            local dy = my - ey
            if math.sqrt(dx * dx + dy * dy) < e.radius + 8 then
                dragEnemy_ = { enemy = e, curX = ex, curY = ey }
                return true
            end
        end
    end
    return false
end

--- Update drag position + release (called every frame from BreedingPage)
function ArenaBattle.UpdatePanelDrag(mouseDown, mx, my, px, py)
    if not dragEnemy_ then return end

    if mouseDown then
        -- Clamp to grass area bounds
        local e = dragEnemy_.enemy
        local r = e.radius
        local minX = px + PANEL_GRASS_X + r
        local maxX = px + PANEL_GRASS_X + PANEL_GRASS_W - r
        local minY = py + PANEL_GRASS_Y + r
        local maxY = py + PANEL_GRASS_Y + PANEL_GRASS_H - r
        dragEnemy_.curX = math.max(minX, math.min(maxX, mx))
        dragEnemy_.curY = math.max(minY, math.min(maxY, my))
    else
        -- Released → snap enemy back, clear drag
        dragEnemy_ = nil
    end
end

--- Check if a point is over an enemy in the panel (for tooltip display)
function ArenaBattle.GetHoveredEnemy(mx, my, px, py)
    if state_ ~= "IDLE" then return nil end
    for i = #panelEnemies_, 1, -1 do
        local e = panelEnemies_[i]
        local ex = px + e.x
        local ey = py + e.y
        local dx = mx - ex
        local dy = my - ey
        if math.sqrt(dx * dx + dy * dy) < e.radius + 6 then
            return e, ex, ey
        end
    end
    return nil
end

--- Check if point is inside panel rect
function ArenaBattle.IsOverPanel(mx, my, px, py)
    return mx >= px and mx <= px + PANEL_W and my >= py and my <= py + PANEL_H
end

--- Process item drag during battle (self-contained input, matching Standalone.lua pattern)
function ArenaBattle.ProcessBattleInput(_, _, _, _, designW, designH)
    -- Read mouse position directly (matching Standalone.lua's ProcessItemAndButtonInput)
    local mousePos = input.mousePosition
    local mx, my = ScreenToDesignArena(mousePos.x, mousePos.y)
    local dW = designW or DESIGN_W

    -- Track mouse position for coin hover detection
    arenaMouseX_ = mx
    arenaMouseY_ = my
    arenaDesignW_ = dW

    -- === Update drag position unconditionally every frame ===
    if dragItem_ then
        dragItem_.curX = mx
        dragItem_.curY = my
    end

    -- === Check drag release (mouse button released) ===
    local uiBlocked = (UI.GetTopOverlay() ~= nil)
    if dragItem_ and (uiBlocked or not input:GetMouseButtonDown(MOUSEB_LEFT)) then
        log:Write(LOG_INFO, string.format("[DRAG] Released at (%.0f, %.0f)", mx, my))
        if state_ == "BATTLE" then
            local def = ItemSystem.GetDef(dragItem_.slot)
            if def then
                local screenX = mx - BATTLE_ARENA_X
                local screenY = my - BATTLE_ARENA_Y
                if screenX >= 0 and screenX <= BATTLE_ARENA_W and screenY >= 0 and screenY <= BATTLE_ARENA_H then
                    local logicX = screenX * ARENA_SIZE / BATTLE_ARENA_W
                    local logicY = screenY * ARENA_SIZE / BATTLE_ARENA_H
                    ItemSystem.Place(dragItem_.slot, logicX, logicY)
                    log:Write(LOG_INFO, string.format("[DRAG] Placed item at logic (%.0f, %.0f)", logicX, logicY))
                else
                    log:Write(LOG_INFO, "[DRAG] Released outside arena, cancelled")
                end
            end
        end
        dragItem_ = nil
        return
    end

    -- If still dragging, consume input
    if dragItem_ then return end

    -- New interactions only during BATTLE
    if state_ ~= "BATTLE" then return end

    -- Calculate dynamic btnY matching RenderBattle layout exactly
    -- (accounts for multiple enemy HP bars, same formula as RenderBattle)
    local hpBarH = 18  -- 与 RenderBattle 保持一致
    local hpY = BATTLE_IMG_Y + BATTLE_IMG_H + 6 + BATTLE_UI_OFFSET_Y + 100  -- 与 RenderBattle 保持一致

    local enemyCount = 0
    for i = 2, #battleBalls_ do
        if battleBalls_[i] then enemyCount = enemyCount + 1 end
    end
    local eBarH = hpBarH
    local eBarSpacing = 4
    if enemyCount > 1 then
        eBarH = math.max(8, math.floor((hpBarH * 2 + eBarSpacing * (enemyCount - 1)) / enemyCount))
    end
    local totalEnemyBarsH = enemyCount > 0 and (enemyCount * eBarH + (enemyCount - 1) * eBarSpacing) or hpBarH

    local skillY = hpY + math.max(hpBarH, totalEnemyBarsH) + 8  -- 与 RenderBattle 保持一致
    local skillLineH = 22  -- 与 RenderBattle 保持一致
    local btnY = skillY + skillLineH * 3 + 10

    -- HP bar area width matches image width (narrower)
    local hpBarAreaW = BATTLE_IMG_W * 0.8
    local hpBarX = BATTLE_IMG_X + (BATTLE_IMG_W - hpBarAreaW) / 2

    -- === Check mouse press (read directly, skip if UI overlay is open) ===
    if not uiBlocked and input:GetMouseButtonPress(MOUSEB_LEFT) then
        -- Check 自杀 button click (left side)
        local suicideBtnX = hpBarX - 30
        if mx >= suicideBtnX and mx <= suicideBtnX + BTN_W and
           my >= btnY and my <= btnY + BTN_H then
            if battleBalls_[1] and battleBalls_[1].alive then
                battleBalls_[1].hp = 0
            end
            return
        end

        -- Check AI托管 button click (right side)
        local aiBtnX = hpBarX + hpBarAreaW - BTN_W + 30
        if mx >= aiBtnX and mx <= aiBtnX + BTN_W and
           my >= btnY and my <= btnY + BTN_H then
            aiTakeover_ = not aiTakeover_
            return
        end

        -- Item slot clicks (center, 道具栏) — apply same slide offset as rendering
        local itemAnimT = math.min(1, itemBarAnimTimer_ / ITEM_BAR_ANIM_DUR)
        local itemEaseT = 1 - (1 - itemAnimT) * (1 - itemAnimT)
        local itemSlideOffset = (1 - itemEaseT) * 80

        local totalSlotsW = ITEM_SLOT_COUNT * ITEM_SLOT_SIZE + (ITEM_SLOT_COUNT - 1) * ITEM_SLOT_GAP
        local slotsX = (dW - totalSlotsW) / 2
        local slotsY = btnY + itemSlideOffset

        for slot = 1, ITEM_SLOT_COUNT do
            local sx = slotsX + (slot - 1) * (ITEM_SLOT_SIZE + ITEM_SLOT_GAP)
            local hit = mx >= sx and mx <= sx + ITEM_SLOT_SIZE and my >= slotsY and my <= slotsY + ITEM_SLOT_SIZE
            local ready = ItemSystem.IsReady(slot)
            if hit then
                if not ItemSystem.IsUnlocked(slot) then
                    log:Write(LOG_INFO, string.format("[DRAG] Slot %d locked (not purchased)", slot))
                elseif ready then
                    dragItem_ = { slot = slot, startX = mx, startY = my, curX = mx, curY = my }
                    log:Write(LOG_INFO, string.format("[DRAG] Created drag for slot %d at (%.0f, %.0f)", slot, mx, my))
                else
                    log:Write(LOG_INFO, string.format("[DRAG] Slot %d not ready (cooldown)", slot))
                end
                return
            end
        end
    end
end

-- ============================================================================
-- Render: Panel (small view in breeding page)
-- ============================================================================

function ArenaBattle.RenderPanel(vg, fontId, px, py, isDragging, elapsedTime)
    if state_ ~= "IDLE" then return end
    elapsed_ = elapsedTime or elapsed_

    panelX_ = px
    panelY_ = py

    -- Draw full arena background image (no mask, no clipping)
    EnsureArenaBgLoaded(vg)
    if arenaBgImg_ and arenaBgImg_ > 0 then
        local pat = nvgImagePattern(vg, px, py, PANEL_W, PANEL_H, 0, arenaBgImg_, 1.0)
        nvgBeginPath(vg)
        nvgRect(vg, px, py, PANEL_W, PANEL_H)
        nvgFillPaint(vg, pat)
        nvgFill(vg)
    end

    -- Grass area (battle zone) within the image
    local grassX = px + PANEL_GRASS_X
    local grassY = py + PANEL_GRASS_Y

    -- Wave label (white, centered on arena image)
    nvgFontSize(vg, 36)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 230))
    nvgText(vg, px + PANEL_W / 2, py + PANEL_H / 2,
        string.format("第 %d 波", currentWave_), nil)

    -- Debug: draw actual collision boundary (square: W x W)
    if DEBUG_DRAW_BOUNDARY then
        nvgBeginPath(vg)
        nvgRect(vg, grassX, grassY, PANEL_GRASS_W, PANEL_GRASS_W)
        nvgStrokeColor(vg, nvgRGBA(255, 0, 0, 200))
        nvgStrokeWidth(vg, 2)
        nvgStroke(vg)
    end

    -- Draw enemy balls bouncing inside (clipped to grass area)
    nvgSave(vg)
    nvgScissor(vg, grassX, grassY, PANEL_GRASS_W, PANEL_GRASS_H)
    for _, e in ipairs(panelEnemies_) do
        local ex = px + e.x
        local ey = py + e.y
        local r = e.radius
        local c = e.color
        -- Rainbow color cycling for grade 7 panel enemies
        local isPanelRainbow = c and c.rainbow
        if isPanelRainbow then
            local rd = c.rainbowData
            if rd then
                local cr, cg, cb = ComputeRainbowColor(rd, elapsedTime)
                c = { r = cr, g = cg, b = cb, rainbow = true, rainbowData = rd }
            end
        end

        -- Rainbow particles for panel enemies
        if isPanelRainbow and c.rainbowData then
            local rd = c.rainbowData
            for pi = 1, 3 do
                local pAngle = (elapsedTime * (0.9 + pi * 0.35)) + pi * (math.pi * 2 / 3)
                local pDist = r * (1.15 + 0.25 * math.sin(elapsedTime * 2.5 + pi))
                local ppx = ex + math.cos(pAngle) * pDist
                local ppy = ey + math.sin(pAngle) * pDist
                local pAlpha = math.floor(100 + 60 * math.sin(elapsedTime * 3 + pi * 1.5))
                local pSize = 1.5 + 0.5 * math.sin(elapsedTime * 4 + pi)
                local pcr, pcg, pcb = ComputeRainbowColor(rd, elapsedTime + pi * 0.4)
                nvgBeginPath(vg); nvgCircle(vg, ppx, ppy, pSize)
                nvgFillColor(vg, nvgRGBA(pcr, pcg, pcb, pAlpha)); nvgFill(vg)
            end
        end

        -- Ball body
        nvgBeginPath(vg); nvgCircle(vg, ex, ey, r)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 220)); nvgFill(vg)

        -- Highlight
        nvgBeginPath(vg); nvgCircle(vg, ex - r * 0.2, ey - r * 0.2, r * 0.35)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, isPanelRainbow and 100 or 80)); nvgFill(vg)

        -- Expression
        if e.expression then
            Expressions.Draw(vg, e.expression, ex, ey, r)
        end

        -- Level badge
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 8)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 180))
        nvgText(vg, ex, ey + r + 6, string.format("Lv%d", e.level), nil)
    end
    nvgRestore(vg)

    -- (hint text removed)

    -- Dragged enemy: draw at clamped position with highlight + tooltip
    if dragEnemy_ then
        local e = dragEnemy_.enemy
        local dx = dragEnemy_.curX
        local dy = dragEnemy_.curY
        local r = e.radius
        local c = e.color

        -- Pulsing selection ring
        local pulse = 0.6 + 0.4 * math.sin((elapsedTime or 0) * 5)
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, r + 5)
        nvgStrokeColor(vg, nvgRGBA(255, 220, 80, math.floor(200 * pulse)))
        nvgStrokeWidth(vg, 2.5); nvgStroke(vg)

        -- Rainbow color cycling for dragged grade 7 balls
        if c and c.rainbow then
            if c.rainbowData then
                local rc = ComputeRainbowColor(c.rainbowData, elapsedTime or 0)
                c = { r = rc.r, g = rc.g, b = rc.b, rainbow = true, rainbowData = c.rainbowData }
            end
            -- Rainbow glow
            nvgBeginPath(vg); nvgCircle(vg, dx, dy, r * 1.6)
            nvgFillPaint(vg, nvgRadialGradient(vg, dx, dy, r * 0.3, r * 1.6,
                nvgRGBA(c.r, c.g, c.b, 100), nvgRGBA(c.r, c.g, c.b, 0)))
            nvgFill(vg)
            -- Orbiting particles
            for pi = 1, 4 do
                local pAngle = (elapsedTime or 0) * 2.0 + (pi - 1) * (math.pi * 2 / 4)
                local pDist = r * 1.3
                local ptx = dx + math.cos(pAngle) * pDist
                local pty = dy + math.sin(pAngle) * pDist
                local pAlpha = math.floor(120 + 80 * math.sin((elapsedTime or 0) * 3.5 + pi))
                local pOff = (pi - 1) * 0.33
                local prc = ComputeRainbowColor(c.rainbowData or { palette = {{ r = c.r, g = c.g, b = c.b }, { r = c.g, g = c.b, b = c.r }, { r = c.b, g = c.r, b = c.g }}, period = 3.0, phaseOffset = pOff }, (elapsedTime or 0) + pOff)
                nvgBeginPath(vg); nvgCircle(vg, ptx, pty, 3)
                nvgFillColor(vg, nvgRGBA(prc.r, prc.g, prc.b, pAlpha)); nvgFill(vg)
            end
        end

        -- Ball body (drawn on top)
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, r)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 240)); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, dx - r * 0.2, dy - r * 0.2, r * 0.35)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, c.rainbow and 100 or 80)); nvgFill(vg)
        if e.expression then
            Expressions.Draw(vg, e.expression, dx, dy, r)
        end

        -- Draw tooltip via callback
        if drawBallTooltip_ then
            drawBallTooltip_(vg, fontId, dx, dy - r - 8, e, 1920, 1080)
        end
    end
end

function ArenaBattle.GetPanelSize()
    return PANEL_W, PANEL_H
end

-- ============================================================================
-- Render: Full Battle View (transition + countdown + battle + result)
-- ============================================================================

function ArenaBattle.RenderBattle(vg, fontId, designW, designH, elapsedTime)
    if state_ == "IDLE" then return end
    elapsed_ = elapsedTime or elapsed_

    -- Calculate transition interpolation
    local t = 0  -- 0=panel, 1=fullscreen
    if state_ == "TRANSITION_IN" then
        t = math.min(1, transTimer_ / TRANSITION_DURATION)
        t = 1 - (1 - t) * (1 - t) * (1 - t) -- ease out cubic
    elseif state_ == "TRANSITION_OUT" then
        t = 1 - math.min(1, transTimer_ / TRANSITION_DURATION)
        t = 1 - (1 - t) * (1 - t) * (1 - t)
    else
        t = 1
    end

    -- Interpolated full image rect (panel image → fullscreen image)
    local imgX = transFrom_.x + (transTo_.x - transFrom_.x) * t
    local imgY = transFrom_.y + (transTo_.y - transFrom_.y) * t
    local imgW = transFrom_.w + (transTo_.w - transFrom_.w) * t
    local imgH = transFrom_.h + (transTo_.h - transFrom_.h) * t

    -- Compute grass (battle zone) from the interpolated image rect
    local ax = imgX + imgW * GRASS_LEFT_R
    local ay = imgY + imgH * GRASS_TOP_R
    local aw = imgW * GRASS_WIDTH_R
    local ah = imgH * GRASS_HEIGHT_R
    local uiAlpha = t

    -- Scale factors from arena logical coords (ARENA_SIZE) to screen coords
    local scaleF = aw / ARENA_SIZE

    -- ======================================================================
    -- "玩家ID VS 敌人ID" header (screenshot style: large bold text)
    -- ======================================================================
    if t > 0.3 then
        local headerFade = math.min(1, (t - 0.3) / 0.5)
        local headerA = math.floor(255 * headerFade)
        local headerCX = imgX + imgW / 2
        -- Position header on the upper fence area of the image (between image top and grass top)
        local headerY = imgY + (ay - imgY) * 0.65 + BATTLE_UI_OFFSET_Y - 20

        -- Player info (username + ID)
        local pNick = playerNickname_ or "我"
        local pId = playerUserId_ or ""

        -- Collect enemy info list (nickname=组合名用于VS header，name=甜品球用于战斗显示)
        local enemyInfos = {}
        for ei = 2, #battleBalls_ do
            local bb = battleBalls_[ei]
            if bb and bb.farmBall then
                local efb = bb.farmBall
                table.insert(enemyInfos, {
                    nickname = efb.nickname or efb.name or "敌方",
                    userId = efb.userId or "",
                })
            end
        end
        local enemyCount = #enemyInfos

        -- Wave indicator (white, large, centered on arena image)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 72)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(240 * headerFade)))
        nvgText(vg, imgX + imgW / 2, imgY + imgH / 2, string.format("第 %d 波", currentWave_), nil)

        -- Player nickname (left side, bold blue)
        -- Nickname 对齐锚点：右对齐 headerCX-60，底部对齐 headerY-3
        -- ID 独立一行，显示在 nickname 下方
        local nickBaseY = pId ~= "" and (headerY - 14) or (headerY - 3)
        nvgFontSize(vg, 40)
        nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
        -- Shadow
        nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(100 * headerFade)))
        nvgText(vg, headerCX - 58, nickBaseY + 1, pNick, nil)
        -- Main text (blue)
        nvgFillColor(vg, nvgRGBA(40, 120, 255, headerA))
        nvgText(vg, headerCX - 60, nickBaseY, pNick, nil)

        -- Player ID (独立一行，显示在 nickname 下方)
        if pId ~= "" then
            nvgFontSize(vg, 16)
            nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(60, 130, 240, math.floor(180 * headerFade)))
            nvgText(vg, headerCX - 60, nickBaseY + 4, "ID:" .. pId, nil)
        end

        -- "VS" text (center, large bold dark)
        nvgFontSize(vg, 56)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(120 * headerFade)))
        nvgText(vg, headerCX + 2, headerY + 4, "VS", nil)
        nvgFillColor(vg, nvgRGBA(255, 220, 60, headerA))
        nvgText(vg, headerCX, headerY + 2, "VS", nil)

        -- Enemy names + IDs (right side, bold red)
        if enemyCount == 1 then
            local eInfo = enemyInfos[1]
            -- 有 ID 时 nickname 上移，ID 显示在下方
            local eNickBaseY = eInfo.userId ~= "" and (headerY - 14) or (headerY - 3)
            nvgFontSize(vg, 40)
            nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
            -- Shadow
            nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(100 * headerFade)))
            nvgText(vg, headerCX + 62, eNickBaseY + 1, eInfo.nickname, nil)
            -- Main text (red)
            nvgFillColor(vg, nvgRGBA(240, 50, 40, headerA))
            nvgText(vg, headerCX + 60, eNickBaseY, eInfo.nickname, nil)
            -- ID 独立一行，显示在 nickname 下方
            if eInfo.userId ~= "" then
                nvgFontSize(vg, 16)
                nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
                nvgFillColor(vg, nvgRGBA(220, 60, 50, math.floor(180 * headerFade)))
                nvgText(vg, headerCX + 60, eNickBaseY + 4, "ID:" .. eInfo.userId, nil)
            end
        elseif enemyCount > 1 then
            local fontSize = enemyCount <= 3 and 24 or 18
            local lineH = fontSize + 16  -- 名字间距加大10px
            local totalH = enemyCount * lineH
            local startY = headerY - totalH / 2 - fontSize / 2
            for ei, eInfo in ipairs(enemyInfos) do
                local ey = startY + (ei - 1) * lineH
                nvgFontSize(vg, fontSize)
                nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
                nvgFillColor(vg, nvgRGBA(240, 50, 40, headerA))
                nvgText(vg, headerCX + 60, ey, eInfo.nickname, nil)
                -- ID 显示在 nickname 下方（不再跟在右侧）
                if eInfo.userId ~= "" then
                    nvgFontSize(vg, math.max(11, fontSize - 8))
                    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
                    nvgFillColor(vg, nvgRGBA(220, 60, 50, math.floor(160 * headerFade)))
                    nvgText(vg, headerCX + 60, ey + 1, "ID:" .. eInfo.userId, nil)
                end
            end
        end
    end

    -- ======================================================================
    -- Arena background image (full image, no masking)
    -- ======================================================================
    EnsureArenaBgLoaded(vg)
    if arenaBgImg_ > 0 then
        local pat = nvgImagePattern(vg, imgX, imgY, imgW, imgH, 0, arenaBgImg_, uiAlpha)
        nvgBeginPath(vg)
        nvgRect(vg, imgX, imgY, imgW, imgH)
        nvgFillPaint(vg, pat)
        nvgFill(vg)
    end

    -- Debug: draw actual collision boundary (square: aw x aw)
    if DEBUG_DRAW_BOUNDARY then
        nvgBeginPath(vg)
        nvgRect(vg, ax, ay, aw, aw)
        nvgStrokeColor(vg, nvgRGBA(255, 0, 0, 200))
        nvgStrokeWidth(vg, 3)
        nvgStroke(vg)
    end

    -- ======================================================================
    -- Battle content (balls, projectiles, blood, coins) - clipped to arena
    -- ======================================================================
    if state_ == "BATTLE" or state_ == "RESULT" or state_ == "COUNTDOWN" then
        nvgSave(vg)
        nvgScissor(vg, ax, ay, aw, ah)

        -- Placed items
        if state_ ~= "COUNTDOWN" then
            ItemSystem.Draw(vg, ax, ay, fontId, scaleF)
        end

        -- Blood splatters
        for _, sp in ipairs(bloodSplatters_) do
            if sp.elapsed < sp.life then
                local bAlpha = math.floor(200 * (1 - sp.elapsed / sp.life))
                local c = sp.color
                nvgBeginPath(vg); nvgCircle(vg, ax + sp.x * scaleF, ay + sp.y * scaleF, sp.radius * scaleF)
                nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, bAlpha)); nvgFill(vg)
            end
        end

        -- SkillExecutor visuals (projectiles, beams, etc.)
        if seState_ then
            SkillExecutor.RestoreState(seState_)
            nvgSave(vg)
            nvgTranslate(vg, ax, ay)
            nvgScale(vg, scaleF, scaleF)
            SkillExecutor.Draw(vg, 0, 0)
            nvgRestore(vg)
        end

        -- ==================================================================
        -- Draw balls (with name label above, level badge, HP bar)
        -- ==================================================================
        for bi, ball in ipairs(battleBalls_) do
            if ball.alive or (state_ == "RESULT") then
                local bx = ax + ball.x * scaleF
                local by = ay + ball.y * scaleF
                local br = ball.radius * scaleF * BALL_VISUAL_SCALE
                local c = ball.color
                -- Rainbow color cycling for grade 7 balls (unique per ball)
                if c and c.rainbow then
                    local rainbowData = c.rainbowData
                    if not rainbowData then
                        -- Fallback: generate deterministic rainbow data from ball index
                        local seed = bi * 137
                        math.randomseed(seed)
                        rainbowData = {
                            palette = GenerateRainbowPalette(),
                            period = 2.0 + math.random() * 2.5,
                            phaseOffset = math.random() * 10.0,
                        }
                        math.randomseed(os.clock() * 10000)
                        c.rainbowData = rainbowData
                    end
                    local rc = ComputeRainbowColor(rainbowData, elapsed_)
                    c = { r = rc.r, g = rc.g, b = rc.b, rainbow = true, rainbowData = rainbowData }
                end
                local ballAlpha = ball.alive and 230 or 60

                local blvl = ball.level
                local btier = blvl >= 20 and 6 or blvl >= 15 and 5 or blvl >= 10 and 4 or blvl >= 5 and 3 or blvl >= 2 and 2 or 1

                -- Outer glow
                if ball.alive then
                    local glowR = br * (1.2 + btier * 0.1)
                    if c.rainbow then
                        -- Rainbow enhanced glow
                        nvgBeginPath(vg); nvgCircle(vg, bx, by, br * 1.8)
                        nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.3, br * 1.8,
                            nvgRGBA(c.r, c.g, c.b, 90), nvgRGBA(c.r, c.g, c.b, 0)))
                        nvgFill(vg)
                        -- Rainbow orbiting particles
                        local rainbowData = c.rainbowData
                        for pi = 1, 5 do
                            local pa = elapsed_ * 1.8 + (pi - 1) * (math.pi * 2 / 5) + bi * 1.2
                            local pDist = br * 1.4
                            local px = bx + math.cos(pa) * pDist
                            local py = by + math.sin(pa) * pDist
                            local pAlpha = math.floor(130 + 80 * math.sin(elapsed_ * 3.0 + pi * 0.8))
                            local pOff = (pi - 1) * 0.4
                            local prc
                            if rainbowData then
                                prc = ComputeRainbowColor(rainbowData, elapsed_ + pOff)
                            else
                                prc = { r = c.r, g = c.g, b = c.b }
                            end
                            nvgBeginPath(vg); nvgCircle(vg, px, py, 3.5)
                            nvgFillColor(vg, nvgRGBA(prc.r, prc.g, prc.b, pAlpha)); nvgFill(vg)
                        end
                    elseif btier >= 4 then
                        local tierGlowC = btier >= 6 and {255,150,255} or btier >= 5 and {150,200,255} or {255,215,0}
                        local glowA = 20 + btier * 6
                        nvgBeginPath(vg); nvgCircle(vg, bx, by, glowR)
                        nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.3, glowR,
                            nvgRGBA(tierGlowC[1], tierGlowC[2], tierGlowC[3], glowA),
                            nvgRGBA(tierGlowC[1], tierGlowC[2], tierGlowC[3], 0)))
                        nvgFill(vg)
                    end
                    nvgBeginPath(vg); nvgCircle(vg, bx, by, br * 1.3)
                    nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, br * 0.3, br * 1.3,
                        nvgRGBA(c.r, c.g, c.b, c.rainbow and 50 or 25), nvgRGBA(c.r, c.g, c.b, 0)))
                    nvgFill(vg)
                end

                -- Tier ring
                if ball.alive and btier >= 2 then
                    local tierRingC = btier >= 6 and {255,150,255} or btier >= 5 and {150,200,255} or btier >= 4 and {255,220,50} or btier >= 3 and {200,210,220} or {205,150,50}
                    nvgBeginPath(vg); nvgCircle(vg, bx, by, br + 3)
                    nvgStrokeColor(vg, nvgRGBA(tierRingC[1], tierRingC[2], tierRingC[3], 180))
                    nvgStrokeWidth(vg, 2.0 + btier * 0.5); nvgStroke(vg)
                end

                -- Circle-clipped ball body
                nvgSave(vg)
                nvgIntersectScissor(vg, bx - br, by - br, br * 2, br * 2)
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br)
                nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, ballAlpha)); nvgFill(vg)
                if ball.alive then
                    nvgBeginPath(vg); nvgCircle(vg, bx, by, br)
                    nvgFillPaint(vg, nvgRadialGradient(vg, bx - br * 0.2, by - br * 0.2, br * 0.1, br,
                        nvgRGBA(255, 255, 255, c.rainbow and 60 or 40), nvgRGBA(0, 0, 0, 30)))
                    nvgFill(vg)
                    nvgBeginPath(vg); nvgCircle(vg, bx - br * 0.25, by - br * 0.25, br * 0.35)
                    nvgFillColor(vg, nvgRGBA(255, 255, 255, c.rainbow and 80 or 50)); nvgFill(vg)
                end
                -- Sparkles
                if ball.alive and btier >= 5 then
                    local sparkCount = btier == 6 and 6 or 3
                    for si = 1, sparkCount do
                        local sa = elapsed_ * 2.5 + (si - 1) * (math.pi * 2 / sparkCount) + bi * 1.5
                        local sDist = br * 0.7
                        local sx2 = bx + math.cos(sa) * sDist
                        local sy2 = by + math.sin(sa) * sDist
                        local sparkA = math.floor(100 + 80 * math.sin(elapsed_ * 4 + si))
                        nvgBeginPath(vg); nvgCircle(vg, sx2, sy2, 3)
                        nvgFillColor(vg, btier == 6 and nvgRGBA(255,150,255,sparkA) or nvgRGBA(180,220,255,sparkA))
                        nvgFill(vg)
                    end
                end
                -- Expression face
                if ball.alive then
                    local expr = ball.farmBall and ball.farmBall.expression
                    if not expr then expr = ball.expression end
                    if expr then
                        Expressions.Draw(vg, expr, bx, by, br * 0.6)
                    end
                end
                -- Dead X
                if not ball.alive then
                    local xSz = br * 0.4
                    nvgBeginPath(vg)
                    nvgMoveTo(vg, bx - xSz, by - xSz); nvgLineTo(vg, bx + xSz, by + xSz)
                    nvgMoveTo(vg, bx + xSz, by - xSz); nvgLineTo(vg, bx - xSz, by + xSz)
                    nvgStrokeColor(vg, nvgRGBA(255, 50, 50, 180))
                    nvgStrokeWidth(vg, 6); nvgStroke(vg)
                end
                nvgRestore(vg)  -- end circle clip

                -- Ball border
                nvgBeginPath(vg); nvgCircle(vg, bx, by, br)
                nvgStrokeColor(vg, nvgRGBA(c.r, c.g, c.b, ball.alive and 120 or 40))
                nvgStrokeWidth(vg, 2); nvgStroke(vg)

                -- Level badge inside ball (like screenshot shows number)
                if ball.alive then
                    nvgFontFaceId(vg, fontId)
                    nvgFontSize(vg, br * 0.55)
                    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                    nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
                    nvgText(vg, bx, by, tostring(ball.level), nil)
                end

                -- ============ Ball name label above (screenshot: "球球名字") ============
                if ball.alive then
                    local ballName = (ball.farmBall and ball.farmBall.name) or "???"
                    nvgFontFaceId(vg, fontId)
                    nvgFontSize(vg, 14)
                    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
                    if ball.isPlayer then
                        -- Player: bright cyan-blue
                        nvgFillColor(vg, nvgRGBA(100, 200, 255, 230))
                    else
                        -- Enemy: bright red-orange
                        nvgFillColor(vg, nvgRGBA(255, 100, 80, 230))
                    end
                    nvgText(vg, bx, by - br - 18, ballName, nil)
                end

                -- ============ Small HP bar above ball ============
                if ball.alive then
                    local hpW = br * 1.4
                    local hpH = 6
                    local hpX = bx - hpW / 2
                    local hpY = by - br - 14
                    local hpPct = math.max(0, ball.hp / ball.maxHp)
                    nvgBeginPath(vg); nvgRoundedRect(vg, hpX, hpY, hpW, hpH, 2)
                    nvgFillColor(vg, nvgRGBA(0, 0, 0, 160)); nvgFill(vg)
                    if hpPct > 0 then
                        nvgBeginPath(vg); nvgRoundedRect(vg, hpX, hpY, hpW * hpPct, hpH, 2)
                        if ball.isPlayer then
                            -- Player HP: cyan-blue
                            nvgFillColor(vg, nvgRGBA(80, 180, 255, 230)); nvgFill(vg)
                        else
                            -- Enemy HP: red
                            nvgFillColor(vg, nvgRGBA(230, 70, 60, 230)); nvgFill(vg)
                        end
                    end
                end

                -- Stun indicator
                if ball.alive and ball.stunTimer > 0 then
                    nvgBeginPath(vg); nvgCircle(vg, bx, by, br + 6)
                    nvgStrokeColor(vg, nvgRGBA(255, 255, 0, 150))
                    nvgStrokeWidth(vg, 4); nvgStroke(vg)
                    for si = 1, 3 do
                        local sa = elapsed_ * 4 + (si - 1) * (math.pi * 2 / 3)
                        local starX = bx + math.cos(sa) * (br + 15)
                        local starY = by + math.sin(sa) * (br + 15)
                        nvgFontFaceId(vg, fontId); nvgFontSize(vg, 20)
                        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                        nvgFillColor(vg, nvgRGBA(255, 255, 50, 200))
                        nvgText(vg, starX, starY, "★", nil)
                    end
                end
            end
        end

        -- Damage popups
        for _, p in ipairs(damagePopups_) do
            local pFade = 1 - p.elapsed / p.duration
            local dmgAlpha = math.floor(255 * math.max(0, pFade))
            local pc = p.color or { r = 255, g = 80, b = 80 }
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, (p.isEnhanced and 36 or 28) * scaleF)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(dmgAlpha * 0.5)))
            local txt = p.text or string.format("-%.1f", p.damage or 0)
            local popX = ax + p.x * scaleF
            local popY = ay + p.y * scaleF - (1 - pFade) * 30
            nvgText(vg, popX + 2, popY + 2, txt, nil)
            nvgFillColor(vg, nvgRGBA(pc.r, pc.g, pc.b, dmgAlpha))
            nvgText(vg, popX, popY, txt, nil)
        end

        -- Result coins (elliptical rotation style, matching persistent coins)
        if state_ == "RESULT" and resultIsWin_ then
            for _, coin in ipairs(resultCoins_) do
                if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.01 then
                    if not coin.spawnDelay or coin.spawnDelay <= 0 then
                        local cx = ax + coin.x * scaleF
                        local cy = ay + coin.y * scaleF
                        local cs = coin.scale
                        local wobbleY = math.sin(coin.wobble) * 3 * cs
                        local COIN_R = coin.radius * scaleF * cs
                        DrawCoinImg(vg, cx, cy + wobbleY, COIN_R, coin.rotation, math.floor(250 * cs))
                        -- Value label
                        nvgFontFaceId(vg, fontId)
                        nvgFontSize(vg, 18 * scaleF)
                        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                        nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
                        nvgText(vg, cx, cy + wobbleY + COIN_R + 3,
                            string.format("+%d", math.floor(coin.value)), nil)
                    end
                end
            end

            -- Result diamond coins (diamond-shaped gems)
            for _, dc in ipairs(resultDiamondCoins_) do
                if dc.visible and not dc.collected and dc.scale > 0.01 then
                    if not dc.spawnDelay or dc.spawnDelay <= 0 then
                        local dx = ax + dc.x * scaleF
                        local dy = ay + dc.y * scaleF
                        local ds = dc.scale
                        local wobbleY = math.sin(dc.wobble) * 3 * ds
                        local DR = dc.radius * scaleF * ds
                        local dAlpha = math.floor(250 * ds)
                        -- Draw diamond shape
                        nvgBeginPath(vg)
                        nvgMoveTo(vg, dx, dy + wobbleY - DR)
                        nvgLineTo(vg, dx + DR * 0.7, dy + wobbleY - DR * 0.1)
                        nvgLineTo(vg, dx, dy + wobbleY + DR)
                        nvgLineTo(vg, dx - DR * 0.7, dy + wobbleY - DR * 0.1)
                        nvgClosePath(vg)
                        nvgFillColor(vg, nvgRGBA(80, 160, 255, dAlpha))
                        nvgFill(vg)
                        -- Inner highlight
                        nvgBeginPath(vg)
                        nvgMoveTo(vg, dx, dy + wobbleY - DR * 0.7)
                        nvgLineTo(vg, dx + DR * 0.35, dy + wobbleY - DR * 0.05)
                        nvgLineTo(vg, dx, dy + wobbleY + DR * 0.4)
                        nvgLineTo(vg, dx - DR * 0.35, dy + wobbleY - DR * 0.05)
                        nvgClosePath(vg)
                        nvgFillColor(vg, nvgRGBA(180, 220, 255, math.floor(160 * ds)))
                        nvgFill(vg)
                        -- Value label
                        nvgFontFaceId(vg, fontId)
                        nvgFontSize(vg, 18 * scaleF)
                        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                        nvgFillColor(vg, nvgRGBA(120, 200, 255, math.floor(220 * ds)))
                        nvgText(vg, dx, dy + wobbleY + DR + 3,
                            string.format("+%d💎", math.floor(dc.value)), nil)
                    end
                end
            end
        end

        nvgRestore(vg)  -- end arena scissor
    end

    -- Countdown overlay (dark brown)
    if state_ == "COUNTDOWN" then
        local num = math.ceil(countdownTimer_)
        local pulse = 1 + 0.3 * math.sin((countdownTimer_ % 1) * math.pi)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 100 * pulse)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(80, 50, 20, 240))
        nvgText(vg, ax + aw / 2, ay + ah / 2, tostring(num), nil)
    end

    -- Result overlay (dark brown tones)
    if state_ == "RESULT" then
        local resultAlpha = math.min(1, resultTimer_ * 3)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 72)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if resultIsWin_ then
            nvgFillColor(vg, nvgRGBA(130, 80, 10, math.floor(240 * resultAlpha)))
            nvgText(vg, ax + aw / 2, ay + ah / 2 - 50, "胜利!", nil)
            nvgFontSize(vg, 32)
            nvgFillColor(vg, nvgRGBA(120, 75, 15, math.floor(200 * resultAlpha)))
            nvgText(vg, ax + aw / 2, ay + ah / 2 + 20,
                string.format("+%d 金币", resultGoldAwarded_), nil)
            -- Diamond reward line
            if resultDiamondAwarded_ > 0 then
                nvgFontSize(vg, 28)
                nvgFillColor(vg, nvgRGBA(60, 140, 220, math.floor(220 * resultAlpha)))
                nvgText(vg, ax + aw / 2, ay + ah / 2 + 58,
                    string.format("+%d 💎", resultDiamondAwarded_), nil)
            end
        else
            nvgFillColor(vg, nvgRGBA(160, 40, 20, math.floor(220 * resultAlpha)))
            nvgText(vg, ax + aw / 2, ay + ah / 2, "失败...", nil)
        end
    end

    -- ======================================================================
    -- Bottom UI (only when transition is mostly complete)
    -- ======================================================================
    if t > 0.3 then
        local uiFade = math.min(1, (t - 0.3) / 0.7)
        local a = math.floor(255 * uiFade)

        -- Get ball references for HP/skill display
        local playerBall = battleBalls_[1]
        -- Collect all enemy balls
        local enemyBalls = {}
        for ei = 2, #battleBalls_ do
            if battleBalls_[ei] then
                table.insert(enemyBalls, battleBalls_[ei])
            end
        end

        -- ============ Health bars below image (screenshot layout) ============
        local hpBarAreaW = imgW * 0.8  -- narrower than full image
        local hpBarX = imgX + (imgW - hpBarAreaW) / 2
        local hpBarH = 18  -- 血量条加高（文字放大后匹配）
        local hpY = imgY + imgH + 6 + BATTLE_UI_OFFSET_Y + 100  -- 在原基础上再下移50px

        nvgFontFaceId(vg, fontId)

        -- --- Player HP bar (left side, blue-tinted) ---
        local playerBarW = hpBarAreaW * 0.42
        nvgFontSize(vg, 20)  -- 标签字号放大
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(40, 80, 160, a))
        nvgText(vg, hpBarX, hpY - 3, "我方血量", nil)

        local pHpPct = 0
        if playerBall then pHpPct = math.max(0, playerBall.hp / playerBall.maxHp) end
        nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpY, playerBarW, hpBarH, 3)
        nvgFillColor(vg, nvgRGBA(30, 40, 60, a)); nvgFill(vg)
        if pHpPct > 0 then
            nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpY, playerBarW * pHpPct, hpBarH, 3)
            nvgFillColor(vg, nvgRGBA(80, 160, 255, a)); nvgFill(vg)
        end

        -- --- Enemy HP bars (right side, red-tinted, stacked) ---
        local enemyCount = #enemyBalls
        local enemyAreaW = hpBarAreaW * 0.52
        local enemyAreaX = hpBarX + hpBarAreaW - enemyAreaW
        local eBarH = hpBarH
        local eBarSpacing = 4
        -- If multiple enemies, shrink bars to fit
        if enemyCount > 1 then
            eBarH = math.max(8, math.floor((hpBarH * 2 + eBarSpacing * (enemyCount - 1)) / enemyCount))
        end

        nvgFontSize(vg, 20)  -- 标签字号放大
        nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(180, 40, 30, a))
        nvgText(vg, hpBarX + hpBarAreaW, hpY - 3, "敌人血量", nil)

        for ei = 1, enemyCount do
            local eb = enemyBalls[ei]
            local eBarY = hpY + (ei - 1) * (eBarH + eBarSpacing)
            local eHpPct = math.max(0, eb.hp / eb.maxHp)
            local eName = (eb.farmBall and eb.farmBall.name) or ("敌人" .. ei)

            -- Background
            nvgBeginPath(vg); nvgRoundedRect(vg, enemyAreaX, eBarY, enemyAreaW, eBarH, 3)
            nvgFillColor(vg, nvgRGBA(60, 30, 30, a)); nvgFill(vg)

            -- Fill (right-to-left)
            if eHpPct > 0 then
                local fillW = enemyAreaW * eHpPct
                nvgBeginPath(vg); nvgRoundedRect(vg, enemyAreaX + enemyAreaW - fillW, eBarY, fillW, eBarH, 3)
                nvgFillColor(vg, nvgRGBA(220, 60, 50, a)); nvgFill(vg)
            end

            -- Enemy name label on the bar
            if eBarH >= 10 then
                nvgFontSize(vg, math.min(12, eBarH - 2))
                nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(200 * uiFade)))
                nvgText(vg, enemyAreaX + enemyAreaW - 4, eBarY + eBarH / 2, eName, nil)
            end
        end

        -- Calculate total enemy bars height for skill section offset
        local totalEnemyBarsH = enemyCount > 0 and (enemyCount * eBarH + (enemyCount - 1) * eBarSpacing) or hpBarH

        -- ============ Skill info below health bars (screenshot layout) ============
        local skillY = hpY + math.max(hpBarH, totalEnemyBarsH) + 8
        local skillFontSz = 18  -- 技能字号放大
        local skillLineH = 22   -- 行高匹配
        nvgFontSize(vg, skillFontSz)

        -- Helper: draw skill line with cooldown pie chart
        local pieR = 9  -- 饼图半径放大
        local function drawSkillInfo(skillId, label, x, y, align, labelColor, cdVal, cdMax)
            local sName = "无"
            if skillId then
                local def = SkillRegistry.Get(skillId)
                sName = def and def.name or skillId
            end
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, skillFontSz)
            nvgTextAlign(vg, align + NVG_ALIGN_TOP)
            nvgFillColor(vg, labelColor or nvgRGBA(100, 65, 30, a))

            local isLeft = (align == NVG_ALIGN_LEFT)
            local textStr = label .. sName
            -- Offset text to make room for pie chart
            local textX = isLeft and (x + pieR * 2 + 4) or (x - pieR * 2 - 4)
            nvgText(vg, textX, y, textStr, nil)

            -- Draw cooldown pie chart
            local pieCX = isLeft and (x + pieR) or (x - pieR)
            local pieCY = y + skillLineH / 2
            local cdPct = 0
            if cdVal and cdMax and cdMax > 0 and cdVal > 0 then
                cdPct = math.min(1, cdVal / cdMax)
            end

            -- Background circle
            nvgBeginPath(vg)
            nvgCircle(vg, pieCX, pieCY, pieR)
            nvgFillColor(vg, nvgRGBA(60, 60, 60, math.floor(160 * uiFade)))
            nvgFill(vg)

            if cdPct > 0 then
                -- Cooldown pie (clockwise from top)
                local startAngle = -math.pi / 2
                local endAngle = startAngle + cdPct * math.pi * 2
                nvgBeginPath(vg)
                nvgMoveTo(vg, pieCX, pieCY)
                nvgArc(vg, pieCX, pieCY, pieR, startAngle, endAngle, NVG_CW)
                nvgClosePath(vg)
                nvgFillColor(vg, nvgRGBA(200, 60, 40, math.floor(200 * uiFade)))
                nvgFill(vg)
            else
                -- Ready: green fill
                nvgBeginPath(vg)
                nvgCircle(vg, pieCX, pieCY, pieR)
                nvgFillColor(vg, nvgRGBA(60, 200, 80, math.floor(200 * uiFade)))
                nvgFill(vg)
            end

            -- Border
            nvgBeginPath(vg)
            nvgCircle(vg, pieCX, pieCY, pieR)
            nvgStrokeColor(vg, nvgRGBA(255, 255, 255, math.floor(120 * uiFade)))
            nvgStrokeWidth(vg, 1)
            nvgStroke(vg)
        end

        -- Player skills (left-aligned, blue tint)
        local playerSkillColor = nvgRGBA(30, 70, 140, a)
        if playerBall then
            drawSkillInfo(playerBall.skill, "普通技能：", hpBarX + 20, skillY, NVG_ALIGN_LEFT, playerSkillColor,
                playerBall.skillCd, playerBall.skillCdMax)
            drawSkillInfo(playerBall.enhancedSkill, "强化技能：", hpBarX + 20, skillY + skillLineH, NVG_ALIGN_LEFT, playerSkillColor,
                playerBall.enhancedCd, playerBall.enhancedCdMax)
            drawSkillInfo(playerBall.ultimateSkill, "终结技能：", hpBarX + 20, skillY + skillLineH * 2, NVG_ALIGN_LEFT, playerSkillColor,
                playerBall.ultimateCd, playerBall.ultimateCdMax)
        end

        -- Enemy skills (right-aligned, red tint) — show first alive enemy's skills
        local enemySkillBall = nil
        for _, eb in ipairs(enemyBalls) do
            if eb.alive then enemySkillBall = eb; break end
        end
        if not enemySkillBall and #enemyBalls > 0 then enemySkillBall = enemyBalls[1] end
        local enemySkillColor = nvgRGBA(160, 40, 30, a)
        if enemySkillBall then
            drawSkillInfo(enemySkillBall.skill, "普通技能：", hpBarX + hpBarAreaW - 20, skillY, NVG_ALIGN_RIGHT, enemySkillColor,
                enemySkillBall.skillCd, enemySkillBall.skillCdMax)
            drawSkillInfo(enemySkillBall.enhancedSkill, "强化技能：", hpBarX + hpBarAreaW - 20, skillY + skillLineH, NVG_ALIGN_RIGHT, enemySkillColor,
                enemySkillBall.enhancedCd, enemySkillBall.enhancedCdMax)
            drawSkillInfo(enemySkillBall.ultimateSkill, "终结技能：", hpBarX + hpBarAreaW - 20, skillY + skillLineH * 2, NVG_ALIGN_RIGHT, enemySkillColor,
                enemySkillBall.ultimateCd, enemySkillBall.ultimateCdMax)
        end

        -- ============ Bottom buttons + Item bar (screenshot layout) ============
        if state_ == "BATTLE" then
            local btnY = skillY + skillLineH * 3 + 10

            -- "自杀" button (left)
            local suicideBtnX = hpBarX - 30
            nvgBeginPath(vg); nvgRoundedRect(vg, suicideBtnX, btnY, BTN_W, BTN_H, 6)
            nvgFillColor(vg, nvgRGBA(50, 45, 60, a)); nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(180, 180, 190, math.floor(120 * uiFade)))
            nvgStrokeWidth(vg, 2); nvgStroke(vg)
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 24)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
            nvgText(vg, suicideBtnX + BTN_W / 2, btnY + BTN_H / 2, "自杀", nil)

            -- "AI托管" button (right)
            local aiBtnX = hpBarX + hpBarAreaW - BTN_W + 30
            nvgBeginPath(vg); nvgRoundedRect(vg, aiBtnX, btnY, BTN_W, BTN_H, 6)
            if aiTakeover_ then
                nvgFillColor(vg, nvgRGBA(60, 100, 60, a))
            else
                nvgFillColor(vg, nvgRGBA(50, 45, 60, a))
            end
            nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(180, 180, 190, math.floor(120 * uiFade)))
            nvgStrokeWidth(vg, 2); nvgStroke(vg)
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 24)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
            nvgText(vg, aiBtnX + BTN_W / 2, btnY + BTN_H / 2, "AI托管", nil)
            if aiTakeover_ then
                nvgFontSize(vg, 11)
                nvgFillColor(vg, nvgRGBA(100, 255, 100, math.floor(180 * uiFade)))
                nvgText(vg, aiBtnX + BTN_W / 2, btnY + BTN_H + 8, "已启用", nil)
            end

            -- "道具栏" (center) - reuse existing DrawItemBar logic
            DrawItemBar(vg, fontId, designW, designH, uiFade, btnY)
        end

        -- Drag item preview is rendered via RenderDragOverlay (absolute last layer)
        -- to avoid scissor/transform state issues from RenderBattle's pipeline
    end

    -- Gold mini-coin particles (rendered on top of everything, outside arena scissor)
    for _, p in ipairs(arenaGoldParticles_) do
        if p.elapsed >= 0 then
            -- Trail (fading tail)
            for ti = 1, #p.trail do
                local tp = p.trail[ti]
                local ta = math.floor(60 * (ti / #p.trail))
                local tr = p.radius * 0.4 * (ti / #p.trail)
                nvgBeginPath(vg); nvgCircle(vg, tp.x, tp.y, tr)
                nvgFillColor(vg, nvgRGBA(255, 225, 60, ta)); nvgFill(vg)
            end
            -- Coin image (spinning)
            local mcR = p.radius
            DrawCoinImg(vg, p.x, p.y, mcR, p.rotation, 240)
        end
    end

    -- Diamond mini-gem particles (rendered on top of everything)
    for _, p in ipairs(arenaDiamondParticles_) do
        if p.elapsed >= 0 then
            -- Trail (fading blue tail)
            for ti = 1, #p.trail do
                local tp = p.trail[ti]
                local ta = math.floor(60 * (ti / #p.trail))
                local tr = p.radius * 0.4 * (ti / #p.trail)
                nvgBeginPath(vg); nvgCircle(vg, tp.x, tp.y, tr)
                nvgFillColor(vg, nvgRGBA(100, 180, 255, ta)); nvgFill(vg)
            end
            -- Diamond shape (small spinning gem)
            local dr = p.radius
            local px, py = p.x, p.y
            nvgBeginPath(vg)
            nvgMoveTo(vg, px, py - dr)
            nvgLineTo(vg, px + dr * 0.65, py - dr * 0.1)
            nvgLineTo(vg, px, py + dr)
            nvgLineTo(vg, px - dr * 0.65, py - dr * 0.1)
            nvgClosePath(vg)
            nvgFillColor(vg, nvgRGBA(80, 160, 255, 240))
            nvgFill(vg)
            -- Highlight
            nvgBeginPath(vg)
            nvgMoveTo(vg, px, py - dr * 0.6)
            nvgLineTo(vg, px + dr * 0.3, py - dr * 0.05)
            nvgLineTo(vg, px, py + dr * 0.3)
            nvgLineTo(vg, px - dr * 0.3, py - dr * 0.05)
            nvgClosePath(vg)
            nvgFillColor(vg, nvgRGBA(180, 220, 255, 150))
            nvgFill(vg)
        end
    end
end

-- ============================================================================
-- Portrait rendering (with TriangleFill)
-- ============================================================================

function DrawPortrait(vg, fontId, cx, cy, r, ball, triFill, alpha, isPlayer)
    if not ball then return end
    local a = math.floor(255 * alpha)
    local c = ball.color

    -- Background circle with glow
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, r + 8)
    nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, r * 0.5, r + 8,
        nvgRGBA(c.r, c.g, c.b, math.floor(50 * alpha)), nvgRGBA(c.r, c.g, c.b, 0)))
    nvgFill(vg)

    -- Ball body
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
    nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, a)); nvgFill(vg)

    -- TriangleFill inside ball (scissor clipped)
    if triFill then
        nvgSave(vg)
        nvgIntersectScissor(vg, cx - r, cy - r, r * 2, r * 2)
        triFill:RenderCircle(vg, cx, cy, r)
        nvgRestore(vg)
    end

    -- Highlight
    nvgBeginPath(vg); nvgCircle(vg, cx - r * 0.25, cy - r * 0.25, r * 0.35)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(80 * alpha))); nvgFill(vg)

    -- Expression
    local fb = ball.farmBall
    if fb and fb.expression then
        Expressions.Draw(vg, fb.expression, cx, cy, r)
    elseif ball.expression then
        Expressions.Draw(vg, ball.expression, cx, cy, r)
    end

    -- Name & level below portrait
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 16)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(240, 240, 255, a))
    local name = (fb and fb.name) or (ball.farmBall and ball.farmBall.name) or "???"
    nvgText(vg, cx, cy + r + 10, name, nil)

    nvgFontSize(vg, 13)
    nvgFillColor(vg, nvgRGBA(200, 200, 220, math.floor(180 * alpha)))
    nvgText(vg, cx, cy + r + 30, string.format("Lv.%d", ball.level), nil)

    -- HP bar below name
    local hpBarW = r * 1.8
    local hpBarH = 6
    local hpBarX = cx - hpBarW / 2
    local hpBarY = cy + r + 48
    local hpPct = math.max(0, ball.hp / ball.maxHp)

    nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpBarY, hpBarW, hpBarH, 3)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(150 * alpha))); nvgFill(vg)
    if hpPct > 0 then
        local hr = hpPct < 0.5 and 255 or math.floor(255 * (1 - hpPct) * 2)
        local hg = hpPct > 0.5 and 255 or math.floor(255 * hpPct * 2)
        nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpBarY, hpBarW * hpPct, hpBarH, 3)
        nvgFillColor(vg, nvgRGBA(hr, hg, 80, math.floor(220 * alpha))); nvgFill(vg)
    end

    -- Player/enemy indicator
    nvgFontSize(vg, 14)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    if isPlayer then
        nvgFillColor(vg, nvgRGBA(100, 255, 150, a))
        nvgText(vg, cx, cy - r - 6, "★ 我方", nil)
    else
        nvgFillColor(vg, nvgRGBA(255, 100, 100, a))
        nvgText(vg, cx, cy - r - 6, "⚔ 敌方", nil)
    end
end

-- ============================================================================
-- Item bar rendering
-- ============================================================================

function DrawItemBar(vg, fontId, designW, designH, alpha, overrideY)
    -- Slide-in animation: ease-out from bottom
    local animT = math.min(1, itemBarAnimTimer_ / ITEM_BAR_ANIM_DUR)
    local easeT = 1 - (1 - animT) * (1 - animT)  -- ease-out quad
    local slideOffset = (1 - easeT) * 80  -- slide up from 80px below
    local animAlpha = alpha * easeT

    local a = math.floor(255 * animAlpha)
    if a <= 0 then return end

    local totalSlotsW = ITEM_SLOT_COUNT * ITEM_SLOT_SIZE + (ITEM_SLOT_COUNT - 1) * ITEM_SLOT_GAP
    local slotsX = (designW - totalSlotsW) / 2
    local slotsY = (overrideY or ITEM_BAR_Y) + slideOffset

    -- Bar background with glow effect
    local barPadX = 20
    local barPadY = 16
    local barW = totalSlotsW + barPadX * 2
    local barH = ITEM_SLOT_SIZE + barPadY * 2 + 18
    local barX = slotsX - barPadX
    local barY = slotsY - barPadY

    -- Outer glow
    nvgBeginPath(vg); nvgRoundedRect(vg, barX - 4, barY - 4, barW + 8, barH + 8, 14)
    nvgFillPaint(vg, nvgRadialGradient(vg, barX + barW / 2, barY + barH / 2,
        barW * 0.3, barW * 0.6,
        nvgRGBA(100, 60, 180, math.floor(40 * animAlpha)),
        nvgRGBA(100, 60, 180, 0)))
    nvgFill(vg)

    -- 教程道具栏发光：脉冲高亮
    if itemBarGlow_ then
        local glowPulse = 0.5 + 0.5 * math.sin((elapsed_ or 0) * 4.0)
        local glowAlpha = math.floor(120 * glowPulse * animAlpha)
        -- 多层扩散光晕
        for gi = 1, 3 do
            local expand = gi * 6
            nvgBeginPath(vg)
            nvgRoundedRect(vg, barX - expand, barY - expand, barW + expand * 2, barH + expand * 2, 14 + expand)
            nvgStrokeColor(vg, nvgRGBA(255, 220, 60, math.floor(glowAlpha / gi)))
            nvgStrokeWidth(vg, 2.5)
            nvgStroke(vg)
        end
        -- 内层金色填充光
        nvgBeginPath(vg); nvgRoundedRect(vg, barX - 2, barY - 2, barW + 4, barH + 4, 12)
        nvgFillPaint(vg, nvgRadialGradient(vg, barX + barW / 2, barY + barH / 2,
            barW * 0.2, barW * 0.7,
            nvgRGBA(255, 200, 50, math.floor(60 * glowPulse * animAlpha)),
            nvgRGBA(255, 180, 30, 0)))
        nvgFill(vg)
    end

    -- Main background
    nvgBeginPath(vg); nvgRoundedRect(vg, barX, barY, barW, barH, 10)
    nvgFillColor(vg, nvgRGBA(25, 20, 40, math.floor(200 * animAlpha))); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(130, 90, 200, math.floor(140 * animAlpha)))
    nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

    -- Label "道具栏" with icon
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 13)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(200, 180, 240, math.floor(200 * animAlpha)))
    nvgText(vg, designW / 2, slotsY - 2, "🎒 道具栏（拖拽放置）", nil)

    for slot = 1, ITEM_SLOT_COUNT do
        local sx = slotsX + (slot - 1) * (ITEM_SLOT_SIZE + ITEM_SLOT_GAP)
        local sy = slotsY
        local def = ItemSystem.GetDef(slot)
        local cd = ItemSystem.GetCooldown(slot)
        local ready = ItemSystem.IsReady(slot)
        local unlocked = ItemSystem.IsUnlocked(slot)

        -- Slot background with ready/cooldown state
        nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, ITEM_SLOT_SIZE, ITEM_SLOT_SIZE, 8)
        if not unlocked then
            nvgFillColor(vg, nvgRGBA(25, 22, 35, a))
        elseif ready then
            -- Ready: brighter, subtle gradient feel
            nvgFillColor(vg, nvgRGBA(60, 50, 85, a))
        else
            nvgFillColor(vg, nvgRGBA(35, 30, 50, a))
        end
        nvgFill(vg)

        -- Border: glowing when ready
        if not unlocked then
            nvgStrokeColor(vg, nvgRGBA(60, 50, 70, math.floor(80 * animAlpha)))
            nvgStrokeWidth(vg, 1)
        elseif ready then
            local glow = 0.7 + 0.3 * math.sin((elapsed_ or 0) * 2.5 + slot)
            nvgStrokeColor(vg, nvgRGBA(160, 120, 220, math.floor(a * glow)))
            nvgStrokeWidth(vg, 2)
        else
            nvgStrokeColor(vg, nvgRGBA(80, 70, 110, math.floor(80 * animAlpha)))
            nvgStrokeWidth(vg, 1)
        end
        nvgStroke(vg)

        if def then
            -- Emoji icon
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 24)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            local iconAlpha = unlocked and (ready and a or math.floor(100 * animAlpha)) or math.floor(50 * animAlpha)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, iconAlpha))
            nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE / 2 - 3, def.emoji, nil)

            -- Item name below
            nvgFontSize(vg, 10)
            local nameAlpha = unlocked and (ready and math.floor(220 * animAlpha) or math.floor(90 * animAlpha)) or math.floor(40 * animAlpha)
            nvgFillColor(vg, nvgRGBA(190, 180, 220, nameAlpha))
            nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE - 4, def.name, nil)

            if not unlocked then
                -- Locked overlay: dark tint + lock icon
                nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, ITEM_SLOT_SIZE, ITEM_SLOT_SIZE, 8)
                nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(120 * animAlpha))); nvgFill(vg)
                nvgFontSize(vg, 18)
                nvgFillColor(vg, nvgRGBA(255, 200, 100, math.floor(200 * animAlpha)))
                nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE / 2, "🔒", nil)
            elseif not ready and cd > 0 then
                -- Cooldown overlay
                local pct = cd / def.cooldown
                local overlayH = ITEM_SLOT_SIZE * pct
                nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy + ITEM_SLOT_SIZE - overlayH, ITEM_SLOT_SIZE, overlayH, 8)
                nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(140 * animAlpha))); nvgFill(vg)

                -- Cooldown number
                nvgFontSize(vg, 16)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
                nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE / 2,
                    string.format("%.0f", math.ceil(cd)), nil)
            end

            -- "Ready" shimmer for available unlocked slots
            if unlocked and ready then
                local shimmer = math.sin((elapsed_ or 0) * 3 + slot * 1.2)
                if shimmer > 0.6 then
                    local shimA = math.floor((shimmer - 0.6) / 0.4 * 50 * animAlpha)
                    nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, ITEM_SLOT_SIZE, ITEM_SLOT_SIZE, 8)
                    nvgFillColor(vg, nvgRGBA(200, 180, 255, shimA)); nvgFill(vg)
                end
            end
        end
    end
end

-- ============================================================================
-- Drag item preview (simple approach matching Standalone.lua that works)
-- ============================================================================

function DrawDragItem(vg, fontId)
    if not dragItem_ then return end
    local def = ItemSystem.GetDef(dragItem_.slot)
    if not def then return end

    -- Isolate NanoVG state to prevent scissor/transform leaks from previous rendering
    nvgSave(vg)
    nvgResetScissor(vg)
    nvgGlobalAlpha(vg, 1.0)

    local dx, dy = dragItem_.curX, dragItem_.curY
    local scaleF = BATTLE_ARENA_W / ARENA_SIZE  -- logic→screen scale
    local t = elapsed_ or 0

    -- Check if cursor is over the arena
    local relX = dx - BATTLE_ARENA_X
    local relY = dy - BATTLE_ARENA_Y
    local overArena = relX >= 0 and relX <= BATTLE_ARENA_W
                  and relY >= 0 and relY <= BATTLE_ARENA_H

    -- Breathing pulse for range circle
    local pulse = 0.9 + 0.1 * math.sin(t * 3.5)

    -- Item-specific colors
    local fillR, fillG, fillB = 255, 255, 255
    local strokeR, strokeG, strokeB = 255, 255, 255
    local glowR, glowG, glowB = 255, 255, 255
    if def.id == "spider_web" then
        fillR, fillG, fillB = 180, 200, 230
        strokeR, strokeG, strokeB = 200, 220, 255
        glowR, glowG, glowB = 150, 180, 220
    elseif def.id == "thorny_stake" then
        fillR, fillG, fillB = 200, 140, 60
        strokeR, strokeG, strokeB = 240, 170, 80
        glowR, glowG, glowB = 180, 120, 50
    elseif def.id == "micro_blackhole" then
        fillR, fillG, fillB = 130, 60, 220
        strokeR, strokeG, strokeB = 170, 90, 255
        glowR, glowG, glowB = 120, 50, 200
    end

    -- ======= Range circle (only when over arena) =======
    if overArena then
        local screenRadius = def.radius * scaleF * pulse

        -- Outer soft glow
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, screenRadius + 10)
        nvgFillPaint(vg, nvgRadialGradient(vg, dx, dy, screenRadius * 0.5, screenRadius + 10,
            nvgRGBA(glowR, glowG, glowB, 30),
            nvgRGBA(glowR, glowG, glowB, 0)))
        nvgFill(vg)

        -- Range fill (semi-transparent)
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, screenRadius)
        nvgFillColor(vg, nvgRGBA(fillR, fillG, fillB, 35)); nvgFill(vg)

        -- Animated range border (rotating dashes via arcs)
        local segments = 8
        local arcLen = math.pi * 2 / segments * 0.6
        local rotOffset = t * 1.5
        nvgStrokeColor(vg, nvgRGBA(strokeR, strokeG, strokeB, 200))
        nvgStrokeWidth(vg, 2.5)
        for seg = 0, segments - 1 do
            local startA = seg * (math.pi * 2 / segments) + rotOffset
            nvgBeginPath(vg)
            nvgArc(vg, dx, dy, screenRadius, startA, startA + arcLen, NVG_CW)
            nvgStroke(vg)
        end

        -- Inner accent ring
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, screenRadius * 0.15)
        nvgStrokeColor(vg, nvgRGBA(strokeR, strokeG, strokeB, 80))
        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

        -- Crosshair lines
        local chLen = 6
        local chGap = 3
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 120))
        nvgStrokeWidth(vg, 1)
        for _, dir in ipairs({{1,0},{-1,0},{0,1},{0,-1}}) do
            nvgBeginPath(vg)
            nvgMoveTo(vg, dx + dir[1] * chGap, dy + dir[2] * chGap)
            nvgLineTo(vg, dx + dir[1] * (chGap + chLen), dy + dir[2] * (chGap + chLen))
            nvgStroke(vg)
        end
    end

    -- ======= Floating item card (always visible during drag) =======
    -- Card position: offset to top-right of cursor to stay out of the way
    local cardOffX = 30
    local cardOffY = -60
    local cardW = 120
    local cardH = 60
    local cardX = dx + cardOffX
    local cardY = dy + cardOffY

    -- Keep card on screen
    if cardX + cardW > 1900 then cardX = dx - cardOffX - cardW end
    if cardY < 10 then cardY = dy + 20 end

    -- Card background
    nvgBeginPath(vg); nvgRoundedRect(vg, cardX, cardY, cardW, cardH, 8)
    nvgFillColor(vg, nvgRGBA(20, 15, 35, 220)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(strokeR, strokeG, strokeB, 160))
    nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

    -- Emoji + name in card
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 20)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, cardX + 8, cardY + 18, def.emoji, nil)

    nvgFontSize(vg, 14)
    nvgFillColor(vg, nvgRGBA(240, 230, 255, 240))
    nvgText(vg, cardX + 32, cardY + 18, def.name, nil)

    -- Description in card
    nvgFontSize(vg, 11)
    nvgFillColor(vg, nvgRGBA(180, 170, 210, 200))
    nvgText(vg, cardX + 8, cardY + 38, def.desc, nil)

    -- Range info
    nvgFontSize(vg, 10)
    nvgFillColor(vg, nvgRGBA(150, 140, 180, 180))
    nvgText(vg, cardX + 8, cardY + 52, string.format("范围:%d", def.radius), nil)

    -- ======= Dragged icon at cursor (always visible) =======
    -- Shadow under emoji
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 36)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 80))
    nvgText(vg, dx + 2, dy + 2, def.emoji, nil)

    -- Main emoji
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
    nvgText(vg, dx, dy, def.emoji, nil)

    -- ======= Status hint below cursor =======
    nvgFontSize(vg, 13)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    if overArena then
        -- "Release to place" hint
        nvgFillColor(vg, nvgRGBA(100, 255, 150, 220))
        nvgText(vg, dx, dy + 22, "松开放置", nil)
    else
        -- "Drag to arena" hint
        nvgFillColor(vg, nvgRGBA(255, 140, 100, 230))
        nvgText(vg, dx, dy + 22, "拖到擂台内放置", nil)
    end

    -- Restore NanoVG state (matches nvgSave at function start)
    nvgRestore(vg)
end

-- ============================================================================
-- Breeding UI overlay opacity (called by BreedingPage to fade its own UI)
-- Returns 0..1 where 0 = fully visible, 1 = fully hidden
-- ============================================================================

function ArenaBattle.GetBreedingFadeOut()
    if state_ == "IDLE" then return 0 end
    if state_ == "TRANSITION_IN" then
        return math.min(1, transTimer_ / TRANSITION_DURATION)
    end
    if state_ == "TRANSITION_OUT" then
        return 1 - math.min(1, transTimer_ / TRANSITION_DURATION)
    end
    return 1  -- fully hidden during battle/countdown/result
end

-- ============================================================================
-- Character Pool (角色池) - Tab key to toggle
-- ============================================================================

local POOL_W = 360
local POOL_H = 600
local POOL_ENTRY_H = 70    -- height per player entry (single ball, compact)
local POOL_BALL_R = 16      -- ball preview radius (larger for single ball)
local POOL_MARGIN = 12

function ArenaBattle.UpdatePool()
    -- Tab key toggles pool
    if input:GetKeyPress(KEY_TAB) then
        poolOpen_ = not poolOpen_
        if poolOpen_ then
            ArenaCloud.FetchPool()
        end
    end

    -- While pool is open, continuously refresh (FetchPool respects its own short TTL)
    if poolOpen_ then
        ArenaCloud.FetchPool()
    end
end

function ArenaBattle.IsPoolOpen()
    return poolOpen_
end

--- Render the character pool panel (called from BreedingPage)
function ArenaBattle.RenderPool(vg, fontId, designW, designH, elapsedTime)
    if not poolOpen_ then return end

    local pool = ArenaCloud.GetPool()
    local px = designW - POOL_W - 20   -- right side
    local py = 60
    local contentH = math.max(POOL_H, #pool * POOL_ENTRY_H + 60)

    -- Dim background overlay
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, designW, designH)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 80))
    nvgFill(vg)

    -- Panel background
    nvgBeginPath(vg)
    nvgRoundedRect(vg, px, py, POOL_W, POOL_H, 12)
    nvgFillColor(vg, nvgRGBA(30, 25, 45, 230))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(140, 100, 200, 180))
    nvgStrokeWidth(vg, 2)
    nvgStroke(vg)

    -- Title bar
    nvgBeginPath(vg)
    nvgRoundedRect(vg, px, py, POOL_W, 44, 12)
    -- Only round top corners - draw full rect then cover bottom
    nvgFillColor(vg, nvgRGBA(60, 40, 90, 200))
    nvgFill(vg)
    nvgBeginPath(vg)
    nvgRect(vg, px, py + 30, POOL_W, 14)
    nvgFillColor(vg, nvgRGBA(60, 40, 90, 200))
    nvgFill(vg)

    -- Title text
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 20)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 220, 140, 255))
    nvgText(vg, px + POOL_W / 2, py + 22, "全服最新球球", nil)

    -- Hint
    nvgFontSize(vg, 11)
    nvgFillColor(vg, nvgRGBA(180, 160, 200, 150))
    nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgText(vg, px + POOL_W - 12, py + 22, "[Tab] 关闭", nil)

    -- Player count / status
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    if ArenaCloud.IsFetching() then
        local dots = string.rep(".", math.floor(elapsedTime * 2) % 4)
        nvgFillColor(vg, nvgRGBA(200, 200, 100, 180))
        nvgText(vg, px + 12, py + 22, "加载中" .. dots, nil)
    end

    -- Clip content area
    nvgSave(vg)
    nvgScissor(vg, px, py + 44, POOL_W, POOL_H - 44)

    local startY = py + 50 - poolScrollY_

    if #pool == 0 then
        -- Empty state
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(160, 140, 180, 160))
        if ArenaCloud.IsFetching() then
            nvgText(vg, px + POOL_W / 2, py + POOL_H / 2, "正在搜索其他玩家...", nil)
        else
            nvgText(vg, px + POOL_W / 2, py + POOL_H / 2, "暂无其他玩家数据", nil)
            nvgFontSize(vg, 12)
            nvgFillColor(vg, nvgRGBA(140, 120, 160, 120))
            nvgText(vg, px + POOL_W / 2, py + POOL_H / 2 + 24, "等待更多玩家上传球球", nil)
        end
    else
        -- Render each player entry
        for i, entry in ipairs(pool) do
            local ey = startY + (i - 1) * POOL_ENTRY_H

            -- Skip if outside visible area
            if ey + POOL_ENTRY_H < py + 44 or ey > py + POOL_H then
                goto continue_entry
            end

            -- Entry background
            nvgBeginPath(vg)
            nvgRoundedRect(vg, px + POOL_MARGIN, ey, POOL_W - POOL_MARGIN * 2, POOL_ENTRY_H - 6, 8)
            local bgAlpha = (i % 2 == 0) and 30 or 20
            nvgFillColor(vg, nvgRGBA(80, 60, 120, bgAlpha + 40))
            nvgFill(vg)
            nvgStrokeColor(vg, nvgRGBA(120, 90, 170, 60))
            nvgStrokeWidth(vg, 1)
            nvgStroke(vg)

            -- === Single-ball layout: [Ball] [Name/Level/Power] [Time] ===
            local ball = entry.ball or (entry.balls and entry.balls[1])
            local ballCX = px + POOL_MARGIN + 8 + POOL_BALL_R  -- ball center X
            local ballCY = ey + (POOL_ENTRY_H - 6) / 2         -- ball center Y (vertically centered)

            if ball then
                local c = ball.color or { r = 200, g = 200, b = 200 }

                -- Ball body
                nvgBeginPath(vg)
                nvgCircle(vg, ballCX, ballCY, POOL_BALL_R)
                nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 220))
                nvgFill(vg)

                -- Highlight
                nvgBeginPath(vg)
                nvgCircle(vg, ballCX - POOL_BALL_R * 0.2, ballCY - POOL_BALL_R * 0.2, POOL_BALL_R * 0.35)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, 80))
                nvgFill(vg)

                -- Expression
                if ball.expression and Expressions then
                    Expressions.Draw(vg, ball.expression, ballCX, ballCY, POOL_BALL_R)
                end

                -- Skill indicator (small dot at top-right of ball)
                if ball.ultimateSkill then
                    nvgBeginPath(vg)
                    nvgCircle(vg, ballCX + POOL_BALL_R - 2, ballCY - POOL_BALL_R + 2, 4)
                    nvgFillColor(vg, nvgRGBA(255, 80, 80, 200))
                    nvgFill(vg)
                elseif ball.enhancedSkill then
                    nvgBeginPath(vg)
                    nvgCircle(vg, ballCX + POOL_BALL_R - 2, ballCY - POOL_BALL_R + 2, 4)
                    nvgFillColor(vg, nvgRGBA(80, 180, 255, 200))
                    nvgFill(vg)
                end
            end

            -- Text info area (to the right of the ball)
            local textX = ballCX + POOL_BALL_R + 12

            -- Player nickname
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 14)
            nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(100, 200, 255, 220))
            local displayName = entry.nickname or tostring(entry.userId)
            nvgText(vg, textX, ey + 8, displayName, nil)

            -- Ball name + level
            nvgFontSize(vg, 12)
            nvgFillColor(vg, nvgRGBA(220, 220, 240, 200))
            local ballName = ball and ball.name or "?"
            local ballLevel = ball and ball.level or 1
            nvgText(vg, textX, ey + 26, string.format("%s  Lv%d", ballName, ballLevel), nil)

            -- Power
            nvgFontSize(vg, 11)
            nvgFillColor(vg, nvgRGBA(255, 200, 80, 180))
            nvgText(vg, textX, ey + 42, "战力 " .. tostring(entry.power), nil)

            -- Upload time (right-aligned)
            nvgFontSize(vg, 10)
            nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(160, 160, 180, 140))
            local timeStr = ""
            if entry.uploadTime and entry.uploadTime > 0 then
                local elapsed = os.time() - entry.uploadTime
                if elapsed < 60 then
                    timeStr = "刚刚"
                elseif elapsed < 3600 then
                    timeStr = math.floor(elapsed / 60) .. "分钟前"
                elseif elapsed < 86400 then
                    timeStr = math.floor(elapsed / 3600) .. "小时前"
                else
                    timeStr = math.floor(elapsed / 86400) .. "天前"
                end
            end
            if timeStr ~= "" then
                nvgText(vg, px + POOL_W - POOL_MARGIN - 8, ey + 8, timeStr, nil)
            end

            ::continue_entry::
        end
    end

    nvgRestore(vg)

    -- Scrollbar (if content exceeds panel)
    local totalContentH = #pool * POOL_ENTRY_H + 10
    local visibleH = POOL_H - 44
    if totalContentH > visibleH then
        local barH = math.max(30, visibleH * (visibleH / totalContentH))
        local maxScroll = totalContentH - visibleH
        local scrollRatio = poolScrollY_ / maxScroll
        local barY = py + 44 + scrollRatio * (visibleH - barH)

        nvgBeginPath(vg)
        nvgRoundedRect(vg, px + POOL_W - 6, barY, 4, barH, 2)
        nvgFillColor(vg, nvgRGBA(180, 140, 220, 100))
        nvgFill(vg)
    end

    -- Bottom info bar
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 11)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(160, 140, 180, 130))
    nvgText(vg, px + POOL_W / 2, py + POOL_H - 6,
        string.format("共 %d 位玩家", #pool), nil)
end

--- Handle mouse wheel for pool scrolling
function ArenaBattle.HandlePoolScroll(wheelY)
    if not poolOpen_ then return end
    local pool = ArenaCloud.GetPool()
    local totalContentH = #pool * POOL_ENTRY_H + 10
    local visibleH = POOL_H - 44
    local maxScroll = math.max(0, totalContentH - visibleH)

    poolScrollY_ = poolScrollY_ - wheelY * 30
    poolScrollY_ = math.max(0, math.min(maxScroll, poolScrollY_))
end

--- Render drag item overlay on top of everything (called from BreedingPage after all other layers)
function ArenaBattle.RenderDragOverlay(vg, fontId)
    if dragItem_ then
        log:Write(LOG_INFO, string.format("[DRAG] RenderDragOverlay: slot=%d pos=(%.0f,%.0f)", dragItem_.slot, dragItem_.curX, dragItem_.curY))
        DrawDragItem(vg, fontId)
    end
end

-- ============================================================================
-- 教程 API
-- ============================================================================

--- 暂停倒计时（教程用）
function ArenaBattle.PauseCountdown()
    countdownPaused_ = true
    print("[Arena] 倒计时已暂停（教程）")
end

--- 恢复倒计时（教程用）
function ArenaBattle.ResumeCountdown()
    countdownPaused_ = false
    print("[Arena] 倒计时已恢复")
end

--- 设置道具栏发光状态（教程用）
function ArenaBattle.SetItemBarGlow(enabled)
    itemBarGlow_ = enabled
end

return ArenaBattle
