-- ============================================================================
-- 双球碰撞游戏 v4
-- 蓝球(玩家)：前期水球(碰墙溅射水花各2伤害) | HP<50 暴走水柱(10伤害+巨大击退+撞墙-10)
-- 红球(AI)：4发追踪弹幕(DOT 3点+吸血)
-- ============================================================================

-- ============================================================================
-- 1. 配置
-- ============================================================================

local CONFIG = {
    Title       = "双球碰撞",
    ArenaSize   = 400,
    BallRadius  = 20,
    BallSpeed   = 150,
    CollisionDamage = 2,
    MaxHP       = 100,
}

-- 蓝球水球（普通）
local WATER = {
    Speed       = 700,
    Radius      = 8,
    Damage      = 5,
    Knockback   = 280,
    Cooldown    = 5,
    TrailLen    = 6,
}

-- 碰墙溅射水花
local SPLASH = {
    Count       = 8,          -- 水花数量
    Speed       = 250,        -- 水花速度
    Radius      = 4,          -- 水花碰撞半径
    Damage      = 2,          -- 每个水花伤害
    SpreadAngle = math.pi,    -- 半圆扩散（180度）
    TrailLen    = 3,
}

-- 蓝球水柱（暴走 HP<50）
local RAGE_WATER = {
    Speed       = 1000,
    BeamWidth   = 10,         -- 柱体宽度（半宽）
    Damage      = 10,
    Knockback   = 600,
    Cooldown    = 5,
    Length      = 50,          -- 柱体可视长度
    WallSlamDmg = 10,
    KnockbackWindow = 0.8,
}

-- 红球追踪弹幕
local HOMING = {
    Speed       = 340,
    Radius      = 6,
    Count       = 4,
    TurnRate    = 1.8,
    DotTotal    = 3,
    DotDuration = 3,
    HealTotal   = 3,
    Cooldown    = 10,
    SpreadAngle = 0.55,
}

-- 弹出数字
local POPUP = {
    Duration        = 0.9,
    RiseSpeed       = 60,
    BaseFontSize    = 20,
    FontSizePerDmg  = 4,
    MaxFontSize     = 64,
    BaseShake       = 1,
    ShakePerDmg     = 1.2,
    MaxShake        = 20,
    ShakeFreq       = 30,
    ScalePunchTime  = 0.15,
    ScalePunchAmount = 1.5,
}

-- ============================================================================
-- 2. 运行时状态
-- ============================================================================

local balls = {}
local projectiles = {}
local dots = {}
local damagePopups = {}
local particles = {}
local arenaX, arenaY = 0, 0
local gameOver = false
local collisionCooldown = 0

local blueCooldown = 0
local redCooldown = 0
local aiFireDelay = 0

local shake = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }
local rageFlash = 0
local wasRage = false

local vg = nil
local fontNormal = -1

-- ============================================================================
-- 3. 工具
-- ============================================================================

local function IsRage()
    return balls[1] and balls[1].hp < 50 and balls[1].hp > 0
end

local function ScreenShake(intensity, duration)
    shake.intensity = math.max(shake.intensity, intensity)
    shake.duration = math.max(shake.duration, duration)
    shake.elapsed = 0
end

local function SpawnParticleBurst(x, y, count, color, speedMin, speedMax, rMin, rMax, life)
    for _ = 1, count do
        local a = math.random() * 2 * math.pi
        local spd = speedMin + math.random() * (speedMax - speedMin)
        local r = rMin + math.random() * (rMax - rMin)
        table.insert(particles, {
            x = x, y = y,
            vx = math.cos(a) * spd, vy = math.sin(a) * spd,
            radius = r, life = life or 0.5, maxLife = life or 0.5,
            color = { color[1], color[2], color[3], color[4] or 255 },
        })
    end
end

-- ============================================================================
-- 4. 生命周期
-- ============================================================================

function Start()
    graphics.windowTitle = CONFIG.Title
    vg = nvgCreate(1)
    if not vg then print("ERROR: NanoVG"); return end
    fontNormal = nvgCreateFont(vg, "sans", "Fonts/MiSans-Regular.ttf")
    InitGame()
    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent(vg, "NanoVGRender", "HandleNanoVGRender")
end

function Stop()
    if vg then nvgDelete(vg); vg = nil end
end

function InitGame()
    local s, spd = CONFIG.ArenaSize, CONFIG.BallSpeed
    local a1 = math.random() * 2 * math.pi
    local a2 = math.random() * 2 * math.pi
    balls = {
        { x = s*0.3, y = s*0.3, vx = math.cos(a1)*spd, vy = math.sin(a1)*spd,
          hp = CONFIG.MaxHP, color = {66,165,245,255}, name = "蓝球", knockbackTimer = 0 },
        { x = s*0.7, y = s*0.7, vx = math.cos(a2)*spd, vy = math.sin(a2)*spd,
          hp = CONFIG.MaxHP, color = {239,83,80,255}, name = "红球", knockbackTimer = 0 },
    }
    projectiles = {}; dots = {}; damagePopups = {}; particles = {}
    gameOver = false; collisionCooldown = 0
    blueCooldown = 0; redCooldown = 0; aiFireDelay = 0
    shake = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }
    rageFlash = 0; wasRage = false
