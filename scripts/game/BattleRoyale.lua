-- ============================================================================
-- BattleRoyale.lua - 吃鸡大战核心模块
-- 31 球 (1 玩家 + 30 AI) 在坦克大战风格大地图上混战，最后存活者胜
-- ============================================================================

local Settings          = require("config.Settings")
local BallAI            = require("game.BallAI")
local SkillRegistry     = require("game.SkillRegistry")
local SkillExecutor     = require("game.SkillExecutor")
local Expressions       = require("game.Expressions")
local BallCustomization = require("game.BallCustomization")
local BRMap             = require("game.BattleRoyaleMap")
local TriangleFill      = require("effects.TriangleFill")

local BattleRoyale = {}

-- ============================================================================
-- Constants
-- ============================================================================

local BR           = Settings.BattleRoyale
local BALL         = Settings.Ball
local MAP_SIZE     = BR.MapSize        -- 2400
local VIEWPORT     = BR.ViewportSize   -- 600
local BALL_COUNT   = BR.BallCount      -- 31
local RADIUS       = BALL.Radius       -- 20
local MAX_HP       = BALL.MaxHP        -- 100

-- ============================================================================
-- State
-- ============================================================================

local balls_       = {}    -- [1..31]
local customs_     = {}    -- [1..31] BallCustomization data
local aiStates_    = {}    -- [1..31] BallAI state
local cooldowns_   = {}    -- [1..31] {normal=0, enhanced=0, ultimate=0}
local triFills_    = {}    -- [1..31] TriangleFill instances
local alive_       = {}    -- [1..31] boolean
local aliveCount_  = 0
local elimOrder_   = 0     -- 淘汰排名计数器

-- Camera
local camX_, camY_ = 0, 0
local followTeam_  = 1

-- Game state
local phase_       = "playing"   -- "playing" | "gameover"
local winner_      = 0
local gameOverTimer_ = 0
local elapsedTime_ = 0
local isAIProxy_   = false

-- Visual effects
local damagePopups_ = {}
local announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
local shake_        = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }
local collisionCDs_ = {}   -- ["i_j"] = timer

-- NanoVG / render state (set each frame)
local vg_          = nil
local fontId_      = -1
local arenaX_, arenaY_, arenaDrawSize_, arenaScale_ = 0, 0, 400, 1.0
local designW_, designH_ = 1920, 1080
local nvgScale_    = 1
local dpr_         = 1
local designOffsetX_ = 0

-- Callbacks
local onGameEnd_   = nil
local originalArenaSize_ = 400

-- ============================================================================
-- Helpers
-- ============================================================================

local function clamp(v, lo, hi) return math.max(lo, math.min(hi, v)) end

local function GetCustom(team)
    return customs_[team] or BallCustomization.GetDefault()
end

local function GetSkillDefForTier(team, tier)
    local custom = GetCustom(team)
    local skillId = custom.skills and custom.skills[tier]
    if skillId and skillId ~= "" then
        return SkillRegistry.Get(skillId), tier
    end
    return nil, nil
end

local function GetBestAvailableSkill(team)
    local ball = balls_[team]
    if not ball then return nil, nil end
    local tiers = BallAI.GetAvailableTiers(ball.hp)
    for _, tier in ipairs(tiers) do
        local cd = cooldowns_[team][tier] or 0
        if cd <= 0 then
            local skillDef = GetSkillDefForTier(team, tier)
            if skillDef then return skillDef, tier end
        end
    end
    return nil, nil
end

local function FindNearestAlive(team)
    local self = balls_[team]
    if not self then return nil end
    local bestDist2 = math.huge
    local bestTeam = nil
    for t = 1, BALL_COUNT do
        if t ~= team and alive_[t] and balls_[t] then
            local dx = balls_[t].x - self.x
            local dy = balls_[t].y - self.y
            local d2 = dx * dx + dy * dy
            if d2 < bestDist2 then bestDist2 = d2; bestTeam = t end
        end
    end
    return bestTeam
end

-- ============================================================================
-- Visual Effects (简化版)
-- ============================================================================

