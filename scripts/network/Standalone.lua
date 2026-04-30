-- ============================================================================
-- Standalone.lua - Single Player vs AI (Modular Skill System)
-- State machine: menu → cultivation → playing → gameover → menu
-- Pure physics movement, data-driven skills, ball customization
-- ============================================================================

local Standalone = {}
local Settings          = require("config.Settings")
local BallAI            = require("game.BallAI")
local SkillRegistry     = require("game.SkillRegistry")
local SkillExecutor     = require("game.SkillExecutor")
local Expressions       = require("game.Expressions")
local BallCustomization = require("game.BallCustomization")
local StartPage         = require("ui.StartPage")
local CultivationPage   = require("ui.CultivationPage")

local UI = require("urhox-libs/UI")

local BALL  = Settings.Ball
local POPUP = Settings.Popup

-- ============================================================================
-- Design Resolution (Mode A)
-- ============================================================================

local designW, designH = Settings.Arena.DesignWidth, Settings.Arena.DesignHeight
local physW, physH, dpr, logicalW, logicalH
local nvgScale_, screenDesignW, screenDesignH, designOffsetX, designOffsetY

local function RecalcLayout()
    physW, physH = graphics:GetWidth(), graphics:GetHeight()
    dpr = graphics:GetDPR()
    if dpr <= 0 then dpr = 1 end
    logicalW, logicalH = physW / dpr, physH / dpr
    if logicalW <= 0 or logicalH <= 0 then
        logicalW, logicalH = designW, designH
    end
    nvgScale_ = math.min(logicalW / designW, logicalH / designH)
    if nvgScale_ <= 0 then nvgScale_ = 1 end
    screenDesignW = logicalW / nvgScale_
    screenDesignH = logicalH / nvgScale_
    designOffsetX = (screenDesignW - designW) / 2
    designOffsetY = (screenDesignH - designH) / 2
end

-- ============================================================================
-- State
-- ============================================================================

---@type Scene
local scene_ = nil
local vg_ = nil
local fontNormal_ = -1

-- Game logic
local balls_ = {}
local aiStates_ = {}
local cooldowns_ = { 0, 0 }
local collisionCooldown_ = 0

-- Game phase
local gamePhase_ = "menu"
local gameWinner_ = 0
local gameOverTimer_ = 0

-- Customization
local playerCustom_ = nil
local aiCustom_ = nil

-- Player control
local isAIProxy_ = true

-- Visual effects
local damagePopups_ = {}
local particles_ = {}
local announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
local shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

-- Tier transition
local tierFlash_ = { 0, 0 }
local lastTier_ = { "normal", "normal" }

-- Arena position (design coords)
local arenaX_, arenaY_ = 0, 0

-- UI initialized flag
local uiInited_ = false

local TIER_NAMES = { normal = "普通", enhanced = "强化", ultimate = "决战" }

-- Debug panel
local debugShow_ = false
local debugToggleCooldown_ = 0

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetCustom(team)
    return team == 1 and playerCustom_ or aiCustom_
end

local function GetActiveSkillDef(team)
    local ball = balls_[team]
    if not ball then return nil end
    local tier = BallAI.GetActiveTier(ball.hp)
    local custom = GetCustom(team)
    if not custom or not custom.skills then return nil end
    local skillId = custom.skills[tier]
    if not skillId then return nil end
    return SkillRegistry.Get(skillId)
end

local function EnsureUIInit()
    if uiInited_ then return end
    uiInited_ = true
    UI.Init({
        theme = "dark",
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } },
        },
        scale = UI.Scale.DESIGN_RESOLUTION(designW, designH),
    })
end

-- ============================================================================
-- Entry
-- ============================================================================

function Standalone.Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)

    RecalcLayout()
    -- NanoVG deferred to StartGame() to reduce startup memory
    SetupCamera()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("ScreenMode", "HandleScreenMode")

    ShowMenu()
    print("[Standalone] Started - Ball Battle Arena")
end

function Standalone.Stop()
    UI.Shutdown()
    if vg_ then nvgDelete(vg_); vg_ = nil end
end

function SetupNanoVG()
    vg_ = nvgCreate(1)
    if not vg_ then
        print("[Standalone] ERROR: NanoVG creation failed")
        return
    end
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
end

function SetupCamera()
    local cameraNode = scene_:CreateChild("Camera", LOCAL)
    local camera = cameraNode:CreateComponent("Camera", LOCAL)
    camera.orthographic = true
    camera.orthoSize = 10
    renderer:SetViewport(0, Viewport:new(scene_, camera))
end

function HandleScreenMode(eventType, eventData)
    RecalcLayout()
end

-- ============================================================================
-- Navigation
-- ============================================================================

function ShowMenu()
    gamePhase_ = "menu"
    -- Destroy NanoVG to free memory while in menu (UI has its own context)
    if vg_ then
        nvgDelete(vg_)
        vg_ = nil
        fontNormal_ = -1
    end
    EnsureUIInit()
    StartPage.Show({
        onBattle = function()
            StartGame()
        end,
        onCultivation = function()
            ShowCultivation()
        end,
    })
end