end

-- ============================================================================
-- 5. 蓝球技能：水球 / 暴走水柱
-- ============================================================================

function FireWaterJet(mx, my)
    local b = balls[1]
    local dx, dy = mx - b.x, my - b.y
    local dist = math.sqrt(dx*dx + dy*dy)
    if dist < 1 then return end
    local dirX, dirY = dx/dist, dy/dist
    local rage = IsRage()

    if rage then
        -- 暴走水柱（beam 型弹体）
        table.insert(projectiles, {
            type = "beam", owner = 1, target = 2,
            x = b.x + dirX * (CONFIG.BallRadius + 4),
            y = b.y + dirY * (CONFIG.BallRadius + 4),
            vx = dirX * RAGE_WATER.Speed,
            vy = dirY * RAGE_WATER.Speed,
            radius = RAGE_WATER.BeamWidth,
            alive = true, age = 0, trail = {},
        })
        SpawnParticleBurst(b.x + dirX*25, b.y + dirY*25,
            12, {120,200,255,255}, 80, 200, 2, 5, 0.3)
        ScreenShake(3, 0.15)
        blueCooldown = RAGE_WATER.Cooldown
    else
        -- 普通水球
        table.insert(projectiles, {
            type = "water", owner = 1, target = 2,
            x = b.x + dirX * (CONFIG.BallRadius + WATER.Radius + 2),
            y = b.y + dirY * (CONFIG.BallRadius + WATER.Radius + 2),
            vx = dirX * WATER.Speed, vy = dirY * WATER.Speed,
            radius = WATER.Radius,
            alive = true, age = 0, trail = {},
        })
        blueCooldown = WATER.Cooldown
    end
end

-- ============================================================================
-- 6. 碰墙溅射水花
-- ============================================================================

function SpawnWallSplash(proj)
    local size = CONFIG.ArenaSize
    local hitX, hitY = proj.x, proj.y

    -- 判断碰到哪面墙，计算法线方向（朝内）
    local nx, ny = 0, 0
    if hitX <= 0 then nx = 1
    elseif hitX >= size then nx = -1 end
    if hitY <= 0 then ny = 1
    elseif hitY >= size then ny = -1 end

    -- 法线角度（朝内）
    local baseAngle = math.atan(ny, nx)

    -- 扇形散布
    local half = SPLASH.SpreadAngle / 2
    for i = 1, SPLASH.Count do
        local t = (i - 1) / (SPLASH.Count - 1)   -- 0~1
        local angle = baseAngle - half + t * SPLASH.SpreadAngle

        table.insert(projectiles, {
            type = "splash", owner = 1, target = 2,
            x = math.max(1, math.min(size - 1, hitX)),
            y = math.max(1, math.min(size - 1, hitY)),
            vx = math.cos(angle) * SPLASH.Speed,
            vy = math.sin(angle) * SPLASH.Speed,
            radius = SPLASH.Radius,
            alive = true, age = 0, trail = {},
        })
    end

    -- 碰墙水花粒子特效
    SpawnParticleBurst(hitX, hitY, 15, {120, 200, 255, 200}, 60, 200, 1, 4, 0.4)
    ScreenShake(2, 0.1)
end

-- ============================================================================
-- 7. 红球追踪弹幕
-- ============================================================================

function FireHomingBullets()
    local src, tgt = balls[2], balls[1]
    local dx, dy = tgt.x - src.x, tgt.y - src.y
    local dist = math.sqrt(dx*dx + dy*dy)
    if dist < 1 then return end
    local baseAngle = math.atan(dy, dx)

    for i = 1, HOMING.Count do
        local offset = (i - (HOMING.Count + 1) / 2) * HOMING.SpreadAngle
        local angle = baseAngle + offset
        local dX, dY = math.cos(angle), math.sin(angle)
        table.insert(projectiles, {
            type = "homing", owner = 2, target = 1,
            x = src.x + dX*(CONFIG.BallRadius + HOMING.Radius + 2),
            y = src.y + dY*(CONFIG.BallRadius + HOMING.Radius + 2),
            vx = dX * HOMING.Speed, vy = dY * HOMING.Speed,
            radius = HOMING.Radius,
            alive = true, age = 0, trail = {},
        })
    end
    redCooldown = HOMING.Cooldown
end

-- ============================================================================
-- 8. 投射物更新
-- ============================================================================

