-- ============================================================================
-- ItemSystem.lua - 道具系统（8种道具 + 装备槽位系统）
-- 道具放置在竞技场中，对场内球体产生区域效果
-- 装备系统：全部道具可解锁，最多选择3个带进擂台赛
-- ============================================================================

local Settings    = require("config.Settings")
local ShopManager = require("game.ShopManager")
local BALL = Settings.Ball

local ItemSystem = {}

-- ============================================================================
-- 道具定义（8种）
-- ============================================================================

ItemSystem.DEFS = {
    -- [1] 蜘蛛网
    {
        id       = "spider_web",
        name     = "蜘蛛网",
        emoji    = "🕸️",
        desc     = "降低范围内速度",
        cooldown = 10,
        radius   = 55,
        slowFactor = 0.35,
        hp       = 1,
    },
    -- [2] 带刺木桩
    {
        id       = "thorny_stake",
        name     = "带刺木桩",
        emoji    = "🌵",
        desc     = "碰撞反弹+伤害",
        cooldown = 10,
        radius   = 30,
        damage   = 8,
        hp       = 3,
    },
    -- [3] 黑洞
    {
        id       = "micro_blackhole",
        name     = "黑洞",
        emoji    = "🌀",
        desc     = "吸引双方球体",
        cooldown = 10,
        radius   = 70,
        duration = 5,
        pullForce = 180,
        pushForce = 350,
    },
    -- [4] 大炸弹
    {
        id       = "big_bomb",
        name     = "大炸弹",
        emoji    = "💣",
        desc     = "延迟3秒爆炸",
        cooldown = 12,
        radius   = 70,
        fuseTime = 3.0,
        damage   = 12,
        pushForce = 600,
    },
    -- [5] 旋转木板（新机制：5次碰撞损坏，无时限）
    {
        id       = "spinning_plank",
        name     = "旋转木板",
        emoji    = "🪵",
        desc     = "旋转扫荡，5次碰撞后损坏",
        cooldown = 10,
        radius   = 60,
        damage   = 5,
        pushForce = 300,
        rotSpeed = 3.0,
        plankWidth = 12,
        hp       = 5,          -- 5次碰撞后损坏
    },
    -- [6] 地雷（新机制：10伤害+50范围冲击）
    {
        id       = "landmine",
        name     = "地雷",
        emoji    = "💥",
        desc     = "踩中爆炸+范围冲击",
        cooldown = 10,
        radius   = 50,          -- 冲击范围50
        triggerRadius = 20,
        damage   = 10,          -- 伤害10
        pushForce = 450,
        armTime  = 1.0,
    },
    -- [7] 破片地雷（新）
    {
        id       = "shrapnel_mine",
        name     = "破片地雷",
        emoji    = "🧨",
        desc     = "爆炸+10弹幕+范围冲击",
        cooldown = 12,
        radius   = 50,          -- 冲击范围50
        triggerRadius = 20,
        damage   = 5,           -- 直接伤害5
        pushForce = 450,
        armTime  = 1.0,
        shrapnelCount = 10,     -- 弹幕数量
        shrapnelDamage = 2,     -- 每个弹幕伤害
        shrapnelSpeed = 350,    -- 弹幕速度
        shrapnelLife  = 2.5,    -- 弹幕存活时间
    },
    -- [8] 冻结（新）
    {
        id       = "freeze",
        name     = "冻结",
        emoji    = "❄️",
        desc     = "冻结范围内球球",
        cooldown = 15,
        radius   = 30,          -- 冻结范围30
        freezeDuration = 5.0,   -- 冻结持续5秒
        freezeCollisionDmg = 5, -- 冻结期间碰撞伤害5
    },
}

-- ============================================================================
-- 装备系统：最多3个道具带入擂台
-- ============================================================================

local SLOT_COUNT = 3
local equipped_ = {}     -- 装备列表：equipped_[slot] = defIndex (1-8)
local DEFAULT_EQUIPPED = { 1, 2, 3 }  -- 默认装备前3个

-- ============================================================================
-- State
-- ============================================================================

local placed_ = {}           -- 场上已放置道具
local projectiles_ = {}      -- 破片弹幕列表
local cooldowns_ = { 0, 0, 0 }  -- per-slot cooldown timers

-- ============================================================================
-- 装备 API
-- ============================================================================

