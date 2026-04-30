-- ============================================================================
-- Server.lua - Authoritative Game Server
-- Manages ball physics, projectiles, AI, damage, and state broadcast
-- ============================================================================

local Server = {}
local Shared = require("network.Shared")
local BallAI = require("game.BallAI")

require "LuaScripts/Utilities/Sample"

-- Mock graphics for headless server
if GetGraphics() == nil then
    local mock = {
        SetWindowIcon = function() end,
        SetWindowTitleAndIcon = function() end,
        GetWidth = function() return 1920 end,
        GetHeight = function() return 1080 end,
    }
    function GetGraphics() return mock end
    graphics = mock
    console = { background = {} }
    function GetConsole() return console end
    debugHud = {}
    function GetDebugHud() return debugHud end
end

-- Shortcuts
local Settings = Shared.Settings
local EVENTS   = Shared.EVENTS
local CTRL     = Shared.CTRL
local VARS     = Shared.VARS
local BALL     = Settings.Ball
local WATER    = Settings.Water
local SPLASH   = Settings.Splash
local RAGE     = Settings.RageWater
local HOMING   = Settings.Homing

-- ============================================================================
-- State
-- ============================================================================

---@type Scene
local scene_ = nil

-- Ball data (server-side authoritative)
local balls_ = {}     -- [1]=blue, [2]=red. Fields: x,y,vx,vy,hp,knockbackTimer
local projectiles_ = {}
local dots_ = {}

-- Cooldowns
local blueCooldown_ = 0
local redCooldown_ = 0

-- Collision
local collisionCooldown_ = 0

-- AI states
local aiStates_ = {}   -- [1]=blue AI, [2]=red AI

-- Role pool (REPLICATED nodes)
local roleNodes_ = {}   -- [1]=Ball_1 node, [2]=Ball_2 node

-- Connection management
local roleAssignments_ = {}  -- [teamId] = connKey or nil
local connectionRoles_ = {}  -- [connKey] = teamId
local serverConnections_ = {} -- [connKey] = connection

-- Proxy mode: [teamId] = true means AI is controlling
local isProxy_ = { true, true }

-- Game phase: "waiting" -> "playing" -> "gameover"
local gamePhase_ = "waiting"
local gameOverTimer_ = 0
local connectedCount_ = 0  -- number of players that sent ClientReady

-- Delayed callbacks
local pendingCallbacks_ = {}

-- ============================================================================
-- Entry
-- ============================================================================

function Server.Start()
    SampleStart()
    Shared.RegisterEvents()

    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)

    InitBalls()
    CreateRoleNodes()

    SubscribeToEvent(EVENTS.CLIENT_READY, "HandleClientReady")
    SubscribeToEvent("ClientDisconnected", "HandleClientDisconnected")
    SubscribeToEvent("Update", "HandleUpdate")

    print("[Server] Started, max " .. Settings.Network.MaxPlayers .. " players")
end

function Server.Stop()
end

-- ============================================================================
-- Initialize Ball Data
-- ============================================================================

function InitBalls()
    local spd = BALL.Speed
    for team = 1, 2 do
        local sx, sy = Shared.GetSpawnPos(team)
        local a = math.random() * 2 * math.pi
        balls_[team] = {
            x = sx + Settings.Arena.Size / 2,  -- offset to arena center
            y = sy + Settings.Arena.Size / 2,
            vx = math.cos(a) * spd,
            vy = math.sin(a) * spd,
            hp = BALL.MaxHP,
            knockbackTimer = 0,
        }
        aiStates_[team] = BallAI.CreateState()
    end
    projectiles_ = {}
    dots_ = {}
    blueCooldown_ = 0
    redCooldown_ = 0
    collisionCooldown_ = 0
    gamePhase_ = "waiting"
    gameOverTimer_ = 0
    isProxy_ = { true, true }
end

-- ============================================================================
-- Create REPLICATED Nodes for Ball Sync
-- ============================================================================

