-- ============================================================================
-- SkillExecutor.lua - Unified Projectile Engine (按设计图重制)
-- 支持弹道类型: wall_splash, fire_shot, leech, bubble,
--              laser_emitter, water_pillar, inferno, bat_swarm
-- ============================================================================

local Settings      = require("config.Settings")
local SkillRegistry = require("game.SkillRegistry")

local BALL = Settings.Ball

local SkillExecutor = {}

-- ============================================================================
-- State
-- ============================================================================

local projectiles_ = {}   -- active physics projectiles
local visualProjs_ = {}   -- visual-only projectiles (trails)
local dots_        = {}   -- damage-over-time effects
local aoeEffects_  = {}   -- expanding shockwaves
local emitters_    = {}   -- laser emitters placed on walls
local fireZones_   = {}   -- persistent fire zones on walls
local bubbles_     = {}   -- slow-moving bubbles with contact DPS
local meteors_     = {}   -- delayed meteor drops (陨石延迟落下)

-- ============================================================================
-- Knockback helper (level→value mapping)
-- ============================================================================

local function GetKnockback(params)
    return params.knockback or 0
end

-- ============================================================================
-- Spawn sub-projectiles (for wall splash)
-- ============================================================================

local function SpawnSplashProjectiles(parent, count, damage, speed, radius, spread, ownerTeam, targetTeam, color, wallNx, wallNy, isSplash2)
    local baseAngle = math.atan(wallNy, wallNx)
    for i = 1, count do
        local offset = (i - (count + 1) / 2) * (spread / math.max(1, count - 1))
        local angle = baseAngle + offset
        local dx, dy = math.cos(angle), math.sin(angle)
        local proj = {
            skillId = parent.skillId, type = isSplash2 and "splash2" or "splash",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = parent.x, y = parent.y,
            vx = dx * speed, vy = dy * speed,
            radius = radius, alive = true, age = 0,
            damage = damage, knockback = 50,
            color = color,
            -- splash2 sub-projectiles can also splash on wall
            canSplash2 = (not isSplash2) and (parent.splash2Count ~= nil),
            splash2Count  = parent.splash2Count,
            splash2Damage = parent.splash2Damage,
            splash2Speed  = parent.splash2Speed,
            splash2Radius = parent.splash2Radius,
        }
        table.insert(projectiles_, proj)
        table.insert(visualProjs_, {
            type = "single",
            x = proj.x, y = proj.y,
            vx = proj.vx, vy = proj.vy,
            radius = radius, alive = true, age = 0, trail = {},
            color = color, trailLen = 3,
        })
    end
end

-- ============================================================================
-- Fire: Create projectile(s) based on skill definition
-- ============================================================================

