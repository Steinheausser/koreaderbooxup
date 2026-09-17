local Renderer = {}

-- Bresenham's line algorithm with brush stamping onto KOReader's BlitBuffer
function Renderer.drawLine(bb, x0, y0, x1, y1, width, color)
    local r = math.max(1, math.floor(width / 2))
    local dx = math.abs(x1 - x0)
    local dy = math.abs(y1 - y0)
    local sx = x0 < x1 and 1 or -1
    local sy = y0 < y1 and 1 or -1
    local err = dx - dy

    local curr_x = x0
    local curr_y = y0

    local bb_w = bb:getWidth()
    local bb_h = bb:getHeight()

    while true do
        -- Bounds clamp
        if curr_x >= 0 and curr_x < bb_w and curr_y >= 0 and curr_y < bb_h then
            bb:paintRect(math.max(0, curr_x - r), math.max(0, curr_y - r), width, width, color)
        end

        if curr_x == x1 and curr_y == y1 then break end
        local e2 = 2 * err
        if e2 > -dy then
            err = err - dy
            curr_x = curr_x + sx
        end
        if e2 < dx then
            err = err + dx
            curr_y = curr_y + sy
        end
    end
end

function Renderer.renderStroke(bb, stroke, screen_w, screen_h)
    local points = stroke.points
    if not points or #points == 0 then return end

    local base_width = stroke.width or 3
    local stroke_color = stroke.color or 0 -- 0 is black in KOReader color palette

    if #points == 1 then
        local pt = points[1]
        local px = math.floor(pt.x * screen_w)
        local py = math.floor(pt.y * screen_h)
        local w = math.min(16, math.max(1, math.floor(base_width * (pt.p or 1.0))))
        local r = math.floor(w / 2)
        bb:paintRect(px - r, py - r, w, w, stroke_color)
        return
    end

    for i = 1, #points - 1 do
        local p0 = points[i]
        local p1 = points[i + 1]
        local x0 = math.floor(p0.x * screen_w)
        local y0 = math.floor(p0.y * screen_h)
        local x1 = math.floor(p1.x * screen_w)
        local y1 = math.floor(p1.y * screen_h)

        local avg_p = ((p0.p or 1.0) + (p1.p or 1.0)) / 2
        local dynamic_w = math.min(16, math.max(1, math.floor(base_width * avg_p)))

        Renderer.drawLine(bb, x0, y0, x1, y1, dynamic_w, stroke_color)
    end
end

function Renderer.renderPageStrokes(bb, strokes, screen_w, screen_h)
    if not strokes or #strokes == 0 then return end
    for _, stroke in ipairs(strokes) do
        Renderer.renderStroke(bb, stroke, screen_w, screen_h)
    end
end

return Renderer
