-- ============================================================================
-- ArenaCloud.lua - 擂台赛异步联机模块
-- 每个玩家上传自己最新放入养殖场的 1 个球（时间戳排序）
-- 通过排行榜拉取全服最新的球作为角色池
-- ============================================================================

local ArenaCloud = {}

-- ============================================================================
-- Constants
-- ============================================================================

local FETCH_COUNT       = 20      -- 每次拉取排行榜人数
local CACHE_TTL         = 5       -- 缓存有效期（秒），实时更新
local UPLOAD_COOLDOWN   = 3       -- 上传冷却（秒）

-- ============================================================================
-- Internal State
-- ============================================================================

local cache_ = {
    pool = {},                -- 角色池: { {userId, nickname, ball}, ... }
    fetchTime = 0,            -- 上次拉取时间
    uploadTime = 0,           -- 上次上传时间
    lastFingerprint = "",     -- 上次上传的数据指纹
    fetching = false,         -- 是否正在拉取
}

-- ============================================================================
-- Power Calculation (保留，用于角色池展示排序)
-- ============================================================================

local function CalculatePower(ball)
    if not ball then return 0 end
    local base = (ball.level or 1) * 100
    local skillBonus = 0
    if ball.skill then skillBonus = skillBonus + 20 end
    if ball.enhancedSkill then skillBonus = skillBonus + 50 end
    if ball.ultimateSkill then skillBonus = skillBonus + 100 end
    local hpBonus = math.floor((ball.maxHp or 0) / 5)
    return base + skillBonus + hpBonus
end

ArenaCloud.CalculatePower = CalculatePower

-- ============================================================================
-- Validation
-- ============================================================================

local function ValidateCloudBall(ball)
    return ball
        and type(ball.level) == "number"
        and ball.level >= 1 and ball.level <= 20
        and type(ball.color) == "table"
end

-- ============================================================================
-- Upload (单球上传)
-- ============================================================================

--- Upload the latest ball to cloud.
--- @param ball table  A single serialized ball (name, color, level, ...)
--- @param onDone function|nil  callback(success, reason)
--- @param force boolean|nil  bypass cooldown
function ArenaCloud.UploadBall(ball, onDone, force)
    if not ball then
        if onDone then onDone(false, "no ball") end
        return
    end

    -- Cooldown check (skipped when force=true)
    local now = os.time()
    if not force and now - cache_.uploadTime < UPLOAD_COOLDOWN then
        if onDone then onDone(true, "cooldown") end
        return
    end

    -- Build fingerprint to detect changes
    local fingerprint = string.format("%s:%d:%d",
        ball.name or "?", ball.level or 1, now)
    if not force and fingerprint == cache_.lastFingerprint then
        if onDone then onDone(true, "unchanged") end
        return
    end

    -- Build ball data
    local ballData = {
        version = 2,
        uploadTime = now,
        color = ball.color,
        name = ball.name,
        expression = ball.expression,
        level = ball.level,
        hp = ball.maxHp or ball.hp,
        maxHp = ball.maxHp,
        skill = ball.skill,
        enhancedSkill = ball.enhancedSkill,
        ultimateSkill = ball.ultimateSkill,
        radius = ball.radius,
    }

    -- 用时间戳作为 iscore，按时间降序排列 = 最新的排在前面
    clientCloud:BatchSet()
        :SetInt("farm_latest_time", now)
        :Set("farm_latest_ball", ballData)
        :Save("farm ball upload", {
            ok = function()
                cache_.uploadTime = os.time()
                cache_.lastFingerprint = fingerprint
                cache_.fetchTime = 0  -- invalidate fetch cache
                print(string.format("[ArenaCloud] Upload OK, ball=%s Lv%d",
                    ball.name or "?", ball.level or 1))
                if onDone then onDone(true) end
                -- Auto-refresh pool after successful upload
                ArenaCloud.FetchPool()
            end,
            error = function(code, reason)
                print("[ArenaCloud] Upload failed: " .. tostring(reason))
                if onDone then onDone(false, reason) end
            end,
        })
end

-- ============================================================================
-- 兼容旧接口：UploadTeam → 取第一个球上传
-- ============================================================================

