-- ============================================================================
-- StartPage.lua - Start Menu with AI Battle / Ball Cultivation buttons
-- ============================================================================

local UI = require("urhox-libs/UI")

local StartPage = {}

--- Show the start page
---@param callbacks table { onBattle: function, onCultivation: function }
function StartPage.Show(callbacks)
    local root = UI.Panel {
        width = "100%", height = "100%",
        backgroundColor = "#0a0a14",
        justifyContent = "center",
        alignItems = "center",
        children = {
            -- Title
            UI.Label {
                text = "球球大作战",
                fontSize = 52,
                color = "#FFFFFF",
                marginBottom = 8,
            },
            UI.Label {
                text = "Ball Battle Arena",
                fontSize = 16,
                color = "#666666",
                marginBottom = 50,
            },

            -- AI Battle button
            UI.Button {
                text = "AI 对战",
                variant = "primary",
                width = 280, height = 56,
                fontSize = 20,
                marginBottom = 16,
                onClick = function()
                    if callbacks and callbacks.onBattle then
                        callbacks.onBattle()
                    end
                end,
            },

            -- Ball Cultivation button
            UI.Button {
                text = "球球培养",
                variant = "outline",
                width = 280, height = 56,
                fontSize = 20,
                marginBottom = 50,
                onClick = function()
                    if callbacks and callbacks.onCultivation then
                        callbacks.onCultivation()
                    end
                end,
            },

            -- Hints
            UI.Label {
                text = "AI 对战: 与随机 AI 球进行技能对决",
                fontSize = 13,
                color = "#555555",
                marginBottom = 6,
            },
            UI.Label {
                text = "球球培养: 自定义颜色、表情和技能配置",
                fontSize = 13,
                color = "#555555",
            },
        },
    }
    UI.SetRoot(root)
end

return StartPage
