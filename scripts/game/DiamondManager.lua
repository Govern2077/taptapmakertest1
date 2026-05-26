-- ============================================================================
-- DiamondManager.lua - Global Diamond Currency (Cross-Save)
-- Diamonds are earned from Arena battle wins, stored independently of save slots.
-- Uses cjson + File API for local persistence, clientCloud for cloud sync.
-- ============================================================================

local DiamondManager = {}

local SAVE_FILE  = "diamond_data.json"
local CLOUD_KEY  = "diamond_global"

-- Cached state
local diamonds_    = 0
local totalEarned_ = 0
local loaded_      = false

-- ============================================================================
-- Load / Save (local file)
-- ============================================================================

function DiamondManager.Load()
    if loaded_ then return diamonds_ end

    if not fileSystem:FileExists(SAVE_FILE) then
        print("[DiamondManager] No save file, starting at 0")
        diamonds_    = 0
        totalEarned_ = 0
        loaded_      = true
        -- Pull from cloud in case another device has data
        DiamondManager.SyncFromCloud()
        return 0
    end

    local file = File(SAVE_FILE, FILE_READ)
    if not file:IsOpen() then
        diamonds_    = 0
        totalEarned_ = 0
        loaded_      = true
        DiamondManager.SyncFromCloud()
        return 0
    end

    local str = file:ReadString()
    file:Close()

    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then
        print("[DiamondManager] ERROR: Failed to parse save file")
        diamonds_    = 0
        totalEarned_ = 0
        loaded_      = true
        DiamondManager.SyncFromCloud()
        return 0
    end

    diamonds_    = type(data.diamonds) == "number" and data.diamonds or 0
    totalEarned_ = type(data.totalEarned) == "number" and data.totalEarned or diamonds_
    loaded_      = true
    print("[DiamondManager] Loaded local: " .. diamonds_ .. " diamonds")
    -- Always pull cloud data and take the larger value
    DiamondManager.SyncFromCloud()
    return diamonds_
end

function DiamondManager.Save()
    local data = {
        diamonds    = diamonds_,
        totalEarned = totalEarned_,
        version     = 1,
    }
    local json = cjson.encode(data)
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(json)
        file:Close()
        return true
    end
    print("[DiamondManager] ERROR: Failed to save")
    return false
end

-- ============================================================================
-- Get / Add
-- ============================================================================

function DiamondManager.Get()
    if not loaded_ then DiamondManager.Load() end
    return diamonds_
end

function DiamondManager.Add(amount)
    if amount <= 0 then return diamonds_ end
    if not loaded_ then DiamondManager.Load() end

    diamonds_    = diamonds_ + amount
    totalEarned_ = totalEarned_ + amount
    DiamondManager.Save()
    DiamondManager.SyncToCloud()
    print(string.format("[DiamondManager] +%d diamonds (total: %d)", amount, diamonds_))
    return diamonds_
end

--- Spend diamonds. Returns true if successful, false if insufficient balance.
function DiamondManager.Spend(amount)
    if amount <= 0 then return false end
    if not loaded_ then DiamondManager.Load() end
    if diamonds_ < amount then
        print(string.format("[DiamondManager] Spend FAILED: need %d, have %d", amount, diamonds_))
        return false
    end
    diamonds_ = diamonds_ - amount
    DiamondManager.Save()
    DiamondManager.SyncToCloud()
    print(string.format("[DiamondManager] -%d diamonds (remaining: %d)", amount, diamonds_))
    return true
end

-- ============================================================================
-- Cloud Sync
-- ============================================================================

function DiamondManager.SyncToCloud()
    if not clientCloud then return end
    clientCloud:SetInt(CLOUD_KEY, diamonds_, {
        ok = function()
            print("[DiamondManager] Cloud sync OK: " .. diamonds_)
        end,
        error = function(code, reason)
            print("[DiamondManager] Cloud sync FAILED: " .. tostring(reason))
        end,
    })
end

function DiamondManager.SyncFromCloud(onDone)
    if not clientCloud then
        if onDone then onDone(diamonds_) end
        return
    end
    clientCloud:Get(CLOUD_KEY, {
        ok = function(values, iscores)
            local cloudVal = iscores and iscores[CLOUD_KEY] or 0
            print(string.format("[DiamondManager] Cloud has %d, local has %d", cloudVal, diamonds_))
            if cloudVal > diamonds_ then
                -- Cloud is ahead: pull cloud data
                diamonds_    = cloudVal
                totalEarned_ = math.max(totalEarned_, diamonds_)
                DiamondManager.Save()
                print("[DiamondManager] Updated from cloud: " .. diamonds_)
            elseif diamonds_ > cloudVal then
                -- Local is ahead: push local data to cloud
                DiamondManager.SyncToCloud()
                print("[DiamondManager] Pushed local to cloud: " .. diamonds_)
            end
            if onDone then onDone(diamonds_) end
        end,
        error = function(code, reason)
            print("[DiamondManager] Cloud load FAILED: " .. tostring(reason))
            if onDone then onDone(diamonds_) end
        end,
    })
end

return DiamondManager
