-- ============================================================================
-- CloudSave.lua - 云存档模块
-- 使用 clientCloud API 将球球数据保存到云端，实现跨设备同步
-- ============================================================================

local CloudSave = {}

-- ============================================================================
-- Constants
-- ============================================================================

local CLOUD_KEY = "breeding_save"  -- 云端存储 key（values 类型，存复杂数据）
local SAVE_COOLDOWN = 10           -- 云存档上传冷却（秒），避免频繁写入
local VERSION = 2                  -- 存档版本号

-- ============================================================================
-- Internal State
-- ============================================================================

local lastSaveTime_ = 0
local lastFingerprint_ = ""
local saving_ = false
local loading_ = false

-- ============================================================================
-- Save (上传到云端)
-- ============================================================================

--- Build a fingerprint from save data to detect changes
local function BuildFingerprint(data)
    local parts = {}
    parts[#parts + 1] = tostring(data.gold or 0)
    parts[#parts + 1] = tostring(data.farmLevel or 1)
    if data.balls then
        for _, b in ipairs(data.balls) do
            parts[#parts + 1] = string.format("%s:%d:%d",
                b.name or "?", b.level or 1, b.exp or 0)
        end
    end
    return table.concat(parts, "|")
end

--- Save breeding data to cloud.
--- @param data table  The same data structure as local SaveBreedingData produces
--- @param onDone function|nil  callback(success, reason)
--- @param force boolean|nil  bypass cooldown
function CloudSave.Save(data, onDone, force)
    if not data then
        if onDone then onDone(false, "no data") end
        return
    end

    if saving_ then
        if onDone then onDone(false, "already saving") end
        return
    end

    -- Cooldown check
    local now = os.time()
    if not force and (now - lastSaveTime_) < SAVE_COOLDOWN then
        if onDone then onDone(true, "cooldown") end
        return
    end

    -- Fingerprint dedup
    local fp = BuildFingerprint(data)
    if not force and fp == lastFingerprint_ then
        if onDone then onDone(true, "unchanged") end
        return
    end

    -- Add version tag
    data.version = VERSION
    data.cloudSaveTime = now

    saving_ = true
    print("[CloudSave] Saving to cloud...")

    clientCloud:Set(CLOUD_KEY, data, {
        ok = function()
            saving_ = false
            lastSaveTime_ = os.time()
            lastFingerprint_ = fp
            local ballCount = data.balls and #data.balls or 0
            print(string.format("[CloudSave] Cloud save OK (%d balls, gold=%.0f)",
                ballCount, data.gold or 0))
            if onDone then onDone(true) end
        end,
        error = function(code, reason)
            saving_ = false
            print("[CloudSave] Cloud save FAILED: " .. tostring(reason))
            if onDone then onDone(false, reason) end
        end,
    })
end

-- ============================================================================
-- Load (从云端加载)
-- ============================================================================

--- Load breeding data from cloud.
--- @param onDone function  callback(data_or_nil, reason)
function CloudSave.Load(onDone)
    if loading_ then
        if onDone then onDone(nil, "already loading") end
        return
    end

    loading_ = true
    print("[CloudSave] Loading from cloud...")

    clientCloud:Get(CLOUD_KEY, {
        ok = function(values, iscores)
            loading_ = false
            local data = values and values[CLOUD_KEY]
            if data and type(data) == "table" and data.balls then
                local ballCount = #data.balls
                print(string.format("[CloudSave] Cloud load OK (%d balls, gold=%.0f)",
                    ballCount, data.gold or 0))
                -- Update fingerprint so we don't re-upload the same data
                lastFingerprint_ = BuildFingerprint(data)
                lastSaveTime_ = os.time()
                if onDone then onDone(data) end
            else
                print("[CloudSave] No cloud save data found")
                if onDone then onDone(nil, "no data") end
            end
        end,
        error = function(code, reason)
            loading_ = false
            print("[CloudSave] Cloud load FAILED: " .. tostring(reason))
            if onDone then onDone(nil, reason) end
        end,
    })
end

-- ============================================================================
-- Status
-- ============================================================================

function CloudSave.IsSaving()
    return saving_
end

function CloudSave.IsLoading()
    return loading_
end

return CloudSave