function SkillExecutor.Fire(skillDef, ownerTeam, targetTeam, ox, oy, dirX, dirY)
    if not skillDef then return 0 end

    local pType = skillDef.projType
    local spawnDist = BALL.Radius + skillDef.projRadius + 2
    local sx, sy = ox + dirX * spawnDist, oy + dirY * spawnDist

    -- ========== wall_splash (水球) ==========
    if pType == "wall_splash" then
        local p = {
            skillId = skillDef.id, type = "wall_splash",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            slowFactor = skillDef.params.slowFactor,
            slowDuration = skillDef.params.slowDuration,
            -- splash params
            splashCount  = skillDef.params.splashCount,
            splashDamage = skillDef.params.splashDamage,
            splashSpeed  = skillDef.params.splashSpeed,
            splashRadius = skillDef.params.splashRadius,
            splashSpread = skillDef.params.splashSpread,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "single", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 6,
        })

    -- ========== fire_shot (火球) ==========
    elseif pType == "fire_shot" then
        local p = {
            skillId = skillDef.id, type = "fire_shot",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            dotTotal = skillDef.params.dotTotal,
            dotDuration = skillDef.params.dotDuration,
            wallAoeDamage = skillDef.params.wallAoeDamage,
            wallAoeRadius = skillDef.params.wallAoeRadius,
            wallAoeSpeed  = skillDef.params.wallAoeSpeed,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "single", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 6,
        })

    -- ========== leech (水蛭) ==========
    elseif pType == "leech" then
        local p = {
            skillId = skillDef.id, type = "homing",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = 0,
            turnRate = skillDef.params.turnRate,
            color = skillDef.color,
            dotTotal = skillDef.params.dotTotal,
            dotDuration = skillDef.params.dotDuration,
            healTotal = skillDef.params.healTotal,
            lifetime = skillDef.params.lifetime or 8,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "homing", targetTeam = targetTeam,
            x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 5,
            turnRate = p.turnRate,
        })

    -- ========== bubble (分裂泡) ==========
    elseif pType == "bubble" then
        local p = {
            skillId = skillDef.id, type = "bubble",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            baseRadius = skillDef.projRadius,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            lifetime = skillDef.params.lifetime or 5,
            growthFactor = skillDef.params.growthFactor or 3.0,
            explodeRadius = skillDef.params.explodeRadius or 80,
        }
        table.insert(bubbles_, p)
        -- visual handled in Draw directly

    -- ========== laser_emitter (激光) ==========
    elseif pType == "laser_emitter" then
        local p = {
            skillId = skillDef.id, type = "laser_proj",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = 0, knockback = 0,
            color = skillDef.color,
            maxEmitters = skillDef.params.maxEmitters,
            emitterLife = skillDef.params.emitterLife,
            laserDps    = skillDef.params.laserDps,
            laserWidth  = skillDef.params.laserWidth,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "single", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 4,
        })

    -- ========== water_pillar (水柱) ==========
    elseif pType == "water_pillar" then
        local p = {
            skillId = skillDef.id, type = "water_pillar",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            -- splash params
            splashCount  = skillDef.params.splashCount,
            splashDamage = skillDef.params.splashDamage,
            splashSpeed  = skillDef.params.splashSpeed,
            splashRadius = skillDef.params.splashRadius,
            -- splash2 params
            splash2Count  = skillDef.params.splash2Count,
            splash2Damage = skillDef.params.splash2Damage,
            splash2Speed  = skillDef.params.splash2Speed,
            splash2Radius = skillDef.params.splash2Radius,
            -- hit effects
            wallSlamDamage  = skillDef.params.wallSlamDamage,
            knockbackWindow = skillDef.params.knockbackWindow,
            stunDuration    = skillDef.params.stunDuration,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "beam", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 10,
        })

    -- ========== inferno (烈焰) ==========
    elseif pType == "inferno" then
        local p = {
            skillId = skillDef.id, type = "inferno",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            turnRate = skillDef.params.turnRate,
            color = skillDef.color,
            dotTotal = skillDef.params.dotTotal,
            dotDuration = skillDef.params.dotDuration,
            fireZoneRadius = skillDef.params.fireZoneRadius,
            fireZoneDuration = skillDef.params.fireZoneDuration,
            fireZoneDps = skillDef.params.fireZoneDps,
            fireZoneSlowFactor = skillDef.params.fireZoneSlowFactor,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "homing", targetTeam = targetTeam,
            x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 7,
            turnRate = p.turnRate,
        })

    -- ========== bat_swarm (血蝙蝠) ==========
    elseif pType == "bat_swarm" then
        local count = skillDef.params.count or 5
        local spread = skillDef.params.spreadAngle or 0.8
        local baseAngle = math.atan(dirY, dirX)
        for i = 1, count do
            local offset = (i - (count + 1) / 2) * (spread / math.max(1, count - 1))
            local angle = baseAngle + offset
            local dx, dy = math.cos(angle), math.sin(angle)
            local p = {
                skillId = skillDef.id, type = "homing",
                ownerTeam = ownerTeam, targetTeam = targetTeam,
                x = ox + dx * spawnDist, y = oy + dy * spawnDist,
                vx = dx * skillDef.projSpeed, vy = dy * skillDef.projSpeed,
                radius = skillDef.projRadius, alive = true, age = 0,
                damage = 0,
                turnRate = skillDef.params.turnRate,
                color = skillDef.color,
                dotTotal    = skillDef.params.dotTotal / count,
                dotDuration = skillDef.params.dotDuration,
                healTotal   = skillDef.params.healTotal / count,
                lifetime    = skillDef.params.lifetime or 12,
            }
            table.insert(projectiles_, p)
            table.insert(visualProjs_, {
                type = "homing", targetTeam = targetTeam,
                x = p.x, y = p.y,
                vx = p.vx, vy = p.vy,
                radius = p.radius, alive = true, age = 0, trail = {},
                color = p.color, trailLen = 4,
                turnRate = p.turnRate,
            })
        end

    -- ========== water_dragon (水龙) ==========
    elseif pType == "water_dragon" then
        local p = {
            skillId = skillDef.id, type = "water_dragon",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            -- bounce params
            bouncesLeft     = skillDef.params.maxBounces or 5,
            splashCount     = skillDef.params.splashCount,
            splashDamage    = skillDef.params.splashDamage,
            splashSpeed     = skillDef.params.splashSpeed,
            splashRadius    = skillDef.params.splashRadius,
            splashSpread    = skillDef.params.splashSpread,
            -- hit effects
            wallSlamDamage  = skillDef.params.wallSlamDamage,
            knockbackWindow = skillDef.params.knockbackWindow,
            stunDuration    = skillDef.params.stunDuration,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "beam", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 12,
        })

    -- ========== meteorite (陨石) ==========
    elseif pType == "meteorite" then
        local p = {
            skillId = skillDef.id, type = "meteorite",
            ownerTeam = ownerTeam, targetTeam = targetTeam,
            x = sx, y = sy,
            vx = dirX * skillDef.projSpeed, vy = dirY * skillDef.projSpeed,
            radius = skillDef.projRadius, alive = true, age = 0,
            damage = skillDef.damage,
            knockback = GetKnockback(skillDef.params),
            color = skillDef.color,
            -- hit effects
            stunDuration    = skillDef.params.stunDuration,
            meteorDelay     = skillDef.params.meteorDelay,
            meteorDamage    = skillDef.params.meteorDamage,
            meteorAoeRadius = skillDef.params.meteorAoeRadius,
            meteorAoeDamage = skillDef.params.meteorAoeDamage,
            dotTotal        = skillDef.params.dotTotal,
            dotDuration     = skillDef.params.dotDuration,
            -- wall homing params
            wallHomingCount    = skillDef.params.wallHomingCount,
            wallHomingSpeed    = skillDef.params.wallHomingSpeed,
            wallHomingRadius   = skillDef.params.wallHomingRadius,
            wallHomingTurnRate = skillDef.params.wallHomingTurnRate,
            wallHomingDamage   = skillDef.params.wallHomingDamage,
            wallHomingLife     = skillDef.params.wallHomingLife,
        }
        table.insert(projectiles_, p)
        table.insert(visualProjs_, {
            type = "single", x = sx, y = sy,
            vx = p.vx, vy = p.vy,
            radius = p.radius, alive = true, age = 0, trail = {},
            color = p.color, trailLen = 6,
        })
    end

    return skillDef.cooldown
end

-- ============================================================================
-- Sweep collision: line-segment (A→B) vs circle (center C, radius R)
-- Returns true if any point on segment AB is within distance R of C.
-- ============================================================================

local function SweepHitCircle(ax, ay, bx, by, cx, cy, R)
    local ex, ey = bx - ax, by - ay   -- segment direction
    local fx, fy = ax - cx, ay - cy   -- start relative to circle center
    local segLenSq = ex * ex + ey * ey
    if segLenSq < 0.001 then
        -- Degenerate segment (zero length) → point check
        return (fx * fx + fy * fy) < R * R
    end
    -- Project circle center onto segment: t in [0,1]
    local t = -(fx * ex + fy * ey) / segLenSq
    if t < 0 then t = 0 elseif t > 1 then t = 1 end
    local nearX = ax + t * ex - cx
    local nearY = ay + t * ey - cy
    return (nearX * nearX + nearY * nearY) < R * R
end

-- ============================================================================
-- Wall collision helper: returns hitWall, normalX, normalY
-- ============================================================================

local function CheckWallHit(p, size)
    local hitWall = false
    local nx, ny = 0, 0

    if p.x - p.radius < 0 then
        hitWall = true; nx = 1
        p.x = p.radius
    elseif p.x + p.radius > size then
        hitWall = true; nx = -1
        p.x = size - p.radius
    end
    if p.y - p.radius < 0 then
        hitWall = true; ny = 1
        p.y = p.radius
    elseif p.y + p.radius > size then
        hitWall = true; ny = -1
        p.y = size - p.radius
    end

    return hitWall, nx, ny
