-- ============================================================================
-- SaveSlotManager.lua - Multiple save slot management for Breeding Data
-- Supports 3 save slots, each stored as breeding_data_N.json
-- ============================================================================

local CloudSave = require("game.CloudSave")

local SaveSlotManager = {}

local MAX_SLOTS = 3

--- Get the file path for a given slot number
---@param slot number 1-3
---@return string
local function SlotFile(slot)
    return string.format("breeding_data_%d.json", slot)
end

--- Public accessor for slot file path
---@param slot number 1-3
---@return string
function SaveSlotManager.GetSlotFile(slot)
    return SlotFile(slot)
end

--- Load data from a specific slot
---@param slot number 1-3
---@return table|nil data, boolean exists
function SaveSlotManager.LoadSlot(slot)
    if slot < 1 or slot > MAX_SLOTS then return nil, false end
    local path = SlotFile(slot)
    if not fileSystem:FileExists(path) then
        return nil, false
    end
    local file = File(path, FILE_READ)
    if not file:IsOpen() then return nil, false end
    local str = file:ReadString()
    file:Close()
    local ok, data = pcall(cjson.decode, str)
    if not ok or type(data) ~= "table" then
        return nil, false
    end
    return data, true
end

--- Delete a slot (local + cloud)
---@param slot number 1-3
function SaveSlotManager.DeleteSlot(slot)
    if slot < 1 or slot > MAX_SLOTS then return end
    local path = SlotFile(slot)
    if fileSystem:FileExists(path) then
        fileSystem:Delete(path)
        print(string.format("[SaveSlotManager] Slot %d local file deleted", slot))
    end
    -- Also delete cloud data for this slot
    CloudSave.DeleteSlot(slot)
end

--- Get summary info for all slots (for UI display)
---@return table[] Array of { slot, exists, gold, farmLevel, ballCount, bestStreak, bestBall }
function SaveSlotManager.GetAllSlotInfo()
    local info = {}
    for i = 1, MAX_SLOTS do
        local data, exists = SaveSlotManager.LoadSlot(i)
        if exists and data then
            -- Count farm balls
            local ballCount = 0
            if data.balls and type(data.balls) == "table" then
                ballCount = #data.balls
            end
            -- Count slot balls
            if data.slotBalls and type(data.slotBalls) == "table" then
                for _, slotData in pairs(data.slotBalls) do
                    if type(slotData) == "table" then
                        ballCount = ballCount + #slotData
                    end
                end
            end
            -- Find best (highest level) ball
            local bestBall = nil
            if data.balls then
                for _, b in ipairs(data.balls) do
                    if not bestBall or (b.level or 1) > (bestBall.level or 1) then
                        bestBall = b
                    end
                end
            end
            if data.slotBalls then
                for _, slotData in pairs(data.slotBalls) do
                    if type(slotData) == "table" then
                        for _, b in ipairs(slotData) do
                            if not bestBall or (b.level or 1) > (bestBall.level or 1) then
                                bestBall = b
                            end
                        end
                    end
                end
            end

            table.insert(info, {
                slot = i,
                exists = true,
                gold = data.gold or 0,
                farmLevel = data.farmLevel or 1,
                ballCount = ballCount,
                bestStreak = data.bestStreak or 0,
                bestBall = bestBall,
            })
        else
            table.insert(info, {
                slot = i,
                exists = false,
            })
        end
    end
    return info
end

