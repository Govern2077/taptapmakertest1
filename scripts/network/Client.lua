-- ============================================================================
-- Client.lua - Multiplayer Client
-- Main menu UI, NanoVG game rendering, input handling
-- ============================================================================

local Client = {}
local Shared = require("network.Shared")

require "LuaScripts/Utilities/Sample"

local UI = require("urhox-libs/UI")

local Settings = Shared.Settings
local EVENTS   = Shared.EVENTS
local CTRL     = Shared.CTRL
local VARS     = Shared.VARS
local BALL     = Settings.Ball
local WATER    = Settings.Water
local SPLASH   = Settings.Splash
local RAGE     = Settings.RageWater
local HOMING   = Settings.Homing
local POPUP    = Settings.Popup

-- ============================================================================
-- Design Resolution (Mode A)
-- ============================================================================

local designW, designH = Settings.Arena.DesignWidth, Settings.Arena.DesignHeight
local physW, physH, dpr, logicalW, logicalH
local nvgScale_, screenDesignW, screenDesignH, designOffsetX, designOffsetY

local function RecalcLayout()
    physW, physH = graphics:GetWidth(), graphics:GetHeight()
    dpr = graphics:GetDPR()
    logicalW, logicalH = physW / dpr, physH / dpr
    nvgScale_ = math.min(logicalW / designW, logicalH / designH)
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
local fontBold_ = -1

-- Game state (from server)
local myTeam_ = 0
local myNodeId_ = 0

-- Ball display state (read from replicated nodes)
local ballDisplay_ = {
    [1] = { x = 0, y = 0, vx = 0, vy = 0, hp = 100, maxHP = 100, isRage = false, isProxy = true },
    [2] = { x = 0, y = 0, vx = 0, vy = 0, hp = 100, maxHP = 100, isRage = false, isProxy = true },
}

-- Visual effects (local only)
local projectilesVis_ = {}   -- visual projectiles with trails
local damagePopups_ = {}
local particles_ = {}
local announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }

-- Screen shake
local shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

-- Rage flash
local rageFlash_ = 0
local wasRage_ = false

-- Arena position in design coords
local arenaX_, arenaY_ = 0, 0

-- Cooldowns (display only)
local blueCooldown_ = 0
local redCooldown_ = 0

-- DOT display
local dotsVis_ = {}

-- Game over
local gameOver_ = false
local gameWinner_ = 0
local gameOverTimer_ = 0
local returningToLobby_ = false

-- Input state
local isManualControl_ = false  -- false = AI proxy, true = player control

-- UI state
local menuVisible_ = true
local waitingForOpponent_ = false  -- waiting screen after connecting
local uiRoot_ = nil

-- Connection
local pendingNodeId_ = 0

-- ============================================================================
-- Entry
-- ============================================================================

function Client.Start()
    SampleStart()
    Shared.RegisterEvents()

    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)

    RecalcLayout()
    SetupNanoVG()
    SetupCamera()

    -- Platform Lobby already handled room creation/joining.
    -- When IsNetworkMode()==true, connection is established, go directly to game.
    menuVisible_ = false
    waitingForOpponent_ = true

    -- Subscribe events BEFORE sending ClientReady (so we can receive responses)
    SubscribeToEvent(EVENTS.ASSIGN_ROLE, "HandleAssignRole")
    SubscribeToEvent(EVENTS.HEALTH_UPDATE, "HandleHealthUpdate")
    SubscribeToEvent(EVENTS.DAMAGE_POPUP, "HandleDamagePopup")
    SubscribeToEvent(EVENTS.ANNOUNCEMENT, "HandleAnnouncement")
    SubscribeToEvent(EVENTS.ABILITY_FIRED, "HandleAbilityFired")
    SubscribeToEvent(EVENTS.GAME_STATE, "HandleGameState")
    SubscribeToEvent(EVENTS.GAME_START, "HandleGameStart")
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("ScreenMode", "HandleScreenMode")

    -- Critical initialization sequence (per docs):
    -- 1. Set serverConnection.scene  (tells engine where to apply sync data)
    -- 2. Send ClientReady            (tells server we are ready for scene sync)
    local serverConn = network:GetServerConnection()
    if serverConn then
        serverConn.scene = scene_
        serverConn:SendRemoteEvent(EVENTS.CLIENT_READY, true)
        print("[Client] Scene set and ClientReady sent")
    else
        print("[Client] WARNING: No server connection available!")
    end

    ShowWaitingUI()

    print("[Client] Started, waiting for opponent...")
end

function Client.Stop()
    UI.Shutdown()
    if vg_ then nvgDelete(vg_); vg_ = nil end
