-- ============================================================================
-- Standalone.lua - Single Player vs AI (Modular Skill System)
-- State machine: menu → cultivation → playing → gameover → menu
-- Pure physics movement, data-driven skills, ball customization
-- ============================================================================

local Standalone = {}
local Settings          = require("config.Settings")
local BallAI            = require("game.BallAI")
local SkillRegistry     = require("game.SkillRegistry")
local SkillExecutor     = require("game.SkillExecutor")
local Expressions       = require("game.Expressions")
local BallCustomization = require("game.BallCustomization")
local StartPage         = require("ui.StartPage")
local CultivationPage   = require("ui.CultivationPage")
local TriangleFill      = require("effects.TriangleFill")
local TriangleButton    = require("ui.TriangleButton")
local ItemSystem        = require("game.ItemSystem")
local BackgroundBubbles = require("effects.BackgroundBubbles")
local BattleRoyale      = require("game.BattleRoyale")
local BreedingPage           = require("ui.BreedingPage")
local BreedingLoadingScreen  = require("ui.BreedingLoadingScreen")
-- local TutorialMascot         = require("ui.TutorialMascot")
-- local TutorialSystem         = require("ui.TutorialSystem")
local ArenaBattle            = require("ui.ArenaBattle")
local SaveSlotManager   = require("game.SaveSlotManager")
local ShopModal         = require("ui.ShopModal")
local ShopManager       = require("game.ShopManager")
local SettingsModal     = require("ui.SettingsModal")

local UI = require("urhox-libs/UI")

local BALL  = Settings.Ball
local POPUP = Settings.Popup

-- ============================================================================
-- Design Resolution (Mode A)
-- ============================================================================

local designW, designH = Settings.Arena.DesignWidth, Settings.Arena.DesignHeight
local physW, physH, dpr, logicalW, logicalH
local nvgScale_, screenDesignW, screenDesignH, designOffsetX, designOffsetY

local function RecalcLayout()
    physW, physH = graphics:GetWidth(), graphics:GetHeight()
    dpr = graphics:GetDPR()
    if dpr <= 0 then dpr = 1 end
    logicalW, logicalH = physW / dpr, physH / dpr
    if logicalW <= 0 or logicalH <= 0 then
        logicalW, logicalH = designW, designH
    end
    nvgScale_ = math.min(logicalW / designW, logicalH / designH)
    if nvgScale_ <= 0 then nvgScale_ = 1 end
    screenDesignW = logicalW / nvgScale_
    screenDesignH = logicalH / nvgScale_
    designOffsetX = (screenDesignW - designW) / 2
    designOffsetY = (screenDesignH - designH) / 2
end

-- ============================================================================
-- State
-- ============================================================================

---@type Scene
local scene_ = nil
local vg_ = nil
local fontNormal_ = -1
local breedingBgImg_ = -1  -- breeding page full-screen background image

-- Game logic
local balls_ = {}
local aiStates_ = {}
-- Per-tier independent cooldowns: cooldowns_[team][tier] = remaining seconds
local cooldowns_ = {
    { normal = 0, enhanced = 0, ultimate = 0 },
    { normal = 0, enhanced = 0, ultimate = 0 },
}
local collisionCooldown_ = 0

-- Game phase
local gamePhase_ = "menu"
local gameWinner_ = 0
local gameOverTimer_ = 0

-- Loading screen state
local loadingActive_ = false
local loadingElapsed_ = 0
local loadingText_ = "正在加载云存档..."
local loadingDone_ = false   -- true when cloud sync finished, triggers modal open

-- Cloud sync preload state
local cloudSyncDone_ = false       -- true once initial preload finishes
local cloudSyncStarted_ = false    -- true once preload has been kicked off
local cloudSyncPendingCb_ = nil    -- callback to run when preload finishes (if user clicked before it's done)

-- Customization
local playerCustom_ = nil
local aiCustom_ = nil

-- Player control
local isAIProxy_ = false

-- Visual effects
local damagePopups_ = {}
local particles_ = {}
local announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
local shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

-- Tier transition
local tierFlash_ = { 0, 0 }
local lastTier_ = { "normal", "normal" }

-- Per-ball triangle fills
local ballTriFills_ = {}

-- Arena position (design coords) and adaptive scale
local arenaX_, arenaY_ = 0, 0
local arenaScale_ = 1.0   -- dynamic scale factor for arena and surrounding UI
local arenaDrawSize_ = Settings.Arena.Size  -- rendered size = Size * arenaScale_

-- Item drag state
local dragItem_ = nil   -- { slot=int, startX, startY, curX, curY }
local bottomBarY_ = 0   -- set during draw layout

-- UI initialized flag
local uiInited_ = false

local TIER_NAMES = { normal = "普通", enhanced = "强化", ultimate = "终结" }
local TIER_LABELS = { normal = "普通技能", enhanced = "强化技能", ultimate = "终结技能" }

-- Debug panel
local debugShow_ = false
local debugToggleCooldown_ = 0

-- ============================================================================
-- Helpers
-- ============================================================================

local function GetCustom(team)
    return team == 1 and playerCustom_ or aiCustom_
end

--- Get skill def for a specific tier
local function GetSkillDefForTier(team, tier)
    local custom = GetCustom(team)
    if not custom or not custom.skills then return nil end
    local skillId = custom.skills[tier]
    if not skillId or skillId == "" then return nil end
    return SkillRegistry.Get(skillId)
end

--- Get the best available skill: highest-priority tier that is off cooldown and has a skill equipped
local function GetBestAvailableSkill(team)
    local ball = balls_[team]
    if not ball then return nil, nil end
    local tiers = BallAI.GetAvailableTiers(ball.hp)
    for _, tier in ipairs(tiers) do
        local cd = cooldowns_[team][tier] or 0
        if cd <= 0 then
            local skillDef = GetSkillDefForTier(team, tier)
            if skillDef then
                return skillDef, tier
            end
        end
    end
    return nil, nil
end

--- Get all skill info for a team (for display)
local function GetAllSkillInfo(team)
    local ball = balls_[team]
    if not ball then return {} end
    local tiers = BallAI.GetAvailableTiers(ball.hp)
    local info = {}
    for _, tier in ipairs(tiers) do
        local skillDef = GetSkillDefForTier(team, tier)
        if skillDef then
            table.insert(info, {
                tier = tier,
                skillDef = skillDef,
                cooldown = math.max(0, cooldowns_[team][tier] or 0),
                ready = (cooldowns_[team][tier] or 0) <= 0,
            })
        end
    end
    return info
end

--- Get ALL equipped skills for display (regardless of HP tier)
local function GetFullSkillInfo(team)
    local info = {}
    for _, tier in ipairs({"normal", "enhanced", "ultimate"}) do
        local skillDef = GetSkillDefForTier(team, tier)
        if skillDef then
            table.insert(info, {
                tier = tier,
                skillDef = skillDef,
                cooldown = math.max(0, cooldowns_[team][tier] or 0),
                ready = (cooldowns_[team][tier] or 0) <= 0,
            })
        end
    end
    return info
end

--- Legacy compat: get the active tier's skill (for display of highest tier)
local function GetActiveSkillDef(team)
    local ball = balls_[team]
    if not ball then return nil end
    local tier = BallAI.GetActiveTier(ball.hp)
    return GetSkillDefForTier(team, tier)
end

local function EnsureUIInit()
    if uiInited_ then return end
    uiInited_ = true
    UI.Init({
        theme = "dark",
        fonts = {
            { family = "sans", weights = { normal = "Fonts/MiSans-Bold.ttf" } },
        },
        scale = UI.Scale.DESIGN_RESOLUTION(designW, designH),
    })
end

-- ============================================================================
-- Entry
-- ============================================================================

function Standalone.Start()
    scene_ = Scene()
    scene_:CreateComponent("Octree", LOCAL)

    RecalcLayout()
    -- NanoVG deferred to StartGame() to reduce startup memory
    SetupCamera()

    SubscribeToEvent("Update", "HandleUpdate")
    SubscribeToEvent("ScreenMode", "HandleScreenMode")

    -- Load saved volume settings (applies master gain before BGM plays)
    SettingsModal.Load()

    -- Play looping background music
    local music = cache:GetResource("Sound", "audio/背景.ogg")
    if music then
        music.looped = true
        local bgmNode = scene_:CreateChild("BGM")
        local src = bgmNode:CreateComponent("SoundSource")
        src.soundType = SOUND_MUSIC
        src:Play(music)
        print("[Standalone] BGM started (looping)")
    else
        print("[Standalone] WARNING: BGM resource not found")
    end

    ShowMenu()
    print("[Standalone] Started - Ball Brawl")
end

function Standalone.Stop()
    UI.Shutdown()
    if vg_ then nvgDelete(vg_); vg_ = nil end
end

function SetupNanoVG()
    vg_ = nvgCreate(1)
    if not vg_ then
        print("[Standalone] ERROR: NanoVG creation failed")
        return
    end
    fontNormal_ = nvgCreateFont(vg_, "sans", "Fonts/LongZhuTi-Regular.ttf")
    breedingBgImg_ = nvgCreateImage(vg_, "image/擂台赛背景.png", 0)
    SubscribeToEvent(vg_, "NanoVGRender", "HandleNanoVGRender")
end

function SetupCamera()
    local cameraNode = scene_:CreateChild("Camera", LOCAL)
    local camera = cameraNode:CreateComponent("Camera", LOCAL)
    camera.orthographic = true
    camera.orthoSize = 10
    renderer:SetViewport(0, Viewport:new(scene_, camera))
end

function HandleScreenMode(eventType, eventData)
    RecalcLayout()
end

-- ============================================================================
-- Breeding Save Slot Selection Popup
-- ============================================================================

--- Format gold number with abbreviation
local function FormatGold(n)
    if n >= 1000000 then
        return string.format("%.1fM", n / 1000000)
    elseif n >= 10000 then
        return string.format("%.1fW", n / 10000)
    elseif n >= 1000 then
        return string.format("%.1fK", n / 1000)
    end
    return tostring(math.floor(n))
end

--- Slot accent colors for visual distinction
local SLOT_COLORS = { "#4fc3f7", "#66bb6a", "#ab47bc" }
local SLOT_LABELS = { "存档一", "存档二", "存档三" }

--- Build a single breeding slot card widget (horizontal layout version)
local function BuildBreedingSlotCard(slotInfo, onSelect, onDelete)
    local accentColor = SLOT_COLORS[slotInfo.slot] or "#4fc3f7"
    local slotLabel = SLOT_LABELS[slotInfo.slot] or string.format("存档 %d", slotInfo.slot)

    if slotInfo.exists then
        -- Info rows
        local infoChildren = {}
        local infos = {
            { icon = "💰", label = "金币", value = FormatGold(slotInfo.gold or 0) },
            { icon = "🏡", label = "牧场", value = "Lv." .. tostring(slotInfo.farmLevel or 1) },
            { icon = "⚽", label = "球球", value = tostring(slotInfo.ballCount or 0) },
            { icon = "🔥", label = "连胜", value = tostring(slotInfo.bestStreak or 0) },
        }
        for _, info in ipairs(infos) do
            table.insert(infoChildren, UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                marginBottom = 2,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 4,
                        children = {
                            UI.Label { text = info.icon, fontSize = 13 },
                            UI.Label { text = info.label, fontSize = 12, color = "#aaaacc" },
                        },
                    },
                    UI.Label { text = info.value, fontSize = 12, fontWeight = "bold", color = "#ffffff" },
                },
            })
        end

        -- Best ball info
        if slotInfo.bestBall then
            local lvl = slotInfo.bestBall.level or 1
            local bname = slotInfo.bestBall.name or "未知"
            table.insert(infoChildren, UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "space-between",
                width = "100%",
                marginTop = 2,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        alignItems = "center",
                        gap = 4,
                        children = {
                            UI.Label { text = "⭐", fontSize = 13 },
                            UI.Label { text = "最强", fontSize = 12, color = "#aaaacc" },
                        },
                    },
                    UI.Label {
                        text = string.format("%s Lv.%d", bname, lvl),
                        fontSize = 12, fontWeight = "bold", color = "#ffd54f",
                    },
                },
            })
        end

        return UI.Panel {
            flex = 1,
            padding = 14,
            borderRadius = 12,
            backgroundColor = "#2a2a3a",
            borderWidth = 2,
            borderColor = accentColor,
            alignItems = "center",
            children = {
                -- Slot title
                UI.Label {
                    text = slotLabel,
                    fontSize = 18,
                    fontWeight = "bold",
                    color = accentColor,
                    marginBottom = 10,
                },
                -- Breeding info
                UI.Panel {
                    width = "100%",
                    gap = 2,
                    marginBottom = 12,
                    children = infoChildren,
                },
                -- Continue button
                UI.Button {
                    text = "继续养殖",
                    variant = "primary",
                    width = "100%",
                    onClick = function()
                        if onSelect then onSelect(slotInfo.slot) end
                    end,
                },
                -- Delete button
                UI.Button {
                    text = "删除存档",
                    variant = "ghost",
                    size = "sm",
                    width = "100%",
                    color = "#ff6666",
                    marginTop = 6,
                    onClick = function()
                        if onDelete then onDelete(slotInfo.slot) end
                    end,
                },
            },
        }
    else
        -- Empty slot
        return UI.Panel {
            flex = 1,
            padding = 14,
            borderRadius = 12,
            backgroundColor = "#1e1e2e",
            borderWidth = 1,
            borderColor = "#444466",
            alignItems = "center",
            justifyContent = "center",
            minHeight = 200,
            children = {
                UI.Label {
                    text = slotLabel,
                    fontSize = 18,
                    fontWeight = "bold",
                    color = "#888888",
                    marginBottom = 8,
                },
                UI.Label {
                    text = "空存档",
                    fontSize = 14,
                    color = "#666666",
                    marginBottom = 16,
                },
                UI.Button {
                    text = "新建存档",
                    variant = "outline",
                    width = "100%",
                    onClick = function()
                        if onSelect then onSelect(slotInfo.slot) end
                    end,
                },
            },
        }
    end