--- 初始化装备列表（从 ShopManager 加载）
function ItemSystem.LoadEquipped()
    local saved = ShopManager.GetEquippedItems()
    if saved and #saved > 0 then
        equipped_ = {}
        for i = 1, math.min(#saved, SLOT_COUNT) do
            -- 将 itemId 转换为 defIndex
            local defIdx = ItemSystem.GetDefIndexById(saved[i])
            if defIdx then
                table.insert(equipped_, defIdx)
            end
        end
    end
    -- 如果装备列表为空，使用默认的已解锁道具
    if #equipped_ == 0 then
        equipped_ = {}
        for _, idx in ipairs(DEFAULT_EQUIPPED) do
            if ShopManager.HasItem(ItemSystem.DEFS[idx].id) then
                table.insert(equipped_, idx)
                if #equipped_ >= SLOT_COUNT then break end
            end
        end
    end
end

--- 保存装备列表到 ShopManager
function ItemSystem.SaveEquipped()
    local ids = {}
    for _, defIdx in ipairs(equipped_) do
        local def = ItemSystem.DEFS[defIdx]
        if def then
            table.insert(ids, def.id)
        end
    end
    ShopManager.SetEquippedItems(ids)
end

--- 设置装备列表（传入 defIndex 数组）
function ItemSystem.SetEquipped(defIndices)
    equipped_ = {}
    for i = 1, math.min(#defIndices, SLOT_COUNT) do
        equipped_[i] = defIndices[i]
    end
    ItemSystem.SaveEquipped()
end

--- 获取装备列表（返回 defIndex 数组）
function ItemSystem.GetEquipped()
    return equipped_
end

--- 装备一个道具（添加到末尾，不超过 SLOT_COUNT）
function ItemSystem.Equip(defIndex)
    if #equipped_ >= SLOT_COUNT then return false end
    -- 检查是否已装备
    for _, idx in ipairs(equipped_) do
        if idx == defIndex then return false end
    end
    -- 检查是否已解锁
    local def = ItemSystem.DEFS[defIndex]
    if not def or not ShopManager.HasItem(def.id) then return false end
    table.insert(equipped_, defIndex)
    ItemSystem.SaveEquipped()
    return true
end

--- 卸下一个道具
function ItemSystem.Unequip(defIndex)
    for i = #equipped_, 1, -1 do
        if equipped_[i] == defIndex then
            table.remove(equipped_, i)
            ItemSystem.SaveEquipped()
            return true
        end
    end
    return false
end

--- 检查某个道具是否已装备
function ItemSystem.IsEquipped(defIndex)
    for _, idx in ipairs(equipped_) do
        if idx == defIndex then return true end
    end
    return false
end

--- 通过 id 查找 defIndex
function ItemSystem.GetDefIndexById(itemId)
    for i, def in ipairs(ItemSystem.DEFS) do
        if def.id == itemId then return i end
    end
    return nil
end

--- 获取所有道具定义数量
function ItemSystem.GetDefCount()
    return #ItemSystem.DEFS
end

-- ============================================================================
-- 核心 API
-- ============================================================================

function ItemSystem.Init()
    placed_ = {}
    projectiles_ = {}
    cooldowns_ = {}
    for i = 1, SLOT_COUNT do cooldowns_[i] = 0 end
    ItemSystem.LoadEquipped()
end

function ItemSystem.GetSlotCount()
    return SLOT_COUNT
end

--- 获取槽位对应的道具定义（通过装备映射）
function ItemSystem.GetDef(slot)
    local defIdx = equipped_[slot]
    if not defIdx then return nil end
    return ItemSystem.DEFS[defIdx]
end

function ItemSystem.GetCooldown(slot)
    return cooldowns_[slot] or 0
end

function ItemSystem.IsReady(slot)
    return (cooldowns_[slot] or 0) <= 0
end

--- 检查槽位道具是否已解锁
function ItemSystem.IsUnlocked(slot)
    local def = ItemSystem.GetDef(slot)
    if not def then return false end
    return ShopManager.HasItem(def.id)
end

--- 在竞技场位置 (ax, ay) 放置道具
function ItemSystem.Place(slot, ax, ay)
    local def = ItemSystem.GetDef(slot)
    if not def then return false end
    if not ItemSystem.IsUnlocked(slot) then return false end
    if not ItemSystem.IsReady(slot) then return false end

    local item = {
        defId    = def.id,
        slot     = slot,
        x        = ax,
        y        = ay,
        radius   = def.radius,
        hp       = def.hp or 999,
        elapsed  = 0,
        duration = def.duration or 999,
        alive    = true,
    }

    -- Type-specific fields
    if def.id == "spider_web" then
        item.slowFactor = def.slowFactor
    elseif def.id == "thorny_stake" then
        item.damage = def.damage
    elseif def.id == "micro_blackhole" then
        item.pullForce = def.pullForce
        item.pushForce = def.pushForce
        item.pushed = false
    elseif def.id == "big_bomb" then
        item.fuseTime = def.fuseTime
        item.damage = def.damage
        item.pushForce = def.pushForce
        item.exploded = false
        item.duration = def.fuseTime + 0.5
    elseif def.id == "spinning_plank" then
        item.damage = def.damage
        item.pushForce = def.pushForce
        item.rotSpeed = def.rotSpeed
        item.plankWidth = def.plankWidth
        item.angle = 0
        item.hitCooldowns = {}
        -- 无时限，通过 hp(5次碰撞)决定寿命
        item.duration = 9999
    elseif def.id == "landmine" then
        item.triggerRadius = def.triggerRadius
        item.damage = def.damage
        item.pushForce = def.pushForce
        item.armTime = def.armTime
        item.armed = false
        item.exploded = false
        item.duration = 30
    elseif def.id == "shrapnel_mine" then
        item.triggerRadius = def.triggerRadius
        item.damage = def.damage
        item.pushForce = def.pushForce
        item.armTime = def.armTime
        item.armed = false
        item.exploded = false
        item.duration = 30
    elseif def.id == "freeze" then
        -- 冻结是瞬发效果，放置后立即生效
        item.duration = 0.8  -- 短暂的视觉特效时间
        item.freezeApplied = false
    end

    table.insert(placed_, item)
    cooldowns_[slot] = def.cooldown
    return true
end

--- 更新所有已放置道具 + 弹幕
function ItemSystem.Update(dt, balls)
    -- Update cooldowns
    for i = 1, SLOT_COUNT do
        if cooldowns_[i] > 0 then
            cooldowns_[i] = cooldowns_[i] - dt
            if cooldowns_[i] < 0 then cooldowns_[i] = 0 end
        end
    end

    local size = Settings.Arena.Size
    local i = 1
    while i <= #placed_ do
        local item = placed_[i]
        item.elapsed = item.elapsed + dt

        if not item.alive or item.elapsed >= item.duration then
            -- End-of-life push for black hole
            if item.defId == "micro_blackhole" and not item.pushed then
                item.pushed = true
                for bi = 1, #balls do
                    local b = balls[bi]
                    if b and b.alive ~= false then
                        local dx, dy = b.x - item.x, b.y - item.y
                        local d = math.sqrt(dx * dx + dy * dy)
                        if d < 1 then d = 1 end
                        local pushF = item.pushForce or 350
                        b.vx = b.vx + (dx / d) * pushF
                        b.vy = b.vy + (dy / d) * pushF
                    end
                end
            end
            table.remove(placed_, i)
        else
            -- Apply per-type effects
            if item.defId == "spider_web" then
                ItemSystem._UpdateSpiderWeb(item, balls, dt)
            elseif item.defId == "thorny_stake" then
                ItemSystem._UpdateThornyStake(item, balls, dt)
            elseif item.defId == "micro_blackhole" then
                ItemSystem._UpdateBlackHole(item, balls, dt)
            elseif item.defId == "big_bomb" then
                ItemSystem._UpdateBigBomb(item, balls, dt)
            elseif item.defId == "spinning_plank" then
                ItemSystem._UpdateSpinningPlank(item, balls, dt)
            elseif item.defId == "landmine" then
                ItemSystem._UpdateLandmine(item, balls, dt)
            elseif item.defId == "shrapnel_mine" then
                ItemSystem._UpdateShrapnelMine(item, balls, dt)
            elseif item.defId == "freeze" then
                ItemSystem._UpdateFreeze(item, balls, dt)
            end
            i = i + 1
        end
    end

    -- 更新弹幕
    ItemSystem._UpdateProjectiles(dt, balls)

    -- 更新冻结状态
    ItemSystem._UpdateFreezeStatus(dt, balls)
end

-- ============================================================================
-- Spider Web
-- ============================================================================

function ItemSystem._UpdateSpiderWeb(item, balls, dt)
    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < item.radius + BALL.Radius then
            local spd = math.sqrt(b.vx * b.vx + b.vy * b.vy)
            local maxSpd = BALL.Speed * item.slowFactor
            if spd > maxSpd then
                local scale = maxSpd / spd
                b.vx = b.vx * scale
                b.vy = b.vy * scale
            end
            if d < item.radius * 0.5 then
                item.hp = item.hp - 1
                if item.hp <= 0 then
                    item.alive = false
                end
            end
        end
        ::continue::
    end
end

-- ============================================================================
-- Thorny Stake
-- ============================================================================

function ItemSystem._UpdateThornyStake(item, balls, dt)
    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        local hitDist = item.radius + BALL.Radius
        if d < hitDist and d > 1 then
            local nx, ny = dx / d, dy / d
            b.x = item.x + nx * hitDist
            b.y = item.y + ny * hitDist
            local dot = b.vx * nx + b.vy * ny
            if dot < 0 then
                b.vx = b.vx - 2 * dot * nx
                b.vy = b.vy - 2 * dot * ny
                b.hp = b.hp - item.damage
                if b.hp < 0 then b.hp = 0 end
                item.hp = item.hp - 1
                if item.hp <= 0 then
                    item.alive = false
                end
            end
        end
        ::continue::
    end
end

-- ============================================================================
-- Black Hole
-- ============================================================================

function ItemSystem._UpdateBlackHole(item, balls, dt)
    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = item.x - b.x, item.y - b.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < 1 then d = 1 end
        local force = item.pullForce or 180
        local strength = force * math.min(1.0, (item.radius * 2) / d)
        b.vx = b.vx + (dx / d) * strength * dt
        b.vy = b.vy + (dy / d) * strength * dt
        ::continue::
    end
end

-- ============================================================================
-- Big Bomb
-- ============================================================================

function ItemSystem._UpdateBigBomb(item, balls, dt)
    if item.exploded then return end
    if item.elapsed < item.fuseTime then return end

    item.exploded = true
    item.alive = false

    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < item.radius + BALL.Radius then
            b.hp = b.hp - item.damage
            if b.hp < 0 then b.hp = 0 end
            if d < 1 then d = 1 end
            local nx, ny = dx / d, dy / d
            local strength = item.pushForce * (1.0 - d / (item.radius + BALL.Radius))
            b.vx = b.vx + nx * strength
            b.vy = b.vy + ny * strength
        end
        ::continue::
    end
end

-- ============================================================================
-- Spinning Plank（新机制：5次碰撞损坏，无时限）
-- ============================================================================

function ItemSystem._UpdateSpinningPlank(item, balls, dt)
    -- 更新旋转角度
    item.angle = item.angle + item.rotSpeed * dt

    -- 更新 per-ball hit cooldowns
    for bIdx, cd in pairs(item.hitCooldowns) do
        item.hitCooldowns[bIdx] = cd - dt
        if item.hitCooldowns[bIdx] <= 0 then
            item.hitCooldowns[bIdx] = nil
        end
    end

    -- 木板两个端点
    local halfLen = item.radius
    local cosA = math.cos(item.angle)
    local sinA = math.sin(item.angle)
    local ex, ey = cosA * halfLen, sinA * halfLen

    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        if item.hitCooldowns[bi] and item.hitCooldowns[bi] > 0 then goto continue end

        local bx, by = b.x - item.x, b.y - item.y
        local segLenSq = (2 * ex) * (2 * ex) + (2 * ey) * (2 * ey)
        if segLenSq < 1 then goto continue end
        local t = ((bx - (-ex)) * (2 * ex) + (by - (-ey)) * (2 * ey)) / segLenSq
        t = math.max(0, math.min(1, t))
        local closestX = -ex + t * (2 * ex)
        local closestY = -ey + t * (2 * ey)
        local distX, distY = bx - closestX, by - closestY
        local dist = math.sqrt(distX * distX + distY * distY)
        local hitDist = (item.plankWidth / 2) + BALL.Radius

        if dist < hitDist then
            b.hp = b.hp - item.damage
            if b.hp < 0 then b.hp = 0 end
            if dist < 1 then dist = 1 end
            local nx, ny = distX / dist, distY / dist
            b.vx = b.vx + nx * item.pushForce
            b.vy = b.vy + ny * item.pushForce
            item.hitCooldowns[bi] = 0.5
            -- 扣除耐久
            item.hp = item.hp - 1
            if item.hp <= 0 then
                item.alive = false
            end
        end
        ::continue::
    end
end

-- ============================================================================
-- Landmine（新机制：10伤害+50范围冲击）
-- ============================================================================

function ItemSystem._UpdateLandmine(item, balls, dt)
    if item.exploded then return end
    if item.elapsed < item.armTime then return end
    item.armed = true

    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < item.triggerRadius + BALL.Radius then
            item.exploded = true
            item.explodeTime = item.elapsed
            item.duration = item.elapsed + 0.5  -- 延长0.5秒播放爆炸特效
            -- 对踩中的球造成伤害
            b.hp = b.hp - item.damage
            if b.hp < 0 then b.hp = 0 end
            -- 范围冲击推力
            for bi2 = 1, #balls do
                local b2 = balls[bi2]
                if not b2 or b2.alive == false then goto continue2 end
                local dx2, dy2 = b2.x - item.x, b2.y - item.y
                local d2 = math.sqrt(dx2 * dx2 + dy2 * dy2)
                if d2 < item.radius + BALL.Radius then
                    if d2 < 1 then d2 = 1 end
                    local nx, ny = dx2 / d2, dy2 / d2
                    local strength = item.pushForce * (1.0 - d2 / (item.radius + BALL.Radius))
                    b2.vx = b2.vx + nx * strength
                    b2.vy = b2.vy + ny * strength
                end
                ::continue2::
            end
            return
        end
        ::continue::
    end
end

-- ============================================================================
-- Shrapnel Mine（破片地雷：5伤害+10弹幕+50范围冲击）
-- ============================================================================

function ItemSystem._UpdateShrapnelMine(item, balls, dt)
    if item.exploded then return end
    if item.elapsed < item.armTime then return end
    item.armed = true

    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < item.triggerRadius + BALL.Radius then
            item.exploded = true
            item.explodeTime = item.elapsed
            item.duration = item.elapsed + 0.5  -- 延长0.5秒播放爆炸特效

            -- 直接伤害
            b.hp = b.hp - item.damage
            if b.hp < 0 then b.hp = 0 end

            -- 范围冲击推力
            for bi2 = 1, #balls do
                local b2 = balls[bi2]
                if not b2 or b2.alive == false then goto continue2 end
                local dx2, dy2 = b2.x - item.x, b2.y - item.y
                local d2 = math.sqrt(dx2 * dx2 + dy2 * dy2)
                if d2 < item.radius + BALL.Radius then
                    if d2 < 1 then d2 = 1 end
                    local nx, ny = dx2 / d2, dy2 / d2
                    local strength = item.pushForce * (1.0 - d2 / (item.radius + BALL.Radius))
                    b2.vx = b2.vx + nx * strength
                    b2.vy = b2.vy + ny * strength
                end
                ::continue2::
            end

            -- 生成弹幕
            local def = nil
            for _, dd in ipairs(ItemSystem.DEFS) do
                if dd.id == "shrapnel_mine" then def = dd; break end
            end
            if def then
                local count = def.shrapnelCount or 10
                local spd = def.shrapnelSpeed or 350
                local dmg = def.shrapnelDamage or 2
                local life = def.shrapnelLife or 2.5
                for si = 1, count do
                    local angle = (si - 1) * (2 * math.pi / count) + math.random() * 0.3
                    table.insert(projectiles_, {
                        x = item.x,
                        y = item.y,
                        vx = math.cos(angle) * spd,
                        vy = math.sin(angle) * spd,
                        damage = dmg,
                        life = life,
                        elapsed = 0,
                        radius = 4,
                    })
                end
            end
            return
        end
        ::continue::
    end
end

-- ============================================================================
-- 弹幕系统（破片地雷的弹丸）
-- ============================================================================

function ItemSystem._UpdateProjectiles(dt, balls)
    local size = Settings.Arena.Size
    local i = 1
    while i <= #projectiles_ do
        local p = projectiles_[i]
        p.elapsed = p.elapsed + dt
        if p.elapsed >= p.life then
            table.remove(projectiles_, i)
        else
            -- 移动
            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt

            -- 墙壁反弹
            if p.x < p.radius then
                p.x = p.radius
                p.vx = math.abs(p.vx)
            elseif p.x > size - p.radius then
                p.x = size - p.radius
                p.vx = -math.abs(p.vx)
            end
            if p.y < p.radius then
                p.y = p.radius
                p.vy = math.abs(p.vy)
            elseif p.y > size - p.radius then
                p.y = size - p.radius
                p.vy = -math.abs(p.vy)
            end

            -- 命中球体
            local hit = false
            for bi = 1, #balls do
                local b = balls[bi]
                if b and b.alive ~= false then
                    local dx, dy = b.x - p.x, b.y - p.y
                    local d = math.sqrt(dx * dx + dy * dy)
                    if d < BALL.Radius + p.radius then
                        b.hp = b.hp - p.damage
                        if b.hp < 0 then b.hp = 0 end
                        -- 轻微推力
                        if d < 1 then d = 1 end
                        local nx, ny = dx / d, dy / d
                        b.vx = b.vx + nx * 60
                        b.vy = b.vy + ny * 60
                        hit = true
                        break
                    end
                end
            end
            if hit then
                table.remove(projectiles_, i)
            else
                i = i + 1
            end
        end
    end
end

-- ============================================================================
-- Freeze（冻结：30范围冻结+碰撞5伤害+5s持续）
-- ============================================================================

function ItemSystem._UpdateFreeze(item, balls, dt)
    if item.freezeApplied then return end
    item.freezeApplied = true

    local def = nil
    for _, d in ipairs(ItemSystem.DEFS) do
        if d.id == "freeze" then def = d; break end
    end
    if not def then return end

    -- 对范围内所有球施加冻结
    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        local dx, dy = b.x - item.x, b.y - item.y
        local d = math.sqrt(dx * dx + dy * dy)
        if d < def.radius + BALL.Radius then
            -- 施加冻结状态
            b.frozenTimer = def.freezeDuration
            b.frozenImmobile = true  -- 冻结后立即静止
            b.frozenCollisionDmg = def.freezeCollisionDmg
            -- 立即停止
            b.vx = 0
            b.vy = 0
            print(string.format("[ItemSystem] Ball %d frozen for %.1fs", bi, def.freezeDuration))
        end
        ::continue::
    end
end

--- 更新球的冻结状态（每帧调用）
function ItemSystem._UpdateFreezeStatus(dt, balls)
    for bi = 1, #balls do
        local b = balls[bi]
        if not b or b.alive == false then goto continue end
        if b.frozenTimer and b.frozenTimer > 0 then
            b.frozenTimer = b.frozenTimer - dt
            if b.frozenTimer <= 0 then
                -- 冻结结束
                b.frozenTimer = 0
                b.frozenImmobile = false
                b.frozenCollisionDmg = 0
                print(string.format("[ItemSystem] Ball %d unfrozen", bi))
            elseif b.frozenImmobile then
                -- 仍然处于完全冻结（未受到冲击）：强制停止
                b.vx = 0
                b.vy = 0
            end
        end
        ::continue::
    end
end

--- 检查球是否被冻结（供外部调用）
function ItemSystem.IsFrozen(ball)
    return ball and ball.frozenTimer and ball.frozenTimer > 0
end

--- 检查球是否完全不动（冻结+未受冲击）
function ItemSystem.IsFrozenImmobile(ball)
    return ball and ball.frozenImmobile == true and ball.frozenTimer and ball.frozenTimer > 0
end

--- 当冻结球受到碰撞时调用（由外部碰撞逻辑调用）
--- 解除immobile状态，施加冻结碰撞伤害
function ItemSystem.OnFrozenCollision(ball)
    if not ItemSystem.IsFrozen(ball) then return end
    -- 解除静止状态，开始移动
    if ball.frozenImmobile then
        ball.frozenImmobile = false
    end
    -- 施加碰撞伤害
    local dmg = ball.frozenCollisionDmg or 5
    ball.hp = ball.hp - dmg
    if ball.hp < 0 then ball.hp = 0 end
    return dmg
end

-- ============================================================================
-- Draw
-- ============================================================================

function ItemSystem.Draw(vg, arenaX, arenaY, fontId, scaleF)
    scaleF = scaleF or 1.0

    -- 绘制已放置道具
    for _, item in ipairs(placed_) do
        local cx, cy = arenaX + item.x * scaleF, arenaY + item.y * scaleF
        local r = item.radius * scaleF
        local life = 1 - item.elapsed / item.duration

        if item.defId == "spider_web" then
            ItemSystem._DrawSpiderWeb(vg, cx, cy, r, item, fontId, scaleF, life)
        elseif item.defId == "thorny_stake" then
            ItemSystem._DrawThornyStake(vg, cx, cy, r, item, fontId, scaleF, life)
        elseif item.defId == "micro_blackhole" then
            ItemSystem._DrawBlackHole(vg, cx, cy, r, item, fontId, scaleF, life)
        elseif item.defId == "big_bomb" then
            ItemSystem._DrawBigBomb(vg, cx, cy, r, item, fontId, scaleF, life)
        elseif item.defId == "spinning_plank" then
            ItemSystem._DrawSpinningPlank(vg, cx, cy, r, item, fontId, scaleF)
        elseif item.defId == "landmine" then
            ItemSystem._DrawLandmine(vg, cx, cy, r, item, fontId, scaleF)
        elseif item.defId == "shrapnel_mine" then
            ItemSystem._DrawShrapnelMine(vg, cx, cy, r, item, fontId, scaleF)
        elseif item.defId == "freeze" then
            ItemSystem._DrawFreeze(vg, cx, cy, r, item, scaleF)
        end
    end

    -- 绘制弹幕
    for _, p in ipairs(projectiles_) do
        local px, py = arenaX + p.x * scaleF, arenaY + p.y * scaleF
        local pr = p.radius * scaleF
        local fade = 1.0 - p.elapsed / p.life
        local alpha = math.floor(220 * fade)
        nvgBeginPath(vg); nvgCircle(vg, px, py, pr)
        nvgFillColor(vg, nvgRGBA(255, 160, 50, alpha)); nvgFill(vg)
        -- 拖尾
        nvgBeginPath(vg); nvgCircle(vg, px, py, pr * 1.5)
        nvgFillColor(vg, nvgRGBA(255, 100, 20, math.floor(alpha * 0.3))); nvgFill(vg)
    end
end

--- 绘制冻结覆盖效果（在球上方）
function ItemSystem.DrawFreezeOverlay(vg, ball, bx, by, ballR, scaleF)
    if not ItemSystem.IsFrozen(ball) then return end
    scaleF = scaleF or 1.0
    local alpha = math.floor(160 * math.min(1.0, ball.frozenTimer / 1.0))
    -- 冰蓝色覆盖圈
    nvgBeginPath(vg); nvgCircle(vg, bx, by, ballR * 1.2)
    nvgFillColor(vg, nvgRGBA(100, 200, 255, math.floor(alpha * 0.3))); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(150, 220, 255, alpha)); nvgStrokeWidth(vg, 2 * scaleF); nvgStroke(vg)
    -- 冰晶效果
    if ball.frozenImmobile then
        -- 完全冻结：显示冰晶
        local t = (ball.frozenTimer or 0) * 2
        for a = 0, 5 do
            local angle = a * math.pi / 3 + t * 0.2
            local len = ballR * 0.6
            nvgBeginPath(vg)
            nvgMoveTo(vg, bx, by)
            nvgLineTo(vg, bx + math.cos(angle) * len, by + math.sin(angle) * len)
            nvgStrokeColor(vg, nvgRGBA(180, 230, 255, alpha))
            nvgStrokeWidth(vg, 1.5 * scaleF); nvgStroke(vg)
        end
    end
end

-- ============================================================================
-- Individual Draw Functions
-- ============================================================================

function ItemSystem._DrawSpiderWeb(vg, cx, cy, r, item, fontId, scaleF, life)
    local alpha = math.floor(160 * math.min(1, life * 3))
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
    nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, r * 0.2, r,
        nvgRGBA(200, 200, 200, math.floor(alpha * 0.3)),
        nvgRGBA(200, 200, 200, 0)))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(220, 220, 220, alpha))
    nvgStrokeWidth(vg, 1)
    for a = 0, 5 do
        local angle = a * math.pi / 3
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx, cy)
        nvgLineTo(vg, cx + math.cos(angle) * r, cy + math.sin(angle) * r)
        nvgStroke(vg)
    end
    for ri = 1, 3 do
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, r * ri / 3)
        nvgStrokeColor(vg, nvgRGBA(220, 220, 220, math.floor(alpha * 0.6)))
        nvgStrokeWidth(vg, 0.8); nvgStroke(vg)
    end
    if item.hp > 0 and fontId >= 0 then
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 14 * scaleF)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgText(vg, cx, cy, "🕸️", nil)
    end