end

-- ============================================================================
-- Setup
-- ============================================================================

function SetupNanoVG()
    vg_ = nvgCreate(1)
    if not vg_ then
        print("[Client] ERROR: NanoVG creation failed")
        return
    end
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/MiSans-Regular.ttf")
    fontBold_ = fontNormal_  -- Only Regular available
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
end

function SetupCamera()
    local cameraNode = scene_:CreateChild("Camera", LOCAL)
    local camera = cameraNode:CreateComponent("Camera", LOCAL)
    camera.orthographic = true
    camera.orthoSize = 10
    local viewport = Viewport:new(scene_, camera)
    renderer:SetViewport(0, viewport)
end

function HandleScreenMode(eventType, eventData)
    RecalcLayout()
end

-- ============================================================================
-- Waiting & Game UI
-- ============================================================================

function ShowWaitingUI()
    UI.Init({
        theme = "dark",
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Regular.ttf" } },
        },
        scale = UI.Scale.DESIGN_RESOLUTION(designW, designH),
    })
    local waitUI = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = "#000000",
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label {
                text = "等待对手加入...",
                fontSize = 32,
                color = "#FFFFFF",
                marginBottom = 20,
            },
            UI.Label {
                text = "匹配中，请稍候",
                fontSize = 16,
                color = "#888888",
            },
        },
    }
    UI.SetRoot(waitUI)
end

function HandleGameStart(eventType, eventData)
    print("[Client] Game started!")
    waitingForOpponent_ = false

    -- Switch to game UI
    ShowGameUI()
end

function ShowGameUI()
    local gameUI = UI.Panel {
        width = "100%", height = "100%",
        position = "absolute",
        children = {
            -- Cancel Proxy button (top right corner)
            UI.Panel {
                position = "absolute",
                right = 20, top = 20,
                children = {
                    UI.Button {
                        id = "proxyBtn",
                        text = "取消代理",
                        variant = "outline",
                        width = 140, height = 40,
                        fontSize = 14,
                        onClick = function(self)
                            isManualControl_ = not isManualControl_
                            self:SetText(isManualControl_ and "启用代理" or "取消代理")
                        end,
                    },
                },
            },
            -- Return to Lobby button (top left corner)
            UI.Panel {
                position = "absolute",
                left = 20, top = 20,
                children = {
                    UI.Button {
                        text = "返回大厅",
                        variant = "outline",
                        width = 120, height = 40,
                        fontSize = 14,
                        onClick = function(self)
                            ReturnToLobby()
                        end,
                    },
                },
            },
        },
    }
    UI.SetRoot(gameUI)
end

function ReturnToLobby()
    print("[Client] Returning to lobby...")
    SendEvent("ReturnToLobby", VariantMap())
end

-- ============================================================================
-- Network Event Handlers
-- ============================================================================

function HandleAssignRole(eventType, eventData)
    local nodeId = eventData["NodeId"]:GetUInt()
    local team = eventData["Team"]:GetInt()
    myTeam_ = team
    myNodeId_ = nodeId
    print("[Client] Assigned team " .. team .. ", NodeId: " .. nodeId)
end

function HandleHealthUpdate(eventType, eventData)
    local team = eventData["Team"]:GetInt()
    local hp = eventData["HP"]:GetInt()
    local maxHP = eventData["MaxHP"]:GetInt()
    if team >= 1 and team <= 2 then
        ballDisplay_[team].hp = hp
        ballDisplay_[team].maxHP = maxHP
    end
end

function HandleDamagePopup(eventType, eventData)
    local x = eventData["X"]:GetFloat()
    local y = eventData["Y"]:GetFloat()
    local damage = eventData["Damage"]:GetFloat()
    local r = eventData["R"]:GetInt()
    local g = eventData["G"]:GetInt()
    local b = eventData["B"]:GetInt()

    local isHeal = (g > 200 and r < 150)
    table.insert(damagePopups_, {
        x = x, y = y, damage = damage,
        color = { r, g, b, 255 },
        elapsed = 0, duration = POPUP.Duration,
        fontSize = math.min(POPUP.BaseFontSize + damage * POPUP.FontSizePerDmg, POPUP.MaxFontSize),
        shakeAmp = math.min(POPUP.BaseShake + damage * POPUP.ShakePerDmg, POPUP.MaxShake),
        isHeal = isHeal,
    })

    -- Screen shake on significant damage
    if damage >= 5 then
        ScreenShake(math.min(damage, 12), 0.2)
    end
end