function UpdateProjectiles(dt)
    local size = CONFIG.ArenaSize
    local ballR = CONFIG.BallRadius

    local i = 1
    while i <= #projectiles do
        local p = projectiles[i]
        p.age = p.age + dt

        -- 追踪转向
        if p.type == "homing" then
            local tgt = balls[p.target]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx*dx + dy*dy)
            if d > 1 then
                local curA = math.atan(p.vy, p.vx)
                local tgtA = math.atan(dy, dx)
                local diff = tgtA - curA
                while diff > math.pi do diff = diff - 2*math.pi end
                while diff < -math.pi do diff = diff + 2*math.pi end
                diff = math.max(-HOMING.TurnRate*dt, math.min(HOMING.TurnRate*dt, diff))
                local newA = curA + diff
                local spd = math.sqrt(p.vx*p.vx + p.vy*p.vy)
                p.vx = math.cos(newA)*spd; p.vy = math.sin(newA)*spd
            end
        end

        -- 拖尾
        table.insert(p.trail, 1, { x = p.x, y = p.y })
        local maxTrail
        if p.type == "beam" then maxTrail = 14
        elseif p.type == "water" then maxTrail = WATER.TrailLen
        elseif p.type == "splash" then maxTrail = SPLASH.TrailLen
        else maxTrail = 4 end
        while #p.trail > maxTrail do table.remove(p.trail) end

        -- 移动
        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        -- 碰墙
        local hitWall = p.x < 0 or p.x > size or p.y < 0 or p.y > size
        if hitWall then
            if p.type == "water" then
                -- 普通水球碰墙：溅射水花
                SpawnWallSplash(p)
            end
            p.alive = false
        end

        -- 命中目标球
        if p.alive then
            local tgt = balls[p.target]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx*dx + dy*dy)
            if d < ballR + p.radius then
                p.alive = false
                OnProjectileHit(p, tgt)
            end
        end

        if not p.alive then
            table.remove(projectiles, i)
        else
            i = i + 1
        end
    end
end

-- ============================================================================
-- 9. 命中处理
-- ============================================================================

function OnProjectileHit(proj, target)
    if proj.type == "water" then
        -- 普通水球命中
        target.hp = target.hp - WATER.Damage
        local spd = math.sqrt(proj.vx*proj.vx + proj.vy*proj.vy)
        if spd > 1 then
            local nx, ny = proj.vx/spd, proj.vy/spd
            target.vx = target.vx + nx * WATER.Knockback
            target.vy = target.vy + ny * WATER.Knockback
        end
        SpawnParticleBurst(proj.x, proj.y, 10, {100,200,255,200}, 60, 150, 1, 4, 0.3)
        SpawnDamagePopup(target.x, target.y - CONFIG.BallRadius, WATER.Damage, {100,200,255,255})
        ScreenShake(3, 0.15)

    elseif proj.type == "beam" then
        -- 暴走水柱命中
        target.hp = target.hp - RAGE_WATER.Damage
        local spd = math.sqrt(proj.vx*proj.vx + proj.vy*proj.vy)
        if spd > 1 then
            local nx, ny = proj.vx/spd, proj.vy/spd
            target.vx = target.vx + nx * RAGE_WATER.Knockback
            target.vy = target.vy + ny * RAGE_WATER.Knockback
        end
        target.knockbackTimer = RAGE_WATER.KnockbackWindow

        SpawnParticleBurst(proj.x, proj.y, 25, {100,200,255,255}, 100, 350, 2, 6, 0.5)
        SpawnParticleBurst(proj.x, proj.y, 15, {255,255,255,255}, 60, 200, 1, 3, 0.35)
        SpawnDamagePopup(target.x, target.y - CONFIG.BallRadius - 10, RAGE_WATER.Damage, {80,200,255,255})
        ScreenShake(8, 0.3)

    elseif proj.type == "splash" then
        -- 溅射水花命中
        target.hp = target.hp - SPLASH.Damage
        SpawnParticleBurst(proj.x, proj.y, 5, {140,210,255,180}, 30, 80, 1, 2, 0.2)
        SpawnDamagePopup(target.x, target.y - CONFIG.BallRadius, SPLASH.Damage, {140,210,255,255})

    elseif proj.type == "homing" then
        -- 追踪弹幕命中 → DOT
        table.insert(dots, {
            targetIdx = proj.target, sourceIdx = proj.owner,
            damageLeft = HOMING.DotTotal, healLeft = HOMING.HealTotal,
            duration = HOMING.DotDuration, elapsed = 0,
            tickInterval = 0.5, tickTimer = 0,
        })
        SpawnParticleBurst(proj.x, proj.y, 8, {255,100,100,200}, 40, 120, 1, 3, 0.3)
    end

    if target.hp <= 0 then target.hp = 0; gameOver = true end
end

-- ============================================================================
-- 10. 撞墙额外伤害
-- ============================================================================

function CheckWallSlam(ball, hitWall)
    if ball.knockbackTimer > 0 and hitWall then
        local dmg = RAGE_WATER.WallSlamDmg
        ball.hp = ball.hp - dmg
        ball.knockbackTimer = 0
        SpawnParticleBurst(ball.x, ball.y, 30, {255,200,50,255}, 100, 400, 2, 7, 0.6)
        SpawnParticleBurst(ball.x, ball.y, 20, {255,255,255,255}, 50, 250, 1, 4, 0.4)
        SpawnParticleBurst(ball.x, ball.y, 12, {255,80,30,255}, 80, 300, 3, 6, 0.5)
        SpawnDamagePopup(ball.x, ball.y - CONFIG.BallRadius - 20, dmg, {255,200,50,255})
        ScreenShake(12, 0.4)
        if ball.hp <= 0 then ball.hp = 0; gameOver = true end
    end
end

-- ============================================================================
-- 11. DOT
-- ============================================================================