function CreateRoleNodes()
    for team = 1, 2 do
        local node = scene_:CreateChild("Ball_" .. team, REPLICATED)
        local ball = balls_[team]
        node.position = Shared.To3D(ball.x, ball.y)

        node:SetVar(VARS.IS_BALL, Variant(true))
        node:SetVar(VARS.BALL_TEAM, Variant(team))
        node:SetVar(VARS.BALL_HP, Variant(ball.hp))
        node:SetVar(VARS.BALL_MAX_HP, Variant(BALL.MaxHP))
        node:SetVar(VARS.BALL_VX, Variant(ball.vx))
        node:SetVar(VARS.BALL_VY, Variant(ball.vy))
        node:SetVar(VARS.IS_RAGE, Variant(false))
        node:SetVar(VARS.IS_PROXY, Variant(true))

        roleNodes_[team] = node
        roleAssignments_[team] = nil
        print("[Server] Created Ball_" .. team .. " (ID: " .. node.ID .. ")")
    end
end

-- ============================================================================
-- Connection Handling
-- ============================================================================

function HandleClientReady(eventType, eventData)
    local connection = eventData["Connection"]:GetPtr("Connection")
    connection.scene = scene_

    local connKey = tostring(connection)
    local team = FindFreeTeam()

    if team == nil then
        print("[Server] Full, rejecting")
        connection:Disconnect()
        return
    end

    roleAssignments_[team] = connKey
    connectionRoles_[connKey] = team
    serverConnections_[connKey] = connection
    connectedCount_ = connectedCount_ + 1

    local node = roleNodes_[team]
    node:SetOwner(connection)

    -- Default to proxy mode; client can cancel
    isProxy_[team] = true
    node:SetVar(VARS.IS_PROXY, Variant(true))

    local nodeId = node.ID
    local conn = connection
    local t = team
    DelayOneFrame(function()
        local data = VariantMap()
        data["NodeId"] = Variant(nodeId)
        data["Team"] = Variant(t)
        conn:SendRemoteEvent(EVENTS.ASSIGN_ROLE, true, data)
        print("[Server] Assigned team " .. t .. " to client, NodeId: " .. nodeId)

        -- Check if both players are connected → start (or resume) game
        if connectedCount_ >= 2 then
            if gamePhase_ == "waiting" then
                StartGame()
            elseif gamePhase_ == "playing" then
                -- Mid-game rejoin: send GAME_START so client switches from waiting UI
                local startData = VariantMap()
                startData["Started"] = Variant(true)
                conn:SendRemoteEvent(EVENTS.GAME_START, true, startData)
                -- Also send current health state
                for sendTeam = 1, 2 do
                    local hpData = VariantMap()
                    hpData["Team"] = Variant(sendTeam)
                    hpData["HP"] = Variant(math.floor(balls_[sendTeam].hp))
                    hpData["MaxHP"] = Variant(BALL.MaxHP)
                    conn:SendRemoteEvent(EVENTS.HEALTH_UPDATE, true, hpData)
                end
                print("[Server] Mid-game rejoin, sent GAME_START to new player")
            end
        end
    end)
end

function StartGame()
    gamePhase_ = "playing"
    print("[Server] Both players connected, starting game!")

    -- Broadcast GAME_START to all clients
    local data = VariantMap()
    data["Started"] = Variant(true)
    BroadcastToAll(EVENTS.GAME_START, data)
end

function HandleClientDisconnected(eventType, eventData)
    local connection = eventData:GetPtr("Connection", "Connection")
    local connKey = tostring(connection)
    local team = connectionRoles_[connKey]

    if team then
        roleAssignments_[team] = nil
        roleNodes_[team]:SetOwner(nil)
        isProxy_[team] = true  -- AI takes over
        roleNodes_[team]:SetVar(VARS.IS_PROXY, Variant(true))
        connectedCount_ = math.max(0, connectedCount_ - 1)
        print("[Server] Team " .. team .. " disconnected, AI takeover")
    end

    connectionRoles_[connKey] = nil
    serverConnections_[connKey] = nil
end

function FindFreeTeam()
    for team = 1, 2 do
        if roleAssignments_[team] == nil then
            return team
        end
    end
    return nil
end

