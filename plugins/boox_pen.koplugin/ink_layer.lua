--[[
Cached raster of the ink on one view (page, layout, scroll position), as in
Onyx Notes / NeoReader: strokes are rasterized once into an offscreen
coverage mask, new strokes are drawn into it incrementally, and every
repaint just composites the mask over the page. Repaint cost no longer
grows with the amount of ink.

One unrotated BB8 mask per ink color (0 = no ink, 0xFF = ink), composited
with colorblitFrom, the C-accelerated path KOReader uses for glyphs.
]]

local BlitBuffer = require("ffi/blitbuffer")
local ffi = require("ffi")
local Renderer = require("renderer")

local InkLayer = {}
InkLayer.__index = InkLayer

function InkLayer.new(w, h)
    return setmetatable({ w = w, h = h, masks = {}, key = nil, box = nil }, InkLayer)
end

local function maskFor(self, color)
    local m = self.masks[color]
    if not m then
        -- calloc'ed: starts fully transparent
        m = BlitBuffer.new(self.w, self.h, BlitBuffer.TYPE_BB8)
        self.masks[color] = m
    end
    return m
end

local function growBox(self, x0, y0, x1, y1)
    local b = self.box
    if not b then
        self.box = { x0, y0, x1, y1 }
    else
        if x0 < b[1] then b[1] = x0 end
        if y0 < b[2] then b[2] = y0 end
        if x1 > b[3] then b[3] = x1 end
        if y1 > b[4] then b[4] = y1 end
    end
end

-- Rasterizes `stroke` with transform tx into the mask of its color.
function InkLayer:addStroke(stroke, tx, weight)
    local color = tonumber(stroke.c) or 0
    local fill, box = Renderer.maskFiller(maskFor(self, color))
    Renderer.fillStroke(fill, stroke, tx, weight)
    local x0, y0, x1, y1 = box()
    if x0 then growBox(self, x0, y0, x1, y1) end
end

-- Zeroes the rows y0..y1-1, columns x0..x1-1 of every mask (clamped).
local function zeroRect(self, x0, y0, x1, y1)
    x0, y0 = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
    x1, y1 = math.min(self.w, math.ceil(x1)), math.min(self.h, math.ceil(y1))
    if x1 <= x0 or y1 <= y0 then return end
    for _, m in pairs(self.masks) do
        local data = ffi.cast("uint8_t*", m.data)
        local stride = m.stride
        if x0 == 0 and x1 == self.w and stride == self.w then
            ffi.fill(data + y0 * stride, (y1 - y0) * stride, 0)
        else
            for y = y0, y1 - 1 do
                ffi.fill(data + y * stride + x0, x1 - x0, 0)
            end
        end
    end
end

-- Erases the ink inside the screen box {x0, y0, x1, y1}. The layer's own
-- box is kept as is (it only has to be an upper bound).
function InkLayer:clearRect(b)
    zeroRect(self, b[1], b[2], b[3], b[4])
end

-- Erases all ink and forgets the view key.
function InkLayer:clear()
    local b = self.box
    if b then zeroRect(self, b[1], b[2], b[3], b[4]) end
    self.box = nil
    self.key = nil
end

-- Paints the ink onto bb, with the layer's origin at (x, y).
function InkLayer:compose(bb, x, y)
    local b = self.box
    if not b then return end
    local w, h = b[3] - b[1], b[4] - b[2]
    if w <= 0 or h <= 0 then return end
    for color, m in pairs(self.masks) do
        bb:colorblitFrom(m, x + b[1], y + b[2], b[1], b[2], w, h, BlitBuffer.Color8(color))
    end
end

-- Paints only the part of the ink inside the screen box {x0, y0, x1, y1}
-- (layer coordinates) onto bb, with the layer's origin at (x, y).
function InkLayer:composeRect(bb, x, y, r)
    local b = self.box
    if not b then return end
    local x0, y0 = math.max(b[1], math.floor(r[1])), math.max(b[2], math.floor(r[2]))
    local x1, y1 = math.min(b[3], math.ceil(r[3])), math.min(b[4], math.ceil(r[4]))
    if x1 <= x0 or y1 <= y0 then return end
    for color, m in pairs(self.masks) do
        bb:colorblitFrom(m, x + x0, y + y0, x0, y0, x1 - x0, y1 - y0, BlitBuffer.Color8(color))
    end
end

function InkLayer:free()
    for color, m in pairs(self.masks) do
        m:free()
        self.masks[color] = nil
    end
    self.box = nil
    self.key = nil
end

return InkLayer