--- Get best profile data across all slots (for main menu display)
---@return table|nil { bestBall, bestStreak, gold, ballCount }
function SaveSlotManager.GetBestProfileData()
    local bestProfile = nil
    for i = 1, MAX_SLOTS do
        local data, exists = SaveSlotManager.LoadSlot(i)
        if exists and data and data.balls and #data.balls > 0 then
            -- Find best ball in this slot
            local bestBall = nil
            for _, b in ipairs(data.balls) do
                if not bestBall or (b.level or 1) > (bestBall.level or 1) then
                    bestBall = b
                end
            end
            if data.slotBalls then
                for _, slotData in pairs(data.slotBalls) do
                    if type(slotData) == "table" then
                        for _, b in ipairs(slotData) do
                            if not bestBall or (b.level or 1) > (bestBall.level or 1) then
                                bestBall = b
                            end
                        end
                    end
                end
            end

            local totalBalls = #data.balls
            if data.slotBalls then
                for _, sd in pairs(data.slotBalls) do
                    if type(sd) == "table" then totalBalls = totalBalls + #sd end
                end
            end

            local profile = {
                bestBall = bestBall,
                bestStreak = data.bestStreak or 0,
                gold = data.gold or 0,
                ballCount = totalBalls,
            }

            -- Pick profile with the highest-level ball
            if not bestProfile
                or (bestBall and bestProfile.bestBall and (bestBall.level or 1) > (bestProfile.bestBall.level or 1))
                or (bestBall and not bestProfile.bestBall) then
                bestProfile = profile
            end
        end
    end
    return bestProfile
end

--- Migrate legacy breeding_data.json to slot 1 if slot 1 is empty.
--- Also attempts to pull cloud save (legacy key) into slot 1.
---@param onDone function|nil callback() called when migration finishes (async if cloud)
function SaveSlotManager.MigrateLegacy(onDone)
    local _, slot1Exists = SaveSlotManager.LoadSlot(1)
    if slot1Exists then
        if onDone then onDone() end
        return
    end

    -- Try local legacy file first
    if fileSystem:FileExists("breeding_data.json") then
        local file = File("breeding_data.json", FILE_READ)
        if file:IsOpen() then
            local str = file:ReadString()
            file:Close()
            local ok, data = pcall(cjson.decode, str)
            if ok and type(data) == "table" and data.balls and #data.balls > 0 then
                local outFile = File(SlotFile(1), FILE_WRITE)
                if outFile:IsOpen() then
                    outFile:WriteString(cjson.encode(data))
                    outFile:Close()
                    print("[SaveSlotManager] Migrated legacy breeding_data.json to slot 1")
                end
                if onDone then onDone() end
                return
            end
        end
    end

    -- No local legacy → try cloud (async)
    CloudSave.SetSlot(1)  -- slot 1 uses legacy cloud key
    CloudSave.Load(function(cloudData, err)
        if cloudData and cloudData.balls and #cloudData.balls > 0 then
            local outFile = File(SlotFile(1), FILE_WRITE)
            if outFile:IsOpen() then
                outFile:WriteString(cjson.encode(cloudData))
                outFile:Close()
                print(string.format("[SaveSlotManager] Migrated cloud save to slot 1 (%d balls)", #cloudData.balls))
            end
        end
        if onDone then onDone() end
    end)
end

--- Sync all slots from cloud: for each slot without local file, pull cloud data.
--- Processes slots sequentially to avoid CloudSave.SetSlot race conditions.
---@param onDone function|nil callback() called when all syncs complete
function SaveSlotManager.SyncAllFromCloud(onDone)
    -- Build list of slots that need cloud sync
    local slotsToSync = {}
    for slot = 1, MAX_SLOTS do
        local _, exists = SaveSlotManager.LoadSlot(slot)
        if not exists then
            table.insert(slotsToSync, slot)
        end
    end

    if #slotsToSync == 0 then
        if onDone then onDone() end
        return
    end

    -- Process one slot at a time (sequential async chain)
    local idx = 0
    local function syncNext()
        idx = idx + 1
        if idx > #slotsToSync then
            if onDone then onDone() end
            return
        end
        local slot = slotsToSync[idx]
        CloudSave.SetSlot(slot)
        CloudSave.Load(function(cloudData, err)
            if cloudData and cloudData.balls and #cloudData.balls > 0 then
                local outFile = File(SlotFile(slot), FILE_WRITE)
                if outFile:IsOpen() then
                    outFile:WriteString(cjson.encode(cloudData))
                    outFile:Close()
                    print(string.format("[SaveSlotManager] Synced cloud → local slot %d (%d balls)", slot, #cloudData.balls))
                end
            end
            syncNext()
        end)
    end
    syncNext()
end

SaveSlotManager.MAX_SLOTS = MAX_SLOTS

return SaveSlotManager