function HandleAnnouncement(eventType, eventData)
    local text = eventData["Text"]:GetString()
    local r = eventData["R"]:GetInt()
    local g = eventData["G"]:GetInt()
    local b = eventData["B"]:GetInt()
    announcement_.text = text
    announcement_.timer = 1.2
    announcement_.duration = 1.2
    announcement_.color = { r, g, b, 255 }
end

function HandleAbilityFired(eventType, eventData)
    local abilityType = eventData["Type"]:GetString()
    local x = eventData["X"]:GetFloat()
    local y = eventData["Y"]:GetFloat()
    local dirX = eventData["DirX"]:GetFloat()
    local dirY = eventData["DirY"]:GetFloat()

    -- Spawn visual projectiles
    if abilityType == "water" then
        table.insert(projectilesVis_, {
            type = "water",
            x = x + dirX * (BALL.Radius + WATER.Radius + 2),
            y = y + dirY * (BALL.Radius + WATER.Radius + 2),
            vx = dirX * WATER.Speed, vy = dirY * WATER.Speed,
            radius = WATER.Radius, alive = true, age = 0, trail = {},
        })
        blueCooldown_ = WATER.Cooldown
    elseif abilityType == "beam" then
        table.insert(projectilesVis_, {
            type = "beam",
            x = x + dirX * (BALL.Radius + 4),
            y = y + dirY * (BALL.Radius + 4),
            vx = dirX * RAGE.Speed, vy = dirY * RAGE.Speed,
            radius = RAGE.BeamWidth, alive = true, age = 0, trail = {},
        })
        SpawnParticleBurst(x + dirX * 25, y + dirY * 25, 12, {120,200,255,255}, 80, 200, 2, 5, 0.3)
        ScreenShake(3, 0.15)
        blueCooldown_ = RAGE.Cooldown
    elseif abilityType == "homing" then
        local baseAngle = math.atan(dirY, dirX)
        for i = 1, HOMING.Count do
            local offset = (i - (HOMING.Count + 1) / 2) * HOMING.SpreadAngle
            local angle = baseAngle + offset
            local dX, dY = math.cos(angle), math.sin(angle)
            table.insert(projectilesVis_, {
                type = "homing", targetTeam = 1,
                x = x + dX * (BALL.Radius + HOMING.Radius + 2),
                y = y + dY * (BALL.Radius + HOMING.Radius + 2),
                vx = dX * HOMING.Speed, vy = dY * HOMING.Speed,
                radius = HOMING.Radius, alive = true, age = 0, trail = {},
            })
        end
        redCooldown_ = HOMING.Cooldown
    end
end

function HandleGameState(eventType, eventData)
    local wasOver = gameOver_
    gameOver_ = eventData["GameOver"]:GetBool()
    gameWinner_ = eventData["Winner"]:GetInt()
    -- Reset countdown when game over first received
    if gameOver_ and not wasOver then
        gameOverTimer_ = 0
        returningToLobby_ = false
    end
end

-- ============================================================================
-- Update
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    -- Read ball state from replicated nodes
    UpdateBallDisplayFromNodes()

    -- Update visual effects
    UpdateProjectilesVis(dt)
    UpdateDamagePopups(dt)
    UpdateParticles(dt)
    UpdateScreenShake(dt)

    -- Cooldown display
    if blueCooldown_ > 0 then blueCooldown_ = blueCooldown_ - dt end
    if redCooldown_ > 0 then redCooldown_ = redCooldown_ - dt end

    -- Announcement timer
    if announcement_.timer > 0 then announcement_.timer = announcement_.timer - dt end

    -- Rage flash
    local nowRage = ballDisplay_[1].isRage
    if nowRage and not wasRage_ then
        rageFlash_ = 0.4
        ScreenShake(6, 0.3)
        local b = ballDisplay_[1]
        SpawnParticleBurst(b.x, b.y, 30, {80,180,255,255}, 80, 250, 2, 5, 0.5)
    end
    wasRage_ = nowRage
    if rageFlash_ > 0 then rageFlash_ = rageFlash_ - dt end

    -- Game over: auto-return to lobby after countdown
    if gameOver_ and not returningToLobby_ then
        gameOverTimer_ = gameOverTimer_ + dt
        if gameOverTimer_ >= 5.0 then
            returningToLobby_ = true
            ReturnToLobby()
        end
    end

    -- Send input controls (only during active gameplay)
    if not menuVisible_ and not waitingForOpponent_ and myTeam_ > 0 and not gameOver_ then
        SendControls()
    end
end

-- ============================================================================
-- Read Ball State from Replicated Nodes
-- ============================================================================

