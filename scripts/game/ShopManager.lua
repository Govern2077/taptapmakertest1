-- ============================================================================
-- ShopManager.lua - 商店购买管理（持久化 + 云同步）
-- 管理已购买的皮肤和已解锁的道具，支持本地文件 + clientCloud 同步
-- ============================================================================

local ShopConfig     = require("config.ShopConfig")
local DiamondManager = require("game.DiamondManager")

local ShopManager = {}

-- ============================================================================
-- Constants
-- ============================================================================

local SAVE_FILE  = "shop_purchases.json"
local CLOUD_KEY  = "shop_purchases"

-- ============================================================================
-- State
-- ============================================================================

local purchasedSkins_ = {}   -- set: skinId -> true
local unlockedItems_  = {}   -- set: itemId -> true
local equippedSkin_   = nil  -- currently equipped skin ID (or nil = default level color)
local equippedItems_  = {}   -- array of item IDs equipped for arena (max 3)
local loaded_         = false
local onChange_       = nil   -- optional callback when purchases change

-- ============================================================================
-- Load / Save (local file)
-- ============================================================================

--- @param onDone function|nil  callback() when cloud sync also finishes
function ShopManager.Load(onDone)
    if loaded_ then
        if onDone then onDone() end
        return
    end

    purchasedSkins_ = {}
    unlockedItems_  = {}
    equippedSkin_   = nil
    equippedItems_  = {}

    if fileSystem:FileExists(SAVE_FILE) then
        local file = File(SAVE_FILE, FILE_READ)
        if file:IsOpen() then
            local str = file:ReadString()
            file:Close()
            local ok, data = pcall(cjson.decode, str)
            if ok and type(data) == "table" then
                if type(data.skins) == "table" then
                    for _, id in ipairs(data.skins) do
                        purchasedSkins_[id] = true
                    end
                end
                if type(data.items) == "table" then
                    for _, id in ipairs(data.items) do
                        unlockedItems_[id] = true
                    end
                end
                if type(data.equippedSkin) == "string" then
                    equippedSkin_ = data.equippedSkin
                end
                if type(data.equippedItems) == "table" then
                    equippedItems_ = data.equippedItems
                end
                print(string.format("[ShopManager] Loaded local: %d skins, %d items, %d equipped, skin=%s",
                    ShopManager._CountTable(purchasedSkins_),
                    ShopManager._CountTable(unlockedItems_),
                    #equippedItems_,
                    tostring(equippedSkin_)))
            end
        end
    end

    loaded_ = true
    ShopManager.SyncFromCloud(onDone)
end

function ShopManager.Save()
    local skinList = {}
    for id in pairs(purchasedSkins_) do
        table.insert(skinList, id)
    end
    local itemList = {}
    for id in pairs(unlockedItems_) do
        table.insert(itemList, id)
    end

    local data = {
        skins         = skinList,
        items         = itemList,
        equippedSkin  = equippedSkin_,
        equippedItems = equippedItems_,
        version       = 1,
    }
    local json = cjson.encode(data)
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(json)
        file:Close()
    end
end

-- ============================================================================
-- Cloud Sync
-- ============================================================================

function ShopManager.SyncToCloud()
    if not clientCloud then return end

    local skinList = {}
    for id in pairs(purchasedSkins_) do table.insert(skinList, id) end
    local itemList = {}
    for id in pairs(unlockedItems_) do table.insert(itemList, id) end

    local data = { skins = skinList, items = itemList, equippedSkin = equippedSkin_, equippedItems = equippedItems_, version = 1 }
    clientCloud:Set(CLOUD_KEY, data, {
        ok = function()
            print("[ShopManager] Cloud sync OK")
        end,
        error = function(code, reason)
            print("[ShopManager] Cloud sync FAILED: " .. tostring(reason))
        end,
    })
end

function ShopManager.SyncFromCloud(onDone)
    if not clientCloud then
        if onDone then onDone() end
        return
    end
    clientCloud:Get(CLOUD_KEY, {
        ok = function(values)
            local data = values and values[CLOUD_KEY]
            if data and type(data) == "table" then
                local changed = false
                -- Merge: union of local + cloud (never remove purchases)
                if type(data.skins) == "table" then
                    for _, id in ipairs(data.skins) do
                        if not purchasedSkins_[id] then
                            purchasedSkins_[id] = true
                            changed = true
                        end
                    end
                end
                if type(data.items) == "table" then
                    for _, id in ipairs(data.items) do
                        if not unlockedItems_[id] then
                            unlockedItems_[id] = true
                            changed = true
                        end
                    end
                end
                -- Sync equipped skin: cloud wins if local is nil
                if type(data.equippedSkin) == "string" and equippedSkin_ == nil then
                    equippedSkin_ = data.equippedSkin
                    changed = true
                end
                -- Sync equipped items: cloud wins if local is empty
                if type(data.equippedItems) == "table" and #equippedItems_ == 0 and #data.equippedItems > 0 then
                    equippedItems_ = data.equippedItems
                    changed = true
                end
                if changed then
                    ShopManager.Save()
                    ShopManager.SyncToCloud()
                    if onChange_ then onChange_() end
                    print("[ShopManager] Merged cloud data")
                end
            end
            if onDone then onDone() end
        end,
        error = function(code, reason)
            print("[ShopManager] Cloud load FAILED: " .. tostring(reason))
            if onDone then onDone() end
        end,
    })