end

function ItemSystem._DrawThornyStake(vg, cx, cy, r, item, fontId, scaleF, life)
    local alpha = math.floor(200 * math.min(1, life * 3))
    local spikeCount = 10
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
    nvgFillColor(vg, nvgRGBA(100, 60, 30, math.floor(alpha * 0.6))); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(180, 120, 60, alpha)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    for s = 0, spikeCount - 1 do
        local angle = s * 2 * math.pi / spikeCount + item.elapsed * 0.5
        local innerR = r * 0.7
        local outerR = r * 1.3
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx + math.cos(angle - 0.15) * innerR, cy + math.sin(angle - 0.15) * innerR)
        nvgLineTo(vg, cx + math.cos(angle) * outerR, cy + math.sin(angle) * outerR)
        nvgLineTo(vg, cx + math.cos(angle + 0.15) * innerR, cy + math.sin(angle + 0.15) * innerR)
        nvgFillColor(vg, nvgRGBA(160, 100, 40, alpha)); nvgFill(vg)
    end
    if fontId >= 0 then
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 12 * scaleF)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, alpha))
        nvgText(vg, cx, cy, tostring(item.hp), nil)
    end
end

function ItemSystem._DrawBlackHole(vg, cx, cy, r, item, fontId, scaleF, life)
    local alpha = math.floor(220 * math.min(1, life * 3))
    local pulse = 1.0 + 0.08 * math.sin(item.elapsed * 4)
    local pr = r * pulse
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, pr)
    nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, pr * 0.1, pr,
        nvgRGBA(80, 0, 160, alpha), nvgRGBA(20, 0, 60, 0)))
    nvgFill(vg)
    nvgStrokeWidth(vg, 2)
    for a = 0, 3 do
        local baseAngle = a * math.pi / 2 + item.elapsed * 3
        nvgBeginPath(vg)
        nvgArc(vg, cx, cy, pr * 0.5, baseAngle, baseAngle + math.pi * 0.6, NVG_CW)
        nvgStrokeColor(vg, nvgRGBA(160, 80, 255, math.floor(alpha * 0.6)))
        nvgStroke(vg)
    end
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, pr * 0.15)
    nvgFillColor(vg, nvgRGBA(0, 0, 0, alpha)); nvgFill(vg)
    if item.duration < 900 then
        local pct = 1 - item.elapsed / item.duration
        nvgBeginPath(vg)
        nvgArc(vg, cx, cy, pr * 0.75, -math.pi / 2, -math.pi / 2 + pct * 2 * math.pi, NVG_CW)
        nvgStrokeColor(vg, nvgRGBA(200, 120, 255, math.floor(alpha * 0.5)))
        nvgStrokeWidth(vg, 2); nvgStroke(vg)
    end