function UpdateBallDisplayFromNodes()
    for team = 1, 2 do
        local node = scene_:GetChild("Ball_" .. team)
        if node then
            local x, y = Shared.To2D(node.position)
            ballDisplay_[team].x = x
            ballDisplay_[team].y = y

            local hpVar = node:GetVar(VARS.BALL_HP)
            if not hpVar:IsEmpty() then ballDisplay_[team].hp = hpVar:GetInt() end

            local maxHPVar = node:GetVar(VARS.BALL_MAX_HP)
            if not maxHPVar:IsEmpty() then ballDisplay_[team].maxHP = maxHPVar:GetInt() end

            local vxVar = node:GetVar(VARS.BALL_VX)
            if not vxVar:IsEmpty() then ballDisplay_[team].vx = vxVar:GetFloat() end

            local vyVar = node:GetVar(VARS.BALL_VY)
            if not vyVar:IsEmpty() then ballDisplay_[team].vy = vyVar:GetFloat() end

            local rageVar = node:GetVar(VARS.IS_RAGE)
            if not rageVar:IsEmpty() then ballDisplay_[team].isRage = rageVar:GetBool() end

            local proxyVar = node:GetVar(VARS.IS_PROXY)
            if not proxyVar:IsEmpty() then ballDisplay_[team].isProxy = proxyVar:GetBool() end
        end
    end
end

-- ============================================================================
-- Send Controls to Server
-- ============================================================================

function SendControls()
    local serverConn = network:GetServerConnection()
    if not serverConn then return end

    local controls = serverConn.controls
    local buttons = 0

    if isManualControl_ then
        -- Manual control: player only controls aim direction + fire timing
        -- Movement is always AI-driven on server
        if input:GetMouseButtonDown(MOUSEB_LEFT) then
            buttons = buttons | CTRL.SHOOT
        end

        -- Compute aim angle from mouse position to ball center
        local mousePos = input.mousePosition
        local ball = ballDisplay_[myTeam_]
        local ballScreenX = (arenaX_ + ball.x + designOffsetX) * nvgScale_ * dpr
        local ballScreenY = (arenaY_ + ball.y + designOffsetY) * nvgScale_ * dpr
        local dx = mousePos.x - ballScreenX
        local dy = mousePos.y - ballScreenY
        local aimAngle = math.deg(math.atan(dy, dx))
        controls.yaw = aimAngle
    end

    -- Toggle proxy: bit is SET when proxy is ACTIVE (cancel_proxy not pressed)
    if not isManualControl_ then
        -- Proxy is active, don't set CANCEL_PROXY
    else
        buttons = buttons | CTRL.CANCEL_PROXY
    end

    controls.buttons = buttons
end

-- ============================================================================
-- Visual Effects Updates
-- ============================================================================

function UpdateProjectilesVis(dt)
    local size = Settings.Arena.Size
    local i = 1
    while i <= #projectilesVis_ do
        local p = projectilesVis_[i]
        p.age = p.age + dt

        -- Homing visual tracking
        if p.type == "homing" and p.targetTeam then
            local tgt = ballDisplay_[p.targetTeam]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 then
                local curA = math.atan(p.vy, p.vx)
                local tgtA = math.atan(dy, dx)
                local diff = tgtA - curA
                while diff > math.pi do diff = diff - 2 * math.pi end
                while diff < -math.pi do diff = diff + 2 * math.pi end
                diff = math.max(-HOMING.TurnRate * dt, math.min(HOMING.TurnRate * dt, diff))
                local newA = curA + diff
                local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                p.vx = math.cos(newA) * spd
                p.vy = math.sin(newA) * spd
            end
        end

        -- Trail
        table.insert(p.trail, 1, { x = p.x, y = p.y })
        local maxTrail = p.type == "beam" and 14 or (p.type == "water" and WATER.TrailLen or 4)
        while #p.trail > maxTrail do table.remove(p.trail) end

        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        -- Remove if out of bounds or too old
        if p.x < -20 or p.x > size + 20 or p.y < -20 or p.y > size + 20 or p.age > 5 then
            table.remove(projectilesVis_, i)
        else
            -- Remove if hit target (close to target ball)
            local hit = false
            if p.targetTeam then
                local tgt = ballDisplay_[p.targetTeam]
                local dx, dy = tgt.x - p.x, tgt.y - p.y
                if math.sqrt(dx * dx + dy * dy) < BALL.Radius + p.radius then hit = true end
            end
            if hit then
                table.remove(projectilesVis_, i)
            else
                i = i + 1
            end
        end
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