function ShowCultivation()
    gamePhase_ = "cultivation"
    local data = BallCustomization.Load()
    CultivationPage.Show(data, {
        onSave = function(newData)
            BallCustomization.Save(newData)
            playerCustom_ = newData
            print("[Standalone] Customization saved")
            ShowMenu()
        end,
        onBack = function()
            ShowMenu()
        end,
    })
end

function ShowGameUI()
    local children = {
        UI.Panel {
            position = "absolute",
            left = 20, top = 20,
            children = {
                UI.Button {
                    text = "返回菜单",
                    variant = "outline",
                    width = 120, height = 40,
                    fontSize = 14,
                    onClick = function() ShowMenu() end,
                },
            },
        },
        UI.Panel {
            position = "absolute",
            right = 20, top = 20,
            children = {
                UI.Button {
                    text = isAIProxy_ and "手动射击" or "AI 代理",
                    variant = isAIProxy_ and "outline" or "primary",
                    width = 140, height = 40,
                    fontSize = 14,
                    onClick = function(self)
                        isAIProxy_ = not isAIProxy_
                        self:SetText(isAIProxy_ and "手动射击" or "AI 代理")
                        self.props.variant = isAIProxy_ and "outline" or "primary"
                    end,
                },
            },
        },
    }

    UI.SetRoot(UI.Panel {
        width = "100%", height = "100%",
        position = "absolute",
        children = children,
    })
end

-- ============================================================================
-- Game Init
-- ============================================================================

function StartGame()
    -- Create NanoVG context on demand (destroyed when returning to menu)
    if not vg_ then
        SetupNanoVG()
    end

    local size = Settings.Arena.Size

    playerCustom_ = BallCustomization.Load()
    aiCustom_ = BallCustomization.Randomize()

    for team = 1, 2 do
        local sp = Settings.SpawnPoints[team]
        local angle = math.random() * 2 * math.pi
        balls_[team] = {
            x = sp.x + size / 2,
            y = sp.y + size / 2,
            vx = math.cos(angle) * BALL.InitialSpeed,
            vy = math.sin(angle) * BALL.InitialSpeed,
            hp = BALL.MaxHP,
            knockbackTimer = 0,
            pendingWallSlamDmg = 0,
            slowTimer = 0,
            slowFactor = 1.0,
            stunTimer = 0,
        }
        aiStates_[team] = BallAI.CreateState()
    end

    cooldowns_ = { 0, 0 }
    collisionCooldown_ = 0
    gameWinner_ = 0
    gameOverTimer_ = 0
    lastTier_ = { "normal", "normal" }
    tierFlash_ = { 0, 0 }

    damagePopups_ = {}
    particles_ = {}
    announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
    shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

    SkillExecutor.Clear()

    gamePhase_ = "playing"
    isAIProxy_ = true
    ShowGameUI()
    print("[Standalone] Game started!")
end