end

-- ============================================================================
-- Update: Move projectiles, check hits
-- ============================================================================

function SkillExecutor.Update(dt, balls, callbacks)
    local size = Settings.Arena.Size
    callbacks = callbacks or {}

    -- === Physics projectiles ===
    local i = 1
    while i <= #projectiles_ do
        local p = projectiles_[i]
        p.age = p.age + dt

        -- Homing turn (for homing, inferno types)
        if (p.type == "homing" or p.type == "inferno") and balls[p.targetTeam] then
            local tgt = balls[p.targetTeam]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 and p.turnRate then
                local curA = math.atan(p.vy, p.vx)
                local tgtA = math.atan(dy, dx)
                local diff = tgtA - curA
                while diff > math.pi do diff = diff - 2 * math.pi end
                while diff < -math.pi do diff = diff + 2 * math.pi end
                diff = math.max(-p.turnRate * dt, math.min(p.turnRate * dt, diff))
                local newA = curA + diff
                local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                p.vx = math.cos(newA) * spd
                p.vy = math.sin(newA) * spd
            end
        end

        -- Save previous position for sweep collision
        local prevX, prevY = p.x, p.y

        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        -- Wall hit check
        local hitWall, wnx, wny = CheckWallHit(p, size)

        if hitWall then
            -- ---- wall_splash type: spawn splashes ----
            if p.type == "wall_splash" then
                -- Reflect normal for splash direction (into arena)
                local refNx = wnx ~= 0 and wnx or 0
                local refNy = wny ~= 0 and wny or 0
                if refNx == 0 and refNy == 0 then refNx = 1 end
                SpawnSplashProjectiles(p, p.splashCount or 8, p.splashDamage or 2,
                    p.splashSpeed or 250, p.splashRadius or 4,
                    p.splashSpread or math.pi, p.ownerTeam, p.targetTeam, p.color,
                    refNx, refNy, false)
                p.alive = false

            -- ---- water_pillar type: first-level splash ----
            elseif p.type == "water_pillar" then
                local refNx = wnx ~= 0 and wnx or 0
                local refNy = wny ~= 0 and wny or 0
                if refNx == 0 and refNy == 0 then refNx = 1 end
                SpawnSplashProjectiles(p, p.splashCount or 8, p.splashDamage or 3,
                    p.splashSpeed or 300, p.splashRadius or 5,
                    math.pi, p.ownerTeam, p.targetTeam, p.color,
                    refNx, refNy, false)
                p.alive = false

            -- ---- splash sub-projectile: can produce splash2 ----
            elseif p.type == "splash" and p.canSplash2 and p.splash2Count then
                local refNx = wnx ~= 0 and wnx or 0
                local refNy = wny ~= 0 and wny or 0
                if refNx == 0 and refNy == 0 then refNx = 1 end
                SpawnSplashProjectiles(p, p.splash2Count, p.splash2Damage or 1,
                    p.splash2Speed or 200, p.splash2Radius or 3,
                    math.pi * 0.8, p.ownerTeam, p.targetTeam, p.color,
                    refNx, refNy, true)
                p.alive = false

            -- ---- fire_shot type: wall AOE ----
            elseif p.type == "fire_shot" and p.wallAoeDamage then
                table.insert(aoeEffects_, {
                    skillId = p.skillId,
                    ownerTeam = p.ownerTeam, targetTeam = p.targetTeam,
                    x = p.x, y = p.y,
                    currentRadius = 0,
                    maxRadius = p.wallAoeRadius or 80,
                    expandSpeed = p.wallAoeSpeed or 300,
                    damage = p.wallAoeDamage,
                    knockback = 100,
                    duration = 0.4,
                    elapsed = 0,
                    hasHit = false,
                    color = p.color,
                })
                p.alive = false

            -- ---- laser_proj type: place emitter on wall ----
            elseif p.type == "laser_proj" then
                -- Remove oldest if at max
                local ownEmitters = {}
                for ei = #emitters_, 1, -1 do
                    if emitters_[ei].ownerTeam == p.ownerTeam then
                        table.insert(ownEmitters, ei)
                    end
                end
                while #ownEmitters >= (p.maxEmitters or 4) do
                    table.remove(emitters_, ownEmitters[#ownEmitters])
                    table.remove(ownEmitters)
                end
                table.insert(emitters_, {
                    ownerTeam = p.ownerTeam, targetTeam = p.targetTeam,
                    x = p.x, y = p.y,
                    life = p.emitterLife or 10,
                    elapsed = 0,
                    laserDps = p.laserDps or 2,
                    laserWidth = p.laserWidth or 4,
                    color = p.color,
                    skillId = p.skillId,
                })
                p.alive = false

            -- ---- inferno type: create fire zone on wall ----
            elseif p.type == "inferno" then
                table.insert(fireZones_, {
                    ownerTeam = p.ownerTeam, targetTeam = p.targetTeam,
                    x = p.x, y = p.y,
                    radius = p.fireZoneRadius or 60,
                    duration = p.fireZoneDuration or 10,
                    elapsed = 0,
                    dps = p.fireZoneDps or 4,
                    slowFactor = p.fireZoneSlowFactor or 0.4,
                    color = p.color,
                    skillId = p.skillId,
                    tickTimer = 0,
                })
                p.alive = false

            -- ---- water_dragon type: bounce + splash each time ----
            elseif p.type == "water_dragon" then
                -- Spawn splash projectiles each bounce
                local refNx = wnx ~= 0 and wnx or 0
                local refNy = wny ~= 0 and wny or 0
                if refNx == 0 and refNy == 0 then refNx = 1 end
                SpawnSplashProjectiles(p, p.splashCount or 10, p.splashDamage or 5,
                    p.splashSpeed or 300, p.splashRadius or 5,
                    p.splashSpread or math.pi, p.ownerTeam, p.targetTeam, p.color,
                    refNx, refNy, false)

                -- Reflect velocity (bounce)
                if wnx ~= 0 then p.vx = -p.vx end
                if wny ~= 0 then p.vy = -p.vy end

                p.bouncesLeft = (p.bouncesLeft or 1) - 1
                if p.bouncesLeft <= 0 then
                    p.alive = false
                end

            -- ---- meteorite type: spawn homing sub-projectiles on wall ----
            elseif p.type == "meteorite" then
                local homingCount = p.wallHomingCount or 3
                local baseAngle = math.atan(p.vy, p.vx) + math.pi -- reflect direction
                local spread = math.pi * 0.6
                for hi = 1, homingCount do
                    local offset = (hi - (homingCount + 1) / 2) * (spread / math.max(1, homingCount - 1))
                    local angle = baseAngle + offset
                    local dx, dy = math.cos(angle), math.sin(angle)
                    local hSpd = p.wallHomingSpeed or 340
                    local hp = {
                        skillId = p.skillId, type = "homing",
                        ownerTeam = p.ownerTeam, targetTeam = p.targetTeam,
                        x = p.x, y = p.y,
                        vx = dx * hSpd, vy = dy * hSpd,
                        radius = p.wallHomingRadius or 5, alive = true, age = 0,
                        damage = p.wallHomingDamage or 3,
                        turnRate = p.wallHomingTurnRate or 1.2,
                        color = { r = 255, g = 160, b = 60 },
                        lifetime = p.wallHomingLife or 6,
                        knockback = 80,
                    }
                    table.insert(projectiles_, hp)
                    table.insert(visualProjs_, {
                        type = "homing", targetTeam = p.targetTeam,
                        x = hp.x, y = hp.y,
                        vx = hp.vx, vy = hp.vy,
                        radius = hp.radius, alive = true, age = 0, trail = {},
                        color = hp.color, trailLen = 5,
                        turnRate = hp.turnRate,
                    })
                end
                p.alive = false

            -- ---- default: destroy on wall ----
            else
                p.alive = false
            end
        end

        -- Hit check against target ball (sweep: prevPos → curPos vs ball)
        if p.alive and balls[p.targetTeam] then
            local tgt = balls[p.targetTeam]
            local hitRadius = BALL.Radius + p.radius
            if SweepHitCircle(prevX, prevY, p.x, p.y, tgt.x, tgt.y, hitRadius) then

                -- All types: destroy on hit
                p.alive = false

                    if p.type == "homing" and p.dotTotal then
                    -- DOT-based hit (leech, bat)
                    if callbacks.onDot then
                        callbacks.onDot(p.targetTeam, p.ownerTeam, p.dotTotal, p.dotDuration, p.healTotal)
                    end
                elseif p.type == "fire_shot" and p.dotTotal then
                    -- Fire ball: direct damage + DOT
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, p.type, p.skillId, p)
                    end
                    if callbacks.onDot then
                        callbacks.onDot(p.targetTeam, p.ownerTeam, p.dotTotal, p.dotDuration, 0)
                    end
                elseif p.type == "inferno" then
                    -- Inferno: direct damage + big DOT
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, p.type, p.skillId, p)
                    end
                    if p.dotTotal and callbacks.onDot then
                        callbacks.onDot(p.targetTeam, p.ownerTeam, p.dotTotal, p.dotDuration, 0)
                    end
                elseif p.type == "water_pillar" then
                    -- Water pillar: huge knockback + wall slam + stun
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, "beam", p.skillId, p)
                    end
                elseif p.type == "water_dragon" then
                    -- Water dragon: huge knockback → wall slam + stun (same as water_pillar)
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, "beam", p.skillId, p)
                    end
                elseif p.type == "meteorite" then
                    -- Meteorite: direct damage + stun + delayed meteor + DOT
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    -- Direct hit damage + stun
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, "meteor_hit", p.skillId, p)
                    end
                    -- Stun the target
                    if callbacks.onStun then
                        callbacks.onStun(p.targetTeam, p.stunDuration or 2.5)
                    end
                    -- Schedule delayed meteor drop at hit location
                    table.insert(meteors_, {
                        skillId = p.skillId,
                        ownerTeam = p.ownerTeam, targetTeam = p.targetTeam,
                        x = tgt.x, y = tgt.y,
                        delay = p.meteorDelay or 1.5,
                        elapsed = 0,
                        meteorDamage = p.meteorDamage or 5,
                        meteorAoeRadius = p.meteorAoeRadius or 80,
                        meteorAoeDamage = p.meteorAoeDamage or 3,
                        color = p.color,
                        landed = false,
                    })
                    -- Apply DOT
                    if p.dotTotal and callbacks.onDot then
                        callbacks.onDot(p.targetTeam, p.ownerTeam, p.dotTotal, p.dotDuration, 0)
                    end
                else
                    -- Standard hit
                    local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                    local kx, ky = 0, 0
                    if spd > 1 and p.knockback > 0 then
                        kx = (p.vx / spd) * p.knockback
                        ky = (p.vy / spd) * p.knockback
                    end
                    if callbacks.onHit then
                        callbacks.onHit(p.targetTeam, p.damage, kx, ky, p.type, p.skillId, p)
                    end
                end -- inner if (homing/fire_shot/.../standard)
            end -- if d < radius
        end

        -- Timeout
        local maxAge = p.lifetime or 6
        if p.age > maxAge then p.alive = false end

        if not p.alive then
            table.remove(projectiles_, i)
        else
            i = i + 1
        end
    end

    -- === Bubbles (分裂泡): 持续膨胀，到期爆炸 ===
    i = 1
    while i <= #bubbles_ do
        local b = bubbles_[i]
        b.age = b.age + dt

        -- Grow: radius linearly increases from baseRadius to baseRadius * growthFactor
        local lifeRatio = math.min(b.age / b.lifetime, 1.0)
        b.radius = b.baseRadius * (1.0 + (b.growthFactor - 1.0) * lifeRatio)

        -- Slow down as it grows (heavier feel)
        local slowFactor = 1.0 - lifeRatio * 0.6
        b.x = b.x + b.vx * slowFactor * dt
        b.y = b.y + b.vy * slowFactor * dt

        -- Wall bounce (bubbles float and bounce gently)
        if b.x - b.radius < 0 then b.x = b.radius; b.vx = math.abs(b.vx) end
        if b.x + b.radius > size then b.x = size - b.radius; b.vx = -math.abs(b.vx) end
        if b.y - b.radius < 0 then b.y = b.radius; b.vy = math.abs(b.vy) end
        if b.y + b.radius > size then b.y = size - b.radius; b.vy = -math.abs(b.vy) end

        -- Contact with enemy → body damage + instant explode
        local shouldExplode = false
        local contactHit = false
        if balls[b.targetTeam] then
            local tgt = balls[b.targetTeam]
            local dx, dy = tgt.x - b.x, tgt.y - b.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < BALL.Radius + b.radius then
                shouldExplode = true
                contactHit = true
            end
        end

        -- Lifetime expired → also explode
        if b.age >= b.lifetime then
            shouldExplode = true
        end

        if shouldExplode then
            b.alive = false
            -- Body damage on contact: 2 base + 2 per second alive
            if contactHit and callbacks.onHit then
                local bodyDmg = 2 + math.floor(b.age) * 2
                callbacks.onHit(b.targetTeam, bodyDmg, 0, 0, "bubble_body", b.skillId, b)
            end
            -- Explosion AOE: deal damage to enemy in range
            table.insert(aoeEffects_, {
                skillId = b.skillId,
                ownerTeam = b.ownerTeam, targetTeam = b.targetTeam,
                x = b.x, y = b.y,
                currentRadius = 0,
                maxRadius = b.explodeRadius,
                expandSpeed = 400,
                damage = b.damage,
                knockback = b.knockback,
                duration = 0.35,
                elapsed = 0,
                hasHit = false,
                color = b.color,
            })
        end

        if not b.alive then
            table.remove(bubbles_, i)
        else
            i = i + 1
        end
    end

    -- === AOE effects ===
    i = 1
    while i <= #aoeEffects_ do
        local a = aoeEffects_[i]
        a.elapsed = a.elapsed + dt
        a.currentRadius = a.currentRadius + a.expandSpeed * dt

        if not a.hasHit and balls[a.targetTeam] then
            local tgt = balls[a.targetTeam]
            local dx, dy = tgt.x - a.x, tgt.y - a.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d < a.currentRadius + BALL.Radius then
                a.hasHit = true
                local kx, ky = 0, 0
                if d > 1 and a.knockback > 0 then
                    kx = (dx / d) * a.knockback
                    ky = (dy / d) * a.knockback
                end
                if callbacks.onHit then
                    callbacks.onHit(a.targetTeam, a.damage, kx, ky, "aoe", a.skillId)
                end
            end
        end

        if a.elapsed >= a.duration then
            table.remove(aoeEffects_, i)
        else
            i = i + 1
        end
    end

    -- === Laser emitters: damage along connecting lines ===
    i = 1
    while i <= #emitters_ do
        local e = emitters_[i]
        e.elapsed = e.elapsed + dt
        if e.elapsed >= e.life then
            table.remove(emitters_, i)
        else
            i = i + 1
        end
    end
    -- Pair emitters and check laser beam damage
    for ei = 1, #emitters_ do
        local e1 = emitters_[ei]
        for ej = ei + 1, #emitters_ do
            local e2 = emitters_[ej]
            if e1.ownerTeam == e2.ownerTeam then
                -- Check if any target ball crosses the laser line
                local targetTeam = e1.targetTeam
                if balls[targetTeam] then
                    local tgt = balls[targetTeam]
                    -- Point-to-line distance
                    local lx, ly = e2.x - e1.x, e2.y - e1.y
                    local len2 = lx * lx + ly * ly
                    if len2 > 1 then
                        local t = math.max(0, math.min(1, ((tgt.x - e1.x) * lx + (tgt.y - e1.y) * ly) / len2))
                        local closestX = e1.x + t * lx
                        local closestY = e1.y + t * ly
                        local dx, dy = tgt.x - closestX, tgt.y - closestY
                        local dist = math.sqrt(dx * dx + dy * dy)
                        if dist < BALL.Radius + (e1.laserWidth or 4) then
                            local dmg = (e1.laserDps or 2) * dt
                            if callbacks.onHit then
                                callbacks.onHit(targetTeam, dmg, 0, 0, "laser", e1.skillId)
                            end
                        end
                    end
                end
            end
        end
    end

    -- === Fire zones: persistent damage area ===
    i = 1
    while i <= #fireZones_ do
        local fz = fireZones_[i]
        fz.elapsed = fz.elapsed + dt
        fz.tickTimer = fz.tickTimer + dt

        if fz.elapsed >= fz.duration then
            table.remove(fireZones_, i)
        else
            -- Tick every 0.5s
            if fz.tickTimer >= 0.5 and balls[fz.targetTeam] then
                fz.tickTimer = fz.tickTimer - 0.5
                local tgt = balls[fz.targetTeam]
                local dx, dy = tgt.x - fz.x, tgt.y - fz.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d < fz.radius + BALL.Radius then
                    local dmg = fz.dps * 0.5
                    if callbacks.onHit then
                        callbacks.onHit(fz.targetTeam, dmg, 0, 0, "fire_zone", fz.skillId)
                    end
                    -- Apply slow
                    if callbacks.onSlow then
                        callbacks.onSlow(fz.targetTeam, fz.slowFactor, 0.6)
                    end
                end
            end
            i = i + 1
        end
    end

    -- === Meteors: delayed meteor drops ===
    i = 1
    while i <= #meteors_ do
        local m = meteors_[i]
        m.elapsed = m.elapsed + dt

        if not m.landed and m.elapsed >= m.delay then
            m.landed = true
            m.landTime = 0
            -- Direct meteor damage on target if still in range
            if balls[m.targetTeam] then
                local tgt = balls[m.targetTeam]
                local dx, dy = tgt.x - m.x, tgt.y - m.y
                local d = math.sqrt(dx * dx + dy * dy)
                if d < m.meteorAoeRadius + BALL.Radius then
                    if callbacks.onHit then
                        callbacks.onHit(m.targetTeam, m.meteorDamage, 0, 0, "meteor_land", m.skillId)
                    end
                end
            end
            -- AOE shockwave
            table.insert(aoeEffects_, {
                skillId = m.skillId,
                ownerTeam = m.ownerTeam, targetTeam = m.targetTeam,
                x = m.x, y = m.y,
                currentRadius = 0,
                maxRadius = m.meteorAoeRadius,
                expandSpeed = 350,
                damage = m.meteorAoeDamage,
                knockback = 200,
                duration = 0.5,
                elapsed = 0,
                hasHit = false,
                color = m.color,
            })
        end

        -- Remove after landing animation completes
        if m.landed then
            m.landTime = (m.landTime or 0) + dt
            if m.landTime > 0.8 then
                table.remove(meteors_, i)
            else
                i = i + 1
            end
        else
            i = i + 1
        end
    end

    -- === DOTs ===
    SkillExecutor.UpdateDots(dt, balls, callbacks)
