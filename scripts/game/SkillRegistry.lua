-- ============================================================================
-- SkillRegistry.lua - Data-driven Skill Definitions (按设计图重制)
-- 基础能力 (HP 100-50): 水球、火球、水蛭、脉冲波、分裂泡
-- 强化能力 (HP 50-30):  水柱、烈焰、血蝙蝠
-- 终结能力 (HP 30-0):   水龙、陨石
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

    -- (激光技能已移除)

    -- 冰刺: 伤害5, CD5s, 反冲力1, 冲击力2
    -- 碰壁→6颗冰碎片(伤害2), 命中敌人→70%减速3s
    {
        id          = "ice_spike",
        name        = "冰刺",
        tier        = "normal",
        icon        = "image/skill_ice_spike_20260520073439.png",
        description = "冰刺碰壁溅射冰碎片，命中敌人造成强力减速",
        cooldown    = 5.0,
        projSpeed   = 520,
        projRadius  = 9,
        damage      = 5,
        knockbackLevel = 1,
        impactLevel = 2,
        projType    = "wall_splash",
        color       = { r = 140, g = 220, b = 255 },
        params      = {
            knockback    = 180,
            splashCount  = 6,
            splashDamage = 2,
            splashSpeed  = 260,
            splashRadius = 4,
            splashSpread = math.pi,
            slowFactor   = 0.3,
            slowDuration = 3.0,
        },
    },

    -- 毒雾: 伤害0, CD8s, 反冲力0, 冲击力1
    -- 极慢漂浮, 6s持续, 到期爆炸→8段DOT(2/s·4s)
    {
        id          = "poison_mist",
        name        = "毒雾",
        tier        = "normal",
        icon        = "image/skill_poison_mist_20260520073128.png",
        description = "漂浮毒雾气泡，到期爆炸释放剧毒",
        cooldown    = 8.0,
        projSpeed   = 70,
        projRadius  = 15,
        damage      = 0,
        knockbackLevel = 0,
        impactLevel = 1,
        projType    = "bubble",
        color       = { r = 80, g = 180, b = 50 },
        params      = {
            knockback     = 100,
            lifetime      = 6.0,
            growthFactor  = 2.5,
            explodeRadius = 90,
        },
    },

    -- 电弧: 伤害7, CD6s, 反冲力2, 冲击力2
    -- 命中敌人→6DOT(2/s·3s), 碰壁→冲击波(4伤害)
    {
        id          = "arc_bolt",
        name        = "电弧",
        tier        = "normal",
        icon        = "image/skill_arc_bolt_20260520073125.png",
        description = "高速电弧，命中持续麻痹，碰壁放出电击波",
        cooldown    = 6.0,
        projSpeed   = 600,
        projRadius  = 8,
        damage      = 7,
        knockbackLevel = 2,
        impactLevel = 2,
        projType    = "fire_shot",
        color       = { r = 180, g = 120, b = 255 },
        params      = {
            knockback    = 280,
            dotTotal     = 6,
            dotDuration  = 3,
            wallAoeDamage   = 4,
            wallAoeRadius   = 85,
            wallAoeSpeed    = 320,
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
            maxBounces      = 2,      -- 弹射2次后消亡
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

    -- 冰柱: 伤害8, CD8s, 反冲力2, 冲击力3
    -- 碰壁→6颗冰滴(3伤害)+二级溅射, 命中→撞墙8伤害+3s眩晕
    {
        id          = "ice_pillar",
        name        = "冰柱",
        tier        = "enhanced",
        icon        = "image/skill_ice_pillar_20260520073125.png",
        description = "巨型冰柱碰壁二级溅射，命中造成冰冻撞墙+眩晕",
        cooldown    = 8.0,
        projSpeed   = 680,
        projRadius  = 12,
        damage      = 8,
        knockbackLevel = 2,
        impactLevel = 3,
        projType    = "water_pillar",
        color       = { r = 100, g = 200, b = 255 },
        params      = {
            knockback       = 550,
            maxBounces      = 2,
            splashCount     = 6,
            splashDamage    = 3,
            splashSpeed     = 280,
            splashRadius    = 5,
            splash2Count    = 3,
            splash2Damage   = 1,
            splash2Speed    = 180,
            splash2Radius   = 3,
            wallSlamDamage  = 8,
            knockbackWindow = 1.0,
            stunDuration    = 3.0,
        },
    },

    -- 雷蝠: 伤害0, CD10s, 反冲力0, 冲击力0
    -- 4个雷蝠弹, 追踪吸血, 12DOT/12s, 治疗12
    {
        id          = "thunder_bat",
        name        = "雷蝠",
        tier        = "enhanced",
        icon        = "image/skill_thunder_bat_20260520073127.png",
        description = "释放4只雷蝠，雷电追踪并吸取生命",
        cooldown    = 10.0,
        projSpeed   = 320,
        projRadius  = 5,
        damage      = 0,
        knockbackLevel = 0,
        impactLevel = 0,
        projType    = "bat_swarm",
        color       = { r = 200, g = 160, b = 255 },
        params      = {
            knockback    = 0,
            count        = 4,
            spreadAngle  = 0.7,
            turnRate     = 0.9,
            dotTotal     = 12,
            dotDuration  = 12,
            healTotal    = 12,
            lifetime     = 14,
        },
    },

    -- 毒焰: 伤害12, CD10s, 反冲力2, 冲击力3
    -- 追踪, 命中→20DOT(5/s·4s), 碰壁→毒圈12s,5DPS
    {
        id          = "venom_flame",
        name        = "毒焰",
        tier        = "enhanced",
        icon        = "image/skill_venom_flame_20260520073123.png",
        description = "追踪毒焰，命中剧烈中毒，碰壁留毒圈",
        cooldown    = 10.0,
        projSpeed   = 380,
        projRadius  = 14,
        damage      = 12,
        knockbackLevel = 2,
        impactLevel = 3,
        projType    = "inferno",
        color       = { r = 120, g = 220, b = 50 },
        params      = {
            knockback     = 380,
            turnRate      = 0.7,
            dotTotal      = 20,
            dotDuration   = 4,
            fireZoneRadius   = 65,
            fireZoneDuration = 12,
            fireZoneDps      = 5,
            fireZoneSlowFactor = 0.35,
        },
    },

    -- ===================== 终结能力 Ultimate Tier (HP 30-0) =====================

    -- 水龙: 伤害10, CD10s, 反冲力2, 冲击力3
    -- 碰壁→反弹进发10颗伤害5的小水滴, 最多碰壁5次才消失
    -- 命中敌人→巨大冲击力击退, 撞墙再受10伤+2s眩晕
    {
        id          = "water_dragon",
        name        = "水龙",
        tier        = "ultimate",
        icon        = "image/skill_water_dragon_20260430053200.png",
        description = "4颗水球连体飞行，碰壁爆1颗溅射水花，命中强力击退+眩晕",
        cooldown    = 10.0,
        projSpeed   = 500,
        projRadius  = 12,
        damage      = 12,
        knockbackLevel = 3,
        impactLevel = 3,
        projType    = "water_dragon",
        color       = { r = 30, g = 160, b = 255 },
        params      = {
            knockback       = 800,    -- 超强击退
            -- 碰壁溅射 (每次碰壁炸1颗水球，产生6颗水滴)
            splashCount     = 6,
            splashDamage    = 4,
            splashSpeed     = 250,
            splashRadius    = 5,
            splashSpread    = math.pi * 1.2,
            -- 4颗水球 → 碰壁3次减球 + 第4次消亡
            maxBounces      = 4,
            waterBallCount  = 4,      -- 初始水球数量
            -- 命中效果: 撞墙伤害 + 眩晕
            wallSlamDamage  = 12,
            knockbackWindow = 1.0,
            stunDuration    = 2.5,
        },
    },

    -- 陨石: 伤害8, CD10s, 反冲力2, 冲击力2
    -- 命中→定格敌人+召唤陨石(5s后落下), 陨石落地5伤害+冲击波3伤害
    -- 碰壁→3个轻微追踪弹, 命中→基础伤害+15DOT(5/秒)
    {
        id          = "meteorite",
        name        = "陨石",
        tier        = "ultimate",
        icon        = "image/skill_meteorite_20260430053200.png",
        description = "命中定格敌人并召唤陨石轰炸，碰壁射出追踪弹",
        cooldown    = 10.0,
        projSpeed   = 500,
        projRadius  = 12,
        damage      = 8,
        knockbackLevel = 2,
        impactLevel = 2,
        projType    = "meteorite",
        color       = { r = 255, g = 100, b = 30 },
        params      = {
            knockback       = 400,
            -- 命中效果: 定格 + 召唤陨石
            stunDuration    = 2.5,       -- 定格时间
            meteorDelay     = 1.5,       -- 陨石延迟落下
            meteorDamage    = 5,         -- 陨石落地伤害
            meteorAoeRadius = 80,        -- 冲击波半径
            meteorAoeDamage = 3,         -- 冲击波伤害
            -- 命中 DOT
            dotTotal        = 15,
            dotDuration     = 3,         -- 5/秒 * 3秒
            -- 碰壁: 3个追踪弹
            wallHomingCount    = 3,
            wallHomingSpeed    = 340,
            wallHomingRadius   = 5,
            wallHomingTurnRate = 1.2,
            wallHomingDamage   = 3,
            wallHomingLife     = 6,
        },
    },
    -- 冰龙: 伤害10, CD10s, 反冲力3, 冲击力3
    -- 碰壁→8颗冰滴(5伤害), 命中→撞墙12伤害+3s冰冻眩晕
    {
        id          = "ice_dragon",
        name        = "冰龙",
        tier        = "ultimate",
        icon        = "image/skill_ice_dragon_20260520073124.png",
        description = "4颗冰球连体飞行，碰壁爆冰花，命中冰冻撞墙+眩晕",
        cooldown    = 10.0,
        projSpeed   = 480,
        projRadius  = 13,
        damage      = 10,
        knockbackLevel = 3,
        impactLevel = 3,
        projType    = "water_dragon",
        color       = { r = 160, g = 230, b = 255 },
        params      = {
            knockback       = 850,
            splashCount     = 8,
            splashDamage    = 5,
            splashSpeed     = 260,
            splashRadius    = 5,
            splashSpread    = math.pi * 1.2,
            maxBounces      = 4,
            waterBallCount  = 4,
            wallSlamDamage  = 12,
            knockbackWindow = 1.0,
            stunDuration    = 3.0,
        },
    },

    -- 雷陨: 伤害10, CD10s, 反冲力2, 冲击力3
    -- 命中→3s眩晕+召唤雷陨(6伤害+冲击波4), 碰壁→4个追踪雷弹(4伤害)
    {
        id          = "thunder_meteor",
        name        = "雷陨",
        tier        = "ultimate",
        icon        = "image/skill_thunder_meteor_20260520073129.png",
        description = "命中定格敌人并召唤雷陨轰炸，碰壁射出追踪雷弹",
        cooldown    = 10.0,
        projSpeed   = 520,
        projRadius  = 12,
        damage      = 10,
        knockbackLevel = 2,
        impactLevel = 3,
        projType    = "meteorite",
        color       = { r = 255, g = 220, b = 100 },
        params      = {
            knockback       = 450,
            stunDuration    = 3.0,
            meteorDelay     = 1.2,
            meteorDamage    = 6,
            meteorAoeRadius = 85,
            meteorAoeDamage = 4,
            dotTotal        = 12,
            dotDuration     = 3,
            wallHomingCount    = 4,
            wallHomingSpeed    = 360,
            wallHomingRadius   = 5,
            wallHomingTurnRate = 1.3,
            wallHomingDamage   = 4,
            wallHomingLife     = 6,
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
