-- ============================================================================
-- ShopConfig.lua - 商店商品目录（静态配置）
-- 定义所有可购买商品：球球皮肤（颜色覆盖）和擂台道具（解锁）
-- ============================================================================

local ShopConfig = {}

-- ============================================================================
-- 球球皮肤（颜色覆盖）
-- 购买后可在养殖页面给球球应用该颜色，覆盖等级默认颜色
-- ============================================================================

-- Grade names: 1=白, 2=绿, 3=蓝, 4=紫, 5=橙, 6=红, 7=彩虹(不可换色)
ShopConfig.GRADE_NAMES = {
    [1] = "白色",
    [2] = "绿色",
    [3] = "蓝色",
    [4] = "紫色",
    [5] = "橙色",
    [6] = "红色",
    [7] = "彩虹",
}

ShopConfig.SKINS = {
    {
        id    = "skin_sakura",
        name  = "樱花粉",
        price = 30,
        targetGrade = 1,  -- 只改变白色等级球球
        color = { r = 255, g = 150, b = 180 },
        desc  = "柔和的樱花粉色",
    },
    {
        id    = "skin_ocean",
        name  = "深海蓝",
        price = 50,
        targetGrade = 2,  -- 只改变绿色等级球球
        color = { r = 30, g = 120, b = 255 },
        desc  = "神秘的深海蓝色",
    },
    {
        id    = "skin_sunset",
        name  = "落日橙",
        price = 80,
        targetGrade = 3,  -- 只改变蓝色等级球球
        color = { r = 255, g = 100, b = 30 },
        desc  = "温暖的落日橙色",
    },
    {
        id    = "skin_emerald",
        name  = "翡翠绿",
        price = 120,
        targetGrade = 4,  -- 只改变紫色等级球球
        color = { r = 20, g = 200, b = 120 },
        desc  = "高贵的翡翠绿色",
    },
    {
        id    = "skin_royal",
        name  = "皇家紫",
        price = 200,
        targetGrade = 5,  -- 只改变橙色等级球球
        color = { r = 140, g = 50, b = 220 },
        desc  = "尊贵的皇家紫色",
    },
    {
        id    = "skin_golden",
        name  = "黄金色",
        price = 300,
        targetGrade = 6,  -- 只改变红色等级球球
        color = { r = 255, g = 215, b = 0 },
        desc  = "闪耀的黄金色",
    },
}

-- ============================================================================
-- 擂台道具（解锁制）
-- 购买后永久解锁，可在擂台赛中使用
-- ============================================================================

ShopConfig.ITEMS = {
    {
        id    = "spider_web",
        name  = "蜘蛛网",
        emoji = "🕸️",
        price = 30,
        desc  = "降低范围内敌方速度",
    },
    {
        id    = "thorny_stake",
        name  = "带刺木桩",
        emoji = "🌵",
        price = 50,
        desc  = "碰撞反弹并造成伤害",
    },
    {
        id    = "landmine",
        name  = "地雷",
        emoji = "💥",
        price = 80,
        desc  = "踩中爆炸+范围冲击",
    },
    {
        id    = "spinning_plank",
        name  = "旋转木板",
        emoji = "🪵",
        price = 120,
        desc  = "旋转扫荡，5次碰撞后损坏",
    },
    {
        id    = "micro_blackhole",
        name  = "黑洞",
        emoji = "🌀",
        price = 180,
        desc  = "吸引场内所有球体",
    },
    {
        id    = "big_bomb",
        name  = "大炸弹",
        emoji = "💣",
        price = 220,
        desc  = "延迟3秒爆炸，强力推开范围内球体",
    },
    {
        id    = "freeze",
        name  = "冻结",
        emoji = "❄️",
        price = 250,
        desc  = "冻结范围内球球",
    },
    {
        id    = "shrapnel_mine",
        name  = "破片地雷",
        emoji = "🧨",
        price = 300,
        desc  = "爆炸+弹幕+范围冲击",
    },
}

-- ============================================================================
-- 快速查找
-- ============================================================================

--- 按 ID 查找皮肤配置
function ShopConfig.GetSkin(skinId)
    for _, skin in ipairs(ShopConfig.SKINS) do
        if skin.id == skinId then return skin end
    end
    return nil
end

--- 按 ID 查找道具配置
function ShopConfig.GetItem(itemId)
    for _, item in ipairs(ShopConfig.ITEMS) do
        if item.id == itemId then return item end
    end
    return nil
end

--- 按 ID 查找任意商品（皮肤或道具），返回 config, category
function ShopConfig.GetProduct(productId)
    local skin = ShopConfig.GetSkin(productId)
    if skin then return skin, "skin" end
    local item = ShopConfig.GetItem(productId)
    if item then return item, "item" end
    return nil, nil
end

return ShopConfig
