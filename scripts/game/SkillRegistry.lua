-- ============================================================================
-- SkillRegistry.lua - Data-driven Skill Definitions (按设计图重制)
-- 基础能力 (HP 100-50): 水球、火球、水蛭、脉冲波、分裂泡、激光
-- 强化能力 (HP 50-30):  水柱、烈焰、血蝙蝠
-- ============================================================================

local SkillRegistry = {}

---@class SkillDef
---@field id string
---@field name string
---@field tier string          -- "normal" | "enhanced" | "ultimate"
---@field description string
---@field cooldown number
---@field projSpeed number
---@field projRadius number
---@field damage number
---@field knockbackLevel number -- 反冲力 0-3
---@field impactLevel number    -- 冲击力 0-3
---@field projType string
---@field color table          -- {r, g, b}
---@field params table         -- type-specific parameters

local skills = {
    -- ===================== 基础能力 Normal Tier (HP 100-50) =====================

    -- 水球: 伤害6, CD5s, 反冲力1, 冲击力1
    -- 碰壁→8颗水滴(伤害2), 命中敌人→减速
    {
        id          = "water_ball",
        name        = "水球",
        tier        = "normal",
        icon        = "image/skill_water_ball_20260428090257.png",
        description = "水球碰壁溅射8颗水滴，命中敌人造成减速",
        cooldown    = 5.0,
        projSpeed   = 500,
        projRadius  = 10,
        damage      = 6,
        knockbackLevel = 1,
        impactLevel = 1,
        projType    = "wall_splash",
        color       = { r = 80, g = 180, b = 255 },
        params      = {
            knockback    = 150,  -- level 1
            -- 碰壁溅射
            splashCount  = 8,
            splashDamage = 2,
            splashSpeed  = 250,
            splashRadius = 4,
            splashSpread = math.pi, -- 半圆溅射
            -- 命中减速
            slowFactor   = 0.5,
            slowDuration = 2.0,
        },
    },

    -- 火球: 伤害4, CD5s, 反冲力2, 冲击力2
    -- 命中敌人→+4DOT(1/秒), 碰壁→冲击波圆圈(3伤害)
    {
        id          = "fire_ball",
        name        = "火球",
        tier        = "normal",
        icon        = "image/skill_fire_ball_20260428090327.png",
        description = "命中敌人造成持续灼伤，碰壁产生火焰冲击波",
        cooldown    = 5.0,
        projSpeed   = 550,
        projRadius  = 9,
        damage      = 4,
        knockbackLevel = 2,
        impactLevel = 2,
        projType    = "fire_shot",
        color       = { r = 255, g = 120, b = 30 },
        params      = {
            knockback    = 250,  -- level 2
            -- 命中DOT
            dotTotal     = 4,
            dotDuration  = 4,  -- 1/秒，持续4秒
            -- 碰壁冲击波
            wallAoeDamage   = 3,
            wallAoeRadius   = 80,
            wallAoeSpeed    = 300,
        },
    },

    -- 水蛭: 伤害0, CD6s, 反冲力0, 冲击力0
    -- 0.5/s吸血, 6s持续, 轻微追踪
    {
        id          = "leech",
        name        = "水蛭",
        tier        = "normal",
        icon        = "image/skill_leech_20260428090258.png",
        description = "轻微追踪的水蛭，持续吸取生命值",
        cooldown    = 6.0,
        projSpeed   = 280,
        projRadius  = 6,
        damage      = 0,
        knockbackLevel = 0,
        impactLevel = 0,
        projType    = "leech",
        color       = { r = 50, g = 200, b = 100 },
        params      = {
            knockback    = 0,
            turnRate     = 0.8,     -- 轻微追踪
            dotTotal     = 3,       -- 0.5/s * 6s = 3总伤
            dotDuration  = 6,
            healTotal    = 3,       -- 吸血=伤害量
            lifetime     = 8,       -- 超时消失
        },
    },

    -- 分裂泡: 伤害3, CD10s, 反冲力1, 冲击力3
    -- 极慢速, 5s持续, 持续膨胀, 到期爆炸造成3点范围伤害
    {
        id          = "split_bubble",
        name        = "分裂泡",
        tier        = "normal",
        icon        = "image/skill_split_bubble_20260428090252.png",
        description = "漂浮气泡持续膨胀，到期爆炸造成范围伤害",
        cooldown    = 10.0,
        projSpeed   = 80,     -- 极慢漂浮
        projRadius  = 14,     -- 初始较小
        damage      = 3,      -- 爆炸伤害
        knockbackLevel = 1,
        impactLevel = 3,
        projType    = "bubble",
        color       = { r = 180, g = 255, b = 220 },
        params      = {
            knockback     = 350,  -- 冲击力3
            lifetime      = 5.0,
            growthFactor  = 3.0,  -- 最终半径 = 初始 * growthFactor
            explodeRadius = 80,   -- 爆炸范围
        },
    },

    -- 激光: 伤害2, CD无, 反冲力0, 冲击力0
    -- 碰壁留下发射器, 两两配对连激光, 最多4个发射器
    {
        id          = "laser",
        name        = "激光",
        tier        = "normal",
        icon        = "image/skill_laser_20260428091042.png",
        description = "碰壁留下发射器，配对连接激光束",
        cooldown    = 3.0,    -- 无CD → 用短CD模拟
        projSpeed   = 800,
        projRadius  = 5,
        damage      = 2,      -- 激光线DPS
        knockbackLevel = 0,
        impactLevel = 0,
        projType    = "laser_emitter",
        color       = { r = 255, g = 50, b = 50 },
        params      = {
            knockback     = 0,
            maxEmitters   = 4,
            emitterLife   = 10,     -- 发射器持续时间
            laserDps      = 2,      -- 激光每秒伤害
            laserWidth    = 4,
        },
    },

    -- ===================== 强化能力 Enhanced Tier (HP 50-30) =====================

    -- 水柱: 伤害10, CD8s, 反冲力2, 冲击力3
    -- 碰壁→8颗水滴(3伤害), 水滴再碰壁→4颗微水滴(1伤害)
    -- 命中敌人→巨大击退+撞墙10伤害+2s眩晕
    {
        id          = "water_pillar",
        name        = "水柱",
        tier        = "enhanced",
        icon        = "image/skill_water_pillar_20260428091105.png",
        description = "超强水柱，碰壁二级溅射，命中造成撞墙重伤+眩晕",
        cooldown    = 8.0,
        projSpeed   = 700,
        projRadius  = 12,
        damage      = 10,
        knockbackLevel = 2,
        impactLevel = 3,
        projType    = "water_pillar",
        color       = { r = 30, g = 120, b = 255 },
        params      = {
            knockback       = 600,    -- level 2 但特大
            -- 碰壁一级溅射
            splashCount     = 8,
            splashDamage    = 3,
            splashSpeed     = 300,
            splashRadius    = 5,
            -- 二级溅射(水滴碰壁)
            splash2Count    = 4,
            splash2Damage   = 1,
            splash2Speed    = 200,
            splash2Radius   = 3,
            -- 命中效果
            wallSlamDamage  = 10,
            knockbackWindow = 1.0,
            stunDuration    = 2.0,
        },
    },

    -- 烈焰: 伤害10, CD10s, 反冲力2, 冲击力3
    -- 轻微追踪, 命中敌人→+15DOT(5/秒), 碰壁→火圈10s, 火圈内减速+4DOT
    {
        id          = "inferno",
        name        = "烈焰",
        tier        = "enhanced",
        icon        = "image/skill_inferno_20260428091140.png",
        description = "追踪烈焰，命中持续灼伤，碰壁留火圈",
        cooldown    = 10.0,
        projSpeed   = 400,
        projRadius  = 14,
        damage      = 10,
        knockbackLevel = 2,
        impactLevel = 3,
        projType    = "inferno",
        color       = { r = 255, g = 60, b = 20 },
        params      = {
            knockback     = 350,
            turnRate      = 0.6,       -- 轻微追踪
            -- 命中DOT
            dotTotal      = 15,
            dotDuration   = 3,         -- 5/秒 * 3秒 = 15
            -- 碰壁火圈
            fireZoneRadius   = 60,
            fireZoneDuration = 10,
            fireZoneDps      = 4,      -- 火圈内4DOT
            fireZoneSlowFactor = 0.4,
        },
    },

    -- 血蝙蝠: 伤害0, CD10s, 反冲力0, 冲击力0
    -- 5个蝙蝠弹, 1/s吸血, 10s持续, 轻微追踪
    {
        id          = "blood_bat",
        name        = "血蝙蝠",
        tier        = "enhanced",
        icon        = "image/skill_blood_bat_20260428091204.png",
        description = "释放5只血蝙蝠，持续吸血恢复自身",
        cooldown    = 10.0,
        projSpeed   = 300,
        projRadius  = 5,
        damage      = 0,
        knockbackLevel = 0,
        impactLevel = 0,
        projType    = "bat_swarm",
        color       = { r = 180, g = 30, b = 60 },
        params      = {
            knockback    = 0,
            count        = 5,
            spreadAngle  = 0.8,
            turnRate     = 0.8,       -- 轻微追踪
            dotTotal     = 10,        -- 1/s * 10s = 10
            dotDuration  = 10,
            healTotal    = 10,        -- 吸血=伤害
            lifetime     = 12,
        },
    },
}

-- Build lookup tables
local byId = {}
local byTier = { normal = {}, enhanced = {}, ultimate = {} }

for _, skill in ipairs(skills) do
    byId[skill.id] = skill
    if byTier[skill.tier] then
        table.insert(byTier[skill.tier], skill)
    end
end

-- ============================================================================
-- Public API
-- ============================================================================

---@param id string
---@return SkillDef|nil
function SkillRegistry.Get(id)
    return byId[id]
end

---@param tier string  "normal"|"enhanced"|"ultimate"
---@return SkillDef[]
function SkillRegistry.GetByTier(tier)
    return byTier[tier] or {}
end

---@return SkillDef[]
function SkillRegistry.GetAll()
    return skills
end

---@param tier string
---@return table[] options with {value, label}
function SkillRegistry.GetDropdownOptions(tier)
    local opts = { { value = "", label = "无" } }
    for _, skill in ipairs(byTier[tier] or {}) do
        table.insert(opts, { value = skill.id, label = skill.name .. " - " .. skill.description })
    end
    return opts
end

return SkillRegistry