function UpdateDots(dt)
    local i = 1
    while i <= #dots do
        local d = dots[i]
        d.elapsed = d.elapsed + dt
        d.tickTimer = d.tickTimer + dt
        if d.elapsed >= d.duration or d.damageLeft <= 0 then
            table.remove(dots, i)
        else
            if d.tickTimer >= d.tickInterval then
                d.tickTimer = d.tickTimer - d.tickInterval
                local totalTicks = math.floor(d.duration / d.tickInterval)
                local dmgT = HOMING.DotTotal / totalTicks
                local healT = HOMING.HealTotal / totalTicks
                local tgt, src = balls[d.targetIdx], balls[d.sourceIdx]

                local ad = math.min(dmgT, d.damageLeft)
                tgt.hp = tgt.hp - ad; d.damageLeft = d.damageLeft - ad
                SpawnDamagePopup(tgt.x, tgt.y - CONFIG.BallRadius, ad, {200,80,255,255})

                local ah = math.min(healT, d.healLeft)
                src.hp = math.min(src.hp + ah, CONFIG.MaxHP); d.healLeft = d.healLeft - ah
                SpawnDamagePopup(src.x, src.y - CONFIG.BallRadius, ah, {80,255,120,255})

                if tgt.hp <= 0 then tgt.hp = 0; gameOver = true end
            end
            i = i + 1
        end
    end
end

-- ============================================================================
-- 12. AI
-- ============================================================================

function UpdateAI(dt)
    if redCooldown > 0 then redCooldown = redCooldown - dt; aiFireDelay = 0; return end
    if aiFireDelay <= 0 then aiFireDelay = 0.3 + math.random()*1.2 end
    aiFireDelay = aiFireDelay - dt
    if aiFireDelay <= 0 then FireHomingBullets() end
end

-- ============================================================================
-- 13. 粒子 & 屏幕震动
-- ============================================================================

function UpdateParticles(dt)
    local i = 1
    while i <= #particles do
        local p = particles[i]
        p.life = p.life - dt
        if p.life <= 0 then table.remove(particles, i)
        else
            p.x = p.x + p.vx*dt; p.y = p.y + p.vy*dt
            p.vx = p.vx*0.96; p.vy = p.vy*0.96
            i = i + 1
        end
    end
end

function UpdateScreenShake(dt)
    if shake.duration > 0 then
        shake.elapsed = shake.elapsed + dt
        if shake.elapsed >= shake.duration then
            shake.duration = 0; shake.intensity = 0; shake.ox = 0; shake.oy = 0
        else
            local t = 1 - shake.elapsed / shake.duration
            local amp = shake.intensity * t
            shake.ox = (math.random()*2-1)*amp; shake.oy = (math.random()*2-1)*amp
        end
    end
end

-- ============================================================================
-- 14. 伤害弹出
-- ============================================================================

function SpawnDamagePopup(x, y, damage, color)
    table.insert(damagePopups, {
        x = x, y = y, damage = damage, color = color,
        elapsed = 0, duration = POPUP.Duration,
        fontSize = math.min(POPUP.BaseFontSize + damage * POPUP.FontSizePerDmg, POPUP.MaxFontSize),
        shakeAmp = math.min(POPUP.BaseShake + damage * POPUP.ShakePerDmg, POPUP.MaxShake),
        isHeal = (color[2] > 200 and color[1] < 150),
    })
end

function UpdateDamagePopups(dt)
    local i = 1
    while i <= #damagePopups do
        local p = damagePopups[i]
        p.elapsed = p.elapsed + dt; p.y = p.y - POPUP.RiseSpeed * dt
        if p.elapsed >= p.duration then table.remove(damagePopups, i)
        else i = i + 1 end
    end
end

-- ============================================================================
-- 15. 主更新
-- ============================================================================

