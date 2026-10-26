local BlitBuffer = require("ffi/blitbuffer")

local floor = math.floor
local sqrt = math.sqrt
local abs = math.abs
local max = math.max
local min = math.min

local MIN_WIDTH = 1
local MAX_WIDTH = 24
-- Width multiplier = PRESSURE_BASE + PRESSURE_GAIN * p (p normalized 0..1):
-- ~1.0 at typical writing pressure, never below 0.75x the pen width.
local PRESSURE_BASE = 0.75
local PRESSURE_GAIN = 0.6
-- Below this radius a diagonal capsule can break into disconnected pixels
local MIN_RADIUS = 0.71

local function toColor(c)
    if type(c) == "number" then
        return BlitBuffer.Color8(c)
    elseif type(c) == "cdata" or (type(c) == "table" and c.getColor8) then
        return c
    end
    return BlitBuffer.COLOR_BLACK
end

local function round(v)
    return floor(v + 0.5)
end

local Renderer = {}

-- Rendered width in px for pen width w (hardware units), normalized
-- pressure p and the user's "ink after lift" weight.
function Renderer.pointWidth(w, p, weight)
    local mult = PRESSURE_BASE + PRESSURE_GAIN * (p or 0.5)
    return min(MAX_WIDTH, max(MIN_WIDTH, w * (weight or 1) * mult))
end

-- Filled disc of diameter d centered at (cx, cy), as horizontal spans.
function Renderer.drawDisc(bb, cx, cy, d, color)
    local r = d / 2
    if r <= 0.75 then
        bb:paintRect(floor(cx), floor(cy), 1, 1, color)
        return
    end
    local r2 = r * r
    for yy = floor(cy - r + 0.5), floor(cy + r - 0.5) do
        local dy = (yy + 0.5) - cy
        local hw = sqrt(max(0, r2 - dy * dy))
        local x0 = round(cx - hw)
        local x1 = round(cx + hw)
        if x1 <= x0 then x1 = x0 + 1 end
        bb:paintRect(x0, yy, x1 - x0, 1, color)
    end
end

-- Filled capsule: every pixel centre within r of the segment (x0,y0)-(x1,y1).
-- A capsule is convex, so each row is a single span (union of the two end
-- discs and the body band), and consecutive capsules share their end disc,
-- so joints are round at any angle: no notches, no cap bookkeeping.
function Renderer.drawCapsule(bb, x0, y0, x1, y1, r, color)
    if r < MIN_RADIUS then r = MIN_RADIUS end
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len < 0.5 then
        Renderer.drawDisc(bb, x1, y1, 2 * r, color)
        return
    end
    local ux, uy = dx / len, dy / len
    local r2 = r * r
    for row = floor(min(y0, y1) - r), floor(max(y0, y1) + r) do
        local yc = row + 0.5
        local xa, xb = math.huge, -math.huge
        -- End discs
        local ey0 = yc - y0
        if ey0 * ey0 <= r2 then
            local hw = sqrt(r2 - ey0 * ey0)
            xa, xb = min(xa, x0 - hw), max(xb, x0 + hw)
        end
        local ey1 = yc - y1
        if ey1 * ey1 <= r2 then
            local hw = sqrt(r2 - ey1 * ey1)
            xa, xb = min(xa, x1 - hw), max(xb, x1 + hw)
        end
        -- Body band, with u = x - x0 on this row:
        -- 0 <= u*ux + ey0*uy <= len and |ey0*ux - u*uy| <= r
        local lo, hi = -math.huge, math.huge
        local along = ey0 * uy
        if abs(ux) > 1e-6 then
            local a, b = -along / ux, (len - along) / ux
            if a > b then a, b = b, a end
            lo, hi = max(lo, a), min(hi, b)
        elseif along < 0 or along > len then
            lo, hi = 1, 0
        end
        local across = ey0 * ux
        if abs(uy) > 1e-6 then
            local a, b = (across - r) / uy, (across + r) / uy
            if a > b then a, b = b, a end
            lo, hi = max(lo, a), min(hi, b)
        elseif abs(across) > r then
            lo, hi = 1, 0
        end
        if lo <= hi then
            xa, xb = min(xa, x0 + lo), max(xb, x0 + hi)
        end
        if xa <= xb then
            -- Columns whose centres fall inside [xa, xb]; never less than
            -- one pixel, so hairlines stay connected.
            local c0 = math.ceil(xa - 0.5)
            local c1 = floor(xb - 0.5)
            if c1 < c0 then
                c0 = floor((xa + xb) / 2)
                c1 = c0
            end
            bb:paintRect(c0, row, c1 - c0 + 1, 1, color)
        end
    end
