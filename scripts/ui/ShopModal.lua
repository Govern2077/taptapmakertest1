-- ============================================================================
-- ShopModal.lua - 商店弹窗 UI
-- 使用 UI.Modal + UI.Tabs 展示皮肤和道具两个分页
-- ============================================================================

local UI             = require("urhox-libs/UI")
local ShopConfig     = require("config.ShopConfig")
local ShopManager    = require("game.ShopManager")
local DiamondManager = require("game.DiamondManager")
local ItemSystem     = require("game.ItemSystem")

local ShopModal = {}

-- ============================================================================
-- State
-- ============================================================================

---@type Modal|nil
local modal_      = nil
local onChanged_  = nil   -- callback when a purchase is made
local activeTab_  = "skins"  -- remember current tab across refreshes

-- ============================================================================
-- Skin Card Builder
-- ============================================================================

local function BuildSkinCard(skin)
    local owned = ShopManager.HasSkin(skin.id)
    local balance = DiamondManager.Get()
    local canAfford = balance >= skin.price

    -- Grade label for which level this skin affects
    local gradeName = ShopConfig.GRADE_NAMES[skin.targetGrade] or "?"

    -- Color preview circle (simulated with a colored panel + borderRadius)
    local colorPreview = UI.Panel {
        width = 48, height = 48,
        borderRadius = 24,
        backgroundColor = string.format("#%02x%02x%02x", skin.color.r, skin.color.g, skin.color.b),
        borderWidth = 2,
        borderColor = owned and "#66bb6a" or "#555577",
    }

    -- Target grade badge
    local gradeBadge = UI.Label {
        text = string.format("适用：%s等级", gradeName),
        fontSize = 11,
        color = owned and "#88cc88" or "#8888bb",
    }

    -- Price / owned label
    local statusWidget
    if owned then
        statusWidget = UI.Label {
            text = "✓ 已生效",
            fontSize = 13,
            color = "#66bb6a",
            fontWeight = "bold",
        }
    else
        statusWidget = UI.Label {
            text = string.format("💎 %d", skin.price),
            fontSize = 13,
            color = canAfford and "#ffd54f" or "#ff6666",
            fontWeight = "bold",
        }
    end

    -- Action button (buy only, no equip needed)
    local actionWidget
    if owned then
        actionWidget = UI.Button {
            text = "已拥有",
            variant = "ghost",
            size = "sm",
            width = "100%",
            disabled = true,
        }
    else
        actionWidget = UI.Button {
            text = "购买",
            variant = canAfford and "primary" or "outline",
            size = "sm",
            width = "100%",
            disabled = not canAfford,
            onClick = function()
                ShopModal._DoPurchase(skin.id, skin.name, skin.price)
            end,
        }
    end

    return UI.Panel {
        width = 150,
        padding = 12,
        borderRadius = 10,
        backgroundColor = owned and "#2a3a2a" or "#2a2a3a",
        borderWidth = owned and 2 or 1,
        borderColor = owned and "#66bb6a" or "#444466",
        alignItems = "center",
        gap = 8,
        children = {
            colorPreview,
            UI.Label { text = skin.name, fontSize = 15, fontWeight = "bold", color = "#ffffff" },
            UI.Label { text = skin.desc, fontSize = 11, color = "#aaaacc" },
            gradeBadge,
            statusWidget,
            actionWidget,
        },
    }
end

-- ============================================================================
-- Item Card Builder
-- ============================================================================

local function BuildItemCard(item)
    local owned = ShopManager.HasItem(item.id)
    local balance = DiamondManager.Get()
    local canAfford = balance >= item.price

    -- Check equip status
    local defIdx = ItemSystem.GetDefIndexById(item.id)
    local isEquipped = defIdx and ItemSystem.IsEquipped(defIdx)
    local equipped = ItemSystem.GetEquipped()
    local canEquipMore = #equipped < 3

    -- Emoji icon
    local iconWidget = UI.Label {
        text = item.emoji,
        fontSize = 36,
    }

    -- Price / owned label
    local statusWidget
    if owned then
        statusWidget = UI.Label {
            text = isEquipped and "已装备" or "已解锁",
            fontSize = 13,
            color = isEquipped and "#4fc3f7" or "#66bb6a",
            fontWeight = "bold",
        }
    else
        statusWidget = UI.Label {
            text = string.format("💎 %d", item.price),
            fontSize = 13,
            color = canAfford and "#ffd54f" or "#ff6666",
            fontWeight = "bold",
        }
    end

    local cardChildren = {
        iconWidget,
        UI.Label { text = item.name, fontSize = 15, fontWeight = "bold", color = "#ffffff" },
        UI.Label { text = item.desc, fontSize = 11, color = "#aaaacc", textAlign = "center" },
        statusWidget,
    }

    if owned then
        -- Equip / unequip button
        if isEquipped then
            table.insert(cardChildren, UI.Button {
                text = "卸下",
                variant = "outline",
                size = "sm",
                width = "100%",
                onClick = function()
                    ItemSystem.Unequip(defIdx)
                    ShopModal._RefreshContent()
                    if onChanged_ then onChanged_() end
                end,
            })
        else
            table.insert(cardChildren, UI.Button {
                text = canEquipMore and "装备" or "已满(3/3)",
                variant = canEquipMore and "success" or "outline",
                size = "sm",
                width = "100%",
                disabled = not canEquipMore,
                onClick = function()
                    ItemSystem.Equip(defIdx)
                    ShopModal._RefreshContent()
                    if onChanged_ then onChanged_() end
                end,
            })
        end
    else
        -- Buy button
        table.insert(cardChildren, UI.Button {
            text = "解锁",
            variant = canAfford and "success" or "outline",
            size = "sm",
            width = "100%",
            disabled = not canAfford,
            onClick = function()
                ShopModal._DoPurchase(item.id, item.name, item.price)
            end,
        })
    end

    return UI.Panel {
        width = 150,
        padding = 12,
        borderRadius = 10,
        backgroundColor = isEquipped and "#1a2a3a" or (owned and "#2a3a2a" or "#2a2a3a"),
        borderWidth = isEquipped and 2 or 1,
        borderColor = isEquipped and "#4fc3f7" or (owned and "#66bb6a" or "#444466"),
        alignItems = "center",
        gap = 8,
        children = cardChildren,
    }