function ArenaCloud.UploadTeam(balls, onDone, force)
    if not balls or #balls == 0 then
        if onDone then onDone(false, "no balls") end
        return
    end
    -- 只上传第一个球（等级最高的）
    table.sort(balls, function(a, b)
        return (a.level or 1) > (b.level or 1)
    end)
    ArenaCloud.UploadBall(balls[1], onDone, force)
end

-- ============================================================================
-- Fetch (角色池拉取 - 按时间戳降序)
-- ============================================================================

function ArenaCloud.FetchPool(onDone)
    -- Cache check
    local now = os.time()
    if #cache_.pool > 0 and (now - cache_.fetchTime) < CACHE_TTL then
        if onDone then onDone(cache_.pool) end
        return
    end

    if cache_.fetching then
        if onDone then onDone(cache_.pool) end
        return
    end

    cache_.fetching = true
    print("[ArenaCloud] Fetching pool...")

    -- 按 farm_latest_time 降序排列，拉取最新的 FETCH_COUNT 个玩家
    clientCloud:GetRankList("farm_latest_time", 0, FETCH_COUNT, {
        ok = function(rankList)
            cache_.fetching = false
            if not rankList or #rankList == 0 then
                print("[ArenaCloud] Rank list empty")
                cache_.fetchTime = os.time()
                if onDone then onDone(cache_.pool) end
                return
            end

            print(string.format("[ArenaCloud] DEBUG: rankList count=%d, myUserId=%s",
                #rankList, tostring(clientCloud.userId)))

            -- Collect valid entries
            local entries = {}
            local userIds = {}

            for idx, item in ipairs(rankList) do
                local ball = item.score and item.score.farm_latest_ball
                local uploadTime = item.iscore and item.iscore.farm_latest_time or 0

                print(string.format(
                    "[ArenaCloud] DEBUG item[%d]: userId=%s uploadTime=%d hasBall=%s",
                    idx, tostring(item.userId), uploadTime, tostring(ball ~= nil)))

                if ball and ValidateCloudBall(ball) then
                    table.insert(entries, {
                        userId = item.userId,
                        nickname = nil,  -- filled later
                        power = CalculatePower(ball),
                        uploadTime = uploadTime,
                        ball = ball,
                        -- 兼容旧代码：balls 数组包含一个球
                        balls = { ball },
                    })
                    table.insert(userIds, item.userId)
                else
                    print(string.format("[ArenaCloud] DEBUG item[%d]: invalid ball, skipped", idx))
                end
            end

            if #entries == 0 then
                cache_.fetchTime = os.time()
                print("[ArenaCloud] No valid entries found")
                if onDone then onDone(cache_.pool) end
                return
            end

            -- Fetch nicknames
            GetUserNickname({
                userIds = userIds,
                onSuccess = function(nicknames)
                    local nameMap = {}
                    for _, info in ipairs(nicknames) do
                        nameMap[info.userId] = info.nickname or "Unknown"
                    end
                    for _, entry in ipairs(entries) do
                        entry.nickname = nameMap[entry.userId] or tostring(entry.userId)
                    end
                    cache_.pool = entries
                    cache_.fetchTime = os.time()
                    print("[ArenaCloud] Pool loaded: " .. #entries .. " players")
                    if onDone then onDone(cache_.pool) end
                end,
                onError = function()
                    for _, entry in ipairs(entries) do
                        entry.nickname = tostring(entry.userId)
                    end
                    cache_.pool = entries
                    cache_.fetchTime = os.time()
                    print("[ArenaCloud] Pool loaded (no nicknames): " .. #entries .. " players")
                    if onDone then onDone(cache_.pool) end
                end,
            })
        end,
        error = function(code, reason)
            cache_.fetching = false
            print("[ArenaCloud] GetRankList failed: " .. tostring(reason))
            if onDone then onDone(cache_.pool) end
        end,
    }, "farm_latest_ball")  -- 附带拉取球数据
end

-- ============================================================================
-- Pool Access
-- ============================================================================

function ArenaCloud.GetPool()
    return cache_.pool
end

function ArenaCloud.GetPoolCount()
    return #cache_.pool
end

function ArenaCloud.IsFetching()
    return cache_.fetching
end

function ArenaCloud.InvalidateCache()
    cache_.fetchTime = 0
end

return ArenaCloud