end

-- ============================================================================
-- Query API
-- ============================================================================

--- Check if a skin has been purchased
function ShopManager.HasSkin(skinId)
    if not loaded_ then ShopManager.Load() end
    return purchasedSkins_[skinId] == true
end

--- Check if an arena item has been unlocked
function ShopManager.HasItem(itemId)
    if not loaded_ then ShopManager.Load() end
    return unlockedItems_[itemId] == true
end

--- Get list of all purchased skin IDs
function ShopManager.GetPurchasedSkins()
    if not loaded_ then ShopManager.Load() end
    local list = {}
    for id in pairs(purchasedSkins_) do
        table.insert(list, id)
    end
    return list
end

--- Get list of all unlocked item IDs
function ShopManager.GetUnlockedItems()
    if not loaded_ then ShopManager.Load() end
    local list = {}
    for id in pairs(unlockedItems_) do
        table.insert(list, id)
    end
    return list
end

--- Get currently equipped skin ID (or nil for default)
function ShopManager.GetEquippedSkin()
    if not loaded_ then ShopManager.Load() end
    return equippedSkin_
end

--- Equip a purchased skin (pass nil to unequip / revert to default)
function ShopManager.EquipSkin(skinId)
    if not loaded_ then ShopManager.Load() end
    if skinId ~= nil and not purchasedSkins_[skinId] then
        print("[ShopManager] Cannot equip unpurchased skin: " .. tostring(skinId))
        return false
    end
    equippedSkin_ = skinId
    ShopManager.Save()
    ShopManager.SyncToCloud()
    if onChange_ then onChange_() end
    print("[ShopManager] Equipped skin: " .. tostring(skinId))
    return true
end

--- Get equipped skin color (or nil if no skin equipped)
--- @deprecated Use GetSkinColorForGrade instead
function ShopManager.GetEquippedSkinColor()
    if not loaded_ then ShopManager.Load() end
    if not equippedSkin_ then return nil end
    local skin = ShopConfig.GetSkin(equippedSkin_)
    if skin then return skin.color end
    return nil
end

--- Get the skin color that applies to a specific grade (1-6)
--- Returns skin color if a purchased skin targets this grade, nil otherwise
function ShopManager.GetSkinColorForGrade(grade)
    if not loaded_ then ShopManager.Load() end
    for _, skin in ipairs(ShopConfig.SKINS) do
        if skin.targetGrade == grade and purchasedSkins_[skin.id] then
            return skin.color
        end
    end
    return nil
end

-- ============================================================================
-- Equipped Items API (arena loadout, max 3)
-- ============================================================================

--- Get list of equipped item IDs for arena
function ShopManager.GetEquippedItems()
    if not loaded_ then ShopManager.Load() end
    return equippedItems_
end

--- Set equipped items list (array of item IDs, max 3)
function ShopManager.SetEquippedItems(itemIds)
    if not loaded_ then ShopManager.Load() end
    equippedItems_ = {}
    for i = 1, math.min(#itemIds, 3) do
        equippedItems_[i] = itemIds[i]
    end
    ShopManager.Save()
    ShopManager.SyncToCloud()
    if onChange_ then onChange_() end
end

-- ============================================================================
-- Purchase API
-- ============================================================================

--- Purchase a product by ID. Returns success, errorReason
function ShopManager.Purchase(productId)
    if not loaded_ then ShopManager.Load() end

    local config, category = ShopConfig.GetProduct(productId)
    if not config then
        return false, "unknown_product"
    end

    -- Already owned?
    if category == "skin" and purchasedSkins_[productId] then
        return false, "already_owned"
    end
    if category == "item" and unlockedItems_[productId] then
        return false, "already_owned"
    end

    -- Try to spend diamonds
    if not DiamondManager.Spend(config.price) then
        return false, "insufficient_diamonds"
    end

    -- Record purchase
    if category == "skin" then
        purchasedSkins_[productId] = true
    elseif category == "item" then
        unlockedItems_[productId] = true
    end

    ShopManager.Save()
    ShopManager.SyncToCloud()

    print(string.format("[ShopManager] Purchased %s (%s) for %d diamonds",
        config.name, productId, config.price))

    if onChange_ then onChange_() end
    return true, nil
end

--- 免费解锁一个道具（教程赠送，不扣钻石）
function ShopManager.UnlockItemFree(itemId)
    if not loaded_ then ShopManager.Load() end
    if unlockedItems_[itemId] then return false end  -- 已解锁
    unlockedItems_[itemId] = true
    ShopManager.Save()
    ShopManager.SyncToCloud()
    print(string.format("[ShopManager] 免费解锁道具: %s（教程赠送）", itemId))
    if onChange_ then onChange_() end
    return true
end

-- ============================================================================
-- Callbacks
-- ============================================================================

--- Set a callback to be called whenever purchase state changes
function ShopManager.SetOnChange(fn)
    onChange_ = fn
end

-- ============================================================================
-- Helpers
-- ============================================================================

function ShopManager._CountTable(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

return ShopManager