local function AddDamagePopup(x, y, dmg, r, g, b)
    table.insert(damagePopups_, {
        x = x, y = y, dmg = dmg,
        r = r, g = g, b = b,
        timer = 0, duration = Settings.Popup.Duration,
    })
end

local function ScreenShake(intensity, duration)
    if intensity > shake_.intensity then
        shake_.intensity = intensity
        shake_.duration = duration
        shake_.elapsed = 0
    end
end

local function SetAnnouncement(text, r, g, b, dur)
    announcement_.text = text
    announcement_.color = {r or 255, g or 255, b or 255, 255}
    announcement_.timer = 0
    announcement_.duration = dur or 2.0
end

-- ============================================================================
-- Init / Cleanup
-- ============================================================================

function BattleRoyale.Init(playerCustom, onGameEnd)
    onGameEnd_ = onGameEnd
    originalArenaSize_ = Settings.Arena.Size
    Settings.Arena.Size = MAP_SIZE

    -- 生成地图
    local spawnPoints = BRMap.Generate()

    -- 创建球体
    balls_ = {}
    customs_ = {}
    aiStates_ = {}
    cooldowns_ = {}
    triFills_ = {}
    alive_ = {}
    aliveCount_ = BALL_COUNT
    elimOrder_ = 0
    damagePopups_ = {}
    collisionCDs_ = {}
    phase_ = "playing"
    winner_ = 0
    gameOverTimer_ = 0
    elapsedTime_ = 0
    isAIProxy_ = false
    announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
    shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

    for t = 1, BALL_COUNT do
        local sp = spawnPoints[t]
        local angle = math.random() * math.pi * 2
        local spd = BALL.InitialSpeed * (0.5 + math.random() * 0.5)
        balls_[t] = {
            x = sp.x, y = sp.y,
            vx = math.cos(angle) * spd,
            vy = math.sin(angle) * spd,
            hp = MAX_HP,
            team = t,
            knockbackTimer = 0,
            pendingWallSlamDmg = 0,
            slowTimer = 0, slowFactor = 1.0,
            stunTimer = 0,
            elimRank = 0,
        }
        if t == 1 then
            customs_[t] = playerCustom or BallCustomization.GetDefault()
        else
            customs_[t] = BallCustomization.Randomize()
        end
        aiStates_[t] = BallAI.CreateState()
        cooldowns_[t] = { normal = 0, enhanced = 0, ultimate = 0 }

        local c = customs_[t].color or {r=100,g=180,b=255}
        triFills_[t] = TriangleFill.new({
            maxTriangles = 12, spawnRate = 25, triLife = 0.5, maxAlpha = 90,
            sizeMin = 6, sizeMax = 18,
            baseColor = { c.r, c.g, c.b },
        })
        alive_[t] = true
    end

    -- Camera 初始位置
    camX_ = balls_[1].x
    camY_ = balls_[1].y

    SkillExecutor.Clear()
    SetAnnouncement("吃鸡大战开始！", 255, 220, 60, 3.0)
    print("[BattleRoyale] Init: " .. BALL_COUNT .. " balls")
end

function BattleRoyale.Cleanup()
    Settings.Arena.Size = originalArenaSize_
    SkillExecutor.Clear()
    balls_ = {}
    alive_ = {}
    phase_ = "playing"
    print("[BattleRoyale] Cleanup")
end

-- ============================================================================
-- Elimination
-- ============================================================================

local function EliminateBall(team)
    if not alive_[team] then return end
    alive_[team] = false
    aliveCount_ = aliveCount_ - 1
    elimOrder_ = elimOrder_ + 1
    if balls_[team] then
        balls_[team].elimRank = BALL_COUNT - elimOrder_ + 1
    end
    balls_[team] = nil  -- SkillExecutor 会安全跳过 nil

    local name = (team == 1) and "你" or ("#" .. team)
    local msg = name .. " 被淘汰！排名 #" .. (BALL_COUNT - elimOrder_ + 1)
    SetAnnouncement(msg, 255, 100, 80, 2.5)

    if aliveCount_ <= 1 then
        -- 找到胜者
        for t = 1, BALL_COUNT do
            if alive_[t] then winner_ = t; break end
        end
        phase_ = "gameover"
        gameOverTimer_ = 0
        local wn = (winner_ == 1) and "你" or ("#" .. winner_)
        SetAnnouncement(wn .. " 大吉大利，今晚吃鸡！", 255, 220, 60, 5.0)
    end
