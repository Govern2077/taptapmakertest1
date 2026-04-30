-- ============================================================================
-- Expressions.lua - Ball Face Expression Presets (NanoVG)
-- Each expression draws eyes + mouth relative to ball center
-- ============================================================================

local Expressions = {}

-- ============================================================================
-- Expression List (for UI display)
-- ============================================================================

Expressions.list = {
    { id = "happy",      name = "开心",   emoji = "😊" },
    { id = "angry",      name = "愤怒",   emoji = "😠" },
    { id = "cool",       name = "酷",     emoji = "😎" },
    { id = "surprised",  name = "惊讶",   emoji = "😲" },
    { id = "dizzy",      name = "晕眩",   emoji = "😵" },
    { id = "determined", name = "坚定",   emoji = "😤" },
    { id = "smug",       name = "得意",   emoji = "😏" },
    { id = "crying",     name = "哭泣",   emoji = "😢" },
}

-- ============================================================================
-- Helper: draw two symmetric eyes
-- ============================================================================

local function eyeOffset(radius)
    return radius * 0.28, radius * 0.15  -- horizontal, vertical offset from center
end

-- ============================================================================
-- Expression Draw Functions
-- Each: Draw(vg, cx, cy, radius)
-- cx, cy = ball center in screen coords, radius = ball radius
-- ============================================================================

local drawFuncs = {}

-- Happy: arc eyes (^_^) + smile
drawFuncs.happy = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)
    local es = r * 0.12  -- eye size

    -- Eyes (happy arcs)
    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 220))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.06))
    nvgLineCap(vg, NVG_ROUND)
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgArc(vg, cx + ex * sx, cy - ey, es, math.pi, 0, NVG_CW)
        nvgStroke(vg)
    end

    -- Smile
    nvgBeginPath(vg)
    nvgArc(vg, cx, cy + r * 0.1, r * 0.22, 0.2, math.pi - 0.2, NVG_CW)
    nvgStroke(vg)
end

-- Angry: V-brows + gritting teeth
drawFuncs.angry = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)
    local es = r * 0.09

    nvgFillColor(vg, nvgRGBA(40, 40, 40, 230))

    -- Eyes (small circles)
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgCircle(vg, cx + ex * sx, cy - ey, es)
        nvgFill(vg)
    end

    -- V-brows
    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 230))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.07))
    nvgLineCap(vg, NVG_ROUND)
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx + (ex - r * 0.12) * sx, cy - ey - r * 0.12)
        nvgLineTo(vg, cx + (ex + r * 0.12) * sx, cy - ey - r * 0.2)
        nvgStroke(vg)
    end

    -- Gritting mouth (rounded corners)
    local mouthW = r * 0.36
    local mouthH = r * 0.1
    local mouthR = mouthH * 0.4  -- corner radius
    nvgBeginPath(vg)
    nvgRoundedRect(vg, cx - mouthW / 2, cy + r * 0.15, mouthW, mouthH, mouthR)
    nvgFillColor(vg, nvgRGBA(40, 40, 40, 200))
    nvgFill(vg)
end

-- Cool: sunglasses + slight smirk
drawFuncs.cool = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)

    -- Sunglasses
    nvgFillColor(vg, nvgRGBA(30, 30, 30, 240))
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgRoundedRect(vg, cx + ex * sx - r * 0.14, cy - ey - r * 0.08, r * 0.28, r * 0.16, r * 0.04)
        nvgFill(vg)
    end
    -- Bridge
    nvgStrokeColor(vg, nvgRGBA(30, 30, 30, 240))
    nvgStrokeWidth(vg, math.max(1, r * 0.05))
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - ex + r * 0.14, cy - ey)
    nvgLineTo(vg, cx + ex - r * 0.14, cy - ey)
    nvgStroke(vg)

    -- Smirk
    nvgStrokeWidth(vg, math.max(1.5, r * 0.06))
    nvgLineCap(vg, NVG_ROUND)
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - r * 0.12, cy + r * 0.18)
    nvgBezierTo(vg, cx, cy + r * 0.22, cx + r * 0.05, cy + r * 0.12, cx + r * 0.18, cy + r * 0.1)
    nvgStroke(vg)
end

-- Surprised: round eyes + O mouth
drawFuncs.surprised = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)
    local es = r * 0.11

    -- Big round eyes
    nvgFillColor(vg, nvgRGBA(255, 255, 255, 255))
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgCircle(vg, cx + ex * sx, cy - ey, es)
        nvgFill(vg)
        nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 230))
        nvgStrokeWidth(vg, math.max(1, r * 0.04))
        nvgStroke(vg)
        -- Pupil
        nvgBeginPath(vg)
        nvgCircle(vg, cx + ex * sx, cy - ey, es * 0.5)
        nvgFillColor(vg, nvgRGBA(40, 40, 40, 240))
        nvgFill(vg)
    end

    -- O mouth
    nvgBeginPath(vg)
    nvgEllipse(vg, cx, cy + r * 0.2, r * 0.1, r * 0.14)
    nvgFillColor(vg, nvgRGBA(40, 40, 40, 200))
    nvgFill(vg)