end

-- ============================================================================
-- Tab Content Builders
-- ============================================================================

local function BuildSkinsTab()
    local cards = {}
    for _, skin in ipairs(ShopConfig.SKINS) do
        table.insert(cards, BuildSkinCard(skin))
    end

    return UI.ScrollView {
        flexGrow = 1,
        flexBasis = 0,
        width = "100%",
        children = {
            -- Diamond balance header
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "center",
                width = "100%",
                marginBottom = 12,
                gap = 6,
                children = {
                    UI.Label { text = "💎", fontSize = 18 },
                    UI.Label {
                        text = tostring(DiamondManager.Get()),
                        fontSize = 16,
                        fontWeight = "bold",
                        color = "#ffd54f",
                    },
                },
            },
            UI.Label {
                text = "购买皮肤后自动生效，只改变对应等级的球球颜色",
                fontSize = 12,
                color = "#888899",
                textAlign = "center",
                width = "100%",
                marginBottom = 12,
            },
            -- Card grid
            UI.Panel {
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                gap = 12,
                width = "100%",
                children = cards,
            },
        },
    }
end

local function BuildItemsTab()
    local cards = {}
    for _, item in ipairs(ShopConfig.ITEMS) do
        table.insert(cards, BuildItemCard(item))
    end

    return UI.ScrollView {
        flexGrow = 1,
        flexBasis = 0,
        width = "100%",
        children = {
            -- Diamond balance header
            UI.Panel {
                flexDirection = "row",
                alignItems = "center",
                justifyContent = "center",
                width = "100%",
                marginBottom = 12,
                gap = 6,
                children = {
                    UI.Label { text = "💎", fontSize = 18 },
                    UI.Label {
                        text = tostring(DiamondManager.Get()),
                        fontSize = 16,
                        fontWeight = "bold",
                        color = "#ffd54f",
                    },
                },
            },
            UI.Label {
                text = string.format("已装备 %d/3 — 解锁道具后点击「装备」带入擂台赛", #ItemSystem.GetEquipped()),
                fontSize = 12,
                color = "#888899",
                textAlign = "center",
                width = "100%",
                marginBottom = 12,
            },
            -- Card grid
            UI.Panel {
                flexDirection = "row",
                flexWrap = "wrap",
                justifyContent = "center",
                gap = 12,
                width = "100%",
                children = cards,
            },
        },
    }
end

-- ============================================================================
-- Purchase Logic
-- ============================================================================

function ShopModal._DoPurchase(productId, productName, price)
    UI.Modal.Confirm({
        title = "确认购买",
        message = string.format("花费 💎%d 购买「%s」？", price, productName),
        onConfirm = function()
            local ok, reason = ShopManager.Purchase(productId)
            if ok then
                UI.Modal.Alert({
                    title = "购买成功",
                    message = string.format("「%s」已解锁！", productName),
                })
                -- Refresh the modal content
                ShopModal._RefreshContent()
                if onChanged_ then onChanged_() end
            else
                local msg = "购买失败"
                if reason == "insufficient_diamonds" then
                    msg = "钻石不足！"
                elseif reason == "already_owned" then
                    msg = "你已经拥有该商品了"
                end
                UI.Modal.Alert({
                    title = "购买失败",
                    message = msg,
                })
            end
        end,
    })
end

-- ============================================================================
-- Refresh Content (rebuild tabs after purchase)
-- ============================================================================

function ShopModal._BuildTabs()
    local tabs = UI.Tabs {
        tabs = {
            { id = "skins", label = "🎨 皮肤" },
            { id = "items", label = "⚔️ 道具" },
        },
        activeTab = activeTab_,
        variant = "pills",
        height = 420,
        onChange = function(self, tabId)
            activeTab_ = tabId
        end,
    }
    -- Must register content via SetTabContent (Tabs.Init does NOT read props.tabs[i].content)
    tabs:SetTabContent("skins", BuildSkinsTab())
    tabs:SetTabContent("items", BuildItemsTab())
    return tabs
end

function ShopModal._RefreshContent()
    if not modal_ then return end
    modal_:ClearContent()
    modal_:AddContent(ShopModal._BuildTabs())
end

-- ============================================================================
-- Open / Close
-- ============================================================================

--- Open the shop modal
--- @param opts table|nil  { onChanged = function }
function ShopModal.Open(opts)
    opts = opts or {}
    onChanged_ = opts.onChanged

    -- Ensure shop data is loaded
    ShopManager.Load()

    -- Ensure equipped items are up-to-date from ShopManager
    ItemSystem.LoadEquipped()

    -- Close previous if exists
    if modal_ then
        modal_:Close()
        modal_ = nil
    end

    modal_ = UI.Modal {
        title = "💎 商店",
        size = "lg",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
    }

    modal_:AddContent(ShopModal._BuildTabs())

    modal_:Open()
end

--- Close the shop modal
function ShopModal.Close()
    if modal_ then
        modal_:Close()
        modal_ = nil
    end
    activeTab_ = "skins"
end

--- Check if the shop modal is open
function ShopModal.IsOpen()
    return modal_ ~= nil and modal_:IsOpen()
end

return ShopModal