end

-- ============================================================================
-- Physics
-- ============================================================================

local function UpdateBallPhysics(dt)
    for t = 1, BALL_COUNT do
        if not alive_[t] then goto continue end
        local b = balls_[t]

        -- Status timers
        if b.knockbackTimer > 0 then b.knockbackTimer = b.knockbackTimer - dt end
        if b.slowTimer > 0 then
            b.slowTimer = b.slowTimer - dt
            if b.slowTimer <= 0 then b.slowFactor = 1.0 end
        end
        if b.stunTimer and b.stunTimer > 0 then b.stunTimer = b.stunTimer - dt end

        -- 移动
        local sf = b.slowFactor or 1.0
        b.x = b.x + b.vx * sf * dt
        b.y = b.y + b.vy * sf * dt

        -- 速度上限
        local spd = math.sqrt(b.vx * b.vx + b.vy * b.vy)
        if spd > BALL.SpeedCap then
            local scale = BALL.SpeedCap / spd
            b.vx = b.vx * scale
            b.vy = b.vy * scale
        end

        -- 墙格碰撞 (含地图边界)
        local prevVx, prevVy = b.vx, b.vy
        BRMap.ResolveBallCollision(b, RADIUS)
        -- Wall slam damage
        if b.knockbackTimer > 0 and b.pendingWallSlamDmg > 0 then
            if math.abs(b.vx - prevVx) > 10 or math.abs(b.vy - prevVy) > 10 then
                b.hp = b.hp - b.pendingWallSlamDmg
                AddDamagePopup(b.x, b.y - RADIUS, b.pendingWallSlamDmg, 255, 160, 60)
                ScreenShake(b.pendingWallSlamDmg, 0.2)
                b.knockbackTimer = 0
                b.pendingWallSlamDmg = 0
                if b.hp <= 0 then b.hp = 0; EliminateBall(t) end
            end
        end
        ::continue::
    end

    -- Ball-ball 弹性碰撞
    for i = 1, BALL_COUNT do
        if not alive_[i] then goto ci end
        local b1 = balls_[i]
        for j = i + 1, BALL_COUNT do
            if not alive_[j] then goto cj end
            local b2 = balls_[j]
            local dx = b2.x - b1.x
            local dy = b2.y - b1.y
            local dist2 = dx * dx + dy * dy
            local minDist = RADIUS * 2
            if dist2 < minDist * minDist and dist2 > 0.01 then
                local dist = math.sqrt(dist2)
                local nx, ny = dx / dist, dy / dist
                local overlap = minDist - dist
                b1.x = b1.x - nx * overlap * 0.5
                b1.y = b1.y - ny * overlap * 0.5
                b2.x = b2.x + nx * overlap * 0.5
                b2.y = b2.y + ny * overlap * 0.5
                -- 弹性速度交换
                local dvx = b1.vx - b2.vx
                local dvy = b1.vy - b2.vy
                local dvDotN = dvx * nx + dvy * ny
                if dvDotN > 0 then
                    b1.vx = b1.vx - dvDotN * nx
                    b1.vy = b1.vy - dvDotN * ny
                    b2.vx = b2.vx + dvDotN * nx
                    b2.vy = b2.vy + dvDotN * ny
                end
                -- 碰撞伤害（带冷却）
                local key = i .. "_" .. j
                if (collisionCDs_[key] or 0) <= 0 then
                    local dmg = BALL.CollisionDamage
                    b1.hp = b1.hp - dmg
                    b2.hp = b2.hp - dmg
                    collisionCDs_[key] = 0.3
                    if b1.hp <= 0 then b1.hp = 0; EliminateBall(i) end
                    if b2.hp <= 0 then b2.hp = 0; EliminateBall(j) end
                end
            end
            ::cj::
        end
        ::ci::
    end

    -- 衰减碰撞冷却
    for key, cd in pairs(collisionCDs_) do
        collisionCDs_[key] = cd - dt
        if collisionCDs_[key] <= 0 then collisionCDs_[key] = nil end
    end