---@param eventType string
---@param eventData UpdateEventData
function HandleUpdate(eventType, eventData)
    local dt = eventData["TimeStep"]:GetFloat()

    UpdateDamagePopups(dt); UpdateParticles(dt); UpdateScreenShake(dt)

    -- 暴走触发检测
    local nowRage = IsRage()
    if nowRage and not wasRage then
        rageFlash = 0.4; ScreenShake(6, 0.3)
        SpawnParticleBurst(balls[1].x, balls[1].y, 30, {80,180,255,255}, 80, 250, 2, 5, 0.5)
        SpawnParticleBurst(balls[1].x, balls[1].y, 20, {255,255,255,255}, 40, 150, 1, 3, 0.4)
    end
    wasRage = nowRage
    if rageFlash > 0 then rageFlash = rageFlash - dt end

    if gameOver then
        if input:GetKeyPress(KEY_SPACE) then InitGame() end
        return
    end

    if blueCooldown > 0 then blueCooldown = blueCooldown - dt end
    for idx = 1, #balls do
        if balls[idx].knockbackTimer > 0 then
            balls[idx].knockbackTimer = balls[idx].knockbackTimer - dt
        end
    end

    -- 玩家输入
    if input:GetMouseButtonPress(MOUSEB_LEFT) and blueCooldown <= 0 then
        local dpr = graphics:GetDPR()
        FireWaterJet(input.mousePosition.x/dpr - arenaX, input.mousePosition.y/dpr - arenaY)
    end

    UpdateAI(dt); UpdateProjectiles(dt); UpdateDots(dt)

    -- ---- 球体物理 ----
    local size = CONFIG.ArenaSize
    local r = CONFIG.BallRadius
    if collisionCooldown > 0 then collisionCooldown = collisionCooldown - dt end

    for idx = 1, #balls do
        local ball = balls[idx]
        ball.x = ball.x + ball.vx*dt; ball.y = ball.y + ball.vy*dt

        local spd = math.sqrt(ball.vx*ball.vx + ball.vy*ball.vy)
        local maxSpd = CONFIG.BallSpeed * 4
        if spd > maxSpd then
            ball.vx = ball.vx*maxSpd/spd; ball.vy = ball.vy*maxSpd/spd
        end

        local hitWall = false
        if ball.x - r < 0 then ball.x = r; ball.vx = math.abs(ball.vx); hitWall = true
        elseif ball.x + r > size then ball.x = size - r; ball.vx = -math.abs(ball.vx); hitWall = true end
        if ball.y - r < 0 then ball.y = r; ball.vy = math.abs(ball.vy); hitWall = true
        elseif ball.y + r > size then ball.y = size - r; ball.vy = -math.abs(ball.vy); hitWall = true end

        CheckWallSlam(ball, hitWall)
    end

    -- 球碰撞
    local b1, b2 = balls[1], balls[2]
    local dx, dy = b2.x - b1.x, b2.y - b1.y
    local dist = math.sqrt(dx*dx + dy*dy)
    if dist < r*2 and dist > 0.01 then
        local nx, ny = dx/dist, dy/dist
        local ov = r*2 - dist
        b1.x = b1.x - nx*ov*0.5; b1.y = b1.y - ny*ov*0.5
        b2.x = b2.x + nx*ov*0.5; b2.y = b2.y + ny*ov*0.5
        local dvx, dvy = b1.vx - b2.vx, b1.vy - b2.vy
        local dvDotN = dvx*nx + dvy*ny
        if dvDotN > 0 then
            b1.vx = b1.vx - dvDotN*nx; b1.vy = b1.vy - dvDotN*ny
            b2.vx = b2.vx + dvDotN*nx; b2.vy = b2.vy + dvDotN*ny
            if collisionCooldown <= 0 then
                local dmg = CONFIG.CollisionDamage
                b1.hp = b1.hp - dmg; b2.hp = b2.hp - dmg; collisionCooldown = 0.1
                SpawnDamagePopup(b1.x, b1.y - r, dmg, {255,80,80,255})
                SpawnDamagePopup(b2.x, b2.y - r, dmg, {255,80,80,255})
            end
        end
    end

    for idx = 1, #balls do
        if balls[idx].hp <= 0 then balls[idx].hp = 0; gameOver = true end
    end
end

-- ============================================================================
-- 16. NanoVG 渲染
-- ============================================================================

function HandleNanoVGRender(eventType, eventData)
    if not vg then return end
    local w = graphics:GetWidth()
    local h = graphics:GetHeight()
    local dpr = graphics:GetDPR()
    local logW, logH = w/dpr, h/dpr

    nvgBeginFrame(vg, logW, logH, dpr)
    nvgSave(vg)
    nvgTranslate(vg, shake.ox, shake.oy)

    -- 背景
    nvgBeginPath(vg); nvgRect(vg, -20, -20, logW+40, logH+40)
    nvgFillColor(vg, nvgRGBA(20,20,30,255)); nvgFill(vg)

    -- 暴走背景
    if IsRage() then
        local time = GetTime():GetElapsedTime()
        local p = math.floor(12 + 8*math.sin(time*3))
        nvgBeginPath(vg); nvgRect(vg, -20, -20, logW+40, logH+40)
        nvgFillColor(vg, nvgRGBA(30,60,120,p)); nvgFill(vg)
    end
    if rageFlash > 0 then
        nvgBeginPath(vg); nvgRect(vg, -20, -20, logW+40, logH+40)
        nvgFillColor(vg, nvgRGBA(180,220,255, math.floor(200*(rageFlash/0.4)))); nvgFill(vg)
    end

    -- 白框
    local size = CONFIG.ArenaSize
    arenaX = (logW - size)/2; arenaY = (logH - size)/2 + 30
    nvgBeginPath(vg); nvgRect(vg, arenaX, arenaY, size, size)
    nvgStrokeColor(vg, nvgRGBA(255,255,255,255)); nvgStrokeWidth(vg, 2); nvgStroke(vg)

    DrawProjectiles()
    DrawParticles()
    DrawBalls()
    DrawDotIndicators()
    DrawDamagePopups()

    nvgRestore(vg)
    DrawHUD(logW, logH)
    if gameOver then DrawGameOver(logW, logH) end
    nvgEndFrame(vg)
end

-- ============================================================================
-- 17. 绘制：球体
-- ============================================================================