end

--- Show breeding save slot selection as overlay modal on top of start page
---@type Modal|nil
local saveSlotModal_ = nil

--- Internal: build and open the save slot modal (called after migration completes)
local function OpenSaveSlotModal()
    -- Close previous modal if exists
    if saveSlotModal_ then
        saveSlotModal_:Close()
        saveSlotModal_ = nil
    end

    EnsureUIInit()

    local function closeModal()
        if saveSlotModal_ then
            saveSlotModal_:Close()
            saveSlotModal_ = nil
        end
    end

    -- 先查询所有存档状态，记录哪些是新存档（不存在的槽位）
    local slots = SaveSlotManager.GetAllSlotInfo()
    local slotExistsMap = {}
    for _, info in ipairs(slots) do
        slotExistsMap[info.slot] = info.exists
    end

    local function onSelectSlot(slot)
        local isNewSave = not slotExistsMap[slot]
        closeModal()
        BreedingPage.SetSaveFile(SaveSlotManager.GetSlotFile(slot))
        ShowBreeding(isNewSave)
    end

    local function onDeleteSlot(slot)
        UI.Modal.Confirm({
            title = "删除存档",
            message = string.format("确定要删除存档 %d 吗？所有养殖进度将被清除，此操作不可撤销。", slot),
            onConfirm = function()
                SaveSlotManager.DeleteSlot(slot)
                -- Refresh: reopen the modal with updated data
                closeModal()
                OpenSaveSlotModal()
            end,
        })
    end

    local slotCards = {}
    for _, info in ipairs(slots) do
        table.insert(slotCards, BuildBreedingSlotCard(info, onSelectSlot, onDeleteSlot))
    end

    -- Create modal overlay
    saveSlotModal_ = UI.Modal {
        title = "选择养殖存档",
        size = "lg",
        closeOnOverlay = true,
        closeOnEscape = true,
        contentPadding = 20,
        contentGap = 16,
    }

    -- Card row
    saveSlotModal_:AddContent(UI.Panel {
        flexDirection = "row",
        justifyContent = "center",
        alignItems = "stretch",
        gap = 14,
        width = "100%",
        children = slotCards,
    })

    saveSlotModal_:Open()
end

function ShowBreedingSaveSlotPopup()
    if cloudSyncDone_ then
        -- Preload already finished → open modal immediately, no loading screen
        print("[Standalone] Cloud sync already done, opening save slot modal directly")
        OpenSaveSlotModal()
        return
    end

    -- Preload still in progress → show loading screen and wait for it to finish
    print("[Standalone] Cloud sync still in progress, showing loading screen...")
    loadingActive_ = true
    loadingElapsed_ = 0
    loadingDone_ = false
    loadingText_ = "正在同步存档数据..."
    StartPage.SetInputBlocked(true)

    -- Register a pending callback so PreloadCloudSync's completion will trigger it
    cloudSyncPendingCb_ = function()
        loadingActive_ = false
        loadingDone_ = false
        StartPage.SetInputBlocked(false)
        OpenSaveSlotModal()
    end
end

-- ============================================================================
-- Navigation
-- ============================================================================

function PreloadCloudSync()
    if cloudSyncStarted_ then return end
    cloudSyncStarted_ = true
    cloudSyncDone_ = false

    -- Show loading screen and block all buttons immediately
    loadingActive_ = true
    loadingElapsed_ = 0
    loadingText_ = "正在加载游戏数据..."
    StartPage.SetInputBlocked(true)
    print("[Standalone] Auto-preloading all game data...")

    -- Track two parallel tasks: save slots + shop data
    local pendingTasks_ = 2

    local function onTaskDone()
        pendingTasks_ = pendingTasks_ - 1
        if pendingTasks_ > 0 then return end

        -- All tasks complete
        print("[Standalone] All preload tasks complete")
        cloudSyncDone_ = true
        loadingActive_ = false
        StartPage.SetInputBlocked(false)

        -- Ensure equipped items reflect loaded shop data
        ItemSystem.LoadEquipped()

        -- Fire any pending callback (e.g. user already clicked breeding)
        if cloudSyncPendingCb_ then
            local cb = cloudSyncPendingCb_
            cloudSyncPendingCb_ = nil
            cb()
        end
    end

    -- Task 1: Save slot cloud sync
    SaveSlotManager.MigrateLegacy(function()
        loadingText_ = "正在同步存档数据..."
        SaveSlotManager.SyncAllFromCloud(function()
            print("[Standalone] Save slot sync done")
            onTaskDone()
        end)
    end)

    -- Task 2: Shop purchase data (local load is instant, cloud sync is async)
    ShopManager.Load(function()
        print("[Standalone] Shop data sync done")
        onTaskDone()
    end)
end

function ShowMenu()
    gamePhase_ = "menu"
    -- Keep NanoVG alive for animated menu background
    if not vg_ then
        SetupNanoVG()
    end
    EnsureUIInit()

    -- Auto-preload cloud saves as soon as we enter the menu
    PreloadCloudSync()

    StartPage.Show({
        onBattle = function()
            StartGame()
        end,
        onMultiplayer = function()
            -- TODO: multiplayer not implemented yet
            print("[Standalone] Multiplayer not implemented")
        end,
        onCultivation = function()
            ShowCultivation()
        end,
        onBattleRoyale = function()
            StartBattleRoyale()
        end,
        onBreeding = function()
            ShowBreedingSaveSlotPopup()
        end,
        onShop = function()
            EnsureUIInit()
            ShopModal.Open()
        end,
        onSettings = function()
            EnsureUIInit()
            SettingsModal.Open()
        end,
    })
end

function StartBattleRoyale()
    StartPage.Hide()
    if not vg_ then SetupNanoVG() end
    playerCustom_ = BallCustomization.Load()
    gamePhase_ = "battle_royale"
    BattleRoyale.Init(playerCustom_, function()
        -- onGameEnd callback: return to menu
        ShowMenu()
    end)
    -- Minimal UI root (all HUD drawn by BattleRoyale via NanoVG)
    UI.SetRoot(UI.Panel { width = "100%", height = "100%" })
    print("[Standalone] Battle Royale started!")
end

