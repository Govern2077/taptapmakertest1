-- TutorialSystem.lua
-- 教程步骤管理系统
-- 与 TutorialMascot、BreedingPage 协作，引导新玩家学习游戏基本操作
--
-- 步骤流程：
--   Step 1: 介绍养殖场（点击推进，3s 延迟）
--   Step 2: 引导拖第一个球到战斗区域（拖放事件推进）
--   Step 3: 引导再拖一个球到同一个槽（相同槽位放入推进）
--   Step 4: 等待战斗说明（5s 自动推进）
--   Step 5: 等待战斗结束（战斗结束事件推进）
--   Step 6: 介绍经验值绿条（5s 自动推进）
--   Step 7: 介绍升级机制（点击推进，3s 延迟）
--   Step 8: 引导赚 50 金币升级养殖场（点击推进，3s 延迟 → 显示任务标记）

local TutorialSystem = {}
local TutorialMascot = require("ui.TutorialMascot")

-- ============================================================
-- 步骤定义
-- ============================================================

-- ---- 养殖场教程步骤 ----
local STEPS = {
    -- 阶段一：认识基本操作
    {
        text    = "养殖场里的球球是你的资产，你可以对他们做任何事情",
        trigger = "click",
    },
    {
        text    = "看到上面的空白的五个战斗区域，拖拽一个球球进入战斗区域吧",
        trigger = "slot_drop",
    },
    {
        text    = "非常好，再拖拽一个球球进入同一个战斗区域",
        trigger = "same_slot",
    },
    {
        text     = "只要有两个球球同时在一个战斗区域，它们就会开始自动战斗",
        trigger  = "timer",
        duration = 5.0,
    },
    {
        text    = "直到只剩下一个球球",
        trigger = "battle_end",
    },
    {
        text    = "看来已经决出胜者了",
        trigger = "ball_returned",   -- 等待胜利球球回到养殖场
    },
    -- 阶段二：成长系统
    {
        text            = "注意到球球下方的绿条吗？那是球球的经验值",
        trigger         = "timer",
        duration        = 5.0,
        highlightWinner = true,   -- 显示箭头 + 高亮胜利球球
    },
    {
        text    = "当球球经验值长满的时候就会升级，获得更多的血量，甚至更强力的技能哦",
        trigger = "click",
    },
    {
        text    = "但是球球的等级受到养殖场等级的限制，所以我们先赚够50金币升级养殖场吧！",
        trigger = "click",
        -- 完成此步骤后，显示养殖场任务标记
        onComplete = "show_farm_task",
    },
}

-- ---- 擂台赛教程步骤 ----
-- trigger: "click" = 需要点击推进（有 2s 等待窗口）
-- glowItemBar: true = 此步骤激活道具栏发光
-- unlockItems: true = 此步骤赠送 3 个道具
local ARENA_STEPS = {
    {
        text    = "擂台赛是检测球球战力的重要标准！并且擂台赛获胜也是获得钻石的途径之一",
        trigger = "click",
    },
    {
        text    = "钻石可以在主菜单的商店中解锁各种道具，表情和皮肤",
        trigger = "click",
    },
    {
        text         = "道具可以在擂台赛开打的时候使用，拖拽进入战斗区域即可",
        trigger      = "click",
        glowItemBar  = true,   -- 激活道具栏发光
    },
    -- 步骤 4 为条件步骤：只有没有任何道具时才出现（由 StartArenaTutorial 动态决定）
    {
        text        = "鉴于你现在还没有道具，这次我帮你先解锁三个试试水",
        trigger     = "click",
        unlockItems = true,    -- 在进入此步骤时赠送 3 个道具
    },
    {
        text    = "祝你好运！",
        trigger = "click",
    },
}

-- ============================================================
-- 私有状态
-- ============================================================
local active_         = false
local stepIndex_      = 0
local stepTimer_      = 0

local firstDropSlot_  = nil
local onFinish_       = nil

-- 任务标记状态（跨存档持久化）
local farmTaskVisible_ = false   -- 是否显示"赚够50金币升级养殖场"任务

-- 存档回调（由外部注入，每次状态变化时调用）
local onSaveNeeded_   = nil

-- 竞态标志：战斗结束事件可能在步骤 5 被激活前就已触发
local battleEnded_        = false
local ballReturnedToFarm_ = false

-- 教程高亮：胜利球球引用 + 是否当前高亮中
local winnerFarmBall_     = nil    -- 胜利球球的 farmBall table 引用
local showWinnerHighlight_ = false  -- 是否正在高亮胜利球球