end

-- Point transform: screen = (o + v * s) per axis. Screen-normalized strokes
-- use { sx = screen_w, sy = screen_h, ox = 0, oy = 0 }; anchored strokes use
-- the anchor's screen position as origin and the font-size ratio as scale.
function Renderer.screenTransform(screen_w, screen_h, ox, oy)
    return { sx = screen_w, sy = screen_h, ox = ox or 0, oy = oy or 0 }
end

-- stroke = { w = pen width, c = gray, p = {x,y,p, ...} }
function Renderer.renderStroke(bb, stroke, tx, weight)
    local pts = stroke.p
    if not pts or #pts < 3 then return end
    local base_w = stroke.w or 5
    local color = toColor(stroke.c or 0)
    local n = floor(#pts / 3)

    local sx, sy, ox, oy = tx.sx, tx.sy, tx.ox, tx.oy
    local px = ox + pts[1] * sx
    local py = oy + pts[2] * sy
    local pw = Renderer.pointWidth(base_w, pts[3], weight)

    local drew = false
    for i = 2, n do
        local j = (i - 1) * 3 + 1
        local x = ox + pts[j] * sx
        local y = oy + pts[j + 1] * sy
        local w = Renderer.pointWidth(base_w, pts[j + 2], weight)
        local dx, dy = x - px, y - py
        if dx * dx + dy * dy >= 0.25 then
            -- Radius = half the mean width of the two ends; segments are
            -- only a few px long, so pressure still tapers smoothly.
            Renderer.drawCapsule(bb, px, py, x, y, (pw + w) / 4, color)
            drew = true
            px, py, pw = x, y, w
        else
            pw = max(pw, w)
        end
    end
    if not drew then
        Renderer.drawDisc(bb, px, py, pw, color)
    end
end

function Renderer.renderPageStrokes(bb, strokes, tx, weight)
    if not strokes or #strokes == 0 then return end
    for _, stroke in ipairs(strokes) do
        Renderer.renderStroke(bb, stroke, tx, weight)
    end
end

-- Screen-space bounding box {x, y, w, h} of a set of strokes drawn with
-- transform tx, padded by their maximum rendered width and clamped to the
-- screen. Returns nil for no points.
function Renderer.strokesBounds(strokes, tx, screen_w, screen_h, weight)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    local maxw = 0
    for _, stroke in ipairs(strokes) do
        local pts = stroke.p
        local wmax = Renderer.pointWidth(stroke.w or 5, 1, weight)
        if wmax > maxw then maxw = wmax end
        for j = 1, #pts - 2, 3 do
            local x, y = pts[j], pts[j + 1]
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
    end
    if x0 > x1 then return nil end
    -- Extra margin so the refresh also wipes the live hardware ink, whose
    -- exact pressure-dependent width is up to the firmware.
    local pad = math.ceil(maxw / 2) + 6
    local left = max(0, floor(tx.ox + x0 * tx.sx) - pad)
    local top = max(0, floor(tx.oy + y0 * tx.sy) - pad)
    local right = min(screen_w, math.ceil(tx.ox + x1 * tx.sx) + pad)
    local bottom = min(screen_h, math.ceil(tx.oy + y1 * tx.sy) + pad)
    if right <= left or bottom <= top then return nil end
    return { x = left, y = top, w = right - left, h = bottom - top }
end

return Renderer
