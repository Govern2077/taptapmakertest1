-- ============================================================================
-- TriangleFill.lua - Reusable animated triangle material effect
-- Renders animated fading triangles inside a region (circle or rectangle)
-- Colors randomly offset from a base color
-- ============================================================================

---@class TriangleFillConfig
---@field maxTriangles number? max concurrent triangles (default 80)
---@field spawnRate number? triangles per second (default 160)
---@field triLife number? seconds per triangle lifecycle (default 0.5)
---@field maxAlpha number? peak alpha 0-255 (default 128)
---@field sizeMin number? min triangle size (default 30)
---@field sizeMax number? max triangle size (default 110)
---@field colorOffset number? per-channel offset from base color (default 30)
---@field baseColor number[]? {r, g, b} base color (default {255,255,255})

local TriangleFill = {}
TriangleFill.__index = TriangleFill

-- ============================================================================
-- Helpers
-- ============================================================================

local function ClampByte(v)
    if v < 0 then return 0 end
    if v > 255 then return 255 end
    return math.floor(v)
end

-- ============================================================================
-- Constructor
-- ============================================================================

---@param config TriangleFillConfig?
function TriangleFill.new(config)
    config = config or {}
    local self = setmetatable({}, TriangleFill)
    self.maxTriangles = config.maxTriangles or 80
    self.spawnRate    = config.spawnRate or 160
    self.triLife      = config.triLife or 0.5
    self.maxAlpha     = config.maxAlpha or 128
    self.sizeMin      = config.sizeMin or 30
    self.sizeMax      = config.sizeMax or 110
    self.colorOffset  = config.colorOffset or 30
    self.baseColor    = config.baseColor or { 255, 255, 255 }

    self.triangles    = {}
    self.spawnAccum   = 0
    return self
end

-- ============================================================================
-- Base color
-- ============================================================================

---@param r number
---@param g number
---@param b number
function TriangleFill:SetBaseColor(r, g, b)
    self.baseColor = { r, g, b }
end

-- ============================================================================
-- Internal: spawn helpers
-- ============================================================================

--- Spawn a triangle at random position within a circle
---@param radius number circle radius
---@return table triangle data
function TriangleFill:SpawnCircle(radius)
    local angle = math.random() * math.pi * 2
    local dist  = math.sqrt(math.random()) * radius * 0.85
    local bc    = self.baseColor
    return {
        offX     = math.cos(angle) * dist,
        offY     = math.sin(angle) * dist,
        size     = self.sizeMin + math.random() * (self.sizeMax - self.sizeMin),
        rotation = math.random() * math.pi * 2,
        r        = ClampByte(bc[1] + math.random(-self.colorOffset, self.colorOffset)),
        g        = ClampByte(bc[2] + math.random(-self.colorOffset, self.colorOffset)),
        b        = ClampByte(bc[3] + math.random(-self.colorOffset, self.colorOffset)),
        elapsed  = 0,
    }
end

--- Spawn a triangle at random position within a rectangle
---@param w number rect width
---@param h number rect height
---@return table triangle data
function TriangleFill:SpawnRect(w, h)
    local bc = self.baseColor
    return {
        offX     = (math.random() - 0.5) * w,
        offY     = (math.random() - 0.5) * h,
        size     = self.sizeMin + math.random() * (self.sizeMax - self.sizeMin),
        rotation = math.random() * math.pi * 2,
        r        = ClampByte(bc[1] + math.random(-self.colorOffset, self.colorOffset)),
        g        = ClampByte(bc[2] + math.random(-self.colorOffset, self.colorOffset)),
        b        = ClampByte(bc[3] + math.random(-self.colorOffset, self.colorOffset)),
        elapsed  = 0,
    }
end

-- ============================================================================
-- Update (call once per frame)
-- ============================================================================

---@param dt number delta time in seconds
function TriangleFill:Update(dt)
    local tris = self.triangles
    local triLife = self.triLife
    -- Age and remove expired
    for i = #tris, 1, -1 do
        tris[i].elapsed = tris[i].elapsed + dt
        if tris[i].elapsed >= triLife then
            table.remove(tris, i)
        end
    end
    self.spawnAccum = self.spawnAccum + dt
end

-- ============================================================================
-- Internal: draw triangles offset from a center point
-- ============================================================================