function SpawnParticleBurst(x, y, count, color, speedMin, speedMax, rMin, rMax, life)
    for _ = 1, count do
        local a = math.random() * 2 * math.pi
        local spd = speedMin + math.random() * (speedMax - speedMin)
        local r = rMin + math.random() * (rMax - rMin)
        table.insert(particles_, {
            x = x, y = y,
            vx = math.cos(a) * spd, vy = math.sin(a) * spd,
            radius = r, life = life or 0.5, maxLife = life or 0.5,
            color = { color[1], color[2], color[3], color[4] or 255 },
        })
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
-- NanoVG Rendering (Mode A: 1920x1080 Design Resolution)
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if not vg_ or menuVisible_ or waitingForOpponent_ then return end

    nvgBeginFrame(vg_, logicalW, logicalH, dpr)
    nvgScale(vg_, nvgScale_, nvgScale_)

    -- Background (fill entire screen)
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
    nvgFillColor(vg_, nvgRGBA(8, 8, 14, 255)); nvgFill(vg_)

    -- Rage atmosphere
    if ballDisplay_[1].isRage then
        local time = GetTime():GetElapsedTime()
        local p = math.floor(10 + 6 * math.sin(time * 3))
        nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
        nvgFillColor(vg_, nvgRGBA(20, 50, 100, p)); nvgFill(vg_)
    end
    if rageFlash_ > 0 then
        nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
        nvgFillColor(vg_, nvgRGBA(180, 220, 255, math.floor(200 * (rageFlash_ / 0.4))))
        nvgFill(vg_)
    end

    -- Enter design space
    nvgTranslate(vg_, designOffsetX, designOffsetY)

    -- Save and apply shake
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

    -- Draw game elements
    DrawTitle(designW, startY)

    -- Arena border
    nvgBeginPath(vg_); nvgRect(vg_, arenaX_, arenaY_, Settings.Arena.Size, Settings.Arena.Size)
    nvgStrokeColor(vg_, nvgRGBA(180, 180, 180, 120)); nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)

    DrawProjectiles()
    DrawParticles()
    DrawBalls()
    DrawDamagePopups()
    DrawAnnouncement()
    DrawBottomPanel(designW, panelY)

    nvgRestore(vg_)  -- Undo shake

    -- Game over overlay
    if gameOver_ then DrawGameOver(designW, designH) end

    nvgEndFrame(vg_)
end

-- ============================================================================
-- Draw: Title
-- ============================================================================

function DrawTitle(w, y)
    if fontNormal_ == -1 then return end

    local names = { "蓝球", "红球" }
    local tags = { "AQUA", "CRIMSON" }
    local colors = { {80,180,255}, {255,80,70} }

    local centerX = w / 2
    local titleY = y + 28

    nvgFontFaceId(vg_, fontBold_)

    -- Blue name (left)
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, centerX - 32, titleY + 2, names[1], nil)
    nvgFillColor(vg_, nvgRGBA(colors[1][1], colors[1][2], colors[1][3], 255))
    nvgText(vg_, centerX - 30, titleY, names[1], nil)

    -- VS
    nvgFontSize(vg_, 26)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, centerX + 2, titleY + 2, "VS", nil)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 240))
    nvgText(vg_, centerX, titleY, "VS", nil)

    -- Red name (right)
    nvgFontSize(vg_, 36)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180))
    nvgText(vg_, centerX + 32, titleY + 2, names[2], nil)
    nvgFillColor(vg_, nvgRGBA(colors[2][1], colors[2][2], colors[2][3], 255))
    nvgText(vg_, centerX + 30, titleY, names[2], nil)
end

-- ============================================================================
-- Draw: Balls
-- ============================================================================