-- ============================================================================
-- Main Update
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    if gamePhase_ ~= "playing" and gamePhase_ ~= "gameover" then return end

    -- TAB toggle debug panel
    if debugToggleCooldown_ > 0 then debugToggleCooldown_ = debugToggleCooldown_ - dt end
    if input:GetKeyPress(KEY_TAB) and debugToggleCooldown_ <= 0 then
        debugShow_ = not debugShow_
        debugToggleCooldown_ = 0.3
    end

    -- Always update visual effects
    UpdateDamagePopups(dt)
    UpdateParticles(dt)
    UpdateScreenShake(dt)
    for team = 1, 2 do
        if cooldowns_[team] > 0 then cooldowns_[team] = cooldowns_[team] - dt end
    end
    if announcement_.timer > 0 then announcement_.timer = announcement_.timer - dt end

    -- Tier transition flash
    for team = 1, 2 do
        if tierFlash_[team] > 0 then tierFlash_[team] = tierFlash_[team] - dt end
        if balls_[team] then
            local tier = BallAI.GetActiveTier(balls_[team].hp)
            if tier ~= lastTier_[team] then
                lastTier_[team] = tier
                tierFlash_[team] = 0.4
                ScreenShake(5, 0.2)
                local c = GetCustom(team).color
                SpawnParticleBurst(balls_[team].x, balls_[team].y, 20,
                    {c.r, c.g, c.b, 255}, 60, 200, 2, 5, 0.5)
                local tierName = TIER_NAMES[tier] or tier
                SetAnnouncement(
                    string.format("%s进入%s阶段!", team == 1 and "玩家" or "AI", tierName),
                    c.r, c.g, c.b)
            end
        end
    end

    if gamePhase_ == "gameover" then
        gameOverTimer_ = gameOverTimer_ + dt
        SkillExecutor.UpdateVisuals(dt, balls_)
        if gameOverTimer_ >= 4.0 then ShowMenu() end
        return
    end

    -- === PLAYING PHASE ===
    if collisionCooldown_ > 0 then collisionCooldown_ = collisionCooldown_ - dt end
    for team = 1, 2 do
        local b = balls_[team]
        if b.knockbackTimer > 0 then b.knockbackTimer = b.knockbackTimer - dt end
        if b.slowTimer > 0 then
            b.slowTimer = b.slowTimer - dt
            if b.slowTimer <= 0 then b.slowFactor = 1.0 end
        end
        if b.stunTimer > 0 then b.stunTimer = b.stunTimer - dt end
    end

    -- Stun blocks shooting
    if not balls_[1].stunTimer or balls_[1].stunTimer <= 0 then
        ProcessInput(1, dt)
    end
    if not balls_[2].stunTimer or balls_[2].stunTimer <= 0 then
        ProcessInput(2, dt)
    end

    UpdateBallPhysics(dt)

    -- SkillExecutor update with callbacks
    local callbacks = {
        onHit = function(targetTeam, damage, kx, ky, projType, skillId, proj)
            local tgt = balls_[targetTeam]
            if not tgt then return end
            tgt.hp = tgt.hp - damage
            tgt.vx = tgt.vx + kx
            tgt.vy = tgt.vy + ky
            -- Beam / water_pillar wall slam setup
            if (projType == "beam") and proj then
                tgt.knockbackTimer = proj.knockbackWindow or 0.8
                tgt.pendingWallSlamDmg = proj.wallSlamDamage or 0
                -- Stun (水柱)
                if proj.stunDuration and proj.stunDuration > 0 then
                    tgt.stunTimer = proj.stunDuration
                end
            end
            -- Slow effect (水球)
            if proj and proj.slowFactor then
                tgt.slowTimer = proj.slowDuration or 2.0
                tgt.slowFactor = proj.slowFactor
            end
            local skillDef = SkillRegistry.Get(skillId)
            local c = skillDef and skillDef.color or {r=255,g=255,b=255}
            if damage > 0.1 then
                AddDamagePopup(tgt.x, tgt.y - BALL.Radius - 10, damage, c.r, c.g, c.b)
            end
            ScreenShake(math.min(damage, 8), 0.15)
            CheckGameOver()
        end,
        onDot = function(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            SkillExecutor.AddDot(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            ScreenShake(2, 0.1)
        end,
        onDotTick = function(targetTeam, sourceTeam, dmgT, healT)
            local tgt = balls_[targetTeam]
            local src = balls_[sourceTeam]
            if tgt then
                tgt.hp = tgt.hp - dmgT
                if dmgT > 0.1 then
                    AddDamagePopup(tgt.x, tgt.y - BALL.Radius, dmgT, 200, 80, 255)
                end
            end
            if src and healT > 0 then
                src.hp = math.min(src.hp + healT, BALL.MaxHP)
                AddDamagePopup(src.x, src.y - BALL.Radius, healT, 80, 255, 120)
            end
            CheckGameOver()
        end,
        onSlow = function(targetTeam, factor, duration)
            local tgt = balls_[targetTeam]
            if tgt then
                tgt.slowTimer = math.max(tgt.slowTimer, duration)
                tgt.slowFactor = math.min(tgt.slowFactor, factor)
            end
        end,
    }
    SkillExecutor.Update(dt, balls_, callbacks)
    SkillExecutor.UpdateVisuals(dt, balls_)
end

-- ============================================================================
-- Check Game Over
-- ============================================================================

function CheckGameOver()
    for team = 1, 2 do
        if balls_[team] and balls_[team].hp <= 0 then
            balls_[team].hp = 0
            gamePhase_ = "gameover"
            gameOverTimer_ = 0
            gameWinner_ = team == 1 and 2 or 1
            return true
        end
    end
    return false
end

-- ============================================================================
-- Process Input (Shooting Only - no movement control)
-- ============================================================================

function ProcessInput(team, dt)
    local ball = balls_[team]
    local opponent = balls_[team == 1 and 2 or 1]
    if not ball or not opponent then return end

    local skillDef = GetActiveSkillDef(team)
    if not skillDef then return end

    local cooldown = cooldowns_[team]
    local projSpeed = skillDef.projSpeed or 500

    if team == 1 and not isAIProxy_ then
        -- Player manual aim + fire
        if input:GetMouseButtonDown(MOUSEB_LEFT) and cooldown <= 0 then
            local mousePos = input.mousePosition
            local bScreenX = (arenaX_ + ball.x + designOffsetX) * nvgScale_ * dpr
            local bScreenY = (arenaY_ + ball.y + designOffsetY) * nvgScale_ * dpr
            local dx = mousePos.x - bScreenX
            local dy = mousePos.y - bScreenY
            local dist = math.sqrt(dx * dx + dy * dy)
            if dist < 1 then return end
            local dirX, dirY = dx / dist, dy / dist

            local cd = SkillExecutor.Fire(skillDef, 1, 2, ball.x, ball.y, dirX, dirY)
            cooldowns_[1] = cd
            SetAnnouncement(skillDef.name, skillDef.color.r, skillDef.color.g, skillDef.color.b)
        end
    else
        -- AI shooting
        local ai = BallAI.Update(aiStates_[team], ball, opponent, cooldown, projSpeed, dt)
        if ai.shoot and cooldown <= 0 then
            local otherTeam = team == 1 and 2 or 1
            local cd = SkillExecutor.Fire(skillDef, team, otherTeam, ball.x, ball.y, ai.aimX, ai.aimY)
            cooldowns_[team] = cd
            SetAnnouncement(skillDef.name, skillDef.color.r, skillDef.color.g, skillDef.color.b)
        end
    end
end

-- ============================================================================
-- Ball Physics (Pure: launch velocity → wall bounce → speed cap)
-- ============================================================================

function UpdateBallPhysics(dt)
    local size = Settings.Arena.Size
    local r = BALL.Radius

    for team = 1, 2 do
        local ball = balls_[team]

        -- Apply slow factor to effective movement
        local factor = ball.slowFactor
        ball.x = ball.x + ball.vx * factor * dt
        ball.y = ball.y + ball.vy * factor * dt

        -- Speed cap
        local spd = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        if spd > BALL.SpeedCap then
            ball.vx = ball.vx * BALL.SpeedCap / spd
            ball.vy = ball.vy * BALL.SpeedCap / spd
        end

        -- Wall collision with bounce restitution
        local hitWall = false
        if ball.x - r < 0 then
            ball.x = r
            ball.vx = math.abs(ball.vx) * BALL.BounceRestitution
            hitWall = true
        elseif ball.x + r > size then
            ball.x = size - r
            ball.vx = -math.abs(ball.vx) * BALL.BounceRestitution
            hitWall = true
        end
        if ball.y - r < 0 then
            ball.y = r
            ball.vy = math.abs(ball.vy) * BALL.BounceRestitution
            hitWall = true
        elseif ball.y + r > size then
            ball.y = size - r
            ball.vy = -math.abs(ball.vy) * BALL.BounceRestitution
            hitWall = true
        end

        -- Wall slam from beam knockback
        if ball.knockbackTimer > 0 and hitWall and ball.pendingWallSlamDmg > 0 then
            local dmg = ball.pendingWallSlamDmg
            ball.hp = ball.hp - dmg
            ball.knockbackTimer = 0
            ball.pendingWallSlamDmg = 0
            AddDamagePopup(ball.x, ball.y - r - 20, dmg, 255, 200, 50)
            SetAnnouncement("WALL SLAM!", 255, 200, 50)
            ScreenShake(8, 0.25)
            SpawnParticleBurst(ball.x, ball.y, 15, {255, 200, 50, 255}, 80, 250, 2, 5, 0.4)
            CheckGameOver()
        end
    end

    -- Ball-ball elastic collision
    local b1, b2 = balls_[1], balls_[2]
    local dx, dy = b2.x - b1.x, b2.y - b1.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < r * 2 and dist > 0.01 then
        local nx, ny = dx / dist, dy / dist
        local ov = r * 2 - dist
        b1.x = b1.x - nx * ov * 0.5
        b1.y = b1.y - ny * ov * 0.5
        b2.x = b2.x + nx * ov * 0.5
        b2.y = b2.y + ny * ov * 0.5

        local dvx, dvy = b1.vx - b2.vx, b1.vy - b2.vy
        local dvDotN = dvx * nx + dvy * ny
        if dvDotN > 0 then
            b1.vx = b1.vx - dvDotN * nx
            b1.vy = b1.vy - dvDotN * ny
            b2.vx = b2.vx + dvDotN * nx
            b2.vy = b2.vy + dvDotN * ny

            if collisionCooldown_ <= 0 then
                local dmg = BALL.CollisionDamage
                b1.hp = b1.hp - dmg
                b2.hp = b2.hp - dmg
                collisionCooldown_ = 0.1
                AddDamagePopup(b1.x, b1.y - r, dmg, 255, 80, 80)
                AddDamagePopup(b2.x, b2.y - r, dmg, 255, 80, 80)
                CheckGameOver()
            end
        end
    end
end

-- ============================================================================
-- Visual Effects
-- ============================================================================

function AddDamagePopup(x, y, damage, r, g, b)
    local isHeal = (g > 200 and r < 150)
    table.insert(damagePopups_, {
        x = x, y = y, damage = damage,
        color = { r, g, b, 255 },
        elapsed = 0, duration = POPUP.Duration,
        fontSize = math.min(POPUP.BaseFontSize + damage * POPUP.FontSizePerDmg, POPUP.MaxFontSize),
        shakeAmp = math.min(POPUP.BaseShake + damage * POPUP.ShakePerDmg, POPUP.MaxShake),
        isHeal = isHeal,
    })
    if damage >= 5 then ScreenShake(math.min(damage, 12), 0.2) end
end

function SetAnnouncement(text, r, g, b)
    announcement_.text = text
    announcement_.timer = 1.2
    announcement_.duration = 1.2
    announcement_.color = { r, g, b, 255 }
end

function SpawnParticleBurst(x, y, count, color, speedMin, speedMax, rMin, rMax, life)
    for _ = 1, count do
        local a = math.random() * 2 * math.pi
        local spd = speedMin + math.random() * (speedMax - speedMin)
        local radius = rMin + math.random() * (rMax - rMin)
        table.insert(particles_, {
            x = x, y = y,
            vx = math.cos(a) * spd, vy = math.sin(a) * spd,
            radius = radius, life = life or 0.5, maxLife = life or 0.5,
            color = { color[1], color[2], color[3], color[4] or 255 },
        })
    end
end

function UpdateDamagePopups(dt)
    local i = 1
    while i <= #damagePopups_ do
        local p = damagePopups_[i]
        p.elapsed = p.elapsed + dt
        p.y = p.y - POPUP.RiseSpeed * dt
        if p.elapsed >= p.duration then
            table.remove(damagePopups_, i)
        else
            i = i + 1
        end
    end
end

function UpdateParticles(dt)
    local i = 1
    while i <= #particles_ do
        local p = particles_[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(particles_, i)
        else
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt
            p.vx = p.vx * 0.96
            p.vy = p.vy * 0.96
            i = i + 1
        end
    end
end

function ScreenShake(intensity, duration)
    shake_.intensity = math.max(shake_.intensity, intensity)
    shake_.duration = math.max(shake_.duration, duration)
    shake_.elapsed = 0
end

function UpdateScreenShake(dt)
    if shake_.duration > 0 then
        shake_.elapsed = shake_.elapsed + dt
        if shake_.elapsed >= shake_.duration then
            shake_.duration = 0; shake_.intensity = 0; shake_.ox = 0; shake_.oy = 0
        else
            local t = 1 - shake_.elapsed / shake_.duration
            local amp = shake_.intensity * t
            shake_.ox = (math.random() * 2 - 1) * amp
            shake_.oy = (math.random() * 2 - 1) * amp
        end
    end
end

-- ============================================================================
-- NanoVG Rendering
-- ============================================================================

function DoNanoVGRender()
    nvgScale(vg_, nvgScale_, nvgScale_)

    -- Background
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
    nvgFillColor(vg_, nvgRGBA(8, 8, 14, 255)); nvgFill(vg_)

    -- Tier flash overlay
    for team = 1, 2 do
        if tierFlash_[team] > 0 then
            local c = GetCustom(team).color
            local a = math.floor(120 * (tierFlash_[team] / 0.4))
            nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
            nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, a)); nvgFill(vg_)
        end
    end

    nvgTranslate(vg_, designOffsetX, designOffsetY)
    nvgSave(vg_)
    nvgTranslate(vg_, shake_.ox, shake_.oy)

    -- Layout
    local titleH = 55
    local panelH = 90
    local gap = 8
    local totalH = titleH + gap + Settings.Arena.Size + gap + panelH
    local startY = math.max(4, (designH - totalH) / 2)

    arenaX_ = (designW - Settings.Arena.Size) / 2
    arenaY_ = startY + titleH + gap
    local panelY = arenaY_ + Settings.Arena.Size + gap

    DrawTitle(designW, startY)

    -- Arena border
    nvgBeginPath(vg_); nvgRect(vg_, arenaX_, arenaY_, Settings.Arena.Size, Settings.Arena.Size)
    nvgStrokeColor(vg_, nvgRGBA(180, 180, 180, 120)); nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)

    SkillExecutor.Draw(vg_, arenaX_, arenaY_)
    DrawParticles()
    DrawBalls()
    DrawDamagePopups()
    DrawAnnouncement()
    DrawBottomPanel(designW, panelY)

    nvgRestore(vg_)

    if gamePhase_ == "gameover" then DrawGameOver(designW, designH) end
    DrawDebugPanel()