end

-- ============================================================================
-- Input / AI
-- ============================================================================

local function ProcessAllInput(dt)
    for t = 1, BALL_COUNT do
        if not alive_[t] then goto skip end
        local b = balls_[t]
        if b.stunTimer and b.stunTimer > 0 then goto skip end

        -- 更新冷却
        for _, tier in ipairs({"normal", "enhanced", "ultimate"}) do
            if cooldowns_[t][tier] > 0 then
                cooldowns_[t][tier] = cooldowns_[t][tier] - dt
            end
        end

        local nearestTeam = FindNearestAlive(t)
        if not nearestTeam then goto skip end
        local nearestBall = balls_[nearestTeam]

        local skillDef, skillTier = GetBestAvailableSkill(t)
        if not skillDef then goto skip end

        local projSpeed = skillDef.speed or 500

        if t == 1 and not isAIProxy_ then
            -- 玩家手动瞄准：鼠标点击射击
            if input:GetMouseButtonDown(MOUSEB_LEFT) then
                local mx = input:GetMousePosition().x
                local my = input:GetMousePosition().y
                -- 屏幕坐标 → 地图坐标
                local vpScale = arenaDrawSize_ / VIEWPORT
                local viewL = camX_ - VIEWPORT / 2
                local viewT = camY_ - VIEWPORT / 2
                local localX = (mx / dpr_ / nvgScale_ - designOffsetX_ - arenaX_) / vpScale + viewL
                local localY = (my / dpr_ / nvgScale_ - arenaY_) / vpScale + viewT
                local dx = localX - b.x
                local dy = localY - b.y
                local dist = math.sqrt(dx * dx + dy * dy)
                if dist > 1 then
                    local dirX, dirY = dx / dist, dy / dist
                    local cd = SkillExecutor.Fire(skillDef, t, nearestTeam, b.x, b.y, dirX, dirY)
                    if cd then cooldowns_[t][skillTier] = cd end
                end
            end
        else
            -- AI 控制
            local ai = BallAI.Update(aiStates_[t], b, nearestBall, cooldowns_[t][skillTier] or 0, projSpeed, dt)
            if ai.shoot then
                local cd = SkillExecutor.Fire(skillDef, t, nearestTeam, b.x, b.y, ai.aimX, ai.aimY)
                if cd then cooldowns_[t][skillTier] = cd end
            end
        end
        ::skip::
    end
end

-- ============================================================================
-- Camera
-- ============================================================================

local function UpdateCamera(dt)
    if alive_[1] then
        followTeam_ = 1
    else
        local bestHP, bestT = -1, 0
        for t = 1, BALL_COUNT do
            if alive_[t] and balls_[t] and balls_[t].hp > bestHP then
                bestHP = balls_[t].hp; bestT = t
            end
        end
        if bestT > 0 then followTeam_ = bestT end
    end
    if not balls_[followTeam_] then return end
    local target = balls_[followTeam_]
    local spd = BR.CameraLerpSpeed
    camX_ = camX_ + (target.x - camX_) * clamp(spd * dt, 0, 1)
    camY_ = camY_ + (target.y - camY_) * clamp(spd * dt, 0, 1)
    local half = VIEWPORT / 2
    camX_ = clamp(camX_, half, MAP_SIZE - half)
    camY_ = clamp(camY_, half, MAP_SIZE - half)
end

-- ============================================================================
-- Update effects
-- ============================================================================

local function UpdateEffects(dt)
    -- Damage popups
    for i = #damagePopups_, 1, -1 do
        local p = damagePopups_[i]
        p.timer = p.timer + dt
        if p.timer >= p.duration then table.remove(damagePopups_, i) end
    end
    -- Announcement
    if announcement_.timer < announcement_.duration then
        announcement_.timer = announcement_.timer + dt
    end
    -- Screen shake
    if shake_.elapsed < shake_.duration then
        shake_.elapsed = shake_.elapsed + dt
        local t = shake_.elapsed / shake_.duration
        local decay = 1 - t
        shake_.ox = math.sin(shake_.elapsed * 30) * shake_.intensity * decay
        shake_.oy = math.cos(shake_.elapsed * 37) * shake_.intensity * decay * 0.7
    else
        shake_.ox = 0; shake_.oy = 0
    end
    -- TriangleFills
    for t = 1, BALL_COUNT do
        if alive_[t] and triFills_[t] then
            triFills_[t]:Update(dt)
        end
    end
