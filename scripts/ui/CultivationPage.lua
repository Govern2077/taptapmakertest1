-- ============================================================================
-- CultivationPage.lua - Ball Customization (Drag-Drop Skill Equipping)
-- Design: 1920×1080 proportions
-- Layout: Left (42%) = color bar + ball preview | Right (58%) = 3 tier rows
-- Drag: pool cards → equip slot | Click equip slot → unequip
-- ============================================================================

local UI              = require("urhox-libs/UI")
local ItemSlot        = require("urhox-libs/UI/Components/ItemSlot")
local DragDropContext = require("urhox-libs/UI/Components/DragDropContext")
local SkillRegistry   = require("game.SkillRegistry")
local BallCustomization = require("game.BallCustomization")

local CultivationPage = {}

-- ============================================================================
-- State
-- ============================================================================

local currentData_ = nil
local onSave_      = nil
local onBack_      = nil

local ballPreview_   = nil
local colorLabel_    = nil
local equipSlots_    = {}   -- { [tier] = ItemSlot }
local dragCtx_       = nil

-- ============================================================================
-- Constants (proportional to 1920×1080)
-- ============================================================================

local BALL_SIZE    = 460   -- diameter (~43% of 1080 height)
local SLOT_SIZE    = 70    -- equip slot & skill card size
local CARD_SIZE    = 70    -- pool skill card size
local CARD_GAP     = 12    -- gap between cards in pool

-- ============================================================================
-- Skill item helpers
-- ============================================================================

local SKILL_EMOJI = {
    water_ball   = "💧",
    fire_ball    = "🔥",
    leech        = "🪱",
    split_bubble = "🫧",
    laser        = "⚡",
    water_pillar = "🌊",
    inferno      = "💥",
    blood_bat    = "🦇",
}

--- Build item data for ItemSlot from a skill definition
---@param skill SkillDef
---@return table
local function makeSkillItem(skill)
    return {
        id   = skill.id,
        name = skill.name,
        icon = SKILL_EMOJI[skill.id] or "❓",
        type = skill.tier,
    }
end

-- ============================================================================
-- Tier definitions
-- ============================================================================

local TIER_DEFS = {
    { tier = "normal",   label = "普通技能", color = { 100, 180, 255 }, slotIcon = "🔹" },
    { tier = "enhanced", label = "强化技能", color = { 255, 180, 60 },  slotIcon = "🔸" },
    { tier = "ultimate", label = "终结技能", color = { 255, 80, 80 },   slotIcon = "💠" },
}

-- ============================================================================
-- Update equip slots from currentData_
-- ============================================================================

local function updateEquipSlots()
    for _, def in ipairs(TIER_DEFS) do
        local slot = equipSlots_[def.tier]
        if slot then
            local skillId = currentData_.skills[def.tier]
            if skillId then
                local skill = SkillRegistry.Get(skillId)
                if skill then
                    slot:SetItem(makeSkillItem(skill))
                else
                    slot:SetItem(nil)
                end
            else
                slot:SetItem(nil)
            end
        end
    end
end

-- ============================================================================
-- Build pool skill card (drag source)
-- ============================================================================

local function buildSkillCard(skill, dragContext)
    return ItemSlot {
        slotId       = "pool_" .. skill.id,
        slotCategory = "pool",
        slotType     = skill.tier,
        size         = CARD_SIZE,
        item         = makeSkillItem(skill),
        dragContext  = dragContext,
        borderRadius = 8,
        borderWidth  = 2,
        borderColor  = { skill.color.r, skill.color.g, skill.color.b, 120 },
        backgroundColor = {
            math.floor(skill.color.r * 0.35),
            math.floor(skill.color.g * 0.35),
            math.floor(skill.color.b * 0.35),
            230,
        },
    }
end

-- ============================================================================
-- Build a tier row (flexGrow=1 to distribute 3 rows equally)
-- ============================================================================