end

function HandleNanoVGRender(eventType, eventData)
    if not vg_ then return end
    if gamePhase_ ~= "playing" and gamePhase_ ~= "gameover" then return end
    if not balls_[1] then return end
    if nvgScale_ <= 0 or logicalW <= 0 or logicalH <= 0 then return end

    nvgBeginFrame(vg_, logicalW, logicalH, dpr)
    local ok, err = pcall(DoNanoVGRender)
    nvgEndFrame(vg_)

    if not ok then
        print("[Standalone] Render error: " .. tostring(err))
    end
end

-- ============================================================================
-- Draw: Title (player VS AI with custom colors)
-- ============================================================================

function DrawTitle(w, y)
    if fontNormal_ == -1 then return end
    local centerX = w / 2
    local titleY = y + 28
    local c1 = GetCustom(1).color
    local c2 = GetCustom(2).color

    nvgFontFaceId(vg_, fontNormal_)

    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, centerX - 32, titleY + 2, "玩家", nil)
    nvgFillColor(vg_, nvgRGBA(c1.r, c1.g, c1.b, 255))
    nvgText(vg_, centerX - 30, titleY, "玩家", nil)

    nvgFontSize(vg_, 26)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, centerX, titleY, "VS", nil)

    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, centerX + 32, titleY + 2, "AI", nil)
    nvgFillColor(vg_, nvgRGBA(c2.r, c2.g, c2.b, 255))
    nvgText(vg_, centerX + 30, titleY, "AI", nil)