end

-- ============================================================================
-- Update (called by Standalone each frame)
-- ============================================================================

function BattleRoyale.Update(dt)
    if phase_ == "gameover" then
        gameOverTimer_ = gameOverTimer_ + dt
        UpdateEffects(dt)
        if gameOverTimer_ > 5 then
            BattleRoyale.Cleanup()
            if onGameEnd_ then onGameEnd_() end
        end
        return
    end

    elapsedTime_ = elapsedTime_ + dt
    UpdateEffects(dt)
    ProcessAllInput(dt)
    UpdateBallPhysics(dt)

    -- SkillExecutor
    local callbacks = {
        onHit = function(targetTeam, damage, kx, ky, projType, skillId, proj)
            local tgt = balls_[targetTeam]
            if not tgt then return end
            tgt.hp = tgt.hp - damage
            tgt.vx = tgt.vx + kx
            tgt.vy = tgt.vy + ky
            if projType == "beam" and proj then
                tgt.knockbackTimer = proj.knockbackWindow or 0.8
                tgt.pendingWallSlamDmg = proj.wallSlamDamage or 0
                if proj.stunDuration and proj.stunDuration > 0 then
                    tgt.stunTimer = proj.stunDuration
                end
            end
            if proj and proj.slowFactor then
                tgt.slowTimer = proj.slowDuration or 2.0
                tgt.slowFactor = proj.slowFactor
            end
            local sd = SkillRegistry.Get(skillId)
            local c = sd and sd.color or {r=255,g=255,b=255}
            if damage > 0.1 then
                AddDamagePopup(tgt.x, tgt.y - RADIUS - 10, damage, c.r, c.g, c.b)
                ScreenShake(math.min(damage, 6), 0.12)
            end
            if tgt.hp <= 0 then tgt.hp = 0; EliminateBall(targetTeam) end
        end,
        onDot = function(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            SkillExecutor.AddDot(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
        end,
        onDotTick = function(targetTeam, sourceTeam, dmgT, healT)
            local tgt = balls_[targetTeam]
            local src = balls_[sourceTeam]
            if tgt then
                tgt.hp = tgt.hp - dmgT
                if dmgT > 0.1 then
                    AddDamagePopup(tgt.x, tgt.y - RADIUS, dmgT, 200, 80, 255)
                end
                if tgt.hp <= 0 then tgt.hp = 0; EliminateBall(targetTeam) end
            end
            if src and healT > 0 then
                src.hp = math.min(src.hp + healT, MAX_HP)
            end
        end,
        onSlow = function(targetTeam, factor, duration)
            local tgt = balls_[targetTeam]
            if tgt then
                tgt.slowTimer = math.max(tgt.slowTimer or 0, duration)
                tgt.slowFactor = math.min(tgt.slowFactor or 1, factor)
            end
        end,
        onStun = function(targetTeam, duration)
            local tgt = balls_[targetTeam]
            if tgt then
                tgt.stunTimer = math.max(tgt.stunTimer or 0, duration)
            end
        end,
    }
    SkillExecutor.Update(dt, balls_, callbacks)
    SkillExecutor.UpdateDots(dt, balls_, callbacks)
    SkillExecutor.UpdateVisuals(dt, balls_)
    UpdateCamera(dt)
end

-- ============================================================================
-- Drawing
-- ============================================================================

local function DrawBalls(vg)
    for t = 1, BALL_COUNT do
        if not alive_[t] or not balls_[t] then goto skip end
        local b = balls_[t]
        local c = GetCustom(t).color or {r=100,g=180,b=255}

        -- Ball body
        nvgBeginPath(vg)
        nvgCircle(vg, b.x, b.y, RADIUS)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, 220))
        nvgFill(vg)

        -- TriangleFill (scissor-clipped inside ball)
        if triFills_[t] then
            nvgSave(vg)
            nvgIntersectScissor(vg, b.x - RADIUS, b.y - RADIUS, RADIUS * 2, RADIUS * 2)
            triFills_[t]:RenderCircle(vg, b.x, b.y, RADIUS)
            nvgRestore(vg)
        end

        -- Expression
        local expr = GetCustom(t).expression or "happy"
        Expressions.Draw(vg, expr, b.x, b.y, RADIUS)

        -- HP bar
        local barW = RADIUS * 2.2
        local barH = 4
        local barX = b.x - barW / 2
        local barY = b.y - RADIUS - 10
        nvgBeginPath(vg)
        nvgRoundedRect(vg, barX, barY, barW, barH, 2)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, 160))
        nvgFill(vg)
        local hpPct = clamp(b.hp / MAX_HP, 0, 1)
        local hr = hpPct > 0.5 and 0 or (hpPct > 0.25 and 255 or 255)
        local hg = hpPct > 0.5 and 220 or (hpPct > 0.25 and 180 or 60)
        local hb = hpPct > 0.5 and 80 or 0
        nvgBeginPath(vg)
        nvgRoundedRect(vg, barX, barY, barW * hpPct, barH, 2)
        nvgFillColor(vg, nvgRGBA(hr, hg, hb, 220))
        nvgFill(vg)

        -- Player indicator ring
        if t == 1 then
            nvgBeginPath(vg)
            nvgCircle(vg, b.x, b.y, RADIUS + 4)
            nvgStrokeWidth(vg, 2)
            nvgStrokeColor(vg, nvgRGBA(255, 255, 100, 200))
            nvgStroke(vg)
        end
        ::skip::
    end