-- ============================================================================
-- Main Update
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    ProcessPendingCallbacks()

    -- Waiting phase: do nothing until both players are ready
    if gamePhase_ == "waiting" then
        return
    end

    -- Game over phase: match_info mode, one match per session.
    -- Server stays alive; clients will ReturnToLobby on their own.
    if gamePhase_ == "gameover" then
        return
    end

    -- Playing phase: run game logic
    -- Process cooldowns
    if blueCooldown_ > 0 then blueCooldown_ = blueCooldown_ - dt end
    if redCooldown_ > 0 then redCooldown_ = redCooldown_ - dt end
    if collisionCooldown_ > 0 then collisionCooldown_ = collisionCooldown_ - dt end
    for team = 1, 2 do
        if balls_[team].knockbackTimer > 0 then
            balls_[team].knockbackTimer = balls_[team].knockbackTimer - dt
        end
    end

    -- Process player input or AI for each ball
    for team = 1, 2 do
        ProcessBallInput(team, dt)
    end

    -- Physics
    UpdateBallPhysics(dt)
    UpdateProjectiles(dt)
    UpdateDots(dt)

    -- Sync nodes
    SyncNodesToState()

    -- Check game over
    for team = 1, 2 do
        if balls_[team].hp <= 0 then
            balls_[team].hp = 0
            gamePhase_ = "gameover"
            gameOverTimer_ = 0
            BroadcastGameState()
        end
    end
end

-- ============================================================================
-- Process Input (Player or AI)
-- ============================================================================

function ProcessBallInput(team, dt)
    local ball = balls_[team]
    local opponent = balls_[team == 1 and 2 or 1]
    local connKey = roleAssignments_[team]
    local cooldown = team == 1 and blueCooldown_ or redCooldown_

    -- Check proxy toggle from player
    if connKey and serverConnections_[connKey] then
        local connection = serverConnections_[connKey]
        local buttons = connection.controls.buttons
        local wantProxy = (buttons & CTRL.CANCEL_PROXY) == 0
        if isProxy_[team] ~= wantProxy then
            isProxy_[team] = wantProxy
            roleNodes_[team]:SetVar(VARS.IS_PROXY, Variant(wantProxy))
        end
    end

    -- Movement is ALWAYS AI-driven (balls bounce autonomously)
    local projSpeed = team == 1 and (ball.hp < 50 and RAGE.Speed or WATER.Speed) or HOMING.Speed
    local ai = BallAI.Update(aiStates_[team], ball, opponent, projectiles_, cooldown, projSpeed, dt)
    ball.vx = ball.vx + ai.moveX * BALL.Speed * dt * 3
    ball.vy = ball.vy + ai.moveY * BALL.Speed * dt * 3

    -- Shooting: AI or Player depending on proxy mode
    if isProxy_[team] or connKey == nil then
        -- AI shooting
        if ai.shoot and cooldown <= 0 then
            local aimX = opponent.x + ai.aimX * 10
            local aimY = opponent.y + ai.aimY * 10
            if team == 1 then
                FireWaterJet(ball, aimX, aimY)
            else
                FireHomingBullets(ball, opponent)
            end
        end
    else
        -- Player controls shooting only (aim direction + fire timing)
        local connection = serverConnections_[connKey]
        if connection then
            local buttons = connection.controls.buttons
            if (buttons & CTRL.SHOOT) ~= 0 and cooldown <= 0 then
                local aimAngle = math.rad(connection.controls.yaw)
                local aimX = ball.x + math.cos(aimAngle) * 200
                local aimY = ball.y + math.sin(aimAngle) * 200

                if team == 1 then
                    FireWaterJet(ball, aimX, aimY)
                else
                    FireHomingBullets(ball, opponent)
                end
            end
        end
    end
end

-- ============================================================================
-- Ball Physics
-- ============================================================================

function UpdateBallPhysics(dt)
    local size = Settings.Arena.Size
    local r = BALL.Radius

    for team = 1, 2 do
        local ball = balls_[team]

        -- Apply velocity
        ball.x = ball.x + ball.vx * dt
        ball.y = ball.y + ball.vy * dt

        -- Speed limit
        local spd = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        local maxSpd = BALL.Speed * 4
        if spd > maxSpd then
            ball.vx = ball.vx * maxSpd / spd
            ball.vy = ball.vy * maxSpd / spd
        end

        -- Wall collision
        local hitWall = false
        if ball.x - r < 0 then ball.x = r; ball.vx = math.abs(ball.vx); hitWall = true
        elseif ball.x + r > size then ball.x = size - r; ball.vx = -math.abs(ball.vx); hitWall = true end
        if ball.y - r < 0 then ball.y = r; ball.vy = math.abs(ball.vy); hitWall = true
        elseif ball.y + r > size then ball.y = size - r; ball.vy = -math.abs(ball.vy); hitWall = true end

        -- Wall slam damage
        if ball.knockbackTimer > 0 and hitWall then
            local dmg = RAGE.WallSlamDmg
            ball.hp = ball.hp - dmg
            ball.knockbackTimer = 0
            BroadcastDamagePopup(ball.x, ball.y - r - 20, dmg, 255, 200, 50)
            BroadcastAnnouncement("WALL SLAM!", 255, 200, 50)
            if ball.hp <= 0 then ball.hp = 0; gamePhase_ = "gameover" end
        end
    end

    -- Ball-ball collision
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
                BroadcastDamagePopup(b1.x, b1.y - r, dmg, 255, 80, 80)
                BroadcastDamagePopup(b2.x, b2.y - r, dmg, 255, 80, 80)
            end
        end
    end