function ShowBreeding(isNewSave)
    StartPage.Hide()
    if not vg_ then SetupNanoVG() end
    -- 先显示加载屏幕，预加载完成后再进入养殖页
    gamePhase_ = "breeding_loading"
    UI.SetRoot(UI.Panel { width = "100%", height = "100%" })
    BreedingLoadingScreen.Show(vg_, fontNormal_, function()
        -- 加载完成回调：切换到正式养殖页
        gamePhase_ = "breeding"
        BreedingPage.Show({
            onBack = function()
                BreedingPage.Hide()
                -- TutorialMascot.Dismiss()
                ShowMenu()
            end,
            onBallDroppedToSlot = function(slotIdx)
                -- TutorialSystem.OnBallDroppedToSlot(slotIdx)
            end,
            onBattleFinished = function(slotIdx)
                -- TutorialSystem.OnBattleFinished(slotIdx)
            end,
            onBallReturnedToFarm = function(slotIdx, farmBall)
                -- TutorialSystem.OnBallReturnedToFarm(slotIdx, farmBall)
            end,
            onFirstBallDroppedToArena = function()
                -- TutorialSystem.OnFirstBallDroppedToArena()
            end,
            scene = scene_,
        })
        -- 无论新旧存档，都注入存档回调，确保教程进度变化能触发存档
        -- TutorialSystem.SetSaveCallback(function()
        --     BreedingPage.ForceSave()
        -- end)
        -- 注入擂台赛教程控制回调
        -- TutorialSystem.SetArenaTutorialCallbacks({
        --     pauseCountdown = function()
        --         ArenaBattle.PauseCountdown()
        --     end,
        --     resumeCountdown = function()
        --         ArenaBattle.ResumeCountdown()
        --     end,
        --     setItemBarGlow = function(enabled)
        --         ArenaBattle.SetItemBarGlow(enabled)
        --     end,
        --     unlockFreeItems = function()
        --         local itemDefs = require("game.ItemSystem").DEFS
        --         local unlocked = 0
        --         for i = 1, math.min(3, #itemDefs) do
        --             local ok = ShopManager.UnlockItemFree(itemDefs[i].id)
        --             if ok then
        --                 unlocked = unlocked + 1
        --                 print(string.format("[Tutorial] 赠送道具: %s", itemDefs[i].name))
        --             end
        --         end
        --         print(string.format("[Tutorial] 共赠送 %d 个道具", unlocked))
        --     end,
        --     hasAnyItem = function()
        --         local itemDefs = require("game.ItemSystem").DEFS
        --         for i = 1, #itemDefs do
        --             if ShopManager.HasItem(itemDefs[i].id) then
        --                 return true
        --             end
        --         end
        --         return false
        --     end,
        -- })
        -- 新存档：显示教程引导吉祥物
        -- if isNewSave then
        --     TutorialMascot.Show(
        --         function()  -- 需要教学
        --             print("[Tutorial] 玩家选择需要教学，开始教程")
        --             TutorialSystem.Start(function()
        --                 print("[Tutorial] 教程全部完成")
        --                 BreedingPage.ForceSave()
        --             end)
        --         end,
        --         function()  -- 不需要教学（永久禁用此存档所有教程）
        --             print("[Tutorial] 玩家永久跳过教学")
        --             TutorialSystem.DeclineAllTutorials()
        --         end
        --     )
        -- end
        print("[Standalone] Breeding page opened after preload! isNew=" .. tostring(isNewSave))
    end)
    print("[Standalone] Breeding loading screen shown!")
end

function ShowCultivation()
    gamePhase_ = "cultivation"
    StartPage.Hide()
    -- Destroy NanoVG to free memory in pure-UI page
    if vg_ then
        nvgDelete(vg_)
        vg_ = nil
        fontNormal_ = -1
    end
    local data = BallCustomization.Load()
    CultivationPage.Show(data, {
        onChanged = function(newData)
            BallCustomization.Save(newData)
            playerCustom_ = newData
            print("[Standalone] Customization auto-saved")
        end,
        onBack = function()
            ShowMenu()
        end,
    })
end

function ShowGameUI()
    -- All battle HUD is drawn via NanoVG for pixel-perfect layout
    UI.SetRoot(UI.Panel { width = "100%", height = "100%" })
end

-- ============================================================================
-- Bottom Bar Layout Constants (design coords relative to arena)
-- ============================================================================

local BOTTOM_BAR = {
    height      = 55,
    btnW        = 140,
    btnH        = 42,
    slotSize    = 52,
    slotGap     = 12,
    slotCount   = 3,
    labelH      = 20,   -- "道具栏" label height
}

-- Convert screen pixel position to design coords (inside nvg transform)
local function ScreenToDesign(sx, sy)
    local dx = sx / dpr / nvgScale_ - designOffsetX
    local dy = sy / dpr / nvgScale_ - designOffsetY
    return dx, dy
end

-- ============================================================================
-- Item Drag & NanoVG Button Input
-- ============================================================================

function ProcessItemAndButtonInput()
    local S = arenaScale_
    local px = arenaX_
    local pw = arenaDrawSize_

    -- Scaled BOTTOM_BAR dimensions (must match DrawBottomBar)
    local btnW     = BOTTOM_BAR.btnW * S
    local btnH     = BOTTOM_BAR.btnH * S
    local slotSize = BOTTOM_BAR.slotSize * S
    local slotGap  = BOTTOM_BAR.slotGap * S
    local labelH   = BOTTOM_BAR.labelH * S
    local height   = BOTTOM_BAR.height * S

    -- Item slot geometry (same as DrawBottomBar)
    local totalSlotsW = BOTTOM_BAR.slotCount * slotSize + (BOTTOM_BAR.slotCount - 1) * slotGap
    local slotsX = px + (pw - totalSlotsW) / 2
    local slotsY = bottomBarY_ + labelH

    -- Button geometry (same as DrawBottomBar)
    local lbx = px - btnW - 20 * S
    local lby = bottomBarY_ + (height - btnH) / 2
    local rbx = px + pw + 20 * S
    local rby = lby

    -- Get mouse in design coords
    local mousePos = input.mousePosition
    local mx, my = ScreenToDesign(mousePos.x, mousePos.y)

    -- Helper: point inside rect
    local function HitRect(x, y, rx, ry, rw, rh)
        return x >= rx and x <= rx + rw and y >= ry and y <= ry + rh
    end

    -- === Mouse press: start drag or click button ===
    if input:GetMouseButtonPress(MOUSEB_LEFT) then
        -- Check item slots
        for slot = 1, BOTTOM_BAR.slotCount do
            local sx = slotsX + (slot - 1) * (slotSize + slotGap)
            if HitRect(mx, my, sx, slotsY, slotSize, slotSize) then
                if not ItemSystem.IsUnlocked(slot) then
                    print(string.format("[Standalone] Slot %d is locked, need to purchase first", slot))
                elseif ItemSystem.IsReady(slot) then
                    dragItem_ = { slot = slot, startX = mx, startY = my, curX = mx, curY = my }
                end
                return  -- consumed
            end
        end

        -- Check "返回主页" button
        if HitRect(mx, my, lbx, lby, btnW, btnH) then
            ShowMenu()
            return
        end

        -- Check "AI托管" button
        if HitRect(mx, my, rbx, rby, btnW, btnH) then
            isAIProxy_ = not isAIProxy_
            return
        end
    end

    -- === Mouse move: update drag position ===
    if dragItem_ then
        dragItem_.curX = mx
        dragItem_.curY = my
    end

    -- === Mouse release: place item or cancel drag ===
    if dragItem_ and not input:GetMouseButtonDown(MOUSEB_LEFT) then
        -- Check if released over arena (convert design coords → arena-local 0..400)
        local ax = (mx - arenaX_) / S
        local ay = (my - arenaY_) / S
        local baseSize = Settings.Arena.Size
        if ax >= 0 and ax <= baseSize and ay >= 0 and ay <= baseSize then
            ItemSystem.Place(dragItem_.slot, ax, ay)
        end
        dragItem_ = nil
    end
end

-- ============================================================================
-- Game Init
-- ============================================================================

function StartGame()
    StartPage.Hide()
    -- NanoVG should already be alive from menu, ensure it exists
    if not vg_ then
        SetupNanoVG()
    end

    local size = Settings.Arena.Size

    playerCustom_ = BallCustomization.Load()
    aiCustom_ = BallCustomization.Randomize()

    -- Create per-ball triangle fills
    for team = 1, 2 do
        local c = (team == 1) and playerCustom_.color or aiCustom_.color
        ballTriFills_[team] = TriangleFill.new({
            maxTriangles = 16,
            spawnRate    = 32,
            triLife      = 0.5,
            maxAlpha     = 110,
            sizeMin      = 3,
            sizeMax      = 10,
            colorOffset  = 25,
            baseColor    = { c.r, c.g, c.b },
        })
    end

    for team = 1, 2 do
        local sp = Settings.SpawnPoints[team]
        local angle = math.random() * 2 * math.pi
        balls_[team] = {
            x = sp.x + size / 2,
            y = sp.y + size / 2,
            vx = math.cos(angle) * BALL.InitialSpeed,
            vy = math.sin(angle) * BALL.InitialSpeed,
            hp = BALL.MaxHP,
            knockbackTimer = 0,
            pendingWallSlamDmg = 0,
            slowTimer = 0,
            slowFactor = 1.0,
            stunTimer = 0,
            frozenTimer = 0,
            frozenImmobile = false,
            frozenCollisionDmg = 0,
        }
        aiStates_[team] = BallAI.CreateState()
    end

    cooldowns_ = {
        { normal = 0, enhanced = 0, ultimate = 0 },
        { normal = 0, enhanced = 0, ultimate = 0 },
    }
    collisionCooldown_ = 0
    gameWinner_ = 0
    gameOverTimer_ = 0
    lastTier_ = { "normal", "normal" }
    tierFlash_ = { 0, 0 }

    damagePopups_ = {}
    particles_ = {}
    announcement_ = { text = "", timer = 0, duration = 0, color = {255,255,255,255} }
    shake_ = { intensity = 0, duration = 0, elapsed = 0, ox = 0, oy = 0 }

    SkillExecutor.Clear()
    ItemSystem.Init()
    dragItem_ = nil

    gamePhase_ = "playing"
    isAIProxy_ = false
    ShowGameUI()
    print("[Standalone] Game started!")
end

-- ============================================================================
-- Main Update
-- ============================================================================

function HandleUpdate(eventType, eventData)
    local dt = eventData:GetFloat("TimeStep")

    -- Background bubbles always update (all phases)
    BackgroundBubbles.Update(dt, screenDesignW, screenDesignH)

    -- Menu: update animated background
    if gamePhase_ == "menu" then
        StartPage.Update(dt)
        -- Update loading screen animation timer
        if loadingActive_ then
            loadingElapsed_ = loadingElapsed_ + dt
        end
        return
    end

    -- Battle Royale: delegate entirely to BattleRoyale module
    if gamePhase_ == "battle_royale" then
        BattleRoyale.Update(dt)
        -- Check if BR ended and phase was reset by callback
        return
    end

    -- Breeding loading screen: update animation + wait for preload
    if gamePhase_ == "breeding_loading" then
        BreedingLoadingScreen.Update(dt)
        return
    end

    -- Breeding: delegate to BreedingPage module
    if gamePhase_ == "breeding" then
        local mousePos = input.mousePosition
        local mx, my = ScreenToDesign(mousePos.x, mousePos.y)
        BreedingPage.Update(dt, mx, my)
        -- 教程系统更新（timer 步骤计时）
        -- if TutorialSystem.IsActive() then
        --     TutorialSystem.Update(dt)
        -- end
        -- 教程吉祥物更新（鼠标跟踪 + 动画）
        -- if TutorialMascot.IsActive() then
        --     TutorialMascot.Update(dt, mx, my, designW, designH)
        -- end
        -- 如果 UI 层有打开的弹窗（Modal/Confirm），阻止 NanoVG 自绘层接收点击
        local uiBlocked = (UI.GetTopOverlay() ~= nil)
        local pressed = (not uiBlocked) and input:GetMouseButtonPress(MOUSEB_LEFT) or false
        -- 教程吉祥物优先消耗点击
        -- if pressed and TutorialMascot.IsActive() then
        --     local consumed = TutorialMascot.ProcessInput(mx, my, pressed, designW, designH)
        --     if consumed then pressed = false end
        -- end
        BreedingPage.ProcessInput(mx, my, pressed)
        -- Continuous mouse tracking for drag-and-drop release detection
        local mouseDown = (not uiBlocked) and input:GetMouseButtonDown(MOUSEB_LEFT) or false
        BreedingPage.ProcessMouseRelease(mouseDown, mx, my)
        return
    end

    if gamePhase_ ~= "playing" and gamePhase_ ~= "gameover" then return end

    -- TAB toggle debug panel
    if debugToggleCooldown_ > 0 then debugToggleCooldown_ = debugToggleCooldown_ - dt end
    if input:GetKeyPress(KEY_TAB) and debugToggleCooldown_ <= 0 then
        debugShow_ = not debugShow_
        debugToggleCooldown_ = 0.3
    end

    -- Always update visual effects
    UpdateDamagePopups(dt)
    UpdateParticles(dt)
    UpdateScreenShake(dt)
    for team = 1, 2 do
        if ballTriFills_[team] then ballTriFills_[team]:Update(dt) end
    end
    for team = 1, 2 do
        for tier, cd in pairs(cooldowns_[team]) do
            if cd > 0 then cooldowns_[team][tier] = cd - dt end
        end
    end
    if announcement_.timer > 0 then announcement_.timer = announcement_.timer - dt end

    -- Tier transition flash
    for team = 1, 2 do
        if tierFlash_[team] > 0 then tierFlash_[team] = tierFlash_[team] - dt end
        if balls_[team] then
            local tier = BallAI.GetActiveTier(balls_[team].hp)
            if tier ~= lastTier_[team] then
                lastTier_[team] = tier
                tierFlash_[team] = 0.4
                ScreenShake(5, 0.2)
                local c = GetCustom(team).color
                SpawnParticleBurst(balls_[team].x, balls_[team].y, 20,
                    {c.r, c.g, c.b, 255}, 60, 200, 2, 5, 0.5)
                local tierName = TIER_NAMES[tier] or tier
                SetAnnouncement(
                    string.format("%s进入%s阶段!", team == 1 and "玩家" or "AI", tierName),
                    c.r, c.g, c.b)
            end
        end
    end

    if gamePhase_ == "gameover" then
        gameOverTimer_ = gameOverTimer_ + dt
        SkillExecutor.UpdateVisuals(dt, balls_)
        if gameOverTimer_ >= 4.0 then ShowMenu() end
        return
    end

    -- === PLAYING PHASE ===
    if collisionCooldown_ > 0 then collisionCooldown_ = collisionCooldown_ - dt end
    for team = 1, 2 do
        local b = balls_[team]
        if b.knockbackTimer > 0 then b.knockbackTimer = b.knockbackTimer - dt end
        if b.slowTimer > 0 then
            b.slowTimer = b.slowTimer - dt
            if b.slowTimer <= 0 then b.slowFactor = 1.0 end
        end
        if b.stunTimer > 0 then b.stunTimer = b.stunTimer - dt end
    end

    -- === Item drag & NanoVG button input ===
    ProcessItemAndButtonInput()

    -- Stun / freeze-immobile blocks shooting
    if (not balls_[1].stunTimer or balls_[1].stunTimer <= 0)
        and not ItemSystem.IsFrozenImmobile(balls_[1]) then
        ProcessInput(1, dt)
    end
    if (not balls_[2].stunTimer or balls_[2].stunTimer <= 0)
        and not ItemSystem.IsFrozenImmobile(balls_[2]) then
        ProcessInput(2, dt)
    end

    UpdateBallPhysics(dt)

    -- SkillExecutor update with callbacks
    local callbacks = {
        onHit = function(targetTeam, damage, kx, ky, projType, skillId, proj)
            local tgt = balls_[targetTeam]
            if not tgt then return end
            tgt.hp = tgt.hp - damage
            tgt.vx = tgt.vx + kx
            tgt.vy = tgt.vy + ky
            -- Beam / water_pillar wall slam setup
            if (projType == "beam") and proj then
                tgt.knockbackTimer = proj.knockbackWindow or 0.8
                tgt.pendingWallSlamDmg = proj.wallSlamDamage or 0
                -- Stun (水柱)
                if proj.stunDuration and proj.stunDuration > 0 then
                    tgt.stunTimer = proj.stunDuration
                end
            end
            -- Slow effect (水球)
            if proj and proj.slowFactor then
                tgt.slowTimer = proj.slowDuration or 2.0
                tgt.slowFactor = proj.slowFactor
            end
            local skillDef = SkillRegistry.Get(skillId)
            local c = skillDef and skillDef.color or {r=255,g=255,b=255}
            if damage > 0.1 then
                AddDamagePopup(tgt.x, tgt.y - BALL.Radius - 10, damage, c.r, c.g, c.b)
                SpawnDamageParticles(tgt.x, tgt.y, damage, GetCustom(targetTeam).color)
            end
            ScreenShake(math.min(damage, 8), 0.15)
            CheckGameOver()
        end,
        onDot = function(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            SkillExecutor.AddDot(targetTeam, sourceTeam, dotTotal, dotDuration, healTotal)
            ScreenShake(2, 0.1)
        end,
        onDotTick = function(targetTeam, sourceTeam, dmgT, healT)
            local tgt = balls_[targetTeam]
            local src = balls_[sourceTeam]
            if tgt then
                tgt.hp = tgt.hp - dmgT
                if dmgT > 0.1 then
                    AddDamagePopup(tgt.x, tgt.y - BALL.Radius, dmgT, 200, 80, 255)
                    SpawnDamageParticles(tgt.x, tgt.y, dmgT, GetCustom(targetTeam).color)
                end
            end
            if src and healT > 0 then
                src.hp = math.min(src.hp + healT, BALL.MaxHP)
                AddDamagePopup(src.x, src.y - BALL.Radius, healT, 80, 255, 120)
            end
            CheckGameOver()
        end,
        onSlow = function(targetTeam, factor, duration)
            local tgt = balls_[targetTeam]
            if tgt then
                tgt.slowTimer = math.max(tgt.slowTimer, duration)
                tgt.slowFactor = math.min(tgt.slowFactor, factor)
            end
        end,
        onStun = function(targetTeam, duration)
            local tgt = balls_[targetTeam]
            if tgt then
                tgt.stunTimer = math.max(tgt.stunTimer or 0, duration)
            end
        end,
    }
    SkillExecutor.Update(dt, balls_, callbacks)
    SkillExecutor.UpdateVisuals(dt, balls_)
    ItemSystem.Update(dt, balls_)
    CheckGameOver()
end

-- ============================================================================
-- Check Game Over
-- ============================================================================

function CheckGameOver()
    for team = 1, 2 do
        if balls_[team] and balls_[team].hp <= 0 then
            balls_[team].hp = 0
            gamePhase_ = "gameover"
            gameOverTimer_ = 0
            gameWinner_ = team == 1 and 2 or 1
            return true
        end
    end
    return false
end

-- ============================================================================
-- Process Input (AI controls both movement and shooting for all balls)
-- ============================================================================

function ProcessInput(team, dt)
    local ball = balls_[team]
    local opponent = balls_[team == 1 and 2 or 1]
    if not ball or not opponent then return end

    -- Find best available skill (highest priority tier, off cooldown)
    local skillDef, skillTier = GetBestAvailableSkill(team)

    local projSpeed = (skillDef and skillDef.projSpeed) or 500

    -- AI controls both movement and shooting for all balls
    local ai = BallAI.Update(aiStates_[team], ball, opponent, 0, projSpeed, dt)

    -- Apply AI movement: blend AI desired velocity into current velocity
    -- 冻结不动时跳过移动
    if not ItemSystem.IsFrozenImmobile(ball) then
        local lerpFactor = 0.15
        ball.vx = ball.vx + (ai.moveVX - ball.vx) * lerpFactor
        ball.vy = ball.vy + (ai.moveVY - ball.vy) * lerpFactor
    end

    -- AI shooting
    if ai.shoot and skillDef and skillTier then
        local otherTeam = team == 1 and 2 or 1
        local cd = SkillExecutor.Fire(skillDef, team, otherTeam, ball.x, ball.y, ai.aimX, ai.aimY)
        cooldowns_[team][skillTier] = cd
        SetAnnouncement(skillDef.name, skillDef.color.r, skillDef.color.g, skillDef.color.b)
    end
end

-- ============================================================================
-- Ball Physics (Pure: launch velocity → wall bounce → speed cap)
-- ============================================================================

function UpdateBallPhysics(dt)
    local size = Settings.Arena.Size
    local r = BALL.Radius

    for team = 1, 2 do
        local ball = balls_[team]

        -- Apply slow factor to effective movement
        local factor = ball.slowFactor
        ball.x = ball.x + ball.vx * factor * dt
        ball.y = ball.y + ball.vy * factor * dt

        -- Speed cap
        local spd = math.sqrt(ball.vx * ball.vx + ball.vy * ball.vy)
        if spd > BALL.SpeedCap then
            ball.vx = ball.vx * BALL.SpeedCap / spd
            ball.vy = ball.vy * BALL.SpeedCap / spd
        end

        -- Wall collision with bounce restitution
        local hitWall = false
        if ball.x - r < 0 then
            ball.x = r
            ball.vx = math.abs(ball.vx) * BALL.BounceRestitution
            hitWall = true
        elseif ball.x + r > size then
            ball.x = size - r
            ball.vx = -math.abs(ball.vx) * BALL.BounceRestitution
            hitWall = true
        end
        if ball.y - r < 0 then
            ball.y = r
            ball.vy = math.abs(ball.vy) * BALL.BounceRestitution
            hitWall = true
        elseif ball.y + r > size then
            ball.y = size - r
            ball.vy = -math.abs(ball.vy) * BALL.BounceRestitution
            hitWall = true
        end

        -- 冻结球撞墙：触发冻结碰撞伤害
        if hitWall and ItemSystem.IsFrozen(ball) then
            local fdmg = ItemSystem.OnFrozenCollision(ball)
            if fdmg and fdmg > 0 then
                AddDamagePopup(ball.x, ball.y - r - 10, fdmg, 100, 200, 255)
                SpawnDamageParticles(ball.x, ball.y, fdmg, GetCustom(team).color)
                ScreenShake(3, 0.1)
                CheckGameOver()
            end
        end

        -- Wall slam from beam knockback
        if ball.knockbackTimer > 0 and hitWall and ball.pendingWallSlamDmg > 0 then
            local dmg = ball.pendingWallSlamDmg
            ball.hp = ball.hp - dmg
            ball.knockbackTimer = 0
            ball.pendingWallSlamDmg = 0
            AddDamagePopup(ball.x, ball.y - r - 20, dmg, 255, 200, 50)
            SetAnnouncement("WALL SLAM!", 255, 200, 50)
            ScreenShake(8, 0.25)
            SpawnDamageParticles(ball.x, ball.y, dmg, GetCustom(team).color)
            CheckGameOver()
        end
    end

    -- Ball-ball elastic collision
    local b1, b2 = balls_[1], balls_[2]
    local dx, dy = b2.x - b1.x, b2.y - b1.y
    local dist = math.sqrt(dx * dx + dy * dy)
    if dist < r * 2 and dist > 0.01 then
        local nx, ny = dx / dist, dy / dist
        local ov = r * 2 - dist
        b1.x = b1.x - nx * ov * 0.5
        b1.y = b1.y - ny * ov * 0.5
        b2.x = b2.x + nx * ov * 0.5
        b2.y = b2.y + ny * ov * 0.5

        local dvx, dvy = b1.vx - b2.vx, b1.vy - b2.vy
        local dvDotN = dvx * nx + dvy * ny
        if dvDotN > 0 then
            b1.vx = b1.vx - dvDotN * nx
            b1.vy = b1.vy - dvDotN * ny
            b2.vx = b2.vx + dvDotN * nx
            b2.vy = b2.vy + dvDotN * ny

            if collisionCooldown_ <= 0 then
                local dmg = BALL.CollisionDamage
                b1.hp = b1.hp - dmg
                b2.hp = b2.hp - dmg
                collisionCooldown_ = 0.1
                AddDamagePopup(b1.x, b1.y - r, dmg, 255, 80, 80)
                AddDamagePopup(b2.x, b2.y - r, dmg, 255, 80, 80)
                SpawnDamageParticles(b1.x, b1.y, dmg, GetCustom(1).color)
                SpawnDamageParticles(b2.x, b2.y, dmg, GetCustom(2).color)

                -- 冻结球碰撞：解除不动状态 + 额外冻结伤害
                if ItemSystem.IsFrozen(b1) then
                    local fdmg = ItemSystem.OnFrozenCollision(b1)
                    if fdmg and fdmg > 0 then
                        AddDamagePopup(b1.x, b1.y - r - 15, fdmg, 100, 200, 255)
                    end
                end
                if ItemSystem.IsFrozen(b2) then
                    local fdmg = ItemSystem.OnFrozenCollision(b2)
                    if fdmg and fdmg > 0 then
                        AddDamagePopup(b2.x, b2.y - r - 15, fdmg, 100, 200, 255)
                    end
                end

                CheckGameOver()
            end
        end
    end
end

-- ============================================================================
-- Visual Effects
-- ============================================================================

function AddDamagePopup(x, y, damage, r, g, b)
    local isHeal = (g > 200 and r < 150)
    table.insert(damagePopups_, {
        x = x, y = y, damage = damage,
        color = { r, g, b, 255 },
        elapsed = 0, duration = POPUP.Duration,
        fontSize = math.min(POPUP.BaseFontSize + damage * POPUP.FontSizePerDmg, POPUP.MaxFontSize),
        shakeAmp = math.min(POPUP.BaseShake + damage * POPUP.ShakePerDmg, POPUP.MaxShake),
        isHeal = isHeal,
    })
    if damage >= 5 then ScreenShake(math.min(damage, 12), 0.2) end
end

function SetAnnouncement(text, r, g, b)
    announcement_.text = text
    announcement_.timer = 1.2
    announcement_.duration = 1.2
    announcement_.color = { r, g, b, 255 }
end

function SpawnParticleBurst(x, y, count, color, speedMin, speedMax, rMin, rMax, life)
    for _ = 1, count do
        local a = math.random() * 2 * math.pi
        local spd = speedMin + math.random() * (speedMax - speedMin)
        local radius = rMin + math.random() * (rMax - rMin)
        table.insert(particles_, {
            x = x, y = y,
            vx = math.cos(a) * spd, vy = math.sin(a) * spd,
            radius = radius, life = life or 0.5, maxLife = life or 0.5,
            color = { color[1], color[2], color[3], color[4] or 255 },
        })
    end
end

--- Spawn collidable damage particles scaled by damage amount
--- color: {r, g, b} table from ball customization
function SpawnDamageParticles(x, y, damage, color)
    -- Scale everything by damage — boosted ejection speed for impact feel
    local count    = math.floor(math.min(4 + damage * 3, 40))
    local rMin     = math.min(1.0 + damage * 0.25, 5)
    local rMax     = math.min(2.0 + damage * 0.5, 10)
    local speedMin = math.min(180 + damage * 40, 550)
    local speedMax = math.min(320 + damage * 55, 800)
    local life     = math.min(0.9 + damage * 0.08, 2.2)

    -- Slight color variation for visual richness
    local cr, cg, cb = color.r or color[1], color.g or color[2], color.b or color[3]

    local TRAIL_LEN = 6  -- trail positions to keep per particle

    for _ = 1, count do
        local a = math.random() * 2 * math.pi
        local spd = speedMin + math.random() * (speedMax - speedMin)
        local radius = rMin + math.random() * (rMax - rMin)
        -- Per-particle color jitter (±20)
        local jitter = math.random(-20, 20)
        local pr = math.max(0, math.min(255, cr + jitter))
        local pg = math.max(0, math.min(255, cg + jitter))
        local pb = math.max(0, math.min(255, cb + jitter))

        table.insert(particles_, {
            x = x, y = y,
            vx = math.cos(a) * spd, vy = math.sin(a) * spd,
            radius = radius,
            life = life + (math.random() - 0.5) * 0.3,
            maxLife = life,
            color = { pr, pg, pb, 255 },
            collidable = true,
            trail = {},           -- stores recent positions for tail rendering
            trailLen = TRAIL_LEN,
        })
    end
end

function UpdateDamagePopups(dt)
    local i = 1
    while i <= #damagePopups_ do
        local p = damagePopups_[i]
        p.elapsed = p.elapsed + dt
        p.y = p.y - POPUP.RiseSpeed * dt
        if p.elapsed >= p.duration then
            table.remove(damagePopups_, i)
        else
            i = i + 1
        end
    end
end

function UpdateParticles(dt)
    local arenaSize = Settings.Arena.Size
    local ballR = BALL.Radius
    local i = 1
    while i <= #particles_ do
        local p = particles_[i]
        p.life = p.life - dt
        if p.life <= 0 then
            table.remove(particles_, i)
        else
            -- Record trail position before moving (only for particles with trail)
            if p.trail then
                table.insert(p.trail, 1, { x = p.x, y = p.y })
                while #p.trail > (p.trailLen or 6) do
                    table.remove(p.trail)
                end
            end

            p.x = p.x + p.vx * dt
            p.y = p.y + p.vy * dt

            if p.collidable then
                local bounce = 0.65

                -- Wall collision (arena bounds)
                if p.x - p.radius < 0 then
                    p.x = p.radius
                    p.vx = math.abs(p.vx) * bounce
                elseif p.x + p.radius > arenaSize then
                    p.x = arenaSize - p.radius
                    p.vx = -math.abs(p.vx) * bounce
                end
                if p.y - p.radius < 0 then
                    p.y = p.radius
                    p.vy = math.abs(p.vy) * bounce
                elseif p.y + p.radius > arenaSize then
                    p.y = arenaSize - p.radius
                    p.vy = -math.abs(p.vy) * bounce
                end

                -- Ball collision
                for team = 1, 2 do
                    local ball = balls_[team]
                    if ball then
                        local dx = p.x - ball.x
                        local dy = p.y - ball.y
                        local dist = math.sqrt(dx * dx + dy * dy)
                        local minDist = ballR + p.radius
                        if dist < minDist and dist > 0.01 then
                            -- Push particle out of ball
                            local nx, ny = dx / dist, dy / dist
                            p.x = ball.x + nx * minDist
                            p.y = ball.y + ny * minDist
                            -- Reflect velocity off ball surface
                            local dotVN = p.vx * nx + p.vy * ny
                            if dotVN < 0 then
                                p.vx = (p.vx - 2 * dotVN * nx) * 0.55
                                p.vy = (p.vy - 2 * dotVN * ny) * 0.55
                            end
                            -- Inherit some ball velocity
                            p.vx = p.vx + ball.vx * 0.15
                            p.vy = p.vy + ball.vy * 0.15
                        end
                    end
                end

                -- Stronger drag for collidable particles (simulate friction)
                p.vx = p.vx * 0.94
                p.vy = p.vy * 0.94
            else
                p.vx = p.vx * 0.96
                p.vy = p.vy * 0.96
            end

            i = i + 1
        end
    end
end

function ScreenShake(intensity, duration)
    shake_.intensity = math.max(shake_.intensity, intensity)
    shake_.duration = math.max(shake_.duration, duration)
    shake_.elapsed = 0
end

function UpdateScreenShake(dt)
    if shake_.duration > 0 then
        shake_.elapsed = shake_.elapsed + dt
        if shake_.elapsed >= shake_.duration then
            shake_.duration = 0; shake_.intensity = 0; shake_.ox = 0; shake_.oy = 0
        else
            local t = 1 - shake_.elapsed / shake_.duration
            local amp = shake_.intensity * t
            shake_.ox = (math.random() * 2 - 1) * amp
            shake_.oy = (math.random() * 2 - 1) * amp
        end
    end
end

-- ============================================================================
-- NanoVG Rendering
-- ============================================================================

-- ============================================================================
-- Loading Screen Overlay
-- ============================================================================

function DrawLoadingScreen(w, h)
    local vg = vg_
    local t = loadingElapsed_

    -- Semi-transparent dark overlay
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, w, h)
    nvgFillColor(vg, nvgRGBA(5, 5, 15, 200))
    nvgFill(vg)

    local cx = w / 2
    local cy = h / 2 - 30

    -- Spinning dots ring
    local dotCount = 8
    local ringRadius = 40
    local dotRadius = 6
    for i = 0, dotCount - 1 do
        local angle = (i / dotCount) * math.pi * 2 - t * 3
        local dx = cx + math.cos(angle) * ringRadius
        local dy = cy + math.sin(angle) * ringRadius
        -- Fade: leading dot is brightest
        local alpha = math.floor(60 + 195 * ((i + 1) / dotCount))
        local pulse = 1.0 + 0.2 * math.sin(t * 4 + i * 0.5)
        nvgBeginPath(vg)
        nvgCircle(vg, dx, dy, dotRadius * pulse)
        nvgFillColor(vg, nvgRGBA(100, 180, 255, alpha))
        nvgFill(vg)
    end

    -- Bouncing ball in center
    local ballBounce = math.abs(math.sin(t * 2.5)) * 12
    local ballCY = cy - ballBounce
    local ballR = 16
    -- Ball gradient
    local innerC = nvgRGBA(255, 200, 80, 255)
    local outerC = nvgRGBA(220, 140, 30, 255)
    local grad = nvgRadialGradient(vg, cx - 3, ballCY - 4, 2, ballR, innerC, outerC)
    nvgBeginPath(vg)
    nvgCircle(vg, cx, ballCY, ballR)
    nvgFillPaint(vg, grad)
    nvgFill(vg)
    -- Highlight
    nvgBeginPath(vg)
    nvgCircle(vg, cx - 4, ballCY - 5, 5)
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 100))
    nvgFill(vg)
    -- Shadow
    if ballBounce < 2 then
        local shadowAlpha = math.floor(60 * (1 - ballBounce / 12))
        nvgBeginPath(vg)
        nvgEllipse(vg, cx, cy + 4, ballR * 0.8, 3)
        nvgFillColor(vg, nvgRGBA(0, 0, 0, shadowAlpha))
        nvgFill(vg)
    end

    -- Loading text
    nvgFontFace(vg, "sans")
    nvgFontSize(vg, 28)
    nvgTextAlign(vg, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    -- Animated dots
    local dotAnim = math.floor(t * 2) % 4
    local dots = string.rep(".", dotAnim)
    local displayText = loadingText_ .. dots
    -- Text shadow
    nvgFillColor(vg, nvgRGBA(0, 0, 0, 180))
    nvgText(vg, cx + 2, cy + 62, displayText, nil)
    -- Text
    nvgFillColor(vg, nvgRGBA(220, 230, 255, 240))
    nvgText(vg, cx, cy + 60, displayText, nil)

    -- Subtle hint at bottom
    nvgFontSize(vg, 16)
    nvgFillColor(vg, nvgRGBA(150, 160, 180, math.floor(120 + 60 * math.sin(t * 1.5))))
    nvgText(vg, cx, cy + 100, "首次加载可能需要几秒钟", nil)
end

function DoNanoVGRender()
    nvgScale(vg_, nvgScale_, nvgScale_)

    -- Background
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
    nvgFillColor(vg_, nvgRGBA(8, 8, 14, 255)); nvgFill(vg_)

    -- Background bubbles
    BackgroundBubbles.Draw(vg_)

    -- Tier flash overlay
    for team = 1, 2 do
        if tierFlash_[team] > 0 then
            local c = GetCustom(team).color
            local a = math.floor(120 * (tierFlash_[team] / 0.4))
            nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
            nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, a)); nvgFill(vg_)
        end
    end

    nvgTranslate(vg_, designOffsetX, designOffsetY)
    nvgSave(vg_)
    nvgTranslate(vg_, shake_.ox, shake_.oy)

    -- ====== Adaptive layout ======
    -- Compute available space and derive arena scale factor
    local baseArenaSize = Settings.Arena.Size   -- logical 400
    local baseTitleH = 55
    local baseInfoH  = 100
    local baseBottomH = BOTTOM_BAR.height + BOTTOM_BAR.labelH
    local baseGap    = 8
    local baseTotalH = baseTitleH + baseGap + baseArenaSize + baseGap + baseInfoH + baseGap + baseBottomH

    -- Scale factor: fit everything vertically with 8px margin
    local vertScale = (designH - 16) / baseTotalH
    -- Also ensure arena + side buttons fit horizontally
    -- Side buttons need: btnW + 20 gap on each side
    local sideMargin = BOTTOM_BAR.btnW + 30  -- btn + gap
    local horizScale = (designW - sideMargin * 2) / baseArenaSize
    -- Use the smaller scale, clamped to max 1.0 (don't enlarge beyond base design)
    arenaScale_ = math.min(vertScale, horizScale, 1.0)
    arenaScale_ = math.max(arenaScale_, 0.3)  -- safety min

    local S = arenaScale_
    arenaDrawSize_ = baseArenaSize * S
    local titleH  = baseTitleH * S
    local infoH   = baseInfoH * S
    local bottomH = baseBottomH * S
    local gap     = baseGap * S
    local totalH  = titleH + gap + arenaDrawSize_ + gap + infoH + gap + bottomH
    local startY  = math.max(4, (designH - totalH) / 2)

    arenaX_ = (designW - arenaDrawSize_) / 2
    arenaY_ = startY + titleH + gap
    local infoY = arenaY_ + arenaDrawSize_ + gap
    bottomBarY_ = infoY + infoH + gap

    DrawTitle(designW, startY)

    -- Arena border (scaled)
    nvgBeginPath(vg_); nvgRect(vg_, arenaX_, arenaY_, arenaDrawSize_, arenaDrawSize_)
    nvgStrokeColor(vg_, nvgRGBA(180, 180, 180, 120)); nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)

    -- Draw arena contents inside a scaled transform
    -- All arena-local coordinates (0..400) are mapped to (arenaX_, arenaY_) .. (arenaX_+arenaDrawSize_)
    nvgSave(vg_)
    nvgTranslate(vg_, arenaX_, arenaY_)
    nvgScale(vg_, S, S)
    -- Now drawing in arena-local coords: 0..baseArenaSize
    SkillExecutor.Draw(vg_, 0, 0)
    ItemSystem.Draw(vg_, 0, 0, fontNormal_)
    DrawParticles()
    DrawBalls()
    DrawDamagePopups()
    DrawAnnouncement()
    nvgRestore(vg_)

    -- HUD panels (outside arena transform, use arenaScale_ for sizing)
    DrawInfoPanel(designW, infoY)
    DrawBottomBar(designW)
    DrawDragItem()

    nvgRestore(vg_)

    if gamePhase_ == "gameover" then DrawGameOver(designW, designH) end
    DrawDebugPanel()