-- 永久拒绝所有教程（存档持久化）
local tutorialDeclined_ = false  -- true = 玩家选择"不需要教学"，永远不再触发任何教程

-- 擂台赛教程状态
local arenaActive_    = false   -- 擂台赛教程是否进行中
local arenaStepIdx_   = 0       -- 当前擂台赛教程步骤
local arenaDone_      = false   -- 擂台赛教程是否已完成（存档持久化）
local arenaSteps_     = nil     -- 运行时步骤列表（含/不含条件步骤）

-- 擂台赛教程外部控制回调（由 Standalone 注入）
local arenaCbs_ = {
    pauseCountdown  = nil,   -- function()
    resumeCountdown = nil,   -- function()
    setItemBarGlow  = nil,   -- function(bool)
    unlockFreeItems = nil,   -- function() 解锁前 3 个道具
    hasAnyItem      = nil,   -- function() → bool
}

-- ============================================================
-- 内部：触发存档
-- ============================================================
local function RequestSave()
    if onSaveNeeded_ then onSaveNeeded_() end
end

-- ============================================================
-- 内部：进入下一步
-- ============================================================
local function ShowStep(idx)
    if idx > #STEPS then
        -- 教程全部完成
        active_    = false
        stepIndex_ = 0
        TutorialMascot.Dismiss()
        print("[TutorialSystem] 全部教程步骤完成！")
        RequestSave()
        if onFinish_ then
            local cb = onFinish_; onFinish_ = nil; cb()
        end
        return
    end

    local prevStep = STEPS[stepIndex_]
    -- 处理上一步的 onComplete 动作
    if prevStep and prevStep.onComplete == "show_farm_task" then
        farmTaskVisible_ = true
        print("[TutorialSystem] 养殖场任务标记已激活")
    end
    -- 离开 highlightWinner 步骤时关闭高亮
    if prevStep and prevStep.highlightWinner then
        showWinnerHighlight_ = false
    end

    stepIndex_  = idx
    stepTimer_  = 0
    local step  = STEPS[idx]
    print(string.format("[TutorialSystem] 步骤 %d/%d: %s (trigger=%s)", idx, #STEPS, step.text, step.trigger))

    -- 进入 highlightWinner 步骤时开启高亮
    if step.highlightWinner then
        showWinnerHighlight_ = true
    end

    -- 竞态检查：battle_end 步骤到达时战斗可能已经提前结束了
    if step.trigger == "battle_end" and battleEnded_ then
        print("[TutorialSystem] 战斗已提前结束，直接跳过步骤 " .. idx)
        ShowStep(idx + 1)
        return
    end

    local allowClick = (step.trigger == "click")
    local onClickCb  = allowClick and function()
        ShowStep(idx + 1)
        RequestSave()
    end or nil

    TutorialMascot.SetDialogText(step.text, allowClick, onClickCb)
    RequestSave()
end

-- ============================================================
-- 公共 API
-- ============================================================

--- 设置存档回调（每次步骤推进时触发）
function TutorialSystem.SetSaveCallback(cb)
    onSaveNeeded_ = cb
end

--- 启动教程（从第 1 步）
function TutorialSystem.Start(onFinishCb)
    -- 玩家已永久拒绝教学，直接跳过
    if tutorialDeclined_ then
        print("[TutorialSystem] 教程已被永久禁用，跳过 Start()")
        return
    end
    active_             = true
    stepIndex_          = 0
    stepTimer_          = 0
    firstDropSlot_      = nil
    farmTaskVisible_    = false
    battleEnded_        = false
    ballReturnedToFarm_ = false
    winnerFarmBall_     = nil
    showWinnerHighlight_ = false
    onFinish_           = onFinishCb
    ShowStep(1)
end

--- 从存档恢复教程状态
--- tutorialData: { stepIndex=int, farmTaskVisible=bool, tutorialDeclined=bool }
function TutorialSystem.Restore(tutorialData, onFinishCb)
    if not tutorialData then return end

    -- 恢复永久拒绝标志
    tutorialDeclined_ = tutorialData.tutorialDeclined or false

    -- 恢复擂台赛教程完成标志（独立于主教程流）
    arenaDone_  = tutorialData.arenaDone or false

    local idx = tutorialData.stepIndex or 0
    if idx <= 0 then return end  -- 教程未开始或已完成

    onFinish_           = onFinishCb
    farmTaskVisible_    = tutorialData.farmTaskVisible or false
    firstDropSlot_      = tutorialData.firstDropSlot or nil
    stepTimer_          = 0
    battleEnded_        = false
    ballReturnedToFarm_ = false

    -- 如果还在进行中，从断点恢复
    if idx <= #STEPS then
        active_     = true
        stepIndex_  = idx - 1  -- ShowStep 会递增
        -- 延迟到下帧再 ShowStep，避免 NanoVG/vg 未就绪
        local capturedIdx = idx
        -- 直接设置（不走 ShowStep 的 onComplete，因为恢复时上一步已完成）
        stepIndex_  = capturedIdx
        stepTimer_  = 0
        local step  = STEPS[capturedIdx]
        if step then
            local allowClick = (step.trigger == "click")
            local onClickCb  = allowClick and function()
                ShowStep(capturedIdx + 1)
                RequestSave()
            end or nil
            TutorialMascot.SetDialogText(step.text, allowClick, onClickCb)
        end
    else
        -- 所有步骤已完成，只恢复任务标记
        active_    = false
        stepIndex_ = 0
    end
    print(string.format("[TutorialSystem] 已从存档恢复：step=%d farmTask=%s", idx, tostring(farmTaskVisible_)))
end

function TutorialSystem.IsActive()
    return active_
end

--- 获取当前教程状态用于存档
function TutorialSystem.GetSaveData()
    return {
        stepIndex        = active_ and stepIndex_ or 0,
        farmTaskVisible  = farmTaskVisible_,
        firstDropSlot    = firstDropSlot_,
        arenaDone        = arenaDone_,
        tutorialDeclined = tutorialDeclined_,
    }
end

--- 养殖场任务标记是否可见
function TutorialSystem.IsFarmTaskVisible()
    return farmTaskVisible_
end

--- 玩家升级了养殖场，隐藏任务标记
function TutorialSystem.OnFarmUpgraded()
    if farmTaskVisible_ then
        farmTaskVisible_ = false
        print("[TutorialSystem] 养殖场已升级，任务标记隐藏")
        RequestSave()
    end
end

--- 每帧更新
function TutorialSystem.Update(dt)
    if not active_ then return end

    local step = STEPS[stepIndex_]
    if not step then return end

    if step.trigger == "timer" then
        stepTimer_ = stepTimer_ + dt
        if stepTimer_ >= (step.duration or 5.0) then
            ShowStep(stepIndex_ + 1)
        end
    end
end

--- 球被放入槽位
function TutorialSystem.OnBallDroppedToSlot(slotIdx)
    if not active_ then return end
    local step = STEPS[stepIndex_]
    if not step then return end

    if step.trigger == "slot_drop" then
        firstDropSlot_ = slotIdx
        ShowStep(stepIndex_ + 1)
    elseif step.trigger == "same_slot" then
        if slotIdx == firstDropSlot_ then
            ShowStep(stepIndex_ + 1)
        else
            print(string.format("[TutorialSystem] 放入槽位 %d，需要槽位 %d，请再试一次", slotIdx, firstDropSlot_))
        end
    end
end

--- 战斗结束（球球胜负已分，胜利球还在战斗区做庆祝动画）
function TutorialSystem.OnBattleFinished(slotIdx)
    battleEnded_ = true  -- 记录战斗已结束，用于竞态处理
    if not active_ then return end
    local step = STEPS[stepIndex_]
    if not step then return end

    if step.trigger == "battle_end" then
        ShowStep(stepIndex_ + 1)
    end
    -- 注意：若当前在 timer 步骤（如步骤4），battleEnded_ 已设置
    -- 当 timer 推进到 battle_end 步骤时，ShowStep 内的竞态检查会自动跳过
end

--- 胜利球球已返回养殖场（经验条可见）
--- farmBall: 胜利球球的 table 引用（用于高亮）
function TutorialSystem.OnBallReturnedToFarm(slotIdx, farmBall)
    ballReturnedToFarm_ = true
    -- 存储胜利球球引用（供高亮使用）
    if farmBall then
        winnerFarmBall_ = farmBall
    end

    if not active_ then return end
    local step = STEPS[stepIndex_]
    if not step then return end

    -- 主推进：ball_returned 步骤等待此事件
    if step.trigger == "ball_returned" then
        print("[TutorialSystem] 胜利球球已返回养殖场，推进步骤 " .. stepIndex_)
        ShowStep(stepIndex_ + 1)
        return
    end

    -- 兜底：若卡在 battle_end 步骤，强制推进
    if step.trigger == "battle_end" then
        print("[TutorialSystem] 球球已返回农场，强制推进 battle_end 步骤")
        ShowStep(stepIndex_ + 1)
    end
end

--- 获取当前需要高亮的胜利球球（供 BreedingPage 渲染用）
--- 返回 farmBall table 引用，若无高亮则返回 nil
function TutorialSystem.GetWinnerHighlightBall()
    if showWinnerHighlight_ then return winnerFarmBall_ end
    return nil
end

-- ============================================================
-- 擂台赛教程
-- ============================================================

--- 注入擂台赛教程所需的外部控制回调
--- callbacks = { pauseCountdown, resumeCountdown, setItemBarGlow, unlockFreeItems, hasAnyItem }
function TutorialSystem.SetArenaTutorialCallbacks(callbacks)
    arenaCbs_.pauseCountdown  = callbacks.pauseCountdown
    arenaCbs_.resumeCountdown = callbacks.resumeCountdown
    arenaCbs_.setItemBarGlow  = callbacks.setItemBarGlow
    arenaCbs_.unlockFreeItems = callbacks.unlockFreeItems
    arenaCbs_.hasAnyItem      = callbacks.hasAnyItem
end

-- 内部：进入擂台赛教程下一步
local function ShowArenaStep(idx)
    if not arenaSteps_ then return end

    if idx > #arenaSteps_ then
        -- 擂台赛教程全部完成
        arenaActive_ = false
        arenaStepIdx_ = 0
        arenaDone_   = true
        -- 停止发光、恢复倒计时
        if arenaCbs_.setItemBarGlow then arenaCbs_.setItemBarGlow(false) end
        if arenaCbs_.resumeCountdown then arenaCbs_.resumeCountdown() end
        TutorialMascot.Dismiss()
        print("[TutorialSystem] 擂台赛教程全部完成！")
        RequestSave()
        return
    end

    local step = arenaSteps_[idx]
    arenaStepIdx_ = idx

    -- 进入此步骤时的副作用
    if step.glowItemBar then
        if arenaCbs_.setItemBarGlow then arenaCbs_.setItemBarGlow(true) end
    else
        if arenaCbs_.setItemBarGlow then arenaCbs_.setItemBarGlow(false) end
    end

    if step.unlockItems then
        -- 赠送道具
        if arenaCbs_.unlockFreeItems then arenaCbs_.unlockFreeItems() end
    end

    print(string.format("[TutorialSystem] 擂台赛步骤 %d/%d: %s", idx, #arenaSteps_, step.text))

    local onClickCb = function()
        ShowArenaStep(idx + 1)
        RequestSave()
    end
    -- allowClick=true，但有 2s 等待窗口（TutorialMascot 内置延迟机制）
    TutorialMascot.SetDialogText(step.text, true, onClickCb)
    RequestSave()
end

--- 当玩家第一次将球放入擂台时触发
function TutorialSystem.OnFirstBallDroppedToArena()
    -- 玩家已永久拒绝教学，跳过
    if tutorialDeclined_ then return end
    -- 已完成过、正在进行中，或养殖场教程仍在进行则跳过
    if arenaDone_ or arenaActive_ then return end
    if active_ then
        print("[TutorialSystem] 养殖场教程仍在进行，跳过擂台赛教程")
        return
    end

    print("[TutorialSystem] 触发擂台赛教程")
    arenaActive_  = true
    arenaStepIdx_ = 0

    -- 根据是否有道具决定步骤列表
    local hasItem = arenaCbs_.hasAnyItem and arenaCbs_.hasAnyItem() or false
    if hasItem then
        -- 已有道具：跳过步骤 4（unlockItems）
        arenaSteps_ = { ARENA_STEPS[1], ARENA_STEPS[2], ARENA_STEPS[3], ARENA_STEPS[5] }
        print("[TutorialSystem] 玩家已有道具，跳过赠送步骤")
    else
        -- 无道具：包含赠送步骤
        arenaSteps_ = { ARENA_STEPS[1], ARENA_STEPS[2], ARENA_STEPS[3], ARENA_STEPS[4], ARENA_STEPS[5] }
    end

    -- 暂停倒计时
    if arenaCbs_.pauseCountdown then arenaCbs_.pauseCountdown() end

    ShowArenaStep(1)
end

--- 擂台赛教程是否已完成
function TutorialSystem.IsArenaTutorialDone()
    return arenaDone_
end

--- 玩家选择"不需要教学"——永久禁用此存档的所有教程（农场 + 擂台赛）
function TutorialSystem.DeclineAllTutorials()
    tutorialDeclined_ = true
    arenaDone_        = true    -- 擂台赛教程也不再触发
    active_           = false   -- 停止正在进行的教程（理论上此时还未开始，但以防万一）
    stepIndex_        = 0
    TutorialMascot.Dismiss()
    print("[TutorialSystem] 玩家永久拒绝教学，所有教程已禁用")
    RequestSave()
end

return TutorialSystem