function DrawBalls()
    local r = BALL.Radius
    local time = GetTime():GetElapsedTime()
    local ballColors = {
        {66, 165, 245, 255},
        {239, 83, 80, 255},
    }

    for team = 1, 2 do
        local ball = ballDisplay_[team]
        local color = ballColors[team]
        local bx, by = arenaX_ + ball.x, arenaY_ + ball.y

        -- Rage aura (blue ball)
        if team == 1 and ball.isRage then
            local pulseR = r + 8 + math.sin(time * 5) * 4
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, pulseR)
            nvgFillPaint(vg_, nvgRadialGradient(vg_, bx, by, r, pulseR,
                nvgRGBA(100, 180, 255, math.floor(60 + 40 * math.sin(time * 4))),
                nvgRGBA(100, 180, 255, 0)))
            nvgFill(vg_)
            for k = 1, 4 do
                local a = time * 6 + k * 1.571
                local sr = r + 4 + math.sin(time * 12 + k * 2) * 6
                nvgBeginPath(vg_)
                nvgCircle(vg_, bx + math.cos(a) * sr, by + math.sin(a) * sr,
                    1.5 + math.sin(time * 15 + k) * 0.8)
                nvgFillColor(vg_, nvgRGBA(200, 230, 255, math.floor(180 + 75 * math.sin(time * 10 + k))))
                nvgFill(vg_)
            end
        end

        -- Outer glow
        nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 6)
        nvgFillPaint(vg_, nvgRadialGradient(vg_, bx, by, r * 0.6, r + 6,
            nvgRGBA(color[1], color[2], color[3], 50),
            nvgRGBA(color[1], color[2], color[3], 0)))
        nvgFill(vg_)

        -- Ball body
        nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r)
        nvgFillPaint(vg_, nvgRadialGradient(vg_, bx - r * 0.2, by - r * 0.2, r * 0.1, r * 1.1,
            nvgRGBA(math.min(255, color[1] + 60), math.min(255, color[2] + 60), math.min(255, color[3] + 60), 255),
            nvgRGBA(math.max(0, color[1] - 40), math.max(0, color[2] - 40), math.max(0, color[3] - 40), 255)))
        nvgFill(vg_)

        -- Highlight
        nvgBeginPath(vg_); nvgCircle(vg_, bx - r * 0.25, by - r * 0.3, r * 0.3)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 70)); nvgFill(vg_)

        -- Border
        nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r)
        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 40)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

        -- HP number on ball
        nvgFontFaceId(vg_, fontBold_)
        local hpText = tostring(math.floor(ball.hp))
        local hpSize = ball.hp < 10 and 24 or 22
        nvgFontSize(vg_, hpSize)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
        nvgText(vg_, bx + 1, by + 1, hpText, nil)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 250))
        nvgText(vg_, bx, by, hpText, nil)

        -- My ball indicator
        if team == myTeam_ then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 3)
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 0, math.floor(120 + 60 * math.sin(time * 4))))
            nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
        end
    end
end

-- ============================================================================
-- Draw: Projectiles (Visual)
-- ============================================================================

function DrawProjectiles()
    local time = GetTime():GetElapsedTime()

    for _, p in ipairs(projectilesVis_) do
        local px, py = arenaX_ + p.x, arenaY_ + p.y

        if p.type == "water" then
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j - 1) / #p.trail
                nvgBeginPath(vg_)
                nvgCircle(vg_, arenaX_ + t.x, arenaY_ + t.y, p.radius * (0.4 + 0.6 * ratio))
                nvgFillColor(vg_, nvgRGBA(100, 200, 255, math.floor(180 * ratio)))
                nvgFill(vg_)
            end
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, p.radius)
            nvgFillColor(vg_, nvgRGBA(150, 220, 255, 255)); nvgFill(vg_)
            nvgBeginPath(vg_); nvgCircle(vg_, px - 2, py - 2, p.radius * 0.4)
            nvgFillColor(vg_, nvgRGBA(255, 255, 255, 180)); nvgFill(vg_)

        elseif p.type == "beam" then
            local bw = RAGE.BeamWidth
            if #p.trail > 0 then
                local tailX = arenaX_ + p.trail[#p.trail].x
                local tailY = arenaY_ + p.trail[#p.trail].y

                nvgBeginPath(vg_)
                nvgMoveTo(vg_, tailX, tailY); nvgLineTo(vg_, px, py)
                nvgLineCap(vg_, NVG_ROUND); nvgStrokeWidth(vg_, bw * 4)
                nvgStrokeColor(vg_, nvgRGBA(60, 140, 255, 40)); nvgStroke(vg_)

                nvgBeginPath(vg_)
                nvgMoveTo(vg_, tailX, tailY); nvgLineTo(vg_, px, py)
                nvgLineCap(vg_, NVG_ROUND); nvgStrokeWidth(vg_, bw * 2.2)
                nvgStrokeColor(vg_, nvgRGBA(100, 190, 255, 120)); nvgStroke(vg_)

                nvgBeginPath(vg_)
                nvgMoveTo(vg_, tailX, tailY); nvgLineTo(vg_, px, py)
                nvgLineCap(vg_, NVG_ROUND); nvgStrokeWidth(vg_, bw * 1.2)
                nvgStrokeColor(vg_, nvgRGBA(180, 230, 255, 220)); nvgStroke(vg_)

                nvgBeginPath(vg_)
                nvgMoveTo(vg_, tailX, tailY); nvgLineTo(vg_, px, py)
                nvgLineCap(vg_, NVG_ROUND); nvgStrokeWidth(vg_, bw * 0.5)
                nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 200)); nvgStroke(vg_)
            end
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, bw + 4)
            nvgFillPaint(vg_, nvgRadialGradient(vg_, px, py, 2, bw + 6,
                nvgRGBA(255, 255, 255, 200), nvgRGBA(120, 200, 255, 0)))
            nvgFill(vg_)

        elseif p.type == "homing" then
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j - 1) / #p.trail
                nvgBeginPath(vg_)
                nvgCircle(vg_, arenaX_ + t.x, arenaY_ + t.y, p.radius * (0.5 + 0.5 * ratio))
                nvgFillColor(vg_, nvgRGBA(255, 100, 100, math.floor(150 * ratio)))
                nvgFill(vg_)
            end
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, p.radius)
            nvgFillColor(vg_, nvgRGBA(255, 120, 80, 255)); nvgFill(vg_)
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, p.radius + 3)
            nvgStrokeColor(vg_, nvgRGBA(255, 80, 50, 100)); nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
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
    if announcement_.timer <= 0 then return end
    if fontNormal_ == -1 then return end

    local t = announcement_.timer / announcement_.duration
    local alpha = 255
    if t > 0.8 then alpha = math.floor(255 * ((1 - t) / 0.2))
    elseif t < 0.3 then alpha = math.floor(255 * (t / 0.3)) end
    if alpha <= 0 then return end

    local cx = arenaX_ + Settings.Arena.Size / 2
    local cy = arenaY_ + Settings.Arena.Size * 0.72

    nvgFontFaceId(vg_, fontBold_); nvgFontSize(vg_, 22)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgBeginPath(vg_); nvgRoundedRect(vg_, cx - 100, cy - 14, 200, 28, 6)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.4))); nvgFill(vg_)

    local c = announcement_.color
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.6)))
    nvgText(vg_, cx + 1, cy + 1, announcement_.text, nil)
    nvgFillColor(vg_, nvgRGBA(c[1], c[2], c[3], alpha))
    nvgText(vg_, cx, cy, announcement_.text, nil)