end

function HandleNanoVGRender(eventType, eventData)
    if not vg_ then return end
    if nvgScale_ <= 0 or logicalW <= 0 or logicalH <= 0 then return end

    -- Menu: render animated start page background
    if gamePhase_ == "menu" then
        nvgBeginFrame(vg_, logicalW, logicalH, dpr)
        local ok, err = pcall(function()
            nvgScale(vg_, nvgScale_, nvgScale_)
            StartPage.Render(vg_, screenDesignW, screenDesignH, fontNormal_)
            -- Loading screen overlay (drawn on top of start page)
            if loadingActive_ then
                DrawLoadingScreen(screenDesignW, screenDesignH)
            end
        end)
        nvgEndFrame(vg_)
        if not ok then
            print("[Standalone] Menu render error: " .. tostring(err))
        end
        return
    end

    -- Battle Royale: render via BattleRoyale module
    if gamePhase_ == "battle_royale" then
        nvgBeginFrame(vg_, logicalW, logicalH, dpr)
        local ok, err = pcall(function()
            nvgScale(vg_, nvgScale_, nvgScale_)

            -- Background
            nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
            nvgFillColor(vg_, nvgRGBA(8, 8, 14, 255)); nvgFill(vg_)
            BackgroundBubbles.Draw(vg_)

            nvgTranslate(vg_, designOffsetX, designOffsetY)

            -- Compute arena layout (same logic as normal mode)
            local baseArenaSize = Settings.BattleRoyale.ViewportSize  -- viewport 600 for layout
            local baseTitleH = 30
            local baseGap = 6
            local vertScale = (designH - 16) / (baseTitleH + baseGap + baseArenaSize + 50)
            local sideMargin = 160
            local horizScale = (designW - sideMargin * 2) / baseArenaSize
            local brScale = math.min(vertScale, horizScale, 1.0)
            brScale = math.max(brScale, 0.3)

            local aDS = baseArenaSize * brScale
            local aX = (designW - aDS) / 2
            local aY = baseTitleH * brScale + baseGap * brScale + 8

            -- Arena border
            nvgBeginPath(vg_); nvgRect(vg_, aX, aY, aDS, aDS)
            nvgStrokeColor(vg_, nvgRGBA(180, 180, 180, 100))
            nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)

            BattleRoyale.Draw(vg_, fontNormal_, designW, designH,
                aX, aY, aDS, brScale,
                nvgScale_, dpr, designOffsetX)
        end)
        nvgEndFrame(vg_)
        if not ok then
            print("[Standalone] BR render error: " .. tostring(err))
        end
        return
    end

    -- Breeding loading screen: render preload animation
    if gamePhase_ == "breeding_loading" then
        nvgBeginFrame(vg_, logicalW, logicalH, dpr)
        local ok, err = pcall(function()
            nvgScale(vg_, nvgScale_, nvgScale_)
            nvgTranslate(vg_, designOffsetX, designOffsetY)
            BreedingLoadingScreen.Render(designW, designH)
        end)
        nvgEndFrame(vg_)
        if not ok then
            print("[Standalone] Loading screen render error: " .. tostring(err))
        end
        return
    end

    -- Breeding: render via BreedingPage module
    if gamePhase_ == "breeding" then
        nvgBeginFrame(vg_, logicalW, logicalH, dpr)
        local ok, err = pcall(function()
            nvgScale(vg_, nvgScale_, nvgScale_)
            -- Background: full-screen image cover (eliminates black bars)
            if breedingBgImg_ and breedingBgImg_ > 0 then
                -- Cover fill: scale image to cover entire screen, center crop
                local imgW, imgH = nvgImageSize(vg_, breedingBgImg_)
                local coverScale = math.max(screenDesignW / imgW, screenDesignH / imgH)
                local drawW = imgW * coverScale
                local drawH = imgH * coverScale
                local drawX = (screenDesignW - drawW) / 2
                local drawY = (screenDesignH - drawH) / 2
                local bgPat = nvgImagePattern(vg_, drawX, drawY, drawW, drawH, 0, breedingBgImg_, 1.0)
                nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
                nvgFillPaint(vg_, bgPat); nvgFill(vg_)
            else
                nvgBeginPath(vg_); nvgRect(vg_, 0, 0, screenDesignW, screenDesignH)
                nvgFillColor(vg_, nvgRGBA(100, 160, 60, 255)); nvgFill(vg_)
            end
            nvgTranslate(vg_, designOffsetX, designOffsetY)
            BreedingPage.Render(vg_, designW, designH, fontNormal_)
            -- 教程吉祥物渲染（叠加在养殖页最顶层）
            -- if TutorialMascot.IsActive() then
            --     TutorialMascot.Render(vg_, designW, designH, fontNormal_)
            -- end
        end)
        nvgEndFrame(vg_)
        if not ok then
            print("[Standalone] Breeding render error: " .. tostring(err))
        end
        return
    end

    if gamePhase_ ~= "playing" and gamePhase_ ~= "gameover" then return end
    if not balls_[1] then return end

    nvgBeginFrame(vg_, logicalW, logicalH, dpr)
    local ok, err = pcall(DoNanoVGRender)
    nvgEndFrame(vg_)

    if not ok then
        print("[Standalone] Render error: " .. tostring(err))
    end