end

local function DrawDamagePopups(vg, fontId)
    for _, p in ipairs(damagePopups_) do
        local t = p.timer / p.duration
        local alpha = 1 - t
        local rise = Settings.Popup.RiseSpeed * p.timer
        local fs = clamp(Settings.Popup.BaseFontSize + p.dmg * Settings.Popup.FontSizePerDmg, 14, Settings.Popup.MaxFontSize)
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, fs)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(p.r, p.g, p.b, math.floor(alpha * 255)))
        nvgText(vg, p.x, p.y - rise, string.format("-%d", math.ceil(p.dmg)))
    end
end

local function DrawAnnouncement(vg, fontId)
    if announcement_.timer >= announcement_.duration then return end
    local t = announcement_.timer / announcement_.duration
    local alpha = 1.0
    if t > 0.7 then alpha = (1 - t) / 0.3 end
    local c = announcement_.color
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 28)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    -- 背景条
    local cx = MAP_SIZE / 2
    local cy = MAP_SIZE * 0.35
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - 200, cy - 20, 400, 40, 8)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(alpha * 180)))
    nvgFill(vg)
    nvgFillColor(vg, nvgRGBA(c[1], c[2], c[3], math.floor(alpha * 255)))
    nvgText(vg, cx, cy, announcement_.text)
end

-- ============================================================================
-- Leaderboard (右上角，设计坐标，不随视口变换)
-- ============================================================================