function DrawBalls()
    local r = CONFIG.BallRadius
    local time = GetTime():GetElapsedTime()

    for i = 1, #balls do
        local ball = balls[i]
        local bx, by = arenaX + ball.x, arenaY + ball.y

        -- DOT 中毒光环
        local hasDot = false
        for _, d in ipairs(dots) do if d.targetIdx == i then hasDot = true; break end end
        if hasDot then
            nvgBeginPath(vg); nvgCircle(vg, bx, by, r + 4 + math.sin(time*8)*2)
            nvgStrokeColor(vg, nvgRGBA(200,80,255, math.floor(100 + 50*math.sin(time*6))))
            nvgStrokeWidth(vg, 2); nvgStroke(vg)
        end

        -- 暴走光环
        if i == 1 and IsRage() then
            local pulseR = r + 8 + math.sin(time*5)*4
            nvgBeginPath(vg); nvgCircle(vg, bx, by, pulseR)
            nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, r, pulseR,
                nvgRGBA(100,180,255, math.floor(60 + 40*math.sin(time*4))),
                nvgRGBA(100,180,255,0)))
            nvgFill(vg)
            for k = 1, 4 do
                local a = time*6 + k*1.571
                local sr = r + 4 + math.sin(time*12 + k*2)*6
                nvgBeginPath(vg)
                nvgCircle(vg, bx + math.cos(a)*sr, by + math.sin(a)*sr,
                    1.5 + math.sin(time*15+k)*0.8)
                nvgFillColor(vg, nvgRGBA(200,230,255, math.floor(180+75*math.sin(time*10+k))))
                nvgFill(vg)
            end
        end

        -- 击退闪烁
        if ball.knockbackTimer > 0 then
            nvgBeginPath(vg); nvgCircle(vg, bx, by, r+2)
            nvgStrokeColor(vg, nvgRGBA(255,200,50, math.floor(180+75*math.sin(time*20))))
            nvgStrokeWidth(vg, 2.5); nvgStroke(vg)
        end

        -- 球体
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
        nvgFillColor(vg, nvgRGBA(ball.color[1],ball.color[2],ball.color[3],ball.color[4]))
        nvgFill(vg)

        -- 高光
        nvgBeginPath(vg); nvgCircle(vg, bx - r*0.25, by - r*0.25, r*0.35)
        nvgFillColor(vg, nvgRGBA(255,255,255,50)); nvgFill(vg)

        -- 边框
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
        nvgStrokeColor(vg, nvgRGBA(255,255,255,60)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

        -- HP
        if fontNormal ~= -1 then
            nvgFontFaceId(vg, fontNormal); nvgFontSize(vg, 14)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
            nvgFillColor(vg, nvgRGBA(255,255,255,220))
            nvgText(vg, bx, by - r - (ball.knockbackTimer > 0 and 8 or 4),
                "HP:"..math.floor(ball.hp), nil)
        end
    end
end

-- ============================================================================
-- 18. 绘制：投射物
-- ============================================================================

function DrawProjectiles()
    local time = GetTime():GetElapsedTime()

    for _, p in ipairs(projectiles) do
        local px, py = arenaX + p.x, arenaY + p.y

        if p.type == "water" then
            -- 普通水球：圆形弹体 + 拖尾
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j-1)/#p.trail
                nvgBeginPath(vg)
                nvgCircle(vg, arenaX+t.x, arenaY+t.y, p.radius*(0.4+0.6*ratio))
                nvgFillColor(vg, nvgRGBA(100,200,255, math.floor(180*ratio)))
                nvgFill(vg)
            end
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius)
            nvgFillColor(vg, nvgRGBA(150,220,255,255)); nvgFill(vg)
            nvgBeginPath(vg); nvgCircle(vg, px-2, py-2, p.radius*0.4)
            nvgFillColor(vg, nvgRGBA(255,255,255,180)); nvgFill(vg)

        elseif p.type == "beam" then
            -- 暴走水柱：粗光束线条
            local angle = math.atan(p.vy, p.vx)
            local bw = RAGE_WATER.BeamWidth

            -- 用拖尾画连续光束
            if #p.trail > 0 then
                local tailX = arenaX + p.trail[#p.trail].x
                local tailY = arenaY + p.trail[#p.trail].y

                -- 外层光晕（最宽）
                nvgBeginPath(vg)
                nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND)
                nvgStrokeWidth(vg, bw * 4)
                nvgStrokeColor(vg, nvgRGBA(60,140,255,40))
                nvgStroke(vg)

                -- 中层光柱
                nvgBeginPath(vg)
                nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND)
                nvgStrokeWidth(vg, bw * 2.2)
                nvgStrokeColor(vg, nvgRGBA(100,190,255,120))
                nvgStroke(vg)

                -- 核心柱体
                nvgBeginPath(vg)
                nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND)
                nvgStrokeWidth(vg, bw * 1.2)
                nvgStrokeColor(vg, nvgRGBA(180,230,255,220))
                nvgStroke(vg)

                -- 最内层白芯
                nvgBeginPath(vg)
                nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND)
                nvgStrokeWidth(vg, bw * 0.5)
                nvgStrokeColor(vg, nvgRGBA(255,255,255,200))
                nvgStroke(vg)
            end

            -- 弹头光球
            nvgBeginPath(vg); nvgCircle(vg, px, py, bw + 4)
            nvgFillPaint(vg, nvgRadialGradient(vg, px, py, 2, bw + 6,
                nvgRGBA(255,255,255,200), nvgRGBA(120,200,255,0)))
            nvgFill(vg)

            -- 沿途闪烁粒子
            for k = 1, 3 do
                local off = math.sin(time*20 + k*2.1) * bw * 1.5
                local along = -k * 8
                local sparkX = px + math.cos(angle)*along + math.cos(angle+1.571)*off
                local sparkY = py + math.sin(angle)*along + math.sin(angle+1.571)*off
                nvgBeginPath(vg)
                nvgCircle(vg, sparkX, sparkY, 1.5 + math.sin(time*15+k)*0.5)
                nvgFillColor(vg, nvgRGBA(200,240,255, math.floor(150+100*math.sin(time*12+k))))
                nvgFill(vg)
            end

        elseif p.type == "splash" then
            -- 溅射水花：小水滴 + 短拖尾
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j-1)/#p.trail
                nvgBeginPath(vg)
                nvgCircle(vg, arenaX+t.x, arenaY+t.y, p.radius*ratio*0.7)
                nvgFillColor(vg, nvgRGBA(140,220,255, math.floor(120*ratio)))
                nvgFill(vg)
            end
            -- 水滴本体
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius)
            nvgFillColor(vg, nvgRGBA(160,230,255,230)); nvgFill(vg)
            -- 高光
            nvgBeginPath(vg); nvgCircle(vg, px-1, py-1, p.radius*0.35)
            nvgFillColor(vg, nvgRGBA(255,255,255,160)); nvgFill(vg)

        elseif p.type == "homing" then
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j-1)/#p.trail
                nvgBeginPath(vg)
                nvgCircle(vg, arenaX+t.x, arenaY+t.y, p.radius*(0.5+0.5*ratio))
                nvgFillColor(vg, nvgRGBA(255,100,100, math.floor(150*ratio)))
                nvgFill(vg)
            end
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius)
            nvgFillColor(vg, nvgRGBA(255,120,80,255)); nvgFill(vg)
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius+3)
            nvgStrokeColor(vg, nvgRGBA(255,80,50,100)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
        end
    end
end

-- ============================================================================
-- 19. 绘制：粒子 & DOT指示
-- ============================================================================

function DrawParticles()
    for _, p in ipairs(particles) do
        local t = p.life / p.maxLife
        nvgBeginPath(vg)
        nvgCircle(vg, arenaX+p.x, arenaY+p.y, p.radius*(0.5+0.5*t))
        nvgFillColor(vg, nvgRGBA(p.color[1],p.color[2],p.color[3], math.floor(p.color[4]*t)))
        nvgFill(vg)
    end
end

function DrawDotIndicators()
    local time = GetTime():GetElapsedTime()
    for _, d in ipairs(dots) do
        local tgt = balls[d.targetIdx]
        local bx, by = arenaX+tgt.x, arenaY+tgt.y
        for k = 1, 3 do
            local a = time*4 + k*2.094
            local pr = CONFIG.BallRadius + 6
            nvgBeginPath(vg)
            nvgCircle(vg, bx+math.cos(a)*pr, by+math.sin(a)*pr, 2)
            nvgFillColor(vg, nvgRGBA(200,80,255,200)); nvgFill(vg)
        end
    end
end

-- ============================================================================
-- 20. 绘制：弹出数字
-- ============================================================================

function DrawDamagePopups()
    if fontNormal == -1 then return end
    for i = 1, #damagePopups do
        local p = damagePopups[i]
        local t = p.elapsed / p.duration
        local alpha = 255
        if t > 0.7 then alpha = math.floor(255*(1-(t-0.7)/0.3)) end
        if alpha <= 0 then goto continue end

        local sm = 1.0
        if p.elapsed < POPUP.ScalePunchTime then
            sm = 1.0 + (POPUP.ScalePunchAmount-1.0)*math.sin(p.elapsed/POPUP.ScalePunchTime*math.pi)
        end
        local fs = p.fontSize * sm
        local dc = 1 - t
        local sx = p.shakeAmp*dc*math.sin(p.elapsed*POPUP.ShakeFreq)
        local sy = p.shakeAmp*dc*math.cos(p.elapsed*POPUP.ShakeFreq*1.3)
        local screenX, screenY = arenaX+p.x+sx, arenaY+p.y+sy

        local fmt = (p.damage == math.floor(p.damage)) and "%.0f" or "%.1f"
        local txt = (p.isHeal and "+" or "-")..string.format(fmt, p.damage)

        nvgFontFaceId(vg, fontNormal); nvgFontSize(vg, fs)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local off = math.max(1.5, fs*0.05)
        nvgFillColor(vg, nvgRGBA(0,0,0, math.floor(alpha*0.7)))
        nvgText(vg, screenX-off, screenY, txt, nil)
        nvgText(vg, screenX+off, screenY, txt, nil)
        nvgText(vg, screenX, screenY-off, txt, nil)
        nvgText(vg, screenX, screenY+off, txt, nil)
        nvgFillColor(vg, nvgRGBA(p.color[1],p.color[2],p.color[3],alpha))
        nvgText(vg, screenX, screenY, txt, nil)
        ::continue::
    end
end

-- ============================================================================
-- 21. HUD
-- ============================================================================

function DrawHUD(logW, logH)
    if fontNormal == -1 then return end
    nvgFontFaceId(vg, fontNormal)

    nvgFontSize(vg, 20); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg, nvgRGBA(255,255,255,255))
    nvgText(vg, logW/2, 6, "双球碰撞", nil)

    local barW, barH, barY = 120, 12, 30
    DrawHPBar(logW/2 - barW - 30, barY, barW, barH, balls[1])
    DrawHPBar(logW/2 + 30, barY, barW, barH, balls[2])

    nvgFontSize(vg, 16); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255,255,100,255))
    nvgText(vg, logW/2, barY + barH/2, "VS", nil)

    local rage = IsRage()
    DrawCooldownBar(logW/2 - barW - 30, barY+barH+5, barW,
        rage and "暴走水柱" or "水球", blueCooldown,
        WATER.Cooldown, rage and {180,220,255} or {100,200,255})
    DrawCooldownBar(logW/2 + 30, barY+barH+5, barW,
        "弹幕", redCooldown, HOMING.Cooldown, {255,120,80})

    if rage then
        local time = GetTime():GetElapsedTime()
        nvgFontSize(vg, 13); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
        nvgFillColor(vg, nvgRGBA(100,200,255, math.floor(180+75*math.sin(time*4))))
        nvgText(vg, logW/2, barY+barH+18, "RAGE MODE", nil)
    end

    nvgFontSize(vg, 12); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
    nvgFillColor(vg, nvgRGBA(160,160,180,180))
    nvgText(vg, logW/2, logH - 8,
        "鼠标左键 = 发射水球  |  HP<50 暴走水柱(击退撞墙 -10)", nil)