end

function ItemSystem._DrawBigBomb(vg, cx, cy, r, item, fontId, scaleF, life)
    local fuseTime = item.fuseTime or 3.0
    local remaining = fuseTime - item.elapsed
    if remaining > 0 then
        local urgency = 1.0 - remaining / fuseTime
        local pulse = 1.0 + 0.15 * urgency * math.sin(item.elapsed * (8 + urgency * 12))
        local bombR = r * 0.35 * pulse
        local bAlpha = 220
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, bombR)
        nvgFillColor(vg, nvgRGBA(50, 50, 50, bAlpha)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(80, 80, 80, bAlpha)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
        local sparkAlpha = math.floor(200 + 55 * math.sin(item.elapsed * 20))
        nvgBeginPath(vg); nvgCircle(vg, cx, cy - bombR - 4 * scaleF, 3 * scaleF)
        nvgFillColor(vg, nvgRGBA(255, math.floor(180 * (1 - urgency)), 0, sparkAlpha)); nvgFill(vg)
        local rangeAlpha = math.floor(30 + 30 * urgency * math.sin(item.elapsed * 6))
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, r)
        nvgStrokeColor(vg, nvgRGBA(255, 100, 50, rangeAlpha)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
        if fontId >= 0 then
            nvgFontFaceId(vg, fontId)
            nvgFontSize(vg, 16 * scaleF)
            nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
            nvgFillColor(vg, nvgRGBA(255, 255, 255, 220))
            nvgText(vg, cx, cy, string.format("%.0f", math.ceil(remaining)), nil)
        end
    else
        local explodeT = item.elapsed - fuseTime
        if explodeT < 0.5 then
            local fade = 1.0 - explodeT / 0.5
            local expR = r * (1.0 + explodeT * 2)
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, expR)
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, expR * 0.1, expR,
                nvgRGBA(255, 200, 50, math.floor(200 * fade)),
                nvgRGBA(255, 80, 0, 0)))
            nvgFill(vg)
        end
    end
