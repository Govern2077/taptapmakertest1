-- ============================================================================
-- TriangleButton.lua - Button with animated triangle fill background
-- Extends urhox-libs Button, injects TriangleFill between background and text
-- ============================================================================

local Button = require("urhox-libs/UI/Widgets/Button")
local Theme  = require("urhox-libs/UI/Core/Theme")
local TriangleFill = require("effects.TriangleFill")

---@class TriangleButton : Button
local TriangleButton = Button:Extend("TriangleButton")

-- ============================================================================
-- Constructor
-- ============================================================================

function TriangleButton:Init(props)
    -- Initialize parent Button
    Button.Init(self, props)

    -- Resolve base color for triangles from the button's background
    local bgColor = self:ResolveStateBgColor() or { 100, 100, 200 }

    -- Create TriangleFill instance with parameters scaled for button size
    local h = props.height or 44
    local sizeScale = h / 56  -- normalize to reference button height
    self.triFill_ = TriangleFill.new({
        maxTriangles = 20,
        spawnRate    = 40,
        triLife      = 0.5,
        maxAlpha     = 100,
        sizeMin      = math.max(6, math.floor(10 * sizeScale)),
        sizeMax      = math.max(14, math.floor(30 * sizeScale)),
        colorOffset  = 25,
        baseColor    = { bgColor[1] or 100, bgColor[2] or 100, bgColor[3] or 200 },
    })
    self.triLastTime_ = -1
end

-- ============================================================================
-- Override: must be stateful (for BaseUpdate to be called)
-- ============================================================================

function TriangleButton:IsStateful()
    return true
end

-- ============================================================================
-- Override BaseUpdate: update triangle animation
-- ============================================================================

function TriangleButton:BaseUpdate(dt)
    -- Call parent BaseUpdate (handles transitions)
    Button.BaseUpdate(self, dt)

    -- Update triangle fill
    if self.triFill_ then
        self.triFill_:Update(dt)

        -- Sync base color when state changes (hover/pressed)
        local bgColor = self:ResolveStateBgColor()
        if bgColor then
            self.triFill_:SetBaseColor(bgColor[1] or 100, bgColor[2] or 100, bgColor[3] or 200)
        end
    end
end

-- ============================================================================
-- Override Render: inject triangle fill between background and text
-- ============================================================================

function TriangleButton:Render(nvg)
    local l = self:GetAbsoluteLayout()
    local props = self.props
    local state = self.state

    local disabled = props.disabled
    local borderRadius = props.borderRadius or Theme.BaseRadius("md")

    -- Update decoration state
    local decorState = disabled and "disabled" or (state.pressed and "pressed" or (state.hovered and "hover" or "default"))
    self:UpdateDecorationState(decorState)

    -- Determine background color (same logic as Button)
    local bgColor = self.renderProps_.backgroundColor
    local bgImage, textColor

    if not bgColor then
        bgColor = self:ResolveStateBgColor()
    end

    if disabled then
        bgImage = props.disabledBackgroundImage or props.backgroundImage
        textColor = props.textColor or Theme.Color("disabledText")
    elseif state.pressed then
        bgImage = props.pressedBackgroundImage or props.backgroundImage
        textColor = props.textColor or Theme.Color("text")
    elseif state.hovered then
        bgImage = props.hoverBackgroundImage or props.backgroundImage
        textColor = props.textColor or Theme.Color("text")
    else
        bgImage = props.backgroundImage
        textColor = props.textColor or Theme.Color("text")
    end

    -- 1. Render background
    self:RenderFullBackground(nvg, {
        backgroundColor = bgColor,
        backgroundImage = bgImage,
        backgroundFit = props.backgroundFit,
        backgroundSlice = props.backgroundSlice,
        borderRadius = borderRadius,
    })

    -- 2. Render triangle fill (clipped to button rect)
    if self.triFill_ and not disabled then
        self.triFill_:RenderRect(nvg, l.x, l.y, l.w, l.h, borderRadius)
    end

    -- 3. Draw text
    local text = props.text or ""
    if text ~= "" then
        nvgSave(nvg)
        nvgIntersectScissor(nvg, l.x, l.y, l.w, l.h)
        nvgFontFace(nvg, Theme.FontFamily())
        nvgFontSize(nvg, Theme.FontSize(props.fontSize))
        nvgFillColor(nvg, nvgRGBA(textColor[1], textColor[2], textColor[3], textColor[4] or 255))
        nvgTextAlign(nvg, NVG_ALIGN_CENTER_VISUAL + NVG_ALIGN_MIDDLE)
        nvgText(nvg, l.x + l.w / 2, l.y + l.h / 2, text, nil)
        nvgRestore(nvg)
    end
end

return TriangleButton
