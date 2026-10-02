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
-- Joints sharper than this (cosine of the turn) get a round cap
local SHARP_TURN_COS = 0.7

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

-- Thick line body: one span per pixel along the major axis, with the span
-- stretched by 1/cos(angle) so the visible thickness stays w on diagonals.
function Renderer.drawSegment(bb, x0, y0, x1, y1, w0, w1, color, skip_first)
    local dx = x1 - x0
    local dy = y1 - y0
    local adx, ady = abs(dx), abs(dy)
    if adx < 0.5 and ady < 0.5 then
        Renderer.drawDisc(bb, x1, y1, max(w0, w1), color)
        return
    end
    if adx >= ady then
        local slope = dy / dx
        local stretch = sqrt(1 + slope * slope)
        local c0, c1 = floor(min(x0, x1)), floor(max(x0, x1))
        for col = c0, c1 do
            local t = ((col + 0.5) - x0) / dx
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            if not (skip_first and t == 0) then
                local yc = y0 + dy * t
                local half = (w0 + (w1 - w0) * t) * stretch / 2
                local top = round(yc - half)
                local h = round(yc + half) - top
                bb:paintRect(col, top, 1, h > 0 and h or 1, color)
            end
        end
    else
        local slope = dx / dy
        local stretch = sqrt(1 + slope * slope)
        local r0, r1 = floor(min(y0, y1)), floor(max(y0, y1))
        for row = r0, r1 do
            local t = ((row + 0.5) - y0) / dy
            if t < 0 then t = 0 elseif t > 1 then t = 1 end
            if not (skip_first and t == 0) then
                local xc = x0 + dx * t
                local half = (w0 + (w1 - w0) * t) * stretch / 2
                local left = round(xc - half)
                local wd = round(xc + half) - left
                bb:paintRect(left, row, wd > 0 and wd or 1, 1, color)
            end
        end
    end
end

-- stroke = { w = pen width, c = gray, p = {x,y,p, ...} } (normalized coords)
function Renderer.renderStroke(bb, stroke, screen_w, screen_h, weight)
    local pts = stroke.p
    if not pts or #pts < 3 then return end
    local base_w = stroke.w or 5
    local color = toColor(stroke.c or 0)
    local n = floor(#pts / 3)

    local px = pts[1] * screen_w
    local py = pts[2] * screen_h
    local pw = Renderer.pointWidth(base_w, pts[3], weight)
    Renderer.drawDisc(bb, px, py, pw, color)
    if n == 1 then return end

    local pdx, pdy -- previous segment direction (unit vector)
    for i = 2, n do
        local j = (i - 1) * 3 + 1
        local x = pts[j] * screen_w
        local y = pts[j + 1] * screen_h
        local w = Renderer.pointWidth(base_w, pts[j + 2], weight)
        local dx, dy = x - px, y - py
        local len = sqrt(dx * dx + dy * dy)
        if len >= 0.5 then
            local ux, uy = dx / len, dy / len
            if pdx and (pdx * ux + pdy * uy) < SHARP_TURN_COS then
                Renderer.drawDisc(bb, px, py, pw, color)
            end
            Renderer.drawSegment(bb, px, py, x, y, pw, w, color, pdx ~= nil)
            pdx, pdy = ux, uy
            px, py, pw = x, y, w
        else
            pw = max(pw, w)
        end
    end
    Renderer.drawDisc(bb, px, py, pw, color)
end

function Renderer.renderPageStrokes(bb, strokes, screen_w, screen_h, weight)
    if not strokes or #strokes == 0 then return end
    for _, stroke in ipairs(strokes) do
        Renderer.renderStroke(bb, stroke, screen_w, screen_h, weight)
    end
end

-- Screen-space bounding box {x, y, w, h} of a set of strokes, padded by
-- their maximum rendered width. Returns nil for no points.
function Renderer.strokesBounds(strokes, screen_w, screen_h, weight)
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
    local left = max(0, floor(x0 * screen_w) - pad)
    local top = max(0, floor(y0 * screen_h) - pad)
    local right = min(screen_w, math.ceil(x1 * screen_w) + pad)
    local bottom = min(screen_h, math.ceil(y1 * screen_h) + pad)
    return { x = left, y = top, w = right - left, h = bottom - top }
end

return Renderer