local function DrawLeaderboard(vg, fontId, lbX, lbY, S)
    -- 收集存活球
    local sorted = {}
    for t = 1, BALL_COUNT do
        if alive_[t] and balls_[t] then
            table.insert(sorted, { team = t, hp = balls_[t].hp, color = GetCustom(t).color })
        end
    end
    table.sort(sorted, function(a, b) return a.hp > b.hp end)

    local maxShow = math.min(10, #sorted)
    local rowH = 20 * S
    local headerH = 24 * S
    local lbW = 140 * S
    local panelH = headerH + maxShow * rowH + 8 * S

    -- 背景
    nvgBeginPath(vg)
    nvgRoundedRect(vg, lbX, lbY, lbW, panelH, 6 * S)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 180))
    nvgFill(vg)
    nvgStrokeWidth(vg, 1)
    nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 50))
    nvgBeginPath(vg)
    nvgRoundedRect(vg, lbX, lbY, lbW, panelH, 6 * S)
    nvgStroke(vg)

    -- 标题
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 13 * S)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255, 220, 80, 240))
    nvgText(vg, lbX + lbW / 2, lbY + headerH * 0.5, "存活 " .. aliveCount_ .. "/" .. BALL_COUNT)

    -- 行
    nvgFontSize(vg, 11 * S)
    nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    for i = 1, maxShow do
        local entry = sorted[i]
        local ry = lbY + headerH + (i - 1) * rowH + rowH * 0.5
        local isPlayer = (entry.team == 1)

        if isPlayer then
            nvgBeginPath(vg)
            nvgRect(vg, lbX + 2, ry - rowH * 0.45, lbW - 4, rowH * 0.9)
            nvgFillColor(vg, nvgRGBA(255, 255, 0, 35))
            nvgFill(vg)
        end

        -- 排名
        nvgFillColor(vg, nvgRGBA(180, 180, 180, 220))
        nvgText(vg, lbX + 6 * S, ry, tostring(i))

        -- 颜色点
        local ec = entry.color
        nvgBeginPath(vg)
        nvgCircle(vg, lbX + 22 * S, ry, 4 * S)
        nvgFillColor(vg, nvgRGBA(ec.r, ec.g, ec.b, 230))
        nvgFill(vg)

        -- 名称 + HP
        local label = isPlayer and "你" or ("#" .. entry.team)
        nvgFillColor(vg, isPlayer and nvgRGBA(255, 255, 150, 255) or nvgRGBA(220, 220, 220, 220))
        nvgText(vg, lbX + 32 * S, ry, label)

        nvgTextAlign(vg, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(200, 200, 200, 200))
        nvgText(vg, lbX + lbW - 6 * S, ry, tostring(math.floor(entry.hp)))
        nvgTextAlign(vg, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    end
end

-- ============================================================================
-- HUD (按钮等，设计坐标)
-- ============================================================================

local function DrawHUD(vg, fontId, aX, aY, aDS, S)
    -- 返回主页按钮 (左下)
    local btnW = 70 * S
    local btnH = 28 * S
    local btnX = aX
    local btnY = aY + aDS + 6 * S
    nvgBeginPath(vg)
    nvgRoundedRect(vg, btnX, btnY, btnW, btnH, 4 * S)
    nvgFillColor(vg, nvgRGBA(60, 60, 80, 200))
    nvgFill(vg)
    nvgFontFaceId(vg, fontId)
    nvgFontSize(vg, 12 * S)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(220, 220, 220, 220))
    nvgText(vg, btnX + btnW / 2, btnY + btnH / 2, "返回主页")

    -- AI托管 (右下)
    local rbx = aX + aDS - btnW
    nvgBeginPath(vg)
    nvgRoundedRect(vg, rbx, btnY, btnW, btnH, 4 * S)
    if isAIProxy_ then
        nvgFillColor(vg, nvgRGBA(60, 100, 180, 200))
    else
        nvgFillColor(vg, nvgRGBA(60, 60, 80, 200))
    end
    nvgFill(vg)
    nvgFillColor(vg, nvgRGBA(220, 220, 220, 220))
    nvgText(vg, rbx + btnW / 2, btnY + btnH / 2, isAIProxy_ and "AI托管中" or "AI托管")

    -- 玩家淘汰提示
    if not alive_[1] and phase_ == "playing" then
        nvgFontSize(vg, 18 * S)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 100, 80, 220))
        nvgText(vg, aX + aDS / 2, aY - 20 * S, "你已被淘汰！观战中...")
    end
end