end

-- ============================================================================
-- Draw: Bottom Panel
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

    -- Divider
    local midX = px + pw / 2
    nvgBeginPath(vg_)
    nvgMoveTo(vg_, midX, panelY + 6); nvgLineTo(vg_, midX, panelY + ph - 6)
    nvgStrokeColor(vg_, nvgRGBA(80, 80, 100, 100)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

    local time = GetTime():GetElapsedTime()

    -- Left: Blue
    local leftX = px + 12
    local isRage = ballDisplay_[1].isRage

    nvgFontFaceId(vg_, fontBold_); nvgFontSize(vg_, 15)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(80, 180, 255, 255))
    nvgText(vg_, leftX, panelY + 8, "AQUA", nil)

    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 11)
    local statusText = isRage and "[RAGE]" or "[NORMAL]"
    local statusA = isRage and math.floor(200 + 55 * math.sin(time * 4)) or 180
    nvgFillColor(vg_, nvgRGBA(isRage and 100 or 120, isRage and 200 or 120, isRage and 255 or 140, statusA))
    nvgText(vg_, leftX + 58, panelY + 10, statusText, nil)

    -- Cooldown bar
    local barW = pw / 2 - 24
    local barY = panelY + 26
    nvgBeginPath(vg_); nvgRoundedRect(vg_, leftX, barY, barW, 4, 2)
    nvgFillColor(vg_, nvgRGBA(30, 30, 50, 200)); nvgFill(vg_)
    if blueCooldown_ > 0 then
        local pct = 1 - blueCooldown_ / WATER.Cooldown
        nvgBeginPath(vg_); nvgRoundedRect(vg_, leftX, barY, barW * pct, 4, 2)
        nvgFillColor(vg_, nvgRGBA(80, 180, 255, 160)); nvgFill(vg_)
    else
        nvgBeginPath(vg_); nvgRoundedRect(vg_, leftX, barY, barW, 4, 2)
        nvgFillColor(vg_, nvgRGBA(80, 200, 255, 220)); nvgFill(vg_)
    end

    nvgFontSize(vg_, 11); nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
    if isRage then
        nvgText(vg_, leftX, panelY + 35, "Beam dmg: " .. RAGE.Damage, nil)
        nvgText(vg_, leftX, panelY + 49, "Wall slam: +" .. RAGE.WallSlamDmg, nil)
    else
        nvgText(vg_, leftX, panelY + 35, "Water dmg: " .. WATER.Damage, nil)
        nvgText(vg_, leftX, panelY + 49, "Splash dmg: " .. SPLASH.Damage, nil)
    end

    nvgFontSize(vg_, 12)
    local abilityName = isRage and "Rage Beam" or "Water Shot"
    if blueCooldown_ <= 0 then
        nvgFillColor(vg_, nvgRGBA(80, 220, 255, 255))
        nvgText(vg_, leftX, panelY + 66, string.format("%s %s", "\226\151\134", abilityName), nil)
    else
        nvgFillColor(vg_, nvgRGBA(100, 100, 120, 180))
        nvgText(vg_, leftX, panelY + 66,
            string.format("%s %s  %.1fs", "\226\151\135", abilityName, blueCooldown_), nil)
    end

    -- Right: Red
    local rightX = midX + 12
    nvgFontFaceId(vg_, fontBold_); nvgFontSize(vg_, 15)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(255, 80, 70, 255))
    nvgText(vg_, rightX, panelY + 8, "CRIMSON", nil)

    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 11)
    nvgFillColor(vg_, nvgRGBA(120, 120, 140, 180))
    nvgText(vg_, rightX + 68, panelY + 10, "[NORMAL]", nil)

    nvgBeginPath(vg_); nvgRoundedRect(vg_, rightX, barY, barW, 4, 2)
    nvgFillColor(vg_, nvgRGBA(30, 30, 50, 200)); nvgFill(vg_)
    if redCooldown_ > 0 then
        local pct = 1 - redCooldown_ / HOMING.Cooldown
        nvgBeginPath(vg_); nvgRoundedRect(vg_, rightX, barY, barW * pct, 4, 2)
        nvgFillColor(vg_, nvgRGBA(255, 100, 80, 160)); nvgFill(vg_)
    else
        nvgBeginPath(vg_); nvgRoundedRect(vg_, rightX, barY, barW, 4, 2)
        nvgFillColor(vg_, nvgRGBA(255, 120, 80, 220)); nvgFill(vg_)
    end

    nvgFontSize(vg_, 11); nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
    nvgText(vg_, rightX, panelY + 35, "Barrage: " .. HOMING.Count .. "x homing", nil)
    nvgText(vg_, rightX, panelY + 49, "DOT: " .. HOMING.DotTotal .. " | Heal: " .. HOMING.HealTotal, nil)

    nvgFontSize(vg_, 12)
    if redCooldown_ <= 0 then
        nvgFillColor(vg_, nvgRGBA(255, 120, 80, 255))
        nvgText(vg_, rightX, panelY + 66, "Barrage READY", nil)
    else
        nvgFillColor(vg_, nvgRGBA(100, 100, 120, 180))
        nvgText(vg_, rightX, panelY + 66, string.format("Barrage  %.1fs", redCooldown_), nil)
    end

    -- Bottom hint
    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 10)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(100, 100, 120, 140))
    local hint = isManualControl_
        and "Click = Fire  |  Aim with mouse  |  HP<50 = Rage"
        or "AI Proxy Active  |  Click 'Cancel Proxy' to aim & fire manually"
    nvgText(vg_, px + pw / 2, panelY + ph + 4, hint, nil)