end

-- Dizzy: spiral eyes + wavy mouth
drawFuncs.dizzy = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)

    -- X eyes
    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 220))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.06))
    nvgLineCap(vg, NVG_ROUND)
    local xs = r * 0.1
    for _, sx in ipairs({ -1, 1 }) do
        local ecx = cx + ex * sx
        local ecy = cy - ey
        nvgBeginPath(vg)
        nvgMoveTo(vg, ecx - xs, ecy - xs)
        nvgLineTo(vg, ecx + xs, ecy + xs)
        nvgStroke(vg)
        nvgBeginPath(vg)
        nvgMoveTo(vg, ecx + xs, ecy - xs)
        nvgLineTo(vg, ecx - xs, ecy + xs)
        nvgStroke(vg)
    end

    -- Wavy mouth
    nvgBeginPath(vg)
    local my = cy + r * 0.2
    nvgMoveTo(vg, cx - r * 0.2, my)
    nvgBezierTo(vg, cx - r * 0.1, my - r * 0.08, cx, my + r * 0.08, cx + r * 0.1, my)
    nvgBezierTo(vg, cx + r * 0.15, my - r * 0.05, cx + r * 0.18, my + r * 0.03, cx + r * 0.2, my)
    nvgStroke(vg)
end

-- Determined: flat brows + tight lips
drawFuncs.determined = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)
    local es = r * 0.09

    -- Focused eyes
    nvgFillColor(vg, nvgRGBA(40, 40, 40, 240))
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgCircle(vg, cx + ex * sx, cy - ey, es)
        nvgFill(vg)
    end

    -- Flat brows
    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 230))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.07))
    nvgLineCap(vg, NVG_ROUND)
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx + (ex - r * 0.12) * sx, cy - ey - r * 0.16)
        nvgLineTo(vg, cx + (ex + r * 0.12) * sx, cy - ey - r * 0.16)
        nvgStroke(vg)
    end

    -- Tight lips (horizontal line)
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - r * 0.15, cy + r * 0.18)
    nvgLineTo(vg, cx + r * 0.15, cy + r * 0.18)
    nvgStroke(vg)
end

-- Smug: half-closed eyes + crooked smile
drawFuncs.smug = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)

    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 220))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.06))
    nvgLineCap(vg, NVG_ROUND)

    -- Half-closed eyes (horizontal lines, slightly curved)
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgMoveTo(vg, cx + (ex - r * 0.1) * sx, cy - ey)
        nvgLineTo(vg, cx + (ex + r * 0.1) * sx, cy - ey - r * 0.03)
        nvgStroke(vg)
    end

    -- Crooked smile
    nvgBeginPath(vg)
    nvgMoveTo(vg, cx - r * 0.08, cy + r * 0.18)
    nvgBezierTo(vg, cx + r * 0.05, cy + r * 0.25, cx + r * 0.15, cy + r * 0.15, cx + r * 0.22, cy + r * 0.1)
    nvgStroke(vg)
end

-- Crying: teary eyes + sad mouth
drawFuncs.crying = function(vg, cx, cy, r)
    local ex, ey = eyeOffset(r)
    local es = r * 0.09

    -- Sad eyes
    nvgFillColor(vg, nvgRGBA(40, 40, 40, 220))
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgCircle(vg, cx + ex * sx, cy - ey, es)
        nvgFill(vg)
    end

    -- Tears
    nvgFillColor(vg, nvgRGBA(100, 180, 255, 180))
    for _, sx in ipairs({ -1, 1 }) do
        nvgBeginPath(vg)
        nvgEllipse(vg, cx + ex * sx + r * 0.04 * sx, cy - ey + r * 0.18, r * 0.04, r * 0.1)
        nvgFill(vg)
    end

    -- Sad mouth (upside-down arc)
    nvgStrokeColor(vg, nvgRGBA(40, 40, 40, 220))
    nvgStrokeWidth(vg, math.max(1.5, r * 0.06))
    nvgLineCap(vg, NVG_ROUND)
    nvgBeginPath(vg)
    nvgArc(vg, cx, cy + r * 0.32, r * 0.15, math.pi + 0.3, -0.3, NVG_CW)
    nvgStroke(vg)
end

-- ============================================================================
-- Public API
-- ============================================================================

--- Draw expression on a ball
---@param vg userdata  NanoVG context
---@param id string    Expression id (e.g. "happy")
---@param cx number    Ball center X in screen coords
---@param cy number    Ball center Y in screen coords
---@param radius number Ball radius in screen coords
function Expressions.Draw(vg, id, cx, cy, radius)
    if not id then return end
    local fn = drawFuncs[id]
    if fn then
        nvgSave(vg)
        fn(vg, cx, cy, radius)
        nvgRestore(vg)
    end
end

--- Get expression info by id
function Expressions.GetInfo(id)
    for _, expr in ipairs(Expressions.list) do
        if expr.id == id then return expr end
    end
    return nil
end

return Expressions