end

function ItemSystem._DrawSpinningPlank(vg, cx, cy, r, item, fontId, scaleF)
    local alpha = 220
    local halfLen = r
    local halfW = (item.plankWidth or 12) * scaleF * 0.5
    local cosA = math.cos(item.angle or 0)
    local sinA = math.sin(item.angle or 0)
    local function rotPt(px, py)
        return cx + px * cosA - py * sinA, cy + px * sinA + py * cosA
    end
    local x1, y1 = rotPt(-halfLen, -halfW)
    local x2, y2 = rotPt(halfLen, -halfW)
    local x3, y3 = rotPt(halfLen, halfW)
    local x4, y4 = rotPt(-halfLen, halfW)
    nvgBeginPath(vg)
    nvgMoveTo(vg, x1, y1); nvgLineTo(vg, x2, y2)
    nvgLineTo(vg, x3, y3); nvgLineTo(vg, x4, y4)
    nvgClosePath(vg)
    nvgFillColor(vg, nvgRGBA(139, 90, 43, alpha)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(100, 65, 25, alpha)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    -- 中心转轴
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, 4 * scaleF)
    nvgFillColor(vg, nvgRGBA(80, 80, 80, alpha)); nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(120, 120, 120, alpha)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    -- 木板纹理
    for li = -2, 2 do
        local offsetY = li * halfW * 0.35
        local lx1, ly1 = rotPt(-halfLen * 0.85, offsetY)
        local lx2, ly2 = rotPt(halfLen * 0.85, offsetY)
        nvgBeginPath(vg); nvgMoveTo(vg, lx1, ly1); nvgLineTo(vg, lx2, ly2)
        nvgStrokeColor(vg, nvgRGBA(115, 70, 30, math.floor(alpha * 0.4)))
        nvgStrokeWidth(vg, 0.8); nvgStroke(vg)
    end
    -- 耐久度显示
    if fontId >= 0 and item.hp then
        nvgFontFaceId(vg, fontId)
        nvgFontSize(vg, 10 * scaleF)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(255, 255, 255, 200))
        nvgText(vg, cx, cy, tostring(item.hp), nil)
    end