end

-- ============================================================================
-- DOT System
-- ============================================================================

function SkillExecutor.AddDot(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
    table.insert(dots_, {
        targetTeam = targetTeam, sourceTeam = sourceTeam,
        damageLeft = dotTotal, healLeft = healTotal or 0,
        duration = dotDuration, elapsed = 0,
        tickInterval = 0.5, tickTimer = 0,
    })
end

function SkillExecutor.UpdateDots(dt, balls, callbacks)
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
                local remainTicks = math.max(1, totalTicks - math.floor(d.elapsed / d.tickInterval) + 1)
                local dmgT = d.damageLeft / remainTicks
                local healT = d.healLeft / remainTicks

                if callbacks.onDotTick then
                    callbacks.onDotTick(d.targetTeam, d.sourceTeam, dmgT, healT)
                end
                d.damageLeft = d.damageLeft - dmgT
                d.healLeft = d.healLeft - healT
            end
            i = i + 1
        end
    end
end

-- ============================================================================
-- Update Visual Projectiles
-- ============================================================================

function SkillExecutor.UpdateVisuals(dt, balls)
    local size = Settings.Arena.Size
    local i = 1
    while i <= #visualProjs_ do
        local p = visualProjs_[i]
        p.age = p.age + dt

        -- Homing visual turn
        if p.type == "homing" and p.targetTeam and balls[p.targetTeam] then
            local tgt = balls[p.targetTeam]
            local dx, dy = tgt.x - p.x, tgt.y - p.y
            local d = math.sqrt(dx * dx + dy * dy)
            if d > 1 and p.turnRate then
                local curA = math.atan(p.vy, p.vx)
                local tgtA = math.atan(dy, dx)
                local diff = tgtA - curA
                while diff > math.pi do diff = diff - 2 * math.pi end
                while diff < -math.pi do diff = diff + 2 * math.pi end
                local tr = p.turnRate
                diff = math.max(-tr * dt, math.min(tr * dt, diff))
                local newA = curA + diff
                local spd = math.sqrt(p.vx * p.vx + p.vy * p.vy)
                p.vx = math.cos(newA) * spd
                p.vy = math.sin(newA) * spd
            end
        end

        table.insert(p.trail, 1, { x = p.x, y = p.y })
        while #p.trail > (p.trailLen or 4) do table.remove(p.trail) end

        -- Save previous position for sweep collision
        local vprevX, vprevY = p.x, p.y

        p.x = p.x + p.vx * dt
        p.y = p.y + p.vy * dt

        local remove = false
        if p.age > 8 then
            remove = true
        end

        -- Wall collision for visual projectiles (no penetration)
        if not remove then
            local hitWall = false
            if p.x - p.radius < 0 then
                p.x = p.radius; hitWall = true
                if p.type == "beam" then p.vx = math.abs(p.vx) end
            elseif p.x + p.radius > size then
                p.x = size - p.radius; hitWall = true
                if p.type == "beam" then p.vx = -math.abs(p.vx) end
            end
            if p.y - p.radius < 0 then
                p.y = p.radius; hitWall = true
                if p.type == "beam" then p.vy = math.abs(p.vy) end
            elseif p.y + p.radius > size then
                p.y = size - p.radius; hitWall = true
                if p.type == "beam" then p.vy = -math.abs(p.vy) end
            end
            -- Beam bounces off walls; all others are destroyed
            if hitWall and p.type ~= "beam" then
                remove = true
            end
        end

        -- Hit target ball → remove (sweep: prevPos → curPos vs ball)
        if not remove and p.targetTeam and balls[p.targetTeam] then
            local tgt = balls[p.targetTeam]
            local hitR = BALL.Radius + p.radius
            if SweepHitCircle(vprevX, vprevY, p.x, p.y, tgt.x, tgt.y, hitR) then
                remove = true
            end
        end

        if remove then
            table.remove(visualProjs_, i)
        else
            i = i + 1
        end
    end
end

-- ============================================================================
-- Draw: Render all effects
-- ============================================================================

function SkillExecutor.Draw(vg, arenaX, arenaY)
    -- Fire zones (draw first, under everything)
    for _, fz in ipairs(fireZones_) do
        local fx, fy = arenaX + fz.x, arenaY + fz.y
        local t = 1 - fz.elapsed / fz.duration
        local alpha = math.floor(120 * math.min(1, t * 3)) -- fade in fast, fade out
        local pulse = 1.0 + 0.05 * math.sin(fz.elapsed * 6)
        local r = fz.radius * pulse

        -- Glow
        nvgBeginPath(vg); nvgCircle(vg, fx, fy, r)
        nvgFillPaint(vg, nvgRadialGradient(vg, fx, fy, r * 0.3, r,
            nvgRGBA(255, 100, 20, alpha),
            nvgRGBA(255, 50, 0, math.floor(alpha * 0.2))))
        nvgFill(vg)
        -- Border
        nvgBeginPath(vg); nvgCircle(vg, fx, fy, r)
        nvgStrokeColor(vg, nvgRGBA(255, 120, 30, math.floor(alpha * 0.8)))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
    end

    -- Laser beams between emitter pairs
    for ei = 1, #emitters_ do
        local e1 = emitters_[ei]
        local ex1, ey1 = arenaX + e1.x, arenaY + e1.y
        local t1 = 1 - e1.elapsed / e1.life

        -- Draw emitter dot
        nvgBeginPath(vg); nvgCircle(vg, ex1, ey1, 5)
        nvgFillColor(vg, nvgRGBA(e1.color.r, e1.color.g, e1.color.b, math.floor(200 * t1)))
        nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, ex1, ey1, 8)
        nvgFillPaint(vg, nvgRadialGradient(vg, ex1, ey1, 2, 8,
            nvgRGBA(e1.color.r, e1.color.g, e1.color.b, math.floor(100 * t1)),
            nvgRGBA(e1.color.r, e1.color.g, e1.color.b, 0)))
        nvgFill(vg)

        for ej = ei + 1, #emitters_ do
            local e2 = emitters_[ej]
            if e1.ownerTeam == e2.ownerTeam then
                local ex2, ey2 = arenaX + e2.x, arenaY + e2.y
                local t2 = 1 - e2.elapsed / e2.life
                local alpha = math.floor(180 * math.min(t1, t2))
                local w = e1.laserWidth or 4
                -- Outer glow
                nvgBeginPath(vg); nvgMoveTo(vg, ex1, ey1); nvgLineTo(vg, ex2, ey2)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, w * 3)
                nvgStrokeColor(vg, nvgRGBA(e1.color.r, e1.color.g, e1.color.b, math.floor(alpha * 0.3)))
                nvgStroke(vg)
                -- Core
                nvgBeginPath(vg); nvgMoveTo(vg, ex1, ey1); nvgLineTo(vg, ex2, ey2)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, w)
                nvgStrokeColor(vg, nvgRGBA(255, 200, 200, alpha))
                nvgStroke(vg)
            end
        end
    end

    -- Bubbles (分裂泡: 膨胀 + 接近爆炸时变红抖动)
    for _, b in ipairs(bubbles_) do
        local lifeRatio = math.min(b.age / b.lifetime, 1.0)
        local bx, by = arenaX + b.x, arenaY + b.y
        local c = b.color

        -- Shake more intensely as explosion approaches (last 30% of life)
        local shakePhase = math.max(0, (lifeRatio - 0.7) / 0.3)
        local shakeAmp = shakePhase * 3.0
        bx = bx + math.sin(b.age * 30) * shakeAmp
        by = by + math.cos(b.age * 25) * shakeAmp

        -- Gentle pulse
        local pulse = 1.0 + 0.05 * math.sin(b.age * 3)
        local r = b.radius * pulse

        -- Color: blend from original green toward red as it matures
        local cr = math.floor(c.r + (255 - c.r) * lifeRatio * 0.6)
        local cg = math.floor(c.g * (1.0 - lifeRatio * 0.5))
        local cb = math.floor(c.b * (1.0 - lifeRatio * 0.4))
        local alpha = math.floor(180 - lifeRatio * 40)  -- stays fairly opaque

        -- Outer glow (grows with bubble)
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r + 8)
        nvgFillPaint(vg, nvgRadialGradient(vg, bx, by, r * 0.4, r + 8,
            nvgRGBA(cr, cg, cb, math.floor(50 + 30 * lifeRatio)),
            nvgRGBA(cr, cg, cb, 0)))
        nvgFill(vg)

        -- Body (semi-transparent bubble)
        nvgBeginPath(vg); nvgCircle(vg, bx, by, r)
        nvgFillColor(vg, nvgRGBA(cr, cg, cb, math.floor(alpha * 0.6)))
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(255, 255, 255, math.floor(alpha * 0.8)))
        nvgStrokeWidth(vg, 1.5 + lifeRatio); nvgStroke(vg)

        -- Highlight (bubble shine)
        nvgBeginPath(vg); nvgCircle(vg, bx - r * 0.3, by - r * 0.3, r * 0.2)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, math.floor(100 * (1.0 - lifeRatio * 0.5))))
        nvgFill(vg)

        -- Warning ring in last 20% of life
        if lifeRatio > 0.8 then
            local ringAlpha = math.floor((lifeRatio - 0.8) / 0.2 * 180)
            local ringPulse = 1.0 + 0.1 * math.sin(b.age * 15)
            nvgBeginPath(vg); nvgCircle(vg, bx, by, r * ringPulse + 4)
            nvgStrokeColor(vg, nvgRGBA(255, 80, 80, ringAlpha))
            nvgStrokeWidth(vg, 2.0); nvgStroke(vg)
        end
    end

    -- Visual projectiles (trails)
    for _, p in ipairs(visualProjs_) do
        local px, py = arenaX + p.x, arenaY + p.y
        local c = p.color or { r = 255, g = 255, b = 255 }

        if p.type == "beam" then
            if #p.trail > 0 then
                local tailX = arenaX + p.trail[#p.trail].x
                local tailY = arenaY + p.trail[#p.trail].y
                local bw = p.radius
                nvgBeginPath(vg); nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, bw * 4)
                nvgStrokeColor(vg, nvgRGBA(c.r, c.g, c.b, 40)); nvgStroke(vg)
                nvgBeginPath(vg); nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, bw * 2.2)
                nvgStrokeColor(vg, nvgRGBA(c.r, c.g, c.b, 120)); nvgStroke(vg)
                nvgBeginPath(vg); nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, bw * 1.2)
                nvgStrokeColor(vg, nvgRGBA(math.min(255, c.r + 80), math.min(255, c.g + 50), math.min(255, c.b + 50), 220))
                nvgStroke(vg)
                nvgBeginPath(vg); nvgMoveTo(vg, tailX, tailY); nvgLineTo(vg, px, py)
                nvgLineCap(vg, NVG_ROUND); nvgStrokeWidth(vg, bw * 0.5)
                nvgStrokeColor(vg, nvgRGBA(255, 255, 255, 200)); nvgStroke(vg)
            end
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius + 4)
            nvgFillPaint(vg, nvgRadialGradient(vg, px, py, 2, p.radius + 6,
                nvgRGBA(255, 255, 255, 200), nvgRGBA(c.r, c.g, c.b, 0)))
            nvgFill(vg)
        else
            -- Trail
            for j = #p.trail, 1, -1 do
                local t = p.trail[j]
                local ratio = 1 - (j - 1) / #p.trail
                nvgBeginPath(vg)
                nvgCircle(vg, arenaX + t.x, arenaY + t.y, p.radius * (0.4 + 0.6 * ratio))
                nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, math.floor(180 * ratio)))
                nvgFill(vg)
            end
            -- Head
            nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius)
            nvgFillColor(vg, nvgRGBA(math.min(255, c.r + 50), math.min(255, c.g + 50), math.min(255, c.b + 50), 255))
            nvgFill(vg)
            nvgBeginPath(vg); nvgCircle(vg, px - 2, py - 2, p.radius * 0.4)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 180)); nvgFill(vg)
            -- Homing glow ring
            if p.type == "homing" then
                nvgBeginPath(vg); nvgCircle(vg, px, py, p.radius + 3)
                nvgStrokeColor(vg, nvgRGBA(c.r, c.g, c.b, 100)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
            end
        end
    end

    -- Meteors (warning circle + falling rock + impact flash)
    for _, m in ipairs(meteors_) do
        local mx, my = arenaX + m.x, arenaY + m.y
        local c = m.color or { r = 255, g = 100, b = 30 }

        if not m.landed then
            -- Pre-landing: pulsing warning circle
            local t = m.elapsed / m.delay  -- 0→1
            local warningR = (m.meteorAoeRadius or 80) * (0.5 + 0.5 * t)
            local pulse = math.sin(m.elapsed * 10) * 0.3 + 0.7
            local alpha = math.floor(60 + 120 * t * pulse)

            -- Warning fill
            nvgBeginPath(vg); nvgCircle(vg, mx, my, warningR)
            nvgFillPaint(vg, nvgRadialGradient(vg, mx, my, warningR * 0.2, warningR,
                nvgRGBA(255, 60, 20, math.floor(alpha * 0.4)),
                nvgRGBA(255, 30, 0, math.floor(alpha * 0.1))))
            nvgFill(vg)

            -- Warning ring
            nvgBeginPath(vg); nvgCircle(vg, mx, my, warningR)
            nvgStrokeColor(vg, nvgRGBA(255, 80, 30, alpha))
            nvgStrokeWidth(vg, 2.5); nvgStroke(vg)

            -- Inner crosshair
            local crossSize = 8 + 6 * t
            nvgBeginPath(vg)
            nvgMoveTo(vg, mx - crossSize, my); nvgLineTo(vg, mx + crossSize, my)
            nvgMoveTo(vg, mx, my - crossSize); nvgLineTo(vg, mx, my + crossSize)
            nvgStrokeColor(vg, nvgRGBA(255, 200, 100, alpha))
            nvgStrokeWidth(vg, 1.5); nvgStroke(vg)

            -- Falling rock indicator (shrinking circle above)
            local fallProgress = t
            local rockY = my - 60 * (1 - fallProgress)
            local rockR = 6 + 8 * fallProgress
            nvgBeginPath(vg); nvgCircle(vg, mx, rockY, rockR)
            nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, math.floor(180 * fallProgress)))
            nvgFill(vg)
            -- Rock glow
            nvgBeginPath(vg); nvgCircle(vg, mx, rockY, rockR + 4)
            nvgFillPaint(vg, nvgRadialGradient(vg, mx, rockY, rockR * 0.5, rockR + 4,
                nvgRGBA(255, 200, 80, math.floor(80 * fallProgress)),
                nvgRGBA(255, 100, 20, 0)))
            nvgFill(vg)
        else
            -- Post-landing: impact flash + crater
            local lt = m.landTime or 0
            local fadeT = 1 - math.min(lt / 0.8, 1)
            local impactR = (m.meteorAoeRadius or 80) * (0.6 + 0.4 * (1 - fadeT))
            local alpha = math.floor(200 * fadeT)

            -- Impact flash (bright center)
            if lt < 0.15 then
                local flashAlpha = math.floor(255 * (1 - lt / 0.15))
                nvgBeginPath(vg); nvgCircle(vg, mx, my, impactR * 0.8)
                nvgFillPaint(vg, nvgRadialGradient(vg, mx, my, 0, impactR * 0.8,
                    nvgRGBA(255, 255, 200, flashAlpha),
                    nvgRGBA(255, 120, 30, math.floor(flashAlpha * 0.3))))
                nvgFill(vg)
            end

            -- Crater ring
            nvgBeginPath(vg); nvgCircle(vg, mx, my, impactR)
            nvgFillPaint(vg, nvgRadialGradient(vg, mx, my, impactR * 0.3, impactR,
                nvgRGBA(255, 80, 20, math.floor(alpha * 0.3)),
                nvgRGBA(c.r, c.g, c.b, math.floor(alpha * 0.05))))
            nvgFill(vg)
            nvgBeginPath(vg); nvgCircle(vg, mx, my, impactR)
            nvgStrokeColor(vg, nvgRGBA(255, 120, 40, math.floor(alpha * 0.6)))
            nvgStrokeWidth(vg, 2 * fadeT); nvgStroke(vg)
        end
    end

    -- AOE effects
    for _, a in ipairs(aoeEffects_) do
        local ax, ay = arenaX + a.x, arenaY + a.y
        local c = a.color or { r = 255, g = 200, b = 50 }
        local t = 1 - a.elapsed / a.duration
        local alpha = math.floor(180 * t)
        nvgBeginPath(vg); nvgCircle(vg, ax, ay, a.currentRadius)
        nvgStrokeColor(vg, nvgRGBA(c.r, c.g, c.b, alpha))
        nvgStrokeWidth(vg, 4 * t + 1); nvgStroke(vg)
        nvgBeginPath(vg); nvgCircle(vg, ax, ay, a.currentRadius)
        nvgFillColor(vg, nvgRGBA(c.r, c.g, c.b, math.floor(40 * t)))
        nvgFill(vg)
    end
end

-- ============================================================================
-- Clear all state
-- ============================================================================

function SkillExecutor.Clear()
    projectiles_ = {}
    visualProjs_ = {}
    dots_        = {}
    aoeEffects_  = {}
    emitters_    = {}
    fireZones_   = {}
    bubbles_     = {}
    meteors_     = {}
end

-- ============================================================================
-- Accessors
-- ============================================================================

function SkillExecutor.GetProjectiles()
    return projectiles_
end

function SkillExecutor.GetVisualProjectiles()
    return visualProjs_
end

function SkillExecutor.GetEmitters()
    return emitters_
end

function SkillExecutor.GetFireZones()
    return fireZones_
end

function SkillExecutor.GetBubbles()
    return bubbles_
end

function SkillExecutor.GetDots()
    return dots_
end

function SkillExecutor.GetMeteors()
    return meteors_
end

return SkillExecutor