end

-- ============================================================================
-- Projectile System (Water Jet / Beam / Splash / Homing)
-- ============================================================================

function FireWaterJet(ball, aimX, aimY)
    local dx, dy = aimX - ball.x, aimY - ball.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end
    local dirX, dirY = dx / dist, dy / dist
    local rage = ball.hp < 50 and ball.hp > 0

    if rage then
        table.insert(projectiles_, {
            type = "beam", ownerTeam = 1, targetTeam = 2,
            x = ball.x + dirX * (BALL.Radius + 4),
            y = ball.y + dirY * (BALL.Radius + 4),
            vx = dirX * RAGE.Speed, vy = dirY * RAGE.Speed,
            radius = RAGE.BeamWidth, alive = true, age = 0,
        })
        blueCooldown_ = RAGE.Cooldown
        BroadcastAbility("beam", ball.x, ball.y, dirX, dirY)
        BroadcastAnnouncement("RAGE BEAM", 100, 200, 255)
    else
        table.insert(projectiles_, {
            type = "water", ownerTeam = 1, targetTeam = 2,
            x = ball.x + dirX * (BALL.Radius + WATER.Radius + 2),
            y = ball.y + dirY * (BALL.Radius + WATER.Radius + 2),
            vx = dirX * WATER.Speed, vy = dirY * WATER.Speed,
            radius = WATER.Radius, alive = true, age = 0,
        })
        blueCooldown_ = WATER.Cooldown
        BroadcastAbility("water", ball.x, ball.y, dirX, dirY)
        BroadcastAnnouncement("WATER SHOT", 150, 220, 255)
    end
end

function FireHomingBullets(src, tgt)
    local dx, dy = tgt.x - src.x, tgt.y - src.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < 1 then return end
    local baseAngle = math.atan(dy, dx)

    for i = 1, HOMING.Count do
        local offset = (i - (HOMING.Count + 1) / 2) * HOMING.SpreadAngle
        local angle = baseAngle + offset
        local dX, dY = math.cos(angle), math.sin(angle)
        table.insert(projectiles_, {
            type = "homing", ownerTeam = 2, targetTeam = 1,
            x = src.x + dX * (BALL.Radius + HOMING.Radius + 2),
            y = src.y + dY * (BALL.Radius + HOMING.Radius + 2),
            vx = dX * HOMING.Speed, vy = dY * HOMING.Speed,
            radius = HOMING.Radius, alive = true, age = 0,
        })
    end
    redCooldown_ = HOMING.Cooldown
    BroadcastAbility("homing", src.x, src.y, dx / dist, dy / dist)
    BroadcastAnnouncement("CRIMSON BARRAGE", 255, 100, 80)
end

function SpawnWallSplash(proj)
    local size = Settings.Arena.Size
    local hitX, hitY = proj.x, proj.y

    local nx, ny = 0, 0
    if hitX <= 0 then nx = 1 elseif hitX >= size then nx = -1 end
    if hitY <= 0 then ny = 1 elseif hitY >= size then ny = -1 end

    local baseAngle = math.atan(ny, nx)
    local half = SPLASH.SpreadAngle / 2
    for i = 1, SPLASH.Count do
        local t = (i - 1) / (SPLASH.Count - 1)
        local angle = baseAngle - half + t * SPLASH.SpreadAngle
        table.insert(projectiles_, {
            type = "splash", ownerTeam = 1, targetTeam = 2,
            x = math.max(1, math.min(size - 1, hitX)),
            y = math.max(1, math.min(size - 1, hitY)),
            vx = math.cos(angle) * SPLASH.Speed,
            vy = math.sin(angle) * SPLASH.Speed,
            radius = SPLASH.Radius, alive = true, age = 0,
        })
    end