---@param vg userdata NanoVG context
---@param cx number center X
---@param cy number center Y
function TriangleFill:DrawTriangles(vg, cx, cy)
    local tris    = self.triangles
    local triLife = self.triLife
    local maxAlpha = self.maxAlpha

    for _, tri in ipairs(tris) do
        local t     = tri.elapsed / triLife
        local alpha = math.sin(t * math.pi) * maxAlpha
        if alpha >= 1 then
            nvgSave(vg)
            nvgTranslate(vg, cx + tri.offX, cy + tri.offY)
            nvgRotate(vg, tri.rotation)

            local s = tri.size
            nvgBeginPath(vg)
            nvgMoveTo(vg, 0, -s * 0.6)
            nvgLineTo(vg, -s * 0.5, s * 0.4)
            nvgLineTo(vg, s * 0.5, s * 0.4)
            nvgClosePath(vg)
            nvgFillColor(vg, nvgRGBA(tri.r, tri.g, tri.b, math.floor(alpha)))
            nvgFill(vg)

            nvgRestore(vg)
        end
    end
end

-- ============================================================================
-- RenderCircle: spawn + draw inside a circle (no mask — caller handles masking)
-- ============================================================================

---@param vg userdata
---@param cx number circle center X
---@param cy number circle center Y
---@param radius number circle radius
function TriangleFill:RenderCircle(vg, cx, cy, radius)
    -- Spawn
    local interval = 1.0 / self.spawnRate
    while self.spawnAccum >= interval and #self.triangles < self.maxTriangles do
        table.insert(self.triangles, self:SpawnCircle(radius))
        self.spawnAccum = self.spawnAccum - interval
    end

    self:DrawTriangles(vg, cx, cy)
end

-- ============================================================================
-- RenderRect: spawn + draw inside a rounded rect (uses scissor clip)
-- ============================================================================

---@param vg userdata
---@param x number rect left
---@param y number rect top
---@param w number rect width
---@param h number rect height
---@param borderRadius number? corner radius (default 0)
function TriangleFill:RenderRect(vg, x, y, w, h, borderRadius)
    borderRadius = borderRadius or 0

    -- Spawn
    local interval = 1.0 / self.spawnRate
    while self.spawnAccum >= interval and #self.triangles < self.maxTriangles do
        table.insert(self.triangles, self:SpawnRect(w, h))
        self.spawnAccum = self.spawnAccum - interval
    end

    -- Clip to rect
    nvgSave(vg)
    nvgIntersectScissor(vg, x, y, w, h)
    self:DrawTriangles(vg, x + w / 2, y + h / 2)
    nvgRestore(vg)
end

-- ============================================================================
-- MaskCircles: draw a full-screen rect with circle holes to clip overflow
-- Used when multiple circles share one mask pass
-- ============================================================================

---@param vg userdata
---@param screenW number
---@param screenH number
---@param circles table[] array of {x, y, radius}
---@param bgR number background red
---@param bgG number background green
---@param bgB number background blue
function TriangleFill.MaskCircles(vg, screenW, screenH, circles, bgR, bgG, bgB)
    nvgBeginPath(vg)
    nvgRect(vg, 0, 0, screenW, screenH)
    for _, c in ipairs(circles) do
        nvgCircle(vg, c.x, c.y, c.radius)
        nvgPathWinding(vg, NVG_HOLE)
    end
    nvgFillColor(vg, nvgRGBA(bgR, bgG, bgB, 255))
    nvgFill(vg)
end

-- ============================================================================
-- MaskSingleCircle: mask everything outside a single circle
-- Uses a tight bounding box instead of full-screen for efficiency
-- ============================================================================

---@param vg userdata
---@param cx number circle center X
---@param cy number circle center Y
---@param radius number circle radius
---@param bgR number
---@param bgG number
---@param bgB number
function TriangleFill.MaskSingleCircle(vg, cx, cy, radius, bgR, bgG, bgB)
    local margin = 2
    local x = cx - radius - margin
    local y = cy - radius - margin
    local s = (radius + margin) * 2
    nvgBeginPath(vg)
    nvgRect(vg, x, y, s, s)
    nvgCircle(vg, cx, cy, radius)
    nvgPathWinding(vg, NVG_HOLE)
    nvgFillColor(vg, nvgRGBA(bgR, bgG, bgB, 255))
    nvgFill(vg)
end

return TriangleFill