end

function ItemSystem._DrawLandmine(vg, cx, cy, r, item, fontId, scaleF)
    if not item.armed then
        local armPct = item.elapsed / (item.armTime or 1)
        local alpha = math.floor(180 * armPct)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, 8 * scaleF)
        nvgFillColor(vg, nvgRGBA(100, 100, 100, alpha)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(150, 150, 150, alpha)); nvgStrokeWidth(vg, 1); nvgStroke(vg)
    elseif item.exploded and item.explodeTime then
        -- 爆炸特效（0.5秒动画）
        local explodeT = item.elapsed - item.explodeTime
        if explodeT < 0.5 then
            local fade = 1.0 - explodeT / 0.5
            -- 扩展的火球
            local expR = r * (0.3 + explodeT * 4)
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, expR)
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, expR * 0.1, expR,
                nvgRGBA(255, 220, 80, math.floor(220 * fade)),
                nvgRGBA(255, 60, 0, 0)))
            nvgFill(vg)
            -- 内核白光
            local coreR = expR * 0.4 * fade
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, coreR)
            nvgFillColor(vg, nvgRGBA(255, 255, 220, math.floor(255 * fade))); nvgFill(vg)
            -- 冲击波环
            local ringR = r * (0.5 + explodeT * 6)
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, ringR)
            nvgStrokeColor(vg, nvgRGBA(255, 180, 50, math.floor(120 * fade)))
            nvgStrokeWidth(vg, 3 * fade); nvgStroke(vg)
        end
    elseif not item.exploded then
        local blink = math.sin(item.elapsed * 4) > 0.8
        local alpha = blink and 80 or 30
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, item.triggerRadius * scaleF)
        nvgFillColor(vg, nvgRGBA(255, 50, 50, math.floor(alpha * 0.2))); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, 7 * scaleF)
        nvgFillColor(vg, nvgRGBA(80, 80, 80, alpha + 40)); nvgFill(vg)
        if blink then
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, 2.5 * scaleF)
            nvgFillColor(vg, nvgRGBA(255, 0, 0, 160)); nvgFill(vg)
        end
    end