end

-- ============================================================================
-- Draw: Title (player VS AI with custom colors)
-- ============================================================================

function DrawTitle(w, y)
    if fontNormal_ == -1 then return end
    local S = arenaScale_
    local centerX = w / 2
    local titleY = y + 28 * S

    nvgFontFaceId(vg_, fontNormal_)

    -- Player name (yellow-ish, bold, left of VS)
    nvgFontSize(vg_, 38 * S)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
    nvgText(vg_, centerX - 38 * S, titleY + 2 * S, "玩家ID", nil)
    nvgFillColor(vg_, nvgRGBA(255, 220, 50, 255))
    nvgText(vg_, centerX - 36 * S, titleY, "玩家ID", nil)

    -- VS (white, slightly smaller)
    nvgFontSize(vg_, 30 * S)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 255))
    nvgText(vg_, centerX, titleY, "VS", nil)

    -- Enemy name (red, bold, right of VS)
    nvgFontSize(vg_, 38 * S)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
    nvgText(vg_, centerX + 38 * S, titleY + 2 * S, "随机ID", nil)
    nvgFillColor(vg_, nvgRGBA(255, 70, 50, 255))
    nvgText(vg_, centerX + 36 * S, titleY, "随机ID", nil)
end

-- ============================================================================
-- Draw: Balls (custom color + expression face + HP bar)
-- ============================================================================