end

-- ============================================================================
-- Draw: Balls (custom color + expression face + HP bar)
-- ============================================================================

function DrawBalls()
    local r = BALL.Radius
    local elapsedTime = time.elapsedTime

    for team = 1, 2 do
        local ball = balls_[team]
        local custom = GetCustom(team)
        local c = custom.color
        local bx, by = arenaX_ + ball.x, arenaY_ + ball.y

        -- Tier-based aura
        local tier = BallAI.GetActiveTier(ball.hp)
        if tier == "ultimate" then
            local pulseR = r + 8 + math.sin(elapsedTime * 5) * 4
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, pulseR)
            nvgFillPaint(vg_, nvgRadialGradient(vg_, bx, by, r, pulseR,
                nvgRGBA(c.r, c.g, c.b, math.floor(60 + 40 * math.sin(elapsedTime * 4))),
                nvgRGBA(c.r, c.g, c.b, 0)))
            nvgFill(vg_)
        elseif tier == "enhanced" then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 4)
            nvgStrokeColor(vg_, nvgRGBA(c.r, c.g, c.b, math.floor(60 + 30 * math.sin(elapsedTime * 3))))
            nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
        end

        -- Ball body (flat solid color)
        nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r)
        nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 255)); nvgFill(vg_)

        -- Expression face
        Expressions.Draw(vg_, custom.expression, bx, by, r)

        -- HP bar above ball
        local hpBarW = r * 2.4
        local hpBarH = 4
        local hpBarX = bx - hpBarW / 2
        local hpBarY = by - r - 12
        local hpPct = math.max(0, ball.hp / BALL.MaxHP)

        nvgBeginPath(vg_); nvgRoundedRect(vg_, hpBarX, hpBarY, hpBarW, hpBarH, 2)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150)); nvgFill(vg_)
        if hpPct > 0 then
            local hr = hpPct < 0.5 and 255 or math.floor(255 * (1 - hpPct) * 2)
            local hg = hpPct > 0.5 and 255 or math.floor(255 * hpPct * 2)
            nvgBeginPath(vg_); nvgRoundedRect(vg_, hpBarX, hpBarY, hpBarW * hpPct, hpBarH, 2)
            nvgFillColor(vg_, nvgRGBA(hr, hg, 80, 220)); nvgFill(vg_)
        end

        -- HP number
        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 11)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
        nvgText(vg_, bx, hpBarY - 2, tostring(math.floor(ball.hp)), nil)

        -- Player indicator
        if team == 1 then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 3)
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 0, math.floor(120 + 60 * math.sin(elapsedTime * 4))))
            nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
        end

        -- Slow debuff indicator
        if ball.slowTimer > 0 then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 2)
            nvgStrokeColor(vg_, nvgRGBA(120, 255, 50, 120))
            nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)
        end

        -- Stun indicator (旋转星星)
        if ball.stunTimer and ball.stunTimer > 0 then
            local starCount = 3
            for si = 1, starCount do
                local sa = elapsedTime * 4 + (si - 1) * (2 * math.pi / starCount)
                local sx = bx + math.cos(sa) * (r + 6)
                local sy = by - r - 8 + math.sin(sa) * 4
                nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 12)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg_, nvgRGBA(255, 255, 100, 220))
                nvgText(vg_, sx, sy, "*", nil)
            end
        end
    end