local function DrawGameOver(vg, fontId, aX, aY, aDS, S)
    -- 半透明遮罩
    nvgBeginPath(vg)
    nvgRect(vg, aX, aY, aDS, aDS)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, math.floor(clamp(gameOverTimer_ * 80, 0, 160))))
    nvgFill(vg)

    if gameOverTimer_ < 0.5 then return end

    nvgFontFaceId(vg, fontId)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    local cx = aX + aDS / 2
    local cy = aY + aDS * 0.4

    nvgFontSize(vg, 32 * S)
    nvgFillColor(vg, nvgRGBA(255, 220, 60, 255))
    local wn = (winner_ == 1) and "你" or ("#" .. winner_)
    nvgText(vg, cx, cy, "大吉大利，今晚吃鸡！")

    nvgFontSize(vg, 20 * S)
    nvgFillColor(vg, nvgRGBA(220, 220, 220, 220))
    nvgText(vg, cx, cy + 40 * S, "胜者: " .. wn)

    if gameOverTimer_ > 2 then
        nvgFontSize(vg, 13 * S)
        nvgFillColor(vg, nvgRGBA(180, 180, 180, 180))
        nvgText(vg, cx, cy + 75 * S, "即将返回主页...")
    end
end

-- ============================================================================
-- ProcessHUDInput (按钮点击)
-- ============================================================================

local function ProcessHUDInput()
    if not input:GetMouseButtonPress(MOUSEB_LEFT) then return end
    local mx = input:GetMousePosition().x / dpr_ / nvgScale_ - designOffsetX_
    local my = input:GetMousePosition().y / dpr_ / nvgScale_

    local S = arenaScale_
    local btnW = 70 * S
    local btnH = 28 * S
    local btnY = arenaY_ + arenaDrawSize_ + 6 * S

    -- 返回主页
    local btnX = arenaX_
    if mx >= btnX and mx <= btnX + btnW and my >= btnY and my <= btnY + btnH then
        BattleRoyale.Cleanup()
        if onGameEnd_ then onGameEnd_() end
        return
    end

    -- AI托管
    local rbx = arenaX_ + arenaDrawSize_ - btnW
    if mx >= rbx and mx <= rbx + btnW and my >= btnY and my <= btnY + btnH then
        isAIProxy_ = not isAIProxy_
    end
end

-- ============================================================================
-- Draw (called by Standalone)
-- ============================================================================

function BattleRoyale.Draw(vg, fontId, dW, dH, aX, aY, aDS, aScale,
                           nScale, deviceDPR, dOffX)
    vg_ = vg
    fontId_ = fontId
    designW_ = dW
    designH_ = dH
    arenaX_ = aX
    arenaY_ = aY
    arenaDrawSize_ = aDS
    arenaScale_ = aScale
    nvgScale_ = nScale or 1
    dpr_ = deviceDPR or 1
    designOffsetX_ = dOffX or 0

    local S = arenaScale_

    -- HUD 输入
    ProcessHUDInput()

    -- Viewport
    local viewL = camX_ - VIEWPORT / 2
    local viewT = camY_ - VIEWPORT / 2
    local vpScale = arenaDrawSize_ / VIEWPORT

    -- ===== 视口内容 (地图坐标系) =====
    nvgSave(vg)
    nvgIntersectScissor(vg, aX - 1, aY - 1, aDS + 2, aDS + 2)
    nvgTranslate(vg, aX + shake_.ox * S, aY + shake_.oy * S)
    nvgScale(vg, vpScale, vpScale)
    nvgTranslate(vg, -viewL, -viewT)

    -- 地图
    BRMap.Draw(vg, viewL, viewT, VIEWPORT)

    -- 弹道
    SkillExecutor.Draw(vg, 0, 0)

    -- 球体
    DrawBalls(vg)

    -- 伤害数字
    DrawDamagePopups(vg, fontId)

    -- 公告
    DrawAnnouncement(vg, fontId)

    nvgRestore(vg)

    -- ===== HUD 覆盖 (设计坐标) =====
    -- 排行榜 (竞技场右上角)
    local lbX = aX + aDS + 8 * S
    local lbY = aY
    DrawLeaderboard(vg, fontId, lbX, lbY, S)

    -- 按钮 / 状态
    DrawHUD(vg, fontId, aX, aY, aDS, S)

    -- Game Over
    if phase_ == "gameover" then
        DrawGameOver(vg, fontId, aX, aY, aDS, S)
    end
end

-- ============================================================================
-- Query
-- ============================================================================

function BattleRoyale.GetPhase()
    return phase_
end

return BattleRoyale