function DrawBalls()
    local r = BALL.Radius
    local elapsedTime = time.elapsedTime

    for team = 1, 2 do
        local ball = balls_[team]
        local custom = GetCustom(team)
        local c = custom.color
        -- Arena contents now drawn inside nvgTranslate(arenaX_, arenaY_) + nvgScale(S)
        -- so use raw arena-local coords directly
        local bx, by = ball.x, ball.y

        -- Tier-based aura
        local tier = BallAI.GetActiveTier(ball.hp)
        if tier == "ultimate" then
            local pulseR = r + 8 + math.sin(elapsedTime * 5) * 4
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, pulseR)
            nvgFillPaint(vg_, nvgRadialGradient(vg_, bx, by, r, pulseR,
                nvgRGBA(c.r, c.g, c.b, math.floor(60 + 40 * math.sin(elapsedTime * 4))),
                nvgRGBA(c.r, c.g, c.b, 0)))
            nvgFill(vg_)
        elseif tier == "enhanced" then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 4)
            nvgStrokeColor(vg_, nvgRGBA(c.r, c.g, c.b, math.floor(60 + 30 * math.sin(elapsedTime * 3))))
            nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
        end

        -- Ball body (flat solid color)
        nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r)
        nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 255)); nvgFill(vg_)

        -- Triangle fill inside ball (scissor-clipped, no opaque mask)
        if ballTriFills_[team] then
            nvgSave(vg_)
            nvgIntersectScissor(vg_, bx - r, by - r, r * 2, r * 2)
            ballTriFills_[team]:RenderCircle(vg_, bx, by, r)
            nvgRestore(vg_)
        end

        -- Expression face
        Expressions.Draw(vg_, custom.expression, bx, by, r)

        -- HP bar above ball
        local hpBarW = r * 2.4
        local hpBarH = 4
        local hpBarX = bx - hpBarW / 2
        local hpBarY = by - r - 12
        local hpPct = math.max(0, ball.hp / BALL.MaxHP)

        nvgBeginPath(vg_); nvgRoundedRect(vg_, hpBarX, hpBarY, hpBarW, hpBarH, 2)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 150)); nvgFill(vg_)
        if hpPct > 0 then
            local hr = hpPct < 0.5 and 255 or math.floor(255 * (1 - hpPct) * 2)
            local hg = hpPct > 0.5 and 255 or math.floor(255 * hpPct * 2)
            nvgBeginPath(vg_); nvgRoundedRect(vg_, hpBarX, hpBarY, hpBarW * hpPct, hpBarH, 2)
            nvgFillColor(vg_, nvgRGBA(hr, hg, 80, 220)); nvgFill(vg_)
        end

        -- HP number
        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 11)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_BOTTOM)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
        nvgText(vg_, bx, hpBarY - 2, tostring(math.floor(ball.hp)), nil)

        -- Player indicator
        if team == 1 then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 3)
            nvgStrokeColor(vg_, nvgRGBA(255, 255, 0, math.floor(120 + 60 * math.sin(elapsedTime * 4))))
            nvgStrokeWidth(vg_, 2); nvgStroke(vg_)
        end

        -- Slow debuff indicator
        if ball.slowTimer > 0 then
            nvgBeginPath(vg_); nvgCircle(vg_, bx, by, r + 2)
            nvgStrokeColor(vg_, nvgRGBA(120, 255, 50, 120))
            nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)
        end

        -- Freeze overlay (冻结覆盖效果)
        ItemSystem.DrawFreezeOverlay(vg_, ball, bx, by, r, 1.0)

        -- Stun indicator (旋转星星)
        if ball.stunTimer and ball.stunTimer > 0 then
            local starCount = 3
            for si = 1, starCount do
                local sa = elapsedTime * 4 + (si - 1) * (2 * math.pi / starCount)
                local sx = bx + math.cos(sa) * (r + 6)
                local sy = by - r - 8 + math.sin(sa) * 4
                nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 12)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg_, nvgRGBA(255, 255, 100, 220))
                nvgText(vg_, sx, sy, "*", nil)
            end
        end
    end
end

-- ============================================================================
-- Draw: Particles
-- ============================================================================