end

function DrawHPBar(x, y, w, h, ball)
    local hpR = math.max(0, ball.hp / CONFIG.MaxHP)
    nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, 4)
    nvgFillColor(vg, nvgRGBA(40,40,50,200)); nvgFill(vg)
    if hpR > 0 then
        nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w*hpR, h, 4)
        nvgFillColor(vg, nvgRGBA(ball.color[1],ball.color[2],ball.color[3],220)); nvgFill(vg)
    end
    nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, 4)
    nvgStrokeColor(vg, nvgRGBA(255,255,255,100)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    nvgFontFaceId(vg, fontNormal); nvgFontSize(vg, 10)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg, nvgRGBA(255,255,255,255))
    nvgText(vg, x+w/2, y+h/2, ball.name.." "..math.floor(ball.hp).."/"..CONFIG.MaxHP, nil)
end

function DrawCooldownBar(x, y, w, name, cdLeft, cdMax, color)
    local h = 8
    nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, 3)
    nvgFillColor(vg, nvgRGBA(30,30,40,180)); nvgFill(vg)
    if cdLeft > 0 then
        nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w*(1-cdLeft/cdMax), h, 3)
        nvgFillColor(vg, nvgRGBA(color[1],color[2],color[3],100)); nvgFill(vg)
        nvgFontFaceId(vg, fontNormal); nvgFontSize(vg, 8)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(200,200,200,200))
        nvgText(vg, x+w/2, y+h/2, name.." "..string.format("%.1fs",cdLeft), nil)
    else
        nvgBeginPath(vg); nvgRoundedRect(vg, x, y, w, h, 3)
        nvgFillColor(vg, nvgRGBA(color[1],color[2],color[3],200)); nvgFill(vg)
        nvgFontFaceId(vg, fontNormal); nvgFontSize(vg, 8)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255,255,255,255))
        nvgText(vg, x+w/2, y+h/2, name.." 就绪", nil)
    end
