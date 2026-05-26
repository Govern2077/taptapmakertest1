-- ============================================================================
-- SettingsModal.lua - 设置弹窗（音乐/音效音量控制）
-- ============================================================================

local UI   = require("urhox-libs/UI")
local cjson = require("cjson")

local SettingsModal = {}

-- ============================================================================
-- Constants
-- ============================================================================

local SAVE_FILE = "settings_audio.json"
local DEFAULT_MUSIC_VOL  = 50
local DEFAULT_EFFECT_VOL = 80

-- ============================================================================
-- State
-- ============================================================================

---@type Modal|nil
local modal_ = nil
local musicVol_  = DEFAULT_MUSIC_VOL   -- 0-100
local effectVol_ = DEFAULT_EFFECT_VOL  -- 0-100
local loaded_    = false

-- ============================================================================
-- Persistence
-- ============================================================================

function SettingsModal.Load()
    if loaded_ then return end
    loaded_ = true

    if fileSystem:FileExists(SAVE_FILE) then
        local file = File(SAVE_FILE, FILE_READ)
        if file:IsOpen() then
            local str = file:ReadString()
            file:Close()
            local ok, data = pcall(cjson.decode, str)
            if ok and type(data) == "table" then
                musicVol_  = data.musicVol  or DEFAULT_MUSIC_VOL
                effectVol_ = data.effectVol or DEFAULT_EFFECT_VOL
            end
        end
    end

    -- Apply to engine
    SettingsModal._ApplyVolumes()
    print(string.format("[Settings] Loaded volumes: music=%d, effect=%d", musicVol_, effectVol_))
end

local function Save()
    local data = {
        musicVol  = musicVol_,
        effectVol = effectVol_,
        version   = 1,
    }
    local json = cjson.encode(data)
    local file = File(SAVE_FILE, FILE_WRITE)
    if file:IsOpen() then
        file:WriteString(json)
        file:Close()
    end
end

-- ============================================================================
-- Engine volume control
-- ============================================================================

function SettingsModal._ApplyVolumes()
    audio:SetMasterGain(SOUND_MUSIC,  musicVol_ / 100)
    audio:SetMasterGain(SOUND_EFFECT, effectVol_ / 100)
end

-- ============================================================================
-- UI
-- ============================================================================

local function BuildContent()
    -- Create labels first so sliders can reference them via closure
    local musicLabel = UI.Label {
        text = tostring(musicVol_),
        fontSize = 16,
        color = "#ffd54f",
        fontWeight = "bold",
    }

    local effectLabel = UI.Label {
        text = tostring(effectVol_),
        fontSize = 16,
        color = "#4fc3f7",
        fontWeight = "bold",
    }

    return UI.Panel {
        width = "100%",
        padding = 20,
        gap = 24,
        children = {
            -- Music volume
            UI.Panel {
                width = "100%",
                gap = 8,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "🎵 音乐音量",
                                fontSize = 16,
                                color = "#ffffff",
                            },
                            musicLabel,
                        },
                    },
                    UI.Slider {
                        value = musicVol_,
                        min = 0,
                        max = 100,
                        width = "100%",
                        onChange = function(_, v)
                            musicVol_ = math.floor(v + 0.5)
                            SettingsModal._ApplyVolumes()
                            musicLabel:SetText(tostring(musicVol_))
                        end,
                    },
                },
            },

            -- Effect volume
            UI.Panel {
                width = "100%",
                gap = 8,
                children = {
                    UI.Panel {
                        flexDirection = "row",
                        justifyContent = "space-between",
                        width = "100%",
                        children = {
                            UI.Label {
                                text = "🔊 音效音量",
                                fontSize = 16,
                                color = "#ffffff",
                            },
                            effectLabel,
                        },
                    },
                    UI.Slider {
                        value = effectVol_,
                        min = 0,
                        max = 100,
                        width = "100%",
                        onChange = function(_, v)
                            effectVol_ = math.floor(v + 0.5)
                            SettingsModal._ApplyVolumes()
                            effectLabel:SetText(tostring(effectVol_))
                        end,
                    },
                },
            },
        },
    }
end

-- ============================================================================
-- Public API
-- ============================================================================

function SettingsModal.Open()
    SettingsModal.Load()

    if modal_ then
        modal_:Close()
        modal_ = nil
    end

    modal_ = UI.Modal {
        title = "⚙ 设置",
        size = "sm",
        closeOnOverlay = true,
        closeOnEscape = true,
        showCloseButton = true,
        onClose = function()
            Save()
            modal_ = nil
        end,
    }

    modal_:AddContent(BuildContent())
    modal_:Open()
end

function SettingsModal.Close()
    if modal_ then
        Save()
        modal_:Close()
        modal_ = nil
    end
end

function SettingsModal.IsOpen()
    return modal_ ~= nil and modal_:IsOpen()
end

return SettingsModal