function DrawParticles()
    for _, p in ipairs(particles_) do
        local t = p.life / p.maxLife
        local r = p.radius * (0.5 + 0.5 * t)
        -- Now drawn in arena-local coords (nvgTranslate already applied)
        local px, py = p.x, p.y
        local alpha = math.floor(p.color[4] * t)
        local cr, cg, cb = p.color[1], p.color[2], p.color[3]

        if p.collidable and r > 1.5 then
            -- === Trail rendering for damage particles ===
            if p.trail and #p.trail > 1 then
                -- Draw trail as tapered line segments from tail to head
                for j = #p.trail, 2, -1 do
                    local ratio = 1 - (j - 1) / #p.trail  -- 0 at tail, ~1 near head
                    local segAlpha = math.floor(alpha * ratio * 0.6)
                    local segR = r * (0.15 + 0.55 * ratio)
                    if segAlpha > 2 and segR > 0.3 then
                        local tx1 = p.trail[j].x
                        local ty1 = p.trail[j].y
                        local tx2 = p.trail[j - 1].x
                        local ty2 = p.trail[j - 1].y
                        nvgBeginPath(vg_)
                        nvgMoveTo(vg_, tx1, ty1)
                        nvgLineTo(vg_, tx2, ty2)
                        nvgLineCap(vg_, NVG_ROUND)
                        nvgStrokeWidth(vg_, segR * 2)
                        nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, segAlpha))
                        nvgStroke(vg_)
                    end
                end
                -- Connect last trail point to current position
                local lastT = p.trail[1]
                nvgBeginPath(vg_)
                nvgMoveTo(vg_, lastT.x, lastT.y)
                nvgLineTo(vg_, px, py)
                nvgLineCap(vg_, NVG_ROUND)
                nvgStrokeWidth(vg_, r * 1.4)
                nvgStrokeColor(vg_, nvgRGBA(cr, cg, cb, math.floor(alpha * 0.7)))
                nvgStroke(vg_)
            end

            -- Outer glow for collidable damage particles
            local glowR = r * 2.2
            local glowAlpha = math.floor(alpha * 0.3)
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, glowR)
            nvgFillPaint(vg_, nvgRadialGradient(vg_, px, py, r * 0.5, glowR,
                nvgRGBA(cr, cg, cb, glowAlpha), nvgRGBA(cr, cg, cb, 0)))
            nvgFill(vg_)

            -- Bright core
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, r)
            nvgFillColor(vg_, nvgRGBA(cr, cg, cb, alpha)); nvgFill(vg_)

            -- White hot center for large particles
            if r > 3 then
                local coreR = r * 0.4
                local coreAlpha = math.floor(alpha * 0.6)
                nvgBeginPath(vg_); nvgCircle(vg_, px, py, coreR)
                nvgFillColor(vg_, nvgRGBA(255, 255, 255, coreAlpha)); nvgFill(vg_)
            end
        else
            -- Simple circle for decorative particles
            nvgBeginPath(vg_); nvgCircle(vg_, px, py, r)
            nvgFillColor(vg_, nvgRGBA(cr, cg, cb, alpha)); nvgFill(vg_)
        end
    end
end

-- ============================================================================
-- Draw: Damage Popups
-- ============================================================================

function DrawDamagePopups()
    if fontNormal_ == -1 then return end
    for _, p in ipairs(damagePopups_) do
        local t = p.elapsed / p.duration
        local alpha = 255
        if t > 0.7 then alpha = math.floor(255 * (1 - (t - 0.7) / 0.3)) end
        if alpha <= 0 then goto continue end

        local sm = 1.0
        if p.elapsed < POPUP.ScalePunchTime then
            sm = 1.0 + (POPUP.ScalePunchAmount - 1.0) * math.sin(p.elapsed / POPUP.ScalePunchTime * math.pi)
        end
        local fs = p.fontSize * sm
        local dc = 1 - t
        local sx = p.shakeAmp * dc * math.sin(p.elapsed * POPUP.ShakeFreq)
        local sy = p.shakeAmp * dc * math.cos(p.elapsed * POPUP.ShakeFreq * 1.3)
        -- Now drawn in arena-local coords
        local screenX, screenY = p.x + sx, p.y + sy

        local fmt = (p.damage == math.floor(p.damage)) and "%.0f" or "%.1f"
        local txt = (p.isHeal and "+" or "-") .. string.format(fmt, p.damage)

        nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, fs)
        nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

        local off = math.max(1.5, fs * 0.05)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.7)))
        nvgText(vg_, screenX - off, screenY, txt, nil)
        nvgText(vg_, screenX + off, screenY, txt, nil)
        nvgText(vg_, screenX, screenY - off, txt, nil)
        nvgText(vg_, screenX, screenY + off, txt, nil)
        nvgFillColor(vg_, nvgRGBA(p.color[1], p.color[2], p.color[3], alpha))
        nvgText(vg_, screenX, screenY, txt, nil)
        ::continue::
    end
end

-- ============================================================================
-- Draw: Announcement
-- ============================================================================

function DrawAnnouncement()
    if announcement_.timer <= 0 or fontNormal_ == -1 then return end

    local t = announcement_.timer / announcement_.duration
    local alpha = 255
    if t > 0.8 then alpha = math.floor(255 * ((1 - t) / 0.2))
    elseif t < 0.3 then alpha = math.floor(255 * (t / 0.3)) end
    if alpha <= 0 then return end

    -- Now drawn in arena-local coords
    local cx = Settings.Arena.Size / 2
    local cy = Settings.Arena.Size * 0.72

    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 22)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)

    nvgBeginPath(vg_); nvgRoundedRect(vg_, cx - 120, cy - 14, 240, 28, 6)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.4))); nvgFill(vg_)

    local ac = announcement_.color
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, math.floor(alpha * 0.6)))
    nvgText(vg_, cx + 1, cy + 1, announcement_.text, nil)
    nvgFillColor(vg_, nvgRGBA(ac[1], ac[2], ac[3], alpha))
    nvgText(vg_, cx, cy, announcement_.text, nil)
end

-- ============================================================================
-- Draw: Info Panel (health bars + skill list, matching screenshot layout)
-- ============================================================================

function DrawInfoPanel(w, panelY)
    if fontNormal_ == -1 then return end
    local S = arenaScale_
    local px = arenaX_
    local pw = arenaDrawSize_

    nvgFontFaceId(vg_, fontNormal_)

    -- ---- Health bars row ----
    local barY = panelY + 2 * S
    local barH = 10 * S
    local barW = pw / 2 - 50 * S

    -- "我方血量" label + bar (left)
    nvgFontSize(vg_, 13 * S)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(220, 220, 220, 230))
    nvgText(vg_, px, barY, "我方血量", nil)

    -- "敌人血量" label + bar (right)
    nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
    nvgText(vg_, px + pw, barY, "敌人血量", nil)

    local hpBarY = barY + 18 * S
    for team = 1, 2 do
        local ball = balls_[team]
        local c = GetCustom(team).color
        local hpPct = math.max(0, ball.hp / BALL.MaxHP)
        local bx = team == 1 and px or (px + pw - barW)

        -- Bar background
        nvgBeginPath(vg_); nvgRoundedRect(vg_, bx, hpBarY, barW, barH, 3 * S)
        nvgFillColor(vg_, nvgRGBA(40, 40, 50, 200)); nvgFill(vg_)
        -- HP fill
        if hpPct > 0 then
            local fillW = barW * hpPct
            local fillX = team == 1 and bx or (bx + barW - fillW)
            nvgBeginPath(vg_); nvgRoundedRect(vg_, fillX, hpBarY, fillW, barH, 3 * S)
            nvgFillColor(vg_, nvgRGBA(c.r, c.g, c.b, 220)); nvgFill(vg_)
        end
        -- Border
        nvgBeginPath(vg_); nvgRoundedRect(vg_, bx, hpBarY, barW, barH, 3 * S)
        nvgStrokeColor(vg_, nvgRGBA(160, 160, 180, 100)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)
    end

    -- ---- Skill info rows ----
    local skillY = hpBarY + barH + 8 * S
    local rowH = 20 * S

    for team = 1, 2 do
        local skillInfos = GetFullSkillInfo(team)
        local isLeft = (team == 1)

        for si, info in ipairs(skillInfos) do
            local sy = skillY + (si - 1) * rowH
            local sc = info.skillDef.color
            local tierLabel = TIER_LABELS[info.tier] or info.tier
            local skillText = tierLabel .. "：" .. info.skillDef.name

            -- Cooldown icon (circle that fills up)
            local iconR = 7 * S
            local iconX, textX

            if isLeft then
                iconX = px + iconR + 2 * S
                textX = px + iconR * 2 + 8 * S
                nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)
            else
                iconX = px + pw - iconR - 2 * S
                textX = px + pw - iconR * 2 - 8 * S
                nvgTextAlign(vg_, NVG_ALIGN_RIGHT + NVG_ALIGN_TOP)
            end
            local iconY = sy + 5 * S

            -- Draw cooldown circle
            nvgBeginPath(vg_); nvgCircle(vg_, iconX, iconY, iconR)
            nvgFillColor(vg_, nvgRGBA(30, 30, 40, 200)); nvgFill(vg_)

            if info.ready then
                -- Full circle = ready
                nvgBeginPath(vg_); nvgCircle(vg_, iconX, iconY, iconR - 1 * S)
                nvgFillColor(vg_, nvgRGBA(sc.r, sc.g, sc.b, 220)); nvgFill(vg_)
            else
                -- Partial fill arc
                local pct = 1 - info.cooldown / info.skillDef.cooldown
                if pct > 0 then
                    nvgBeginPath(vg_)
                    nvgMoveTo(vg_, iconX, iconY)
                    nvgArc(vg_, iconX, iconY, iconR - 1 * S,
                        -math.pi / 2, -math.pi / 2 + pct * 2 * math.pi, NVG_CW)
                    nvgClosePath(vg_)
                    nvgFillColor(vg_, nvgRGBA(sc.r, sc.g, sc.b, 140)); nvgFill(vg_)
                end
            end

            -- Skill text
            nvgFontSize(vg_, 12 * S)
            if info.ready then
                nvgFillColor(vg_, nvgRGBA(220, 220, 230, 240))
            else
                nvgFillColor(vg_, nvgRGBA(120, 120, 140, 180))
            end
            nvgText(vg_, textX, sy, skillText, nil)

            if si >= 3 then break end
        end
    end
end

-- ============================================================================
-- Draw: Bottom Bar (返回主页 + 道具栏 + AI托管)
-- ============================================================================