end

-- ============================================================================
-- 22. 游戏结束
-- ============================================================================

function DrawGameOver(logW, logH)
    nvgBeginPath(vg); nvgRect(vg, 0, 0, logW, logH)
    nvgFillColor(vg, nvgRGBA(0,0,0,150)); nvgFill(vg)
    nvgFontFaceId(vg, fontNormal)

    local winner, loser = nil, nil
    for i = 1, #balls do
        if balls[i].hp <= 0 then loser = balls[i] else winner = balls[i] end
    end

    if not winner or winner.hp <= 0 then
        nvgFontSize(vg, 36); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255,255,100,255))
        nvgText(vg, logW/2, logH/2-20, "平局!", nil)
    else
        nvgFontSize(vg, 36); nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(winner.color[1],winner.color[2],winner.color[3],255))
        nvgText(vg, logW/2, logH/2-20, winner.name.." 获胜!", nil)
        nvgFontSize(vg, 16); nvgFillColor(vg, nvgRGBA(200,200,200,200))
        nvgText(vg, logW/2, logH/2+20, "剩余血量: "..math.floor(winner.hp), nil)
    end

    nvgFontSize(vg, 18); nvgFillColor(vg, nvgRGBA(255,255,255,180))
    nvgText(vg, logW/2, logH/2+60, "按空格键重新开始", nil)
end