end

function ItemSystem._DrawShrapnelMine(vg, cx, cy, r, item, fontId, scaleF)
    if not item.armed then
        -- 启动中
        local armPct = item.elapsed / (item.armTime or 1)
        local alpha = math.floor(180 * armPct)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, 9 * scaleF)
        nvgFillColor(vg, nvgRGBA(120, 80, 40, alpha)); nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(180, 120, 60, alpha)); nvgStrokeWidth(vg, 1.5); nvgStroke(vg)
    elseif item.exploded and item.explodeTime then
        -- 爆炸特效（0.5秒动画，橙色调）
        local explodeT = item.elapsed - item.explodeTime
        if explodeT < 0.5 then
            local fade = 1.0 - explodeT / 0.5
            -- 扩展的火球（橙色）
            local expR = r * (0.3 + explodeT * 4)
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, expR)
            nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, expR * 0.1, expR,
                nvgRGBA(255, 180, 50, math.floor(220 * fade)),
                nvgRGBA(255, 80, 0, 0)))
            nvgFill(vg)
            -- 内核白光
            local coreR = expR * 0.35 * fade
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, coreR)
            nvgFillColor(vg, nvgRGBA(255, 240, 200, math.floor(255 * fade))); nvgFill(vg)
            -- 冲击波环
            local ringR = r * (0.5 + explodeT * 6)
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, ringR)
            nvgStrokeColor(vg, nvgRGBA(255, 140, 30, math.floor(120 * fade)))
            nvgStrokeWidth(vg, 3 * fade); nvgStroke(vg)
            -- 破片飞散火花
            for s = 0, 7 do
                local angle = s * math.pi / 4 + explodeT * 2
                local sr = expR * (0.8 + explodeT * 2)
                local sparkAlpha = math.floor(180 * fade)
                nvgBeginPath(vg); nvgCircle(vg, cx + math.cos(angle) * sr, cy + math.sin(angle) * sr, 2 * scaleF * fade)
                nvgFillColor(vg, nvgRGBA(255, 200, 80, sparkAlpha)); nvgFill(vg)
            end
        end
    elseif not item.exploded then
        -- 已启动
        local blink = math.sin(item.elapsed * 5) > 0.7
        local alpha = blink and 90 or 35
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, item.triggerRadius * scaleF)
        nvgFillColor(vg, nvgRGBA(255, 120, 30, math.floor(alpha * 0.2))); nvgFill(vg)
        nvgBeginPath(vg); nvgCircle(vg, cx, cy, 8 * scaleF)
        nvgFillColor(vg, nvgRGBA(100, 70, 30, alpha + 50)); nvgFill(vg)
        -- 橙色指示灯
        if blink then
            nvgBeginPath(vg); nvgCircle(vg, cx, cy, 2.5 * scaleF)
            nvgFillColor(vg, nvgRGBA(255, 150, 0, 180)); nvgFill(vg)
        end
        -- 小碎片标记
        for s = 0, 5 do
            local angle = s * math.pi / 3 + item.elapsed * 0.5
            local sr = 12 * scaleF
            nvgBeginPath(vg); nvgCircle(vg, cx + math.cos(angle) * sr, cy + math.sin(angle) * sr, 1.5 * scaleF)
            nvgFillColor(vg, nvgRGBA(255, 180, 80, math.floor(alpha * 0.6))); nvgFill(vg)
        end
    end