function DrawBottomBar(w)
    if fontNormal_ == -1 then return end
    local S = arenaScale_
    local px = arenaX_
    local pw = arenaDrawSize_
    local by = bottomBarY_

    -- Scaled BOTTOM_BAR dimensions
    local btnW     = BOTTOM_BAR.btnW * S
    local btnH     = BOTTOM_BAR.btnH * S
    local slotSize = BOTTOM_BAR.slotSize * S
    local slotGap  = BOTTOM_BAR.slotGap * S
    local labelH   = BOTTOM_BAR.labelH * S
    local height   = BOTTOM_BAR.height * S

    -- ---- "返回主页" button (left) ----
    local lbx = px - btnW - 20 * S
    local lby = by + (height - btnH) / 2
    nvgBeginPath(vg_); nvgRoundedRect(vg_, lbx, lby, btnW, btnH, 4 * S)
    nvgFillColor(vg_, nvgRGBA(50, 50, 60, 200)); nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(160, 160, 180, 150)); nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)
    nvgFontFaceId(vg_, fontNormal_); nvgFontSize(vg_, 16 * S)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(220, 220, 230, 240))
    nvgText(vg_, lbx + btnW / 2, lby + btnH / 2, "返回主页", nil)

    -- ---- "AI托管" button (right) ----
    local rbx = px + pw + 20 * S
    local rby = lby
    nvgBeginPath(vg_); nvgRoundedRect(vg_, rbx, rby, btnW, btnH, 4 * S)
    if isAIProxy_ then
        nvgFillColor(vg_, nvgRGBA(60, 100, 180, 200)); nvgFill(vg_)
    else
        nvgFillColor(vg_, nvgRGBA(50, 50, 60, 200)); nvgFill(vg_)
    end
    nvgStrokeColor(vg_, nvgRGBA(160, 160, 180, 150)); nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)
    nvgFontSize(vg_, 16 * S)
    nvgFillColor(vg_, nvgRGBA(220, 220, 230, 240))
    nvgText(vg_, rbx + btnW / 2, rby + btnH / 2, "AI托管", nil)

    -- ---- Item slots (center) ----
    local totalSlotsW = BOTTOM_BAR.slotCount * slotSize + (BOTTOM_BAR.slotCount - 1) * slotGap
    local slotsX = px + (pw - totalSlotsW) / 2
    local slotsY = by + labelH

    -- "道具栏" label
    nvgFontSize(vg_, 14 * S)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_TOP)
    nvgFillColor(vg_, nvgRGBA(200, 200, 210, 220))
    nvgText(vg_, px + pw / 2, by + 2 * S, "道具栏", nil)

    for slot = 1, BOTTOM_BAR.slotCount do
        local sx = slotsX + (slot - 1) * (slotSize + slotGap)
        local sy = slotsY
        local def = ItemSystem.GetDef(slot)
        local cd = ItemSystem.GetCooldown(slot)
        local ready = ItemSystem.IsReady(slot)
        local unlocked = ItemSystem.IsUnlocked(slot)

        -- Slot background
        nvgBeginPath(vg_); nvgRoundedRect(vg_, sx, sy, slotSize, slotSize, 4 * S)
        if not unlocked then
            nvgFillColor(vg_, nvgRGBA(30, 30, 35, 200))
        elseif ready then
            nvgFillColor(vg_, nvgRGBA(70, 70, 80, 200))
        else
            nvgFillColor(vg_, nvgRGBA(40, 40, 50, 200))
        end
        nvgFill(vg_)
        nvgStrokeColor(vg_, nvgRGBA(140, 140, 160, (not unlocked) and 50 or (ready and 180 or 80)))
        nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)

        if def then
            if not unlocked then
                -- Locked state: dimmed icon + lock overlay
                nvgFontSize(vg_, 22 * S)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                nvgFillColor(vg_, nvgRGBA(100, 100, 110, 80))
                nvgText(vg_, sx + slotSize / 2, sy + slotSize / 2 - 4 * S, def.emoji, nil)

                -- Dark overlay
                nvgBeginPath(vg_); nvgRoundedRect(vg_, sx, sy, slotSize, slotSize, 4 * S)
                nvgFillColor(vg_, nvgRGBA(0, 0, 0, 120)); nvgFill(vg_)

                -- Lock icon
                nvgFontSize(vg_, 18 * S)
                nvgFillColor(vg_, nvgRGBA(255, 200, 80, 200))
                nvgText(vg_, sx + slotSize / 2, sy + slotSize / 2, "🔒", nil)

                -- Dimmed name
                nvgFontSize(vg_, 9 * S)
                nvgFillColor(vg_, nvgRGBA(120, 120, 130, 80))
                nvgText(vg_, sx + slotSize / 2, sy + slotSize - 6 * S, def.name, nil)
            else
                -- Emoji icon
                nvgFontSize(vg_, 22 * S)
                nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
                if ready then
                    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 230))
                else
                    nvgFillColor(vg_, nvgRGBA(120, 120, 140, 140))
                end
                nvgText(vg_, sx + slotSize / 2, sy + slotSize / 2 - 4 * S, def.emoji, nil)

                -- Item name (small, below emoji)
                nvgFontSize(vg_, 9 * S)
                nvgFillColor(vg_, nvgRGBA(180, 180, 200, ready and 200 or 100))
                nvgText(vg_, sx + slotSize / 2, sy + slotSize - 6 * S, def.name, nil)

                -- Cooldown overlay
                if not ready and cd > 0 then
                    local pct = cd / def.cooldown
                    local overlayH = slotSize * pct
                    nvgBeginPath(vg_); nvgRoundedRect(vg_, sx, sy + slotSize - overlayH, slotSize, overlayH, 4 * S)
                    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 130)); nvgFill(vg_)
                    -- CD text
                    nvgFontSize(vg_, 14 * S)
                    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
                    nvgText(vg_, sx + slotSize / 2, sy + slotSize / 2,
                        string.format("%.0f", math.ceil(cd)), nil)
                end
            end
        end
    end
end

-- ============================================================================
-- Draw: Item being dragged
-- ============================================================================

function DrawDragItem()
    if not dragItem_ then return end
    local def = ItemSystem.GetDef(dragItem_.slot)
    if not def then return end
    local S = arenaScale_

    local dx, dy = dragItem_.curX, dragItem_.curY

    -- Range circle preview (if over arena, scale radius)
    local ax = dx - arenaX_
    local ay = dy - arenaY_
    if ax >= 0 and ax <= arenaDrawSize_ and ay >= 0 and ay <= arenaDrawSize_ then
        nvgBeginPath(vg_); nvgCircle(vg_, dx, dy, def.radius * S)
        nvgFillColor(vg_, nvgRGBA(255, 255, 255, 30)); nvgFill(vg_)
        nvgStrokeColor(vg_, nvgRGBA(255, 255, 255, 120))
        nvgStrokeWidth(vg_, 1.5); nvgStroke(vg_)
    end

    -- Dragged icon
    nvgFontFaceId(vg_, fontNormal_)
    nvgFontSize(vg_, 32 * S)
    nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 200))
    nvgText(vg_, dx, dy, def.emoji, nil)

    -- Name below
    nvgFontSize(vg_, 11 * S)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 180))
    nvgText(vg_, dx, dy + 22 * S, def.name, nil)
end

-- ============================================================================
-- Draw: Debug Panel (TAB toggle)
-- ============================================================================

function DrawDebugPanel()
    if not debugShow_ or fontNormal_ == -1 then return end

    local px = 10
    local py = 10
    local pw = 320
    local lineH = 16
    local lines = {}

    table.insert(lines, "=== DEBUG PANEL (TAB to close) ===")
    table.insert(lines, "")

    for team = 1, 2 do
        local ball = balls_[team]
        local custom = GetCustom(team)
        local tier = BallAI.GetActiveTier(ball.hp)
        local skillDef = GetActiveSkillDef(team)

        table.insert(lines, string.format("--- %s ---", team == 1 and "Player" or "AI"))
        table.insert(lines, string.format("  HP: %.1f / %d", ball.hp, BALL.MaxHP))
        table.insert(lines, string.format("  Tier: %s (%s)", tier, TIER_NAMES[tier] or "?"))
        table.insert(lines, string.format("  Pos: %.0f, %.0f", ball.x, ball.y))
        table.insert(lines, string.format("  Vel: %.0f, %.0f (spd %.0f)",
            ball.vx, ball.vy, math.sqrt(ball.vx*ball.vx + ball.vy*ball.vy)))
        table.insert(lines, string.format("  Skill: %s", skillDef and skillDef.name or "无"))
        -- Per-tier cooldowns
        local cdParts = {}
        for _, t in ipairs({"normal", "enhanced", "ultimate"}) do
            local cd = cooldowns_[team][t] or 0
            if cd > 0 then
                table.insert(cdParts, string.format("%s:%.1f", t:sub(1,1):upper(), cd))
            else
                table.insert(cdParts, string.format("%s:OK", t:sub(1,1):upper()))
            end
        end
        table.insert(lines, string.format("  CD: %s", table.concat(cdParts, " ")))
        table.insert(lines, string.format("  Slow: %.2f (%.1fs)", ball.slowFactor, math.max(0, ball.slowTimer)))
        table.insert(lines, string.format("  Stun: %.1fs", math.max(0, ball.stunTimer or 0)))
        table.insert(lines, string.format("  WallSlam: %d (%.1fs)",
            ball.pendingWallSlamDmg, math.max(0, ball.knockbackTimer)))
        table.insert(lines, "")
    end

    -- Executor state
    local projs = SkillExecutor.GetProjectiles()
    local vProjs = SkillExecutor.GetVisualProjectiles()
    local emitters = SkillExecutor.GetEmitters()
    local fzones = SkillExecutor.GetFireZones()
    local bubs = SkillExecutor.GetBubbles()
    local dots = SkillExecutor.GetDots()

    table.insert(lines, "--- Executor ---")
    table.insert(lines, string.format("  Projectiles: %d (vis: %d)", #projs, #vProjs))
    table.insert(lines, string.format("  Emitters: %d", #emitters))
    table.insert(lines, string.format("  FireZones: %d", #fzones))
    table.insert(lines, string.format("  Bubbles: %d", #bubs))
    table.insert(lines, string.format("  DOTs: %d", #dots))
    table.insert(lines, "")

    -- Skill config summary
    table.insert(lines, "--- Skill Config ---")
    for _, custom in ipairs({playerCustom_, aiCustom_}) do
        local label = (custom == playerCustom_) and "Player" or "AI"
        local sk = custom and custom.skills or {}
        table.insert(lines, string.format("  %s: N=%s E=%s U=%s",
            label,
            sk.normal or "-",
            sk.enhanced or "-",
            sk.ultimate or "-"))
    end

    local ph = (#lines + 1) * lineH + 10

    -- Background
    nvgBeginPath(vg_); nvgRoundedRect(vg_, px, py, pw, ph, 6)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200)); nvgFill(vg_)
    nvgStrokeColor(vg_, nvgRGBA(0, 255, 100, 100)); nvgStrokeWidth(vg_, 1); nvgStroke(vg_)

    -- Text
    nvgFontFaceId(vg_, fontNormal_)
    nvgFontSize(vg_, 12)
    nvgTextAlign(vg_, NVG_ALIGN_LEFT + NVG_ALIGN_TOP)

    for idx, line in ipairs(lines) do
        local ly = py + 6 + (idx - 1) * lineH
        if line:find("^===") or line:find("^---") then
            nvgFillColor(vg_, nvgRGBA(0, 255, 120, 255))
        else
            nvgFillColor(vg_, nvgRGBA(200, 220, 200, 230))
        end
        nvgText(vg_, px + 8, ly, line, nil)
    end
end

-- ============================================================================
-- Draw: Game Over
-- ============================================================================

function DrawGameOver(w, h)
    local S = arenaScale_
    nvgBeginPath(vg_); nvgRect(vg_, 0, 0, w, h)
    nvgFillColor(vg_, nvgRGBA(0, 0, 0, 180)); nvgFill(vg_)

    nvgFontFaceId(vg_, fontNormal_)

    local names = { "玩家", "AI" }

    if gameWinner_ >= 1 and gameWinner_ <= 2 then
        local wc = GetCustom(gameWinner_).color
        nvgFontSize(vg_, 40 * S); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(0, 0, 0, 200))
        nvgText(vg_, w / 2 + 2, h / 2 - 18 * S, names[gameWinner_] .. " 获胜!", nil)
        nvgFillColor(vg_, nvgRGBA(wc.r, wc.g, wc.b, 255))
        nvgText(vg_, w / 2, h / 2 - 20 * S, names[gameWinner_] .. " 获胜!", nil)

        nvgFontSize(vg_, 16 * S)
        nvgFillColor(vg_, nvgRGBA(180, 180, 200, 200))
        nvgText(vg_, w / 2, h / 2 + 18 * S,
            "剩余血量: " .. math.floor(balls_[gameWinner_].hp), nil)
    else
        nvgFontSize(vg_, 40 * S); nvgTextAlign(vg_, NVG_ALIGN_CENTER + NVG_ALIGN_MIDDLE)
        nvgFillColor(vg_, nvgRGBA(255, 255, 100, 255))
        nvgText(vg_, w / 2, h / 2 - 20 * S, "平局!", nil)
    end

    nvgFontSize(vg_, 16 * S)
    nvgFillColor(vg_, nvgRGBA(255, 255, 255, 160))
    local remaining = math.max(0, math.ceil(4.0 - gameOverTimer_))
    nvgText(vg_, w / 2, h / 2 + 55 * S,
        remaining > 0 and string.format("%d 秒后返回菜单...", remaining) or "返回菜单...", nil)
end

return Standalone
