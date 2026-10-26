--[[
Ties strokes in reflowable (crengine) documents to a text position instead
of a screen position, so ink follows its text through rotation, font size,
margin and spacing changes, the same way KOReader's own highlights do.

A stroke stores the xpointer of the word nearest to it (`a`), the font size
at capture (`fs`) and its points as px offsets from that word's screen
position. On render, the offsets are scaled by the font-size ratio and
placed at the word's current screen position.
]]

local Anchor = {}

-- Probe offsets around a point, nearest first; vertical before horizontal
-- (strokes usually sit just above/below or on a line of text). The far
-- horizontal probes reach text from notes written in the page margins.
local SEARCH = { { 0, 0 } }
for _, r in ipairs({ 12, 24, 40, 60, 90, 130, 180, 250, 340, 450, 600 }) do
    table.insert(SEARCH, { 0, r })
    table.insert(SEARCH, { 0, -r })
    table.insert(SEARCH, { -r, 0 })
    table.insert(SEARCH, { r, 0 })
end

function Anchor.isSupported(ui)
    local doc = ui and ui.document
    return ui and ui.rolling ~= nil and doc ~= nil
        and type(doc.getDocumentRenderingHash) == "function"
        and type(doc.getWordFromPosition) == "function"
        and type(doc.getScreenPositionFromXPointer) == "function"
        and type(doc.getPosFromXPointer) == "function"
        or false
end

-- Identifies the current layout: changes whenever the text reflows
-- (rotation, font, margins, spacing...).
function Anchor.layoutKey(doc)
    local ok, hash = pcall(doc.getDocumentRenderingHash, doc)
    return ok and tostring(hash) or "?"
end

-- Screen position (x, y) of an xpointer in the current view, or nil.
function Anchor.screenPos(doc, xp)
    local ok, y, x = pcall(doc.getScreenPositionFromXPointer, doc, xp)
    if ok and y and x then return x, y end
    return nil
end

function Anchor.fontSize(doc)
    local ok, fs = pcall(doc.getFontSize, doc)
    return ok and tonumber(fs) or 0
end

-- Finds the text position nearest to screen point (cx, cy) on the current
-- page. Returns xpointer, x, y (the xpointer's screen position) or nil.
function Anchor.find(doc, cx, cy, screen_w, screen_h)
    for _, o in ipairs(SEARCH) do
        local x, y = cx + o[1], cy + o[2]
        if x >= 0 and y >= 0 and x < screen_w and y < screen_h then
            local ok, wb = pcall(doc.getWordFromPosition, doc, { x = x, y = y }, true)
            if ok and wb and wb.pos0 then
                local rx, ry = Anchor.screenPos(doc, wb.pos0)
                if rx then return wb.pos0, rx, ry end
            end
        end
    end
    -- No text nearby (image, blank page): anchor to the page start
    local ok, xp = pcall(doc.getXPointer, doc)
    if ok and xp then
        local rx, ry = Anchor.screenPos(doc, xp)
        if rx then return xp, rx, ry end
    end
    return nil
end

-- Converts screen-px points {x,y,p,...} to an anchored stroke.
function Anchor.makeStroke(px_points, w, c, xp, rx, ry, fs)
    local offs = {}
    for j = 1, #px_points - 2, 3 do
        offs[j] = math.floor((px_points[j] - rx) * 10 + 0.5) / 10
        offs[j + 1] = math.floor((px_points[j + 1] - ry) * 10 + 0.5) / 10
        offs[j + 2] = px_points[j + 2]
    end
    return { w = w, c = c, a = xp, fs = fs, p = offs }
end

-- Screen-px bounding box of a point list: x0, y0, x1, y1.
function Anchor.bbox(px_points)
    local x0, y0, x1, y1 = math.huge, math.huge, -math.huge, -math.huge
    for j = 1, #px_points - 2, 3 do
        local x, y = px_points[j], px_points[j + 1]
        if x < x0 then x0 = x end
        if x > x1 then x1 = x end
        if y < y0 then y0 = y end
        if y > y1 then y1 = y end
    end
    return x0, y0, x1, y1
end

-- Gap in px between two boxes (0 when they overlap).
function Anchor.boxGap(a, b)
    local dx = math.max(0, math.max(a[1], b[1]) - math.min(a[3], b[3]))
    local dy = math.max(0, math.max(a[2], b[2]) - math.min(a[4], b[4]))
    return math.sqrt(dx * dx + dy * dy)
end

return Anchor