end

function UpdateProjectiles(dt)
    local size = Settings.Arena.Size
    local i = 1
    while i <= #projectiles_ do
        local p = projectiles_[i]
        p.age = p.age + dt

        -- Homing turn logic
        if p.type == "homing" then
            local tgt = balls_[p.targetTeam]
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

        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        -- Wall hit
        local hitWall = p.x < 0 or p.x > size or p.y < 0 or p.y > size
        if hitWall then
            if p.type == "water" then SpawnWallSplash(p) end
            p.alive = false
        end

        -- Target hit
        if p.alive then
            local tgt = balls_[p.targetTeam]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < BALL.Radius + p.radius then
                p.alive = false
                OnProjectileHit(p, p.targetTeam)
            end
        end

        if not p.alive then
            table.remove(projectiles_, i)
        else
            i = i + 1
        end
    end
end

function OnProjectileHit(proj, targetTeam)
    local target = balls_[targetTeam]
    local ownerTeam = proj.ownerTeam

    if proj.type == "water" then
        target.hp = target.hp - WATER.Damage
        local spd = math.sqrt(proj.vx * proj.vx + proj.vy * proj.vy)
        if spd > 1 then
            target.vx = target.vx + (proj.vx / spd) * WATER.Knockback
            target.vy = target.vy + (proj.vy / spd) * WATER.Knockback
        end
        BroadcastDamagePopup(target.x, target.y - BALL.Radius, WATER.Damage, 100, 200, 255)

    elseif proj.type == "beam" then
        target.hp = target.hp - RAGE.Damage
        local spd = math.sqrt(proj.vx * proj.vx + proj.vy * proj.vy)
        if spd > 1 then
            target.vx = target.vx + (proj.vx / spd) * RAGE.Knockback
            target.vy = target.vy + (proj.vy / spd) * RAGE.Knockback
        end
        target.knockbackTimer = RAGE.KnockbackWindow
        BroadcastDamagePopup(target.x, target.y - BALL.Radius - 10, RAGE.Damage, 80, 200, 255)

    elseif proj.type == "splash" then
        target.hp = target.hp - SPLASH.Damage
        BroadcastDamagePopup(target.x, target.y - BALL.Radius, SPLASH.Damage, 140, 210, 255)

    elseif proj.type == "homing" then
        table.insert(dots_, {
            targetTeam = targetTeam, sourceTeam = ownerTeam,
            damageLeft = HOMING.DotTotal, healLeft = HOMING.HealTotal,
            duration = HOMING.DotDuration, elapsed = 0,
            tickInterval = 0.5, tickTimer = 0,
        })
    end

    -- Broadcast health
    BroadcastHealthUpdate(targetTeam)
    if target.hp <= 0 then target.hp = 0; gamePhase_ = "gameover" end
end

-- ============================================================================
-- DOT System
-- ============================================================================

function UpdateDots(dt)
    local i = 1
    while i <= #dots_ do
        local d = dots_[i]
        d.elapsed = d.elapsed + dt
        d.tickTimer = d.tickTimer + dt

        if d.elapsed >= d.duration or d.damageLeft <= 0 then
            table.remove(dots_, i)
        else
            if d.tickTimer >= d.tickInterval then
                d.tickTimer = d.tickTimer - d.tickInterval
                local totalTicks = math.floor(d.duration / d.tickInterval)
                local dmgT = HOMING.DotTotal / totalTicks
                local healT = HOMING.HealTotal / totalTicks

                local tgt = balls_[d.targetTeam]
                local src = balls_[d.sourceTeam]

                local ad = math.min(dmgT, d.damageLeft)
                tgt.hp = tgt.hp - ad
                d.damageLeft = d.damageLeft - ad
                BroadcastDamagePopup(tgt.x, tgt.y - BALL.Radius, ad, 200, 80, 255)

                local ah = math.min(healT, d.healLeft)
                src.hp = math.min(src.hp + ah, BALL.MaxHP)
                d.healLeft = d.healLeft - ah
                BroadcastDamagePopup(src.x, src.y - BALL.Radius, ah, 80, 255, 120)

                BroadcastHealthUpdate(d.targetTeam)
                BroadcastHealthUpdate(d.sourceTeam)

                if tgt.hp <= 0 then tgt.hp = 0; gamePhase_ = "gameover" end
            end
            i = i + 1
        end
    end