local function buildTierRow(def, dragContext)
    local skills = SkillRegistry.GetByTier(def.tier)

    -- ----------------------------------------------------------------
    -- Equip slot — NO dragContext so onSlotClick works for unequip.
    -- Manually registered as drop target below.
    -- ----------------------------------------------------------------
    local equipSlot = ItemSlot {
        slotId       = "equip_" .. def.tier,
        slotCategory = "equipment",
        slotType     = def.tier,
        slotTypeIcon = def.slotIcon,
        size         = SLOT_SIZE,
        item         = nil,
        -- intentionally NO dragContext here
        borderRadius = 8,
        borderWidth  = 2,
        borderColor  = { def.color[1], def.color[2], def.color[3], 160 },
        backgroundColor = { 25, 28, 42, 255 },
        onSlotClick  = function(slot, item)
            if item then
                currentData_.skills[def.tier] = nil
                updateEquipSlots()
            end
        end,
    }
    -- Register manually so FindDropTargetAt can find it
    dragContext:RegisterDropTarget(equipSlot)
    equipSlots_[def.tier] = equipSlot

    -- ----------------------------------------------------------------
    -- Pool cards
    -- ----------------------------------------------------------------
    local poolChildren = {}
    for _, skill in ipairs(skills) do
        table.insert(poolChildren, buildSkillCard(skill, dragContext))
    end
    if #poolChildren == 0 then
        table.insert(poolChildren, UI.Label {
            text = "暂无技能",
            fontSize = 13,
            color = "#555555",
        })
    end

    -- ----------------------------------------------------------------
    -- Row layout
    -- ----------------------------------------------------------------
    return UI.Panel {
        width = "100%",
        flexGrow = 1,
        flexDirection = "column",
        children = {
            -- Tier label
            UI.Label {
                text = def.label,
                fontSize = 16,
                fontWeight = "bold",
                color = { def.color[1], def.color[2], def.color[3], 255 },
                marginBottom = 8,
            },
            -- Equip slot + pool container
            UI.Panel {
                width = "100%",
                flexGrow = 1,
                flexShrink = 1,
                flexDirection = "row",
                alignItems = "flex-start",
                gap = 14,
                children = {
                    equipSlot,
                    -- Pool container (gray, holds skill cards)
                    UI.Panel {
                        flexGrow = 1,
                        flexShrink = 1,
                        minHeight = SLOT_SIZE + 20,
                        flexDirection = "row",
                        flexWrap = "wrap",
                        alignItems = "center",
                        alignContent = "center",
                        gap = CARD_GAP,
                        padding = 10,
                        backgroundColor = { 50, 52, 65, 200 },
                        borderRadius = 10,
                        children = poolChildren,
                    },
                },
            },
        },
    }
end

-- ============================================================================
-- Show Page
-- ============================================================================