end

function ItemSystem._DrawFreeze(vg, cx, cy, r, item, scaleF)
    -- 冻结放置后的瞬时特效
    local fade = 1.0 - item.elapsed / item.duration
    if fade <= 0 then return end
    local alpha = math.floor(200 * fade)
    -- 扩展的冰蓝色圆环
    local expandR = r * (1.0 + item.elapsed / item.duration * 0.5)
    nvgBeginPath(vg); nvgCircle(vg, cx, cy, expandR)
    nvgFillPaint(vg, nvgRadialGradient(vg, cx, cy, expandR * 0.1, expandR,
        nvgRGBA(100, 200, 255, math.floor(alpha * 0.4)),
        nvgRGBA(100, 200, 255, 0)))
    nvgFill(vg)
    nvgStrokeColor(vg, nvgRGBA(150, 220, 255, alpha)); nvgStrokeWidth(vg, 2); nvgStroke(vg)
    -- ❄️ 图标
    if item.elapsed < 0.4 then
        nvgFontSize(vg, 20 * scaleF)
        nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg, nvgRGBA(200, 240, 255, alpha))
        nvgText(vg, cx, cy, "❄️", nil)
    end
end

-- ============================================================================
-- Accessors
-- ============================================================================

function ItemSystem.GetPlaced()
    return placed_
end

function ItemSystem.GetProjectiles()
    return projectiles_
end

function ItemSystem.Clear()
    placed_ = {}
    projectiles_ = {}
    cooldowns_ = {}
    for i = 1, SLOT_COUNT do cooldowns_[i] = 0 end
end

return ItemSystem
