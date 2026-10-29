--[[
Clean copy of the reader's pixels under the ink, so removed ink (eraser,
undo) can be wiped off the screen buffer without asking KOReader to repaint
the reader, which for reflowable books means crengine drawing the whole page
again.

Captured right after ReaderView painted and before the ink layer is
composited, but only over the area that can hold ink: the layer's ink box at
paint time, grown (`cover`) by every area new ink is composited onto later.
Outside that area the screen buffer holds no ink, so it can be copied in as
clean whenever the area grows.

Coordinates are those of the ink layer; the screen buffer pixel of (x, y) is
(ox + x, oy + y).
]]

local BlitBuffer = require("ffi/blitbuffer")

local PageSnapshot = {}
PageSnapshot.__index = PageSnapshot

function PageSnapshot.new(w, h)
    return setmetatable({ w = w, h = h, bb = nil, src = nil, valid = nil, ox = 0, oy = 0 }, PageSnapshot)
end

-- Integer box clamped to the snapshot, or nil when empty
local function clampBox(self, b)
    local x0, y0 = math.max(0, math.floor(b[1])), math.max(0, math.floor(b[2]))
    local x1, y1 = math.min(self.w, math.ceil(b[3])), math.min(self.h, math.ceil(b[4]))
    if x1 <= x0 or y1 <= y0 then return nil end
    return { x0, y0, x1, y1 }
end

local function copyIn(self, x0, y0, x1, y1)
    if x1 <= x0 or y1 <= y0 then return end
    self.bb:blitFrom(self.src, x0, y0, self.ox + x0, self.oy + y0, x1 - x0, y1 - y0)
end

-- Starts over after the reader painted `src` with the layer origin at
-- (ox, oy): keeps the pixels under `box` ({x0, y0, x1, y1}, nil = no ink).
function PageSnapshot:capture(src, ox, oy, box)
    self.src, self.ox, self.oy = src, ox, oy
    self.valid = nil
    if self.bb and (self.bb:getType() ~= src:getType() or self.bb:getInverse() ~= src:getInverse()) then
        self.bb:free()
        self.bb = nil
    end
    self.captured = true
    if box then self:cover(box) end
end

-- Makes sure the snapshot holds the clean pixels under `box`, copying in
-- whatever part of it is new from the screen buffer, which must not have
-- ink there yet. Returns false when nothing was captured since the last
-- invalidate.
function PageSnapshot:cover(box)
    if not self.captured then return false end
    local b = clampBox(self, box)
    if not b then return true end
    if not self.bb then
        self.bb = BlitBuffer.new(self.w, self.h, self.src:getType())
        if self.src:getInverse() == 1 then self.bb:setInverse(1) end
    end
    local v = self.valid
    if not v then
        copyIn(self, b[1], b[2], b[3], b[4])
        self.valid = b
        return true
    end
    -- New bounding box; copy the bands of it outside the valid box
    local u = { math.min(v[1], b[1]), math.min(v[2], b[2]), math.max(v[3], b[3]), math.max(v[4], b[4]) }
    copyIn(self, u[1], u[2], u[3], v[2])  -- above
    copyIn(self, u[1], v[4], u[3], u[4])  -- below
    copyIn(self, u[1], v[2], v[1], v[4])  -- left
    copyIn(self, v[3], v[2], u[3], v[4])  -- right
    self.valid = u
    return true
end

-- Copies the clean pixels under `box` back onto the screen buffer. Only
-- valid after cover(box) returned true.
function PageSnapshot:restore(box)
    local b = clampBox(self, box)
    if not b or not self.bb then return end
    self.src:blitFrom(self.bb, self.ox + b[1], self.oy + b[2], b[1], b[2], b[3] - b[1], b[4] - b[2])
end

function PageSnapshot:invalidate()
    self.captured = false
    self.valid = nil
end

function PageSnapshot:free()
    if self.bb then
        self.bb:free()
        self.bb = nil
    end
    self:invalidate()
    self.src = nil
end

return PageSnapshot
