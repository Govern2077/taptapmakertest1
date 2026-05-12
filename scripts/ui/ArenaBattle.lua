-- ============================================================================
-- ArenaBattle.lua - 擂台赛系统（Arena Battle）
-- 模块化设计：由 BreedingPage 集成调用
-- 状态机: IDLE → TRANSITION_IN → COUNTDOWN → BATTLE → RESULT → TRANSITION_OUT
-- ============================================================================

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
-- Constants
-- ============================================================================

-- Panel dimensions in breeding page
local PANEL_W = 200
local PANEL_H = 230

-- Inner square arena inside the panel (bounce area = display area)
local PANEL_ARENA_MARGIN = 20
local PANEL_ARENA_TOP = 48      -- below title text
local PANEL_ARENA_SIZE = PANEL_W - PANEL_ARENA_MARGIN * 2   -- 160×160 square

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
-- Arena is a SQUARE — display border = physics wall boundary
local BATTLE_ARENA_SIZE = 500  -- square arena (width = height)
local BATTLE_ARENA_W = BATTLE_ARENA_SIZE
local BATTLE_ARENA_H = BATTLE_ARENA_SIZE
local BATTLE_ARENA_X = (1920 - BATTLE_ARENA_SIZE) / 2   -- centered horizontally
local BATTLE_ARENA_Y = 120   -- arena top (leave room for VS header)

-- Ball visual scale (1.0 = normal size)
local BALL_VISUAL_SCALE = 1.0

-- Bottom UI layout (below arena)
local HP_BAR_Y      = BATTLE_ARENA_Y + BATTLE_ARENA_H + 12
local SKILL_INFO_Y  = HP_BAR_Y + 30
local BOTTOM_BTN_Y  = SKILL_INFO_Y + 75

-- Item bar
local ITEM_BAR_Y = BOTTOM_BTN_Y
local ITEM_BAR_H = 60
local ITEM_SLOT_SIZE = 52
local ITEM_SLOT_GAP  = 12

-- Bottom buttons
local BTN_W = 140
local BTN_H = 60

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

-- Wave configuration
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

-- Coin rewards per wave
local WAVE_REWARDS = { 20, 40, 60, 100, 150, 200, 300, 450, 600, 1000 }

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

-- Transition animation
local transTimer_ = 0
local transFrom_ = { x = 0, y = 0, w = 0, h = 0 }  -- panel rect in design coords
local transTo_   = { x = BATTLE_ARENA_X, y = BATTLE_ARENA_Y, w = BATTLE_ARENA_W, h = BATTLE_ARENA_H }

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

-- Gold particle system (hover-collect → fly to gold button)
local arenaGoldParticles_ = {}
local arenaMouseX_, arenaMouseY_ = -9999, -9999  -- mouse in design coords
local arenaDesignW_ = 1920  -- cached designW from ProcessBattleInput
local onGoldIncrement_ = nil  -- callback(amount): called when gold particle arrives
local arenaGoldCollected_ = 0  -- total gold already collected via particles

-- Item drag state (within arena battle)
local dragItem_ = nil   -- { slot, curX, curY }

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