end

-- ============================================================================
-- Draw: Particles
-- ============================================================================

function DrawParticles()
    for _, p in ipairs(particles_) do
        local t = p.life / p.maxLife
        nvgBeginPath(vg_)
        nvgCircle(vg_, arenaX_ + p.x, arenaY_ + p.y, p.radius * (0.5 + 0.5 * t))
        nvgFillColor(vg_, nvgRGBA(p.color[1], p.color[2], p.color[3], math.floor(p.color[4] * t)))
        nvgFill(vg_)
    end
end

-- ============================================================================
-- Draw: Damage Popups
-- ============================================================================

function DrawDamagePopups()
    if fontNormal_ == -1 then return end
    for _, p in ipairs(damagePopups_) do
        local t = p.elapsed / p.duration
        local alpha = 255
        if t > 0.7 then alpha = math.floor(255 * (1 - (t - 0.7) / 0.3)) end
        if alpha <= 0 then goto continue end

        local sm = 1.0
        if p.elapsed < POPUP.ScalePunchTime then
            sm = 1.0 + (POPUP.ScalePunchAmount - 1.0) * math.sin(p.elapsed / POPUP.ScalePunchTime * math.pi)
        end
        local fs = p.fontSize * sm
        local dc = 1 - t
        local sx = p.shakeAmp * dc * math.sin(p.elapsed * POPUP.ShakeFreq)
        local sy = p.shakeAmp * dc * math.cos(p.elapsed * POPUP.ShakeFreq * 1.3)
        local screenX, screenY = arenaX_ + p.x + sx, arenaY_ + p.y + sy

        local fmt = (p.damage == math.floor(p.damage)) and "%.0f" or "%.1f"
        local txt = (p.isHeal and "+" or "-") .. string.format(fmt, p.damage)

        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, fs)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local off = math.max(1.5, fs * 0.05)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.7)))
        nvgText(vg_, screenX - off, screenY, txt, nil)
        nvgText(vg_, screenX + off, screenY, txt, nil)
        nvgText(vg_, screenX, screenY - off, txt, nil)
        nvgText(vg_, screenX, screenY + off, txt, nil)
        nvgFillColor(vg_, nvgRGBA(p.color[1], p.color[2], p.color[3], alpha))
        nvgText(vg_, screenX, screenY, txt, nil)
        ::continue::
    end
end

-- ============================================================================
-- Draw: Announcement
-- ============================================================================