---@param data table  Current customization data (deep-copied)
---@param callbacks table  { onSave, onBack }
function CultivationPage.Show(data, callbacks)
    currentData_ = BallCustomization.DeepCopy(data)
    onSave_ = callbacks and callbacks.onSave
    onBack_ = callbacks and callbacks.onBack
    equipSlots_ = {}

    -- ====================================================================
    -- DragDropContext (absolute overlay, last child for z-order)
    -- ====================================================================
    dragCtx_ = DragDropContext {
        width = "100%", height = "100%",
        position = "absolute",
        left = 0, top = 0,
        pointerEvents = "none",

        canDrop = function(itemData, sourceSlot, targetSlot)
            if not targetSlot or not sourceSlot then return false end
            if sourceSlot:GetSlotCategory() ~= "pool" then return false end
            if targetSlot:GetSlotCategory() ~= "equipment" then return false end
            return targetSlot:CanAcceptType(itemData.type)
        end,

        onDragEnd = function(itemData, sourceSlot, targetSlot, success)
            if success and targetSlot then
                local tier = itemData.type
                currentData_.skills[tier] = itemData.id
                updateEquipSlots()
            end
        end,
    }

    -- ====================================================================
    -- LEFT COLUMN (42% width): color adjust + ball preview
    -- ====================================================================

    ballPreview_ = UI.Panel {
        width = BALL_SIZE, height = BALL_SIZE,
        borderRadius = math.floor(BALL_SIZE / 2),
        backgroundColor = {
            currentData_.color.r,
            currentData_.color.g,
            currentData_.color.b, 255,
        },
        justifyContent = "center",
        alignItems = "center",
        children = {
            UI.Label {
                text = "玩家",
                fontSize = 32,
                fontWeight = "bold",
                color = "#FFFFFF",
                textAlign = "center",
            },
        },
    }

    colorLabel_ = UI.Label {
        text = string.format("RGB(%d, %d, %d)",
            currentData_.color.r, currentData_.color.g, currentData_.color.b),
        fontSize = 12,
        color = "#777777",
    }

    local leftColumn = UI.Panel {
        width = "42%",
        flexShrink = 0,
        flexDirection = "row",
        children = {
            -- Narrow color strip column (matches design's thin vertical bar)
            UI.Panel {
                width = 50,
                flexShrink = 0,
                flexDirection = "column",
                alignItems = "center",
                paddingTop = 16,
                gap = 10,
                children = {
                    UI.Label {
                        text = "颜色\n调节",
                        fontSize = 13,
                        fontWeight = "bold",
                        color = "#AAAAAA",
                        textAlign = "center",
                    },
                    -- Color picker in narrow strip
                    UI.ColorPicker {
                        value = {
                            currentData_.color.r,
                            currentData_.color.g,
                            currentData_.color.b, 255,
                        },
                        showAlpha = false,
                        onChange = function(self, color)
                            currentData_.color = { r = color[1], g = color[2], b = color[3] }
                            if ballPreview_ then
                                ballPreview_:SetStyle({
                                    backgroundColor = { color[1], color[2], color[3], 255 },
                                })
                            end
                            if colorLabel_ then
                                colorLabel_:SetText(string.format("RGB(%d, %d, %d)",
                                    color[1], color[2], color[3]))
                            end
                        end,
                    },
                },
            },
            -- Ball preview area (centered)
            UI.Panel {
                flexGrow = 1,
                flexShrink = 1,
                flexDirection = "column",
                justifyContent = "center",
                alignItems = "center",
                gap = 12,
                children = {
                    ballPreview_,
                    colorLabel_,
                },
            },
        },
    }

    -- ====================================================================
    -- RIGHT COLUMN (58%): 3 tier rows equally distributed
    -- ====================================================================

    local tierRows = {}
    for _, def in ipairs(TIER_DEFS) do
        table.insert(tierRows, buildTierRow(def, dragCtx_))
    end

    local rightColumn = UI.Panel {
        flexGrow = 1,
        flexShrink = 1,
        flexDirection = "column",
        padding = 16,
        gap = 10,
        children = tierRows,
    }

    -- ====================================================================
    -- ROOT
    -- ====================================================================

    local root = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = "#0a0a14",
        flexDirection = "column",
        children = {
            -- Header bar (slim)
            UI.Panel {
                width = "100%",
                height = 48,
                flexShrink = 0,
                flexDirection = "row",
                justifyContent = "space-between",
                alignItems = "center",
                paddingLeft = 16, paddingRight = 16,
                backgroundColor = { 12, 12, 26, 255 },
                children = {
                    UI.Button {
                        text = "返回",
                        variant = "outline",
                        width = 80, height = 34,
                        fontSize = 14,
                        onClick = function()
                            if onBack_ then onBack_() end
                        end,
                    },
                    UI.Label {
                        text = "球球培养",
                        fontSize = 20,
                        fontWeight = "bold",
                        color = "#FFFFFF",
                    },
                    UI.Button {
                        text = "保存",
                        variant = "primary",
                        width = 80, height = 34,
                        fontSize = 14,
                        onClick = function()
                            if onSave_ then onSave_(currentData_) end
                        end,
                    },
                },
            },

            -- Body
            UI.Panel {
                width = "100%",
                flexGrow = 1,
                flexShrink = 1,
                flexDirection = "row",
                children = {
                    leftColumn,
                    -- Vertical divider
                    UI.Panel {
                        width = 1,
                        height = "100%",
                        backgroundColor = { 50, 50, 70, 255 },
                        flexShrink = 0,
                    },
                    rightColumn,
                },
            },

            -- DragDropContext overlay (must be last child for z-order)
            dragCtx_,
        },
    }

    UI.SetRoot(root)
    updateEquipSlots()
end

return CultivationPage