-- Simple name generator for enemies
local ENEMY_NAMES = {
    "小霸王", "铁头功", "旋风腿", "暗影刺", "烈焰拳",
    "雷电球", "毒牙虫", "冰霜眼", "巨石手", "疾风翼",
    "钢铁壁", "暗夜爪", "火山弹", "寒冰锥", "狂风斩",
    "雷霆击", "毒雾弹", "冰晶盾", "岩浆流", "飓风眼",
}

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

    -- Color from level
    local grade = GetColorGrade(level)
    local baseColors = {
        { r = 230, g = 230, b = 235 },
        { r = 80,  g = 210, b = 100 },
        { r = 70,  g = 150, b = 255 },
        { r = 170, g = 80,  b = 230 },
        { r = 255, g = 160, b = 40  },
        { r = 240, g = 60,  b = 60  },
        { r = 255, g = 255, b = 255 },
    }
    local base = baseColors[grade] or baseColors[1]
    local color = {
        r = math.max(0, math.min(255, base.r + math.random(-15, 15))),
        g = math.max(0, math.min(255, base.g + math.random(-15, 15))),
        b = math.max(0, math.min(255, base.b + math.random(-15, 15))),
        rainbow = (grade == 7),
    }

    return {
        color = color,
        level = level,
        name = ENEMY_NAMES[math.random(1, #ENEMY_NAMES)],
        expression = ENEMY_EXPRESSIONS[math.random(1, #ENEMY_EXPRESSIONS)],
        skill = skill,
        enhancedSkill = enhancedSkill,
        ultimateSkill = ultimateSkill,
        exp = 0,
        radius = 8,  -- panel display radius
        -- Panel physics
        x = 0, y = 0,
        vx = 0, vy = 0,
    }
end

local function SpawnPanelEnemies()
    local waveDef = WAVE_DEFS[math.min(currentWave_, #WAVE_DEFS)]
    panelEnemies_ = {}

    -- Get player's max ball level to bias enemies lower
    local playerMaxLv = (getPlayerMaxLevel_ and getPlayerMaxLevel_()) or nil

    for i = 1, waveDef.count do
        local lo, hi = waveDef.levelRange[1], waveDef.levelRange[2]

        if playerMaxLv and playerMaxLv >= 1 then
            -- Cap upper bound to (playerMaxLv - 1), at least equal to lo
            hi = math.max(lo, math.min(hi, playerMaxLv - 1))
        end

        local lv = math.random(lo, hi)
        local enemy = GenerateEnemyBall(lv)
        -- Random position inside square arena area
        local r2 = 8  -- enemy radius
        enemy.x = PANEL_ARENA_MARGIN + r2 + math.random() * (PANEL_ARENA_SIZE - r2 * 2)
        enemy.y = PANEL_ARENA_TOP + r2 + math.random() * (PANEL_ARENA_SIZE - r2 * 2)
        enemy.vx = (math.random() - 0.5) * 40
        enemy.vy = (math.random() - 0.5) * 40
        enemy.radius = 8
        table.insert(panelEnemies_, enemy)
    end
end

-- ============================================================================
-- Init / Reset
-- ============================================================================

function ArenaBattle.Init(callbacks)
    onBattleEnd_      = callbacks.onBattleEnd
    onGoldIncrement_  = callbacks.onGoldIncrement
    getColorGrade_    = callbacks.getColorGrade or GetColorGrade
    getLevelColor_    = callbacks.getLevelColor
    drawFarmBall_     = callbacks.drawFarmBall
    drawBallTooltip_  = callbacks.drawBallTooltip
    getPlayerMaxLevel_ = callbacks.getPlayerMaxLevel
    getUploadableBalls_ = callbacks.getUploadableBalls

    state_ = "IDLE"
    currentWave_ = 1
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
    if state_ == "IDLE" then return nil end
    return playerFarmBall_
end

-- ============================================================================
-- Save / Load
-- ============================================================================

function ArenaBattle.GetSaveData()
    return {
        currentWave = currentWave_,
        enemies = panelEnemies_,
    }
end

function ArenaBattle.LoadSaveData(data)
    if not data then return end
    currentWave_ = data.currentWave or 1
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

    -- Record panel position for transition animation
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
    arenaGoldParticles_ = {}
    arenaGoldCollected_ = 0
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
        slowTimer = 0, slowFactor = 1.0,
        stunTimer = 0, knockbackTimer = 0, pendingWallSlamDmg = 0,
        team = 1,
        isPlayer = true,
    })
    table.insert(aiStates_, BallAI.CreateState())

    -- [2..n] = enemy balls (random initial velocity direction)
    for i, enemy in ipairs(panelEnemies_) do
        local eHp = GetMaxHp(enemy.level)
        local eSizeGrowth = math.min((enemy.level - 1) * 2, 30)
        local eAngle = math.random() * math.pi * 2
        local posAngle = (i / (#panelEnemies_ + 1)) * math.pi * 2
        table.insert(battleBalls_, {
            farmBall = enemy,  -- enemy data used as farmBall reference
            x = ARENA_SIZE * 0.75 + math.cos(posAngle) * ARENA_SIZE * 0.1,
            y = ARENA_SIZE / 2 + math.sin(posAngle) * ARENA_SIZE * 0.1,
            vx = math.cos(eAngle) * BALL_SPEED,
            vy = math.sin(eAngle) * BALL_SPEED,
            hp = eHp,
            maxHp = eHp,
            alive = true,
            radius = BALL_RADIUS + eSizeGrowth,
            color = enemy.color,
            level = enemy.level,
            skill = enemy.skill,
            enhancedSkill = enemy.enhancedSkill,
            ultimateSkill = enemy.ultimateSkill,
            skillCd = 1.0, enhancedCd = 2.0, ultimateCd = 3.0,
            slowTimer = 0, slowFactor = 1.0,
            stunTimer = 0, knockbackTimer = 0, pendingWallSlamDmg = 0,
            team = 2,
            isPlayer = false,
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

    -- Start transition
    state_ = "TRANSITION_IN"
    transTimer_ = 0

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
        countdownTimer_ = countdownTimer_ - dt
        if countdownTimer_ <= 0 then
            state_ = "BATTLE"
            battleElapsed_ = 0
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
            -- Subtract gold already collected via hover-particles
            local goldEarned = math.max(0, resultGoldAwarded_ - arenaGoldCollected_)
            local isWin = resultIsWin_

            state_ = "IDLE"

            if isWin then
                -- Advance wave and spawn new enemies
                currentWave_ = currentWave_ + 1
                SpawnPanelEnemies()
            end
            -- else: same enemies remain

            if onBattleEnd_ then
                onBattleEnd_(isWin, goldEarned)
            end
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
        local minX = PANEL_ARENA_MARGIN
        local maxX = PANEL_ARENA_MARGIN + PANEL_ARENA_SIZE
        local minY = PANEL_ARENA_TOP
        local maxY = PANEL_ARENA_TOP + PANEL_ARENA_SIZE
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
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        elseif ball.x + r > ARENA_SIZE then
            ball.x = ARENA_SIZE - r; ball.vx = -math.abs(ball.vx)
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        end
        if ball.y - r < 0 then
            ball.y = r; ball.vy = math.abs(ball.vy)
            if ball.pendingWallSlamDmg > 0 then
                ball.hp = ball.hp - ball.pendingWallSlamDmg
                ball.pendingWallSlamDmg = 0
            end
        elseif ball.y + r > ARENA_SIZE then
            ball.y = ARENA_SIZE - r; ball.vy = -math.abs(ball.vy)
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
        print("[Arena] Player defeated!")
    elseif enemiesAlive == 0 then
        -- Player won
        battleFinished_ = true
        resultIsWin_ = true
        state_ = "RESULT"
        resultTimer_ = 0
        -- Spawn reward coins (fixed 1000¥)
        local reward = 1000
        resultGoldAwarded_ = reward
        local coinCount = 10
        local perCoin = reward / coinCount
        for ci = 1, coinCount do
            table.insert(resultCoins_, {
                x = 40 + math.random() * (ARENA_SIZE - 80),
                y = 40 + math.random() * (ARENA_SIZE - 80),
                visible = true, collected = false,
                value = perCoin,
                wobble = math.random() * math.pi * 2,
                rotation = math.random() * math.pi * 2,
                scale = 0,
                spawnDelay = (ci - 1) * 0.08,
                radius = math.max(12, math.min(26, 10 + math.log(perCoin + 1) / math.log(10) * 5)),
                merged = false,
            })
        end
        print(string.format("[Arena] Victory! Wave %d cleared! Reward: %d gold", currentWave_, reward))
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

    -- Thresholds based on level (simplified)
    local enhThreshold = 0.60 + math.min(shooter.level - 1, 19) * 0.018
    local ultThreshold = 0.30 + math.min(shooter.level - 1, 19) * 0.018

    -- Try ultimate
    if shooter.ultimateSkill and shooter.ultimateCd <= 0 and hpPct <= ultThreshold then
        local ultDef = SkillRegistry.Get(shooter.ultimateSkill)
        if ultDef then
            local cd = SkillExecutor.Fire(ultDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.ultimateCd = (cd or 5.0) * 0.5
            return
        end
    end

    -- Try enhanced
    if shooter.enhancedSkill and shooter.enhancedCd <= 0 and hpPct <= enhThreshold then
        local enhDef = SkillRegistry.Get(shooter.enhancedSkill)
        if enhDef then
            local cd = SkillExecutor.Fire(enhDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
            shooter.enhancedCd = (cd or 3.0) * 0.5
            return
        end
    end

    -- Basic skill
    if skillDef then
        local cd = SkillExecutor.Fire(skillDef, shooterIdx, targetIdx, shooter.x, shooter.y, dirX, dirY)
        shooter.skillCd = (cd or 1.5) * 0.4
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

    -- Hover collection: mouse over coin → spawn particles flying to gold button
    local goldBtnCX = arenaDesignW_ - 30 - 200 / 2  -- same as BreedingPage gold button center
    local goldBtnCY = 22 + 42 / 2

    for _, coin in ipairs(resultCoins_) do
        if coin.visible and not coin.collected and not coin.merged and coin.scale > 0.5 then
            local cx = ax + coin.x * scaleF
            local cy = ay + coin.y * scaleF
            local coinR = coin.radius * scaleF * coin.scale
            local cdx = arenaMouseX_ - cx
            local cdy = arenaMouseY_ - cy
            if cdx * cdx + cdy * cdy < (coinR + 8) * (coinR + 8) then
                coin.visible = false
                coin.collected = true
                -- Spawn mini particles
                local miniCount = math.max(3, math.floor(coin.value * 2))
                if miniCount > 8 then miniCount = 8 end
                local baseFlightTime = math.max(0.5, math.min(1.5, coin.value / 1000))
                local perParticleGold = coin.value / miniCount
                for ci = 1, miniCount do
                    local angle = (ci - 1) / miniCount * math.pi * 2 + math.random() * 0.3
                    local spreadDist = 10 + math.random() * 15
                    local delay = (ci - 1) * 0.02 + math.random() * 0.02
                    table.insert(arenaGoldParticles_, {
                        x = cx + math.cos(angle) * spreadDist,
                        y = cy + math.sin(angle) * spreadDist,
                        startX = cx + math.cos(angle) * spreadDist,
                        startY = cy + math.sin(angle) * spreadDist,
                        targetX = goldBtnCX, targetY = goldBtnCY,
                        radius = 6 + math.random() * 3,
                        elapsed = -delay,
                        flightTime = baseFlightTime + math.random() * 0.15,
                        rotation = math.random() * math.pi * 2,
                        trail = {}, arrived = false,
                        goldValue = perParticleGold,
                    })
                end
                break  -- one coin per frame
            end
        end
    end

    -- Update gold mini-coin particles (flight + arrival)
    local gpi = 1
    while gpi <= #arenaGoldParticles_ do
        local gp = arenaGoldParticles_[gpi]
        gp.elapsed = gp.elapsed + dt

        if gp.elapsed < 0 then
            -- Still waiting (staggered launch delay)
            gpi = gpi + 1
        elseif gp.elapsed >= gp.flightTime then
            -- Arrived at gold button
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
            -- Flying toward target with ease-in-out curve
            local t = gp.elapsed / gp.flightTime  -- 0→1
            local eased = t < 0.5 and (2 * t * t) or (1 - 2 * (1 - t) * (1 - t))
            local arcY = -math.sin(t * math.pi) * 60
            gp.x = gp.startX + (gp.targetX - gp.startX) * eased
            gp.y = gp.startY + (gp.targetY - gp.startY) * eased + arcY
            -- Spin the mini coin
            gp.rotation = gp.rotation + dt * 12
            -- Record trail
            table.insert(gp.trail, { x = gp.x, y = gp.y })
            if #gp.trail > 8 then
                table.remove(gp.trail, 1)
            end
            gpi = gpi + 1
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
        -- Clamp to square arena bounds
        local e = dragEnemy_.enemy
        local r = e.radius
        local minX = px + PANEL_ARENA_MARGIN + r
        local maxX = px + PANEL_ARENA_MARGIN + PANEL_ARENA_SIZE - r
        local minY = py + PANEL_ARENA_TOP + r
        local maxY = py + PANEL_ARENA_TOP + PANEL_ARENA_SIZE - r
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

--- Process item drag during battle (called from BreedingPage)
function ArenaBattle.ProcessBattleInput(pressed, mouseDown, mx, my, designW, designH)
    -- Track mouse position and designW for coin hover detection
    arenaMouseX_ = mx
    arenaMouseY_ = my
    arenaDesignW_ = designW

    -- Always handle ongoing drag first (regardless of battle state)
    if dragItem_ then
        if mouseDown then
            dragItem_.curX = mx
            dragItem_.curY = my
        else
            -- Drag release → place item (only if still in BATTLE)
            if state_ == "BATTLE" then
                local def = ItemSystem.GetDef(dragItem_.slot)
                if def then
                    local screenX = mx - BATTLE_ARENA_X
                    local screenY = my - BATTLE_ARENA_Y
                    if screenX >= 0 and screenX <= BATTLE_ARENA_W and screenY >= 0 and screenY <= BATTLE_ARENA_H then
                        local logicX = screenX * ARENA_SIZE / BATTLE_ARENA_W
                        local logicY = screenY * ARENA_SIZE / BATTLE_ARENA_H
                        ItemSystem.Place(dragItem_.slot, logicX, logicY)
                        print(string.format("[Arena] Placed item '%s' at (%d,%d)", def.name, math.floor(logicX), math.floor(logicY)))
                    end
                end
            end
            dragItem_ = nil
        end
        return
    end

    -- New interactions only during BATTLE
    if state_ ~= "BATTLE" then return end

    -- Calculate dynamic btnY to match RenderBattle layout
    local hpBarH = 14
    local hpY = BATTLE_ARENA_Y + BATTLE_ARENA_H + 12
    local skillY = hpY + hpBarH + 10
    local skillLineH = 18
    local btnY = skillY + skillLineH * 3 + 20

    -- HP bar area width matches arena
    local hpBarAreaW = BATTLE_ARENA_W
    local hpBarX = BATTLE_ARENA_X

    if pressed then
        -- Check 自杀 button click (left side)
        local suicideBtnX = hpBarX - 30
        if mx >= suicideBtnX and mx <= suicideBtnX + BTN_W and
           my >= btnY and my <= btnY + BTN_H then
            -- Kill player ball
            if battleBalls_[1] and battleBalls_[1].alive then
                battleBalls_[1].hp = 0
                print("[Arena] Player used SUICIDE!")
            end
            return
        end

        -- Check AI托管 button click (right side)
        local aiBtnX = hpBarX + hpBarAreaW - BTN_W + 30
        if mx >= aiBtnX and mx <= aiBtnX + BTN_W and
           my >= btnY and my <= btnY + BTN_H then
            aiTakeover_ = not aiTakeover_
            print(string.format("[Arena] AI takeover: %s", aiTakeover_ and "ON" or "OFF"))
            return
        end

        -- Item slot clicks (center, 道具栏)
        local totalSlotsW = 3 * ITEM_SLOT_SIZE + 2 * ITEM_SLOT_GAP
        local slotsX = (designW - totalSlotsW) / 2
        local slotsY = btnY

        for slot = 1, 3 do
            local sx = slotsX + (slot - 1) * (ITEM_SLOT_SIZE + ITEM_SLOT_GAP)
            local sy = slotsY
            if mx >= sx and mx <= sx + ITEM_SLOT_SIZE and my >= sy and my <= sy + ITEM_SLOT_SIZE then
                if ItemSystem.IsReady(slot) then
                    dragItem_ = { slot = slot, curX = mx, curY = my }
                    print(string.format("[Arena][DEBUG] Started drag slot=%d at (%.0f,%.0f) slotsX=%.0f slotsY=%.0f", slot, mx, my, slotsX, slotsY))
                    return
                else
                    print(string.format("[Arena][DEBUG] Slot %d not ready, cd=%.1f", slot, ItemSystem.GetCooldown(slot)))
                end
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

    -- Background panel
    nvgBeginPath(vg); nvgRoundedRect(vg, px, py, PANEL_W, PANEL_H, 8)
    nvgFillColor(vg, nvgRGBA(55, 40, 65, 200)); nvgFill(vg)

    -- Border (glow when dragging a ball)
    if isDragging then
        local pulse = 0.5 + 0.5 * math.sin(elapsedTime * 5)
        nvgStrokeColor(vg, nvgRGBA(255, 180, 60, math.floor(120 + pulse * 80)))
        nvgStrokeWidth(vg, 3)
    else
        nvgStrokeColor(vg, nvgRGBA(180, 120, 220, 160))
        nvgStrokeWidth(vg, 2)
    end
    nvgStroke(vg)

    -- Title
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 18)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(240, 200, 255, 240))
    nvgText(vg, px + PANEL_W / 2, py + 10, "擂台赛", nil)

    -- Wave label
    nvgFontSize(vg, 12)
    nvgFillColor(vg, nvgRGBA(200, 180, 220, 180))
    nvgText(vg, px + PANEL_W / 2, py + 30,
        string.format("第 %d 波", currentWave_), nil)

    -- Square arena area (border)
    local arenaX = px + PANEL_ARENA_MARGIN
    local arenaY = py + PANEL_ARENA_TOP
    nvgBeginPath(vg); nvgRect(vg, arenaX, arenaY, PANEL_ARENA_SIZE, PANEL_ARENA_SIZE)
    nvgFillColor(vg, nvgRGBA(25, 20, 35, 180)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(160, 130, 200, 120))
    nvgStrokeWidth(vg, 1); nvgStroke(vg)

    -- Draw enemy balls bouncing inside (clipped to square arena)
    nvgSave(vg)
    nvgScissor(vg, arenaX, arenaY, PANEL_ARENA_SIZE, PANEL_ARENA_SIZE)
    for _, e in ipairs(panelEnemies_) do
        local ex = px + e.x
        local ey = py + e.y
        local r = e.radius
        local c = e.color

        -- Ball body
        nvgBeginPath(vg); nvgCircle(vg, ex, ey, r)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 220)); nvgFill(vg)

        -- Highlight
        nvgBeginPath(vg); nvgCircle(vg, ex - r * 0.2, ey - r * 0.2, r * 0.35)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 80)); nvgFill(vg)

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

    -- Drag hint at bottom
    if isDragging then
        nvgFontSize(vg, 13)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(255, 220, 100, math.floor(180 + 60 * math.sin(elapsedTime * 4))))
        nvgText(vg, px + PANEL_W / 2, py + PANEL_H - 6, "拖入球球开战!", nil)
    else
        nvgFontSize(vg, 11)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(180, 160, 200, 140))
        nvgText(vg, px + PANEL_W / 2, py + PANEL_H - 6, "拖入球球挑战", nil)
    end

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

        -- Ball body (drawn on top)
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, r)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 240)); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, dx - r * 0.2, dy - r * 0.2, r * 0.35)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 80)); nvgFill(vg)
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

    -- Interpolated arena rect
    local ax = transFrom_.x + (BATTLE_ARENA_X - transFrom_.x) * t
    local ay = transFrom_.y + (BATTLE_ARENA_Y - transFrom_.y) * t
    local aw = transFrom_.w + (BATTLE_ARENA_W - transFrom_.w) * t
    local ah = transFrom_.h + (BATTLE_ARENA_H - transFrom_.h) * t
    local uiAlpha = t

    -- Draw dark overlay (full screen black)
    nvgBeginPath(vg); nvgRect(vg, 0, 0, designW, designH)
    nvgFillColor(vg, nvgRGBA(10, 8, 15, math.floor(235 * uiAlpha))); nvgFill(vg)

    -- Scale factor from arena logical coords (ARENA_SIZE) to screen coords
    local scaleF = aw / ARENA_SIZE

    -- ======================================================================
    -- "玩家ID VS 敌人ID" header (screenshot style: large bold text)
    -- ======================================================================
    if t > 0.3 then
        local headerFade = math.min(1, (t - 0.3) / 0.5)
        local headerA = math.floor(255 * headerFade)
        local headerCX = ax + aw / 2
        local headerY = ay - 20  -- above arena

        -- Player name
        local pName = "???"
        if battleBalls_[1] then
            local fb = battleBalls_[1].farmBall
            pName = (fb and fb.name) or "我方"
        end

        -- Enemy name(s)
        local eName = "???"
        local enemyCount = #battleBalls_ - 1
        if enemyCount == 1 and battleBalls_[2] then
            local efb = battleBalls_[2].farmBall
            eName = (efb and efb.name) or "敌方"
        elseif enemyCount > 1 then
            eName = string.format("敌方 ×%d", enemyCount)
        end

        -- Wave indicator (small, above VS)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(180, 160, 200, math.floor(160 * headerFade)))
        nvgText(vg, headerCX, headerY - 46, string.format("擂台赛 · 第 %d 波", currentWave_), nil)

        -- Player name (left side, yellow/gold like screenshot)
        nvgFontSize(vg, 38)
        nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
        -- Shadow
        nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(180 * headerFade)))
        nvgText(vg, headerCX - 48, headerY + 2, pName, nil)
        -- Main text (yellow)
        nvgFillColor(vg, nvgRGBA(255, 200, 50, headerA))
        nvgText(vg, headerCX - 50, headerY, pName, nil)

        -- "VS" text (center, white bold)
        nvgFontSize(vg, 44)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(180 * headerFade)))
        nvgText(vg, headerCX + 2, headerY + 2, "VS", nil)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, headerA))
        nvgText(vg, headerCX, headerY, "VS", nil)

        -- Enemy name (right side, red like screenshot)
        nvgFontSize(vg, 38)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(180 * headerFade)))
        nvgText(vg, headerCX + 52, headerY + 2, eName, nil)
        nvgFillColor(vg, nvgRGBA(220, 50, 50, headerA))
        nvgText(vg, headerCX + 50, headerY, eName, nil)
    end

    -- ======================================================================
    -- Arena background (dark with white/light border like screenshot)
    -- ======================================================================
    nvgBeginPath(vg); nvgRect(vg, ax, ay, aw, ah)
    nvgFillColor(vg, nvgRGBA(15, 12, 22, 250)); nvgFill(vg)
    -- White border (screenshot shows thin white/gray border)
    nvgStrokeColor(vg, nvgRGBA(200, 200, 210, math.floor(180 * uiAlpha)))
    nvgStrokeWidth(vg, 2); nvgStroke(vg)

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
                local ballAlpha = ball.alive and 230 or 60

                local blvl = ball.level
                local btier = blvl >= 20 and 6 or blvl >= 15 and 5 or blvl >= 10 and 4 or blvl >= 5 and 3 or blvl >= 2 and 2 or 1

                -- Outer glow
                if ball.alive then
                    local glowR = br * (1.2 + btier * 0.1)
                    if btier >= 4 then
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
                        nvgRGBA(c.r, c.g, c.b, 25), nvgRGBA(c.r, c.g, c.b, 0)))
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
                        nvgRGBA(255, 255, 255, 40), nvgRGBA(0, 0, 0, 30)))
                    nvgFill(vg)
                    nvgBeginPath(vg); nvgCircle(vg, bx - br * 0.25, by - br * 0.25, br * 0.35)
                    nvgFillColor(vg, nvgRGBA(255, 255, 255, 50)); nvgFill(vg)
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
                    nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
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
                        nvgFillColor(vg, nvgRGBA(220, 220, 230, 220)); nvgFill(vg)
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
                        local rotCos = math.cos(coin.rotation)
                        local squash = math.abs(rotCos)
                        local coinW = COIN_R * math.max(0.15, squash)
                        -- Edge
                        nvgBeginPath(vg); nvgEllipse(vg, cx, cy + wobbleY, coinW + 2, COIN_R + 2)
                        nvgFillColor(vg, nvgRGBA(180, 130, 0, math.floor(220 * cs))); nvgFill(vg)
                        -- Body
                        nvgBeginPath(vg); nvgEllipse(vg, cx, cy + wobbleY, coinW, COIN_R)
                        nvgFillColor(vg, nvgRGBA(255, 225, 60, math.floor(250 * cs))); nvgFill(vg)
                        -- Value label
                        nvgFontFaceId(vg, fontId)
                        nvgFontSize(vg, 11 * scaleF)
                        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
                        nvgFillColor(vg, nvgRGBA(255, 230, 60, math.floor(200 * cs)))
                        nvgText(vg, cx, cy + wobbleY + COIN_R + 3,
                            string.format("+%d", math.floor(coin.value)), nil)
                    end
                end
            end
        end

        nvgRestore(vg)  -- end arena scissor
    end

    -- Countdown overlay
    if state_ == "COUNTDOWN" then
        local num = math.ceil(countdownTimer_)
        local pulse = 1 + 0.3 * math.sin((countdownTimer_ % 1) * math.pi)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 100 * pulse)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 240))
        nvgText(vg, ax + aw / 2, ay + ah / 2, tostring(num), nil)
    end

    -- Result overlay
    if state_ == "RESULT" then
        local resultAlpha = math.min(1, resultTimer_ * 3)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 72)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        if resultIsWin_ then
            nvgFillColor(vg, nvgRGBA(255, 215, 0, math.floor(240 * resultAlpha)))
            nvgText(vg, ax + aw / 2, ay + ah / 2 - 50, "胜利!", nil)
            nvgFontSize(vg, 32)
            nvgFillColor(vg, nvgRGBA(255, 230, 100, math.floor(200 * resultAlpha)))
            nvgText(vg, ax + aw / 2, ay + ah / 2 + 30,
                string.format("+%d 金币", resultGoldAwarded_), nil)
        else
            nvgFillColor(vg, nvgRGBA(255, 80, 80, math.floor(220 * resultAlpha)))
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
        local enemyBall = battleBalls_[2]  -- first enemy

        -- ============ Health bars below arena (screenshot layout) ============
        local hpBarAreaW = aw  -- same width as arena
        local hpBarX = ax
        local hpBarW = hpBarAreaW * 0.42  -- each bar takes ~42% of arena width
        local hpBarH = 14
        local hpY = ay + ah + 12

        nvgFontFaceId(vg, fontId)

        -- "我方血量" label + bar (left side)
        nvgFontSize(vg, 16)
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
        nvgText(vg, hpBarX, hpY - 2, "我方血量", nil)

        local pHpPct = 0
        if playerBall then pHpPct = math.max(0, playerBall.hp / playerBall.maxHp) end
        nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpY, hpBarW, hpBarH, 3)
        nvgFillColor(vg, nvgRGBA(60, 60, 70, a)); nvgFill(vg)
        if pHpPct > 0 then
            nvgBeginPath(vg); nvgRoundedRect(vg, hpBarX, hpY, hpBarW * pHpPct, hpBarH, 3)
            nvgFillColor(vg, nvgRGBA(220, 220, 230, a)); nvgFill(vg)
        end

        -- "敌人血量" label + bar (right side)
        local eHpBarX = hpBarX + hpBarAreaW - hpBarW
        nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
        nvgText(vg, hpBarX + hpBarAreaW, hpY - 2, "敌人血量", nil)

        local eHpPct = 0
        if enemyBall then eHpPct = math.max(0, enemyBall.hp / enemyBall.maxHp) end
        nvgBeginPath(vg); nvgRoundedRect(vg, eHpBarX, hpY, hpBarW, hpBarH, 3)
        nvgFillColor(vg, nvgRGBA(60, 60, 70, a)); nvgFill(vg)
        if eHpPct > 0 then
            -- Enemy bar fills from right to left
            local fillW = hpBarW * eHpPct
            nvgBeginPath(vg); nvgRoundedRect(vg, eHpBarX + hpBarW - fillW, hpY, fillW, hpBarH, 3)
            nvgFillColor(vg, nvgRGBA(220, 220, 230, a)); nvgFill(vg)
        end

        -- ============ Skill info below health bars (screenshot layout) ============
        local skillY = hpY + hpBarH + 10
        local skillFontSz = 14
        local skillLineH = 18
        nvgFontSize(vg, skillFontSz)

        -- Helper: draw skill line with icon
        local function drawSkillInfo(skillId, label, x, y, align)
            local sName = "无"
            if skillId then
                local def = SkillRegistry.Get(skillId)
                sName = def and def.name or skillId
            end
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, skillFontSz)
            nvgTextAlign(vg, align + NVG_ALIGN_TOP)
            nvgFillColor(vg, nvgRGBA(200, 200, 210, a))
            nvgText(vg, x, y, label .. sName, nil)
        end

        -- Player skills (left-aligned)
        if playerBall then
            drawSkillInfo(playerBall.skill, "普通技能：", hpBarX + 20, skillY, NVG_ALIGN_LEFT)
            drawSkillInfo(playerBall.enhancedSkill, "强化技能：", hpBarX + 20, skillY + skillLineH, NVG_ALIGN_LEFT)
            drawSkillInfo(playerBall.ultimateSkill, "终结技能：", hpBarX + 20, skillY + skillLineH * 2, NVG_ALIGN_LEFT)
        end

        -- Enemy skills (right-aligned)
        if enemyBall then
            drawSkillInfo(enemyBall.skill, "普通技能：", hpBarX + hpBarAreaW - 20, skillY, NVG_ALIGN_RIGHT)
            drawSkillInfo(enemyBall.enhancedSkill, "强化技能：", hpBarX + hpBarAreaW - 20, skillY + skillLineH, NVG_ALIGN_RIGHT)
            drawSkillInfo(enemyBall.ultimateSkill, "终结技能：", hpBarX + hpBarAreaW - 20, skillY + skillLineH * 2, NVG_ALIGN_RIGHT)
        end

        -- ============ Bottom buttons + Item bar (screenshot layout) ============
        if state_ == "BATTLE" then
            local btnY = skillY + skillLineH * 3 + 20

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

        -- Drag item preview
        if dragItem_ then
            print(string.format("[Arena][DEBUG] DrawDragItem: slot=%d pos=(%.0f,%.0f)", dragItem_.slot, dragItem_.curX, dragItem_.curY))
            DrawDragItem(vg, fontId)
        end
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
            -- Elliptical coin (spinning)
            local mcR = p.radius
            local rotCos = math.cos(p.rotation)
            local squash = math.abs(rotCos)
            local coinW = mcR * math.max(0.15, squash)
            -- Edge
            nvgBeginPath(vg); nvgEllipse(vg, p.x, p.y, coinW + 1.5, mcR + 1.5)
            nvgFillColor(vg, nvgRGBA(180, 130, 0, 220)); nvgFill(vg)
            -- Body
            nvgBeginPath(vg); nvgEllipse(vg, p.x, p.y, coinW, mcR)
            nvgFillColor(vg, nvgRGBA(255, 225, 60, 240)); nvgFill(vg)
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
    local a = math.floor(255 * alpha)
    local totalSlotsW = 3 * ITEM_SLOT_SIZE + 2 * ITEM_SLOT_GAP
    local slotsX = (designW - totalSlotsW) / 2
    local slotsY = overrideY or ITEM_BAR_Y

    -- Bar background
    local barPad = 15
    nvgBeginPath(vg); nvgRoundedRect(vg,
        slotsX - barPad, slotsY - barPad,
        totalSlotsW + barPad * 2, ITEM_SLOT_SIZE + barPad * 2 + 20, 10)
    nvgFillColor(vg, nvgRGBA(30, 25, 40, math.floor(180 * alpha))); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(140, 100, 180, math.floor(120 * alpha)))
    nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

    -- Label
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 12)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(180, 160, 200, math.floor(160 * alpha)))
    nvgText(vg, designW / 2, slotsY - 3, "道具栏", nil)

    for slot = 1, 3 do
        local sx = slotsX + (slot - 1) * (ITEM_SLOT_SIZE + ITEM_SLOT_GAP)
        local sy = slotsY
        local def = ItemSystem.GetDef(slot)
        local cd = ItemSystem.GetCooldown(slot)
        local ready = ItemSystem.IsReady(slot)

        -- Slot background
        nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy, ITEM_SLOT_SIZE, ITEM_SLOT_SIZE, 6)
        if ready then
            nvgFillColor(vg, nvgRGBA(70, 60, 90, a))
        else
            nvgFillColor(vg, nvgRGBA(40, 35, 55, a))
        end
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(140, 120, 180, ready and a or math.floor(80 * alpha)))
        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

        if def then
            -- Emoji icon
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 22)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, ready and a or math.floor(120 * alpha)))
            nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE / 2 - 4, def.emoji, nil)

            -- Item name
            nvgFontSize(vg, 9)
            nvgFillColor(vg, nvgRGBA(180, 170, 210, ready and math.floor(200 * alpha) or math.floor(100 * alpha)))
            nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE - 5, def.name, nil)

            -- Cooldown overlay
            if not ready and cd > 0 then
                local pct = cd / def.cooldown
                local overlayH = ITEM_SLOT_SIZE * pct
                nvgBeginPath(vg); nvgRoundedRect(vg, sx, sy + ITEM_SLOT_SIZE - overlayH, ITEM_SLOT_SIZE, overlayH, 6)
                nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(130 * alpha))); nvgFill(vg)

                nvgFontSize(vg, 14)
                nvgFillColor(vg, nvgRGBA(255, 255, 255, a))
                nvgText(vg, sx + ITEM_SLOT_SIZE / 2, sy + ITEM_SLOT_SIZE / 2,
                    string.format("%.0f", math.ceil(cd)), nil)
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

    local dx, dy = dragItem_.curX, dragItem_.curY
    local scaleF = BATTLE_ARENA_W / ARENA_SIZE  -- logic→screen scale (1.25)

    -- Check if cursor is over the arena
    local relX = dx - BATTLE_ARENA_X
    local relY = dy - BATTLE_ARENA_Y
    local overArena = relX >= 0 and relX <= BATTLE_ARENA_W
                  and relY >= 0 and relY <= BATTLE_ARENA_H

    -- Range circle preview (only when over arena) - simple white style
    if overArena then
        local screenRadius = def.radius * scaleF
        nvgBeginPath(vg); nvgCircle(vg, dx, dy, screenRadius)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 30)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 120))
        nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    end

    -- Dragged icon (emoji)
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 32)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
    nvgText(vg, dx, dy, def.emoji, nil)

    -- Name below
    nvgFontSize(vg, 11)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 180))
    nvgText(vg, dx, dy + 22, def.name, nil)

    -- "Not in arena" hint when dragging outside
    if not overArena then
        nvgFontSize(vg, 11)
        nvgFillColor(vg, nvgRGBA(255, 120, 120, 220))
        nvgText(vg, dx, dy + 36, "拖到擂台内放置", nil)
    end
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

return ArenaBattle