function DrawAnnouncement()
    if announcement_.timer <= 0 or fontNormal_ == -1 then return end

    local t = announcement_.timer / announcement_.duration
    local alpha = 255
    if t > 0.8 then alpha = math.floor(255 * ((1 - t) / 0.2))
    elseif t < 0.3 then alpha = math.floor(255 * (t / 0.3)) end
    if alpha <= 0 then return end

    local cx = arenaX_ + Settings.Arena.Size / 2
    local cy = arenaY_ + Settings.Arena.Size * 0.72

    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 22)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgBeginPath(vg_); nvgRoundedRect(vg_, cx - 120, cy - 14, 240, 28, 6)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.4))); nvgFill(vg_)

    local ac = announcement_.color
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.6)))
    nvgText(vg_, cx + 1, cy + 1, announcement_.text, nil)
    nvgFillColor(vg_, nvgRGBA(ac[1], ac[2], ac[3], alpha))
    nvgText(vg_, cx, cy, announcement_.text, nil)
end

-- ============================================================================
-- Draw: Bottom Panel (per-team info: name, tier, skill, cooldown)
-- ============================================================================

function DrawBottomPanel(w, panelY)
    if fontNormal_ == -1 then return end
    local size = Settings.Arena.Size
    local px = arenaX_
    local pw = size
    local ph = 86

    -- Panel background
    nvgBeginPath(vg_); nvgRoundedRect(vg_, px, panelY, pw, ph, 4)
    nvgFillColor(vg_, nvgRGBA(16, 16, 24, 200)); nvgFill(vg_)
    nvgBeginPath(vg_); nvgRoundedRect(vg_, px, panelY, pw, ph, 4)
    nvgStrokeColor(vg_, nvgRGBA(80, 80, 100, 80)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

    -- Center divider
    local midX = px + pw / 2
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, midX, panelY + 6); nvgLineTo(vg_, midX, panelY + ph - 6)
    nvgStrokeColor(vg_, nvgRGBA(80, 80, 100, 100)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

    for team = 1, 2 do
        local baseX = team == 1 and (px + 12) or (midX + 12)
        local barW = pw / 2 - 24
        local custom = GetCustom(team)
        local c = custom.color
        local ball = balls_[team]
        local tier = BallAI.GetActiveTier(ball.hp)
        local tierName = TIER_NAMES[tier] or tier
        local skillDef = GetActiveSkillDef(team)
        local skillName = skillDef and skillDef.name or "无技能"
        local cooldown = cooldowns_[team]
        local maxCd = skillDef and skillDef.cooldown or 1

        -- Team name
        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 15)
        nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
        nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 255))
        nvgText(vg_, baseX, panelY + 8, team == 1 and "玩家" or "AI", nil)

        -- Tier tag
        nvgFontSize(vg_, 11)
        nvgFillColor(vg_, nvgRGBA(200, 200, 220, 180))
        nvgText(vg_, baseX + 50, panelY + 10, "[" .. tierName .. "]", nil)

        -- Cooldown bar
        local barY = panelY + 26
        nvgBeginPath(vg_); nvgRoundedRect(vg_, baseX, barY, barW, 4, 2)
        nvgFillColor(vg_, nvgRGBA(30, 30, 50, 200)); nvgFill(vg_)
        if skillDef then
            if cooldown > 0 then
                local pct = 1 - cooldown / maxCd
                nvgBeginPath(vg_); nvgRoundedRect(vg_, baseX, barY, barW * pct, 4, 2)
                nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 160)); nvgFill(vg_)
            else
                nvgBeginPath(vg_); nvgRoundedRect(vg_, baseX, barY, barW, 4, 2)
                nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 220)); nvgFill(vg_)
            end
        end

        -- Skill info
        nvgFontSize(vg_, 11); nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
        nvgText(vg_, baseX, panelY + 35, "技能: " .. skillName, nil)
        if skillDef then
            nvgText(vg_, baseX, panelY + 49,
                "伤害: " .. skillDef.damage .. " | CD: " .. skillDef.cooldown .. "s", nil)
        else
            nvgText(vg_, baseX, panelY + 49, "当前阶段无技能装配", nil)
        end

        -- Ready / cooldown
        nvgFontSize(vg_, 12)
        if not skillDef then
            nvgFillColor(vg_, nvgRGBA(100, 100, 120, 140))
            nvgText(vg_, baseX, panelY + 66, "- 无技能 -", nil)
        elseif cooldown <= 0 then
            nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 255))
            nvgText(vg_, baseX, panelY + 66, skillName .. " READY", nil)
        else
            nvgFillColor(vg_, nvgRGBA(100, 100, 120, 180))
            nvgText(vg_, baseX, panelY + 66,
                string.format("%s  %.1fs", skillName, cooldown), nil)
        end
    end

    -- Bottom hint
    nvgFontSize(vg_, 10)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(100, 100, 120, 140))
    local hint = isAIProxy_
        and "AI 代理中 | 点击右上角切换手动射击"
        or "手动模式 | 点击鼠标发射技能"
    nvgText(vg_, px + pw / 2, panelY + ph + 4, hint, nil)
end

-- ============================================================================
-- Draw: Debug Panel (TAB toggle)
-- ============================================================================