end

-- ============================================================================
-- Sync Nodes to State
-- ============================================================================

function SyncNodesToState()
    for team = 1, 2 do
        local ball = balls_[team]
        local node = roleNodes_[team]
        if node then
            node.position = Shared.To3D(ball.x, ball.y)
            node:SetVar(VARS.BALL_HP, Variant(math.floor(ball.hp)))
            node:SetVar(VARS.BALL_VX, Variant(ball.vx))
            node:SetVar(VARS.BALL_VY, Variant(ball.vy))
            node:SetVar(VARS.IS_RAGE, Variant(team == 1 and ball.hp < 50 and ball.hp > 0))
        end
    end
end

-- ============================================================================
-- Broadcast Events
-- ============================================================================

function BroadcastToAll(eventName, data)
    for _, conn in pairs(serverConnections_) do
        conn:SendRemoteEvent(eventName, true, data)
    end
end

function BroadcastHealthUpdate(team)
    local ball = balls_[team]
    local data = VariantMap()
    data["Team"] = Variant(team)
    data["HP"] = Variant(math.floor(ball.hp))
    data["MaxHP"] = Variant(BALL.MaxHP)
    BroadcastToAll(EVENTS.HEALTH_UPDATE, data)
end

function BroadcastDamagePopup(x, y, damage, r, g, b)
    local data = VariantMap()
    data["X"] = Variant(x)
    data["Y"] = Variant(y)
    data["Damage"] = Variant(damage)
    data["R"] = Variant(r)
    data["G"] = Variant(g)
    data["B"] = Variant(b)
    BroadcastToAll(EVENTS.DAMAGE_POPUP, data)
end

function BroadcastAnnouncement(text, r, g, b)
    local data = VariantMap()
    data["Text"] = Variant(text)
    data["R"] = Variant(r)
    data["G"] = Variant(g)
    data["B"] = Variant(b)
    BroadcastToAll(EVENTS.ANNOUNCEMENT, data)
end

function BroadcastAbility(abilityType, x, y, dirX, dirY)
    local data = VariantMap()
    data["Type"] = Variant(abilityType)
    data["X"] = Variant(x)
    data["Y"] = Variant(y)
    data["DirX"] = Variant(dirX)
    data["DirY"] = Variant(dirY)
    BroadcastToAll(EVENTS.ABILITY_FIRED, data)
end

function BroadcastGameState()
    local data = VariantMap()
    data["GameOver"] = Variant(gamePhase_ == "gameover")
    local winner = 0
    for team = 1, 2 do
        if balls_[team].hp > 0 then winner = team end
    end
    data["Winner"] = Variant(winner)
    BroadcastToAll(EVENTS.GAME_STATE, data)
end

-- ============================================================================
-- Reset Game
-- ============================================================================

function ResetGame()
    InitBalls()
    -- After InitBalls, gamePhase_ is "waiting", but if both players still connected, go to "playing"
    if connectedCount_ >= 2 then
        gamePhase_ = "playing"
    end

    for team = 1, 2 do
        local node = roleNodes_[team]
        local ball = balls_[team]
        node.position = Shared.To3D(ball.x, ball.y)
        node:SetVar(VARS.BALL_HP, Variant(ball.hp))
        node:SetVar(VARS.BALL_MAX_HP, Variant(BALL.MaxHP))
        node:SetVar(VARS.IS_RAGE, Variant(false))
        node:SetVar(VARS.IS_PROXY, Variant(true))
    end

    -- Re-apply connected players
    for connKey, team in pairs(connectionRoles_) do
        isProxy_[team] = true  -- Reset to proxy
    end

    BroadcastGameState()
    print("[Server] Game reset")
end

-- ============================================================================
-- Delayed Execution
-- ============================================================================

function DelayOneFrame(callback)
    table.insert(pendingCallbacks_, callback)
end

function ProcessPendingCallbacks()
    if #pendingCallbacks_ > 0 then
        local callbacks = pendingCallbacks_
        pendingCallbacks_ = {}
        for _, cb in ipairs(callbacks) do cb() end
    end
end

return Server