end

-- ============================================================================
-- Draw: Game Over
-- ============================================================================

function DrawGameOver(w, h)
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, w, h)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180)); nvgFill(vg_)

    nvgFontFaceId(vg_, fontBold_)

    local names = { "蓝球", "红球" }
    local colors = { {80, 180, 255}, {255, 80, 70} }

    if gameWinner_ >= 1 and gameWinner_ <= 2 then
        local wc = colors[gameWinner_]
        nvgFontSize(vg_, 40); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
        nvgText(vg_, w / 2 + 2, h / 2 - 18, names[gameWinner_] .. " 获胜!", nil)
        nvgFillColor(vg_, nvgRGBA(wc[1], wc[2], wc[3], 255))
        nvgText(vg_, w / 2, h / 2 - 20, names[gameWinner_] .. " 获胜!", nil)

        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 16)
        nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
        nvgText(vg_, w / 2, h / 2 + 18,
            "剩余血量: " .. math.floor(ballDisplay_[gameWinner_].hp), nil)
    else
        nvgFontSize(vg_, 40); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 100, 255))
        nvgText(vg_, w / 2, h / 2 - 20, "平局!", nil)
    end

    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 16)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    local remaining = math.max(0, math.ceil(5.0 - gameOverTimer_))
    local returnText = remaining > 0
        and string.format("%d 秒后自动返回大厅...", remaining)
        or "正在返回大厅..."
    nvgText(vg_, w / 2, h / 2 + 55, returnText, nil)
end

return Client