function DrawDebugPanel()
    if not debugShow_ or fontNormal_ == -1 then return end

    local px = 10
    local py = 10
    local pw = 320
    local lineH = 16
    local lines = {}

    table.insert(lines, "=== DEBUG PANEL (TAB to close) ===")
    table.insert(lines, "")

    for team = 1, 2 do
        local ball = balls_[team]
        local custom = GetCustom(team)
        local tier = BallAI.GetActiveTier(ball.hp)
        local skillDef = GetActiveSkillDef(team)

        table.insert(lines, string.format("--- %s ---", team == 1 and "Player" or "AI"))
        table.insert(lines, string.format("  HP: %.1f / %d", ball.hp, BALL.MaxHP))
        table.insert(lines, string.format("  Tier: %s (%s)", tier, TIER_NAMES[tier] or "?"))
        table.insert(lines, string.format("  Pos: %.0f, %.0f", ball.x, ball.y))
        table.insert(lines, string.format("  Vel: %.0f, %.0f (spd %.0f)",
            ball.vx, ball.vy, math.sqrt(ball.vx*ball.vx + ball.vy*ball.vy)))
        table.insert(lines, string.format("  Skill: %s", skillDef and skillDef.name or "无"))
        table.insert(lines, string.format("  CD: %.1f / %s",
            math.max(0, cooldowns_[team]),
            skillDef and tostring(skillDef.cooldown) or "-"))
        table.insert(lines, string.format("  Slow: %.2f (%.1fs)", ball.slowFactor, math.max(0, ball.slowTimer)))
        table.insert(lines, string.format("  Stun: %.1fs", math.max(0, ball.stunTimer or 0)))
        table.insert(lines, string.format("  WallSlam: %d (%.1fs)",
            ball.pendingWallSlamDmg, math.max(0, ball.knockbackTimer)))
        table.insert(lines, "")
    end

    -- Executor state
    local projs = SkillExecutor.GetProjectiles()
    local vProjs = SkillExecutor.GetVisualProjectiles()
    local emitters = SkillExecutor.GetEmitters()
    local fzones = SkillExecutor.GetFireZones()
    local bubs = SkillExecutor.GetBubbles()
    local dots = SkillExecutor.GetDots()

    table.insert(lines, "--- Executor ---")
    table.insert(lines, string.format("  Projectiles: %d (vis: %d)", #projs, #vProjs))
    table.insert(lines, string.format("  Emitters: %d", #emitters))
    table.insert(lines, string.format("  FireZones: %d", #fzones))
    table.insert(lines, string.format("  Bubbles: %d", #bubs))
    table.insert(lines, string.format("  DOTs: %d", #dots))
    table.insert(lines, "")

    -- Skill config summary
    table.insert(lines, "--- Skill Config ---")
    for _, custom in ipairs({playerCustom_, aiCustom_}) do
        local label = (custom == playerCustom_) and "Player" or "AI"
        local sk = custom and custom.skills or {}
        table.insert(lines, string.format("  %s: N=%s E=%s U=%s",
            label,
            sk.normal or "-",
            sk.enhanced or "-",
            sk.ultimate or "-"))
    end

    local ph = (#lines + 1) * lineH + 10

    -- Background
    nvgBeginPath(vg_); nvgRoundedRect(vg_, px, py, pw, ph, 6)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200)); nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(0, 255, 100, 100)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

    -- Text
    nvgFontFaceId(vg_, fontNormal_)
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    for idx, line in ipairs(lines) do
        local ly = py + 6 + (idx - 1) * lineH
        if line:find("^===") or line:find("^---") then
            nvgFillColor(vg_, nvgRGBA(0, 255, 120, 255))
        else
            nvgFillColor(vg_, nvgRGBA(200, 220, 200, 230))
        end
        nvgText(vg_, px + 8, ly, line, nil)
    end
end

-- ============================================================================
-- Draw: Game Over
-- ============================================================================

function DrawGameOver(w, h)
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, w, h)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180)); nvgFill(vg_)

    nvgFontFaceId(vg_, fontNormal_)

    local names = { "玩家", "AI" }

    if gameWinner_ >= 1 and gameWinner_ <= 2 then
        local wc = GetCustom(gameWinner_).color
        nvgFontSize(vg_, 40); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
        nvgText(vg_, w / 2 + 2, h / 2 - 18, names[gameWinner_] .. " 获胜!", nil)
        nvgFillColor(vg_, nvgRGBA(wc.r, wc.g, wc.b, 255))
        nvgText(vg_, w / 2, h / 2 - 20, names[gameWinner_] .. " 获胜!", nil)

        nvgFontSize(vg_, 16)
        nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
        nvgText(vg_, w / 2, h / 2 + 18,
            "剩余血量: " .. math.floor(balls_[gameWinner_].hp), nil)
    else
        nvgFontSize(vg_, 40); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 100, 255))
        nvgText(vg_, w / 2, h / 2 - 20, "平局!", nil)
    end

    nvgFontSize(vg_, 16)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    local remaining = math.max(0, math.ceil(4.0 - gameOverTimer_))
    nvgText(vg_, w / 2, h / 2 + 55,
        remaining > 0 and string.format("%d 秒后返回菜单...", remaining) or "返回菜单...", nil)
end

return Standalone
