local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local loadstring = loadstring or load -- luacheck: ignore

local EpubStorage = {}
EpubStorage.__index = EpubStorage

-- On-disk format version. v1 was JSON with {x,y,p} point objects; v2 is a
-- Lua table literal with flat point arrays {x,y,p, x,y,p, ...}.
EpubStorage.VERSION = 2

-- Normalized gap above which one point list is split into segments.
-- Must match the capture-time splitter in main.lua (STROKE_SPLIT_GAP).
EpubStorage.SPLIT_GAP = 0.05

-- Seconds of inactivity before pending changes are written out
EpubStorage.SAVE_DELAY = 3

local EMPTY = {}

local function round(v, scale)
    return math.floor(v * scale + 0.5) / scale
end
EpubStorage.round = round

-- Splits a v1 point list ({x,y,p} tables) on teleport jumps (pen
-- micro-lifts / stray contacts). Returns a list of segments.
function EpubStorage.splitSegments(points, gap)
    gap = gap or EpubStorage.SPLIT_GAP
    local segments = { {} }
    for i, pt in ipairs(points) do
        local cur = segments[#segments]
        if i > 1 then
            local prev = points[i - 1]
            local dx = (pt.x or 0) - (prev.x or 0)
            local dy = (pt.y or 0) - (prev.y or 0)
            if (dx * dx + dy * dy) > (gap * gap) then
                cur = {}
                table.insert(segments, cur)
            end
        end
        table.insert(cur, pt)
    end
    return segments
end

-- Same as splitSegments, for flat {x,y,p, ...} arrays.
function EpubStorage.splitFlat(flat, gap)
    gap = gap or EpubStorage.SPLIT_GAP
    local gap2 = gap * gap
    local segments = { {} }
    local cur = segments[1]
    for i = 1, #flat - 2, 3 do
        if i > 1 then
            local dx = flat[i] - flat[i - 3]
            local dy = flat[i + 1] - flat[i - 2]
            if (dx * dx + dy * dy) > gap2 then
                cur = {}
                table.insert(segments, cur)
            end
        end
        local n = #cur
        cur[n + 1] = flat[i]
        cur[n + 2] = flat[i + 1]
        cur[n + 3] = flat[i + 2]
    end
    return segments
end

function EpubStorage:new(doc_path)
    local o = setmetatable({}, EpubStorage)
    o.doc_path = doc_path
    o.sidecar_dir = o:getSidecarDir(doc_path)
    o.file_path = o.sidecar_dir .. "/boox_stylus_annotations.lua"
    o.backup_path = o.sidecar_dir .. "/boox_stylus_annotations.v1.json.bak"
    o.data = { version = EpubStorage.VERSION, pages = {} }
    o.dirty = false
    o.save_cb = function() o:flush() end
    o:load()
    return o
end

function EpubStorage:getSidecarDir(path)
    -- In KOReader, the sidecar folder is typically <filename>.sdr alongside the book file
    -- e.g. /path/to/book.epub -> /path/to/book.sdr
    local dir = path:gsub("%.[^./\\]+$", ".sdr")
    if dir == path then
        dir = path .. ".sdr"
    end
    return dir
end

function EpubStorage:ensureDir()
    local mode = lfs.attributes(self.sidecar_dir, "mode")
    if not mode then
        lfs.mkdir(self.sidecar_dir)
    end
end

-- Converts v1 data (JSON-decoded) to v2: flat points, normalized pressure,
-- width on the hardware scale, string page keys, teleports split.
function EpubStorage.migrateV1(old)
    local pages = {}
    if type(old) ~= "table" or type(old.pages) ~= "table" then
        return { version = EpubStorage.VERSION, pages = pages }
    end
    -- v1 kept numeric and string keys pointing at the same list
    local seen_lists = {}
    for k, list in pairs(old.pages) do
        local key = tostring(k)
        if type(list) == "table" and not seen_lists[list] and not pages[key] then
            seen_lists[list] = true
            local out = {}
            for _, stroke in ipairs(list) do
                if type(stroke) == "table" and type(stroke.points) == "table" and #stroke.points > 0 then
                    -- v1 width was the vector pen width (1/3/5/8) while live
                    -- ink was always 5: shift onto the v2 presets (3/5/7/10).
                    local width = (tonumber(stroke.width) or 3) + 2
                    local color = tonumber(stroke.color) or 0
                    if color < 0 or color > 255 then color = 0 end
                    for _, seg in ipairs(EpubStorage.splitSegments(stroke.points)) do
                        local flat = {}
                        for _, pt in ipairs(seg) do
                            local n = #flat
                            flat[n + 1] = round(tonumber(pt.x) or 0, 10000)
                            flat[n + 2] = round(tonumber(pt.y) or 0, 10000)
                            -- v1 pressure was raw/2048 clamped to 0.3..1.8
                            local p = (tonumber(pt.p) or 1.0) / 2
                            flat[n + 3] = round(math.max(0, math.min(1, p)), 100)
                        end
                        if #flat == 3 then
                            flat[4], flat[5], flat[6] = flat[1], flat[2], flat[3]
                        end
                        table.insert(out, { w = width, c = color, p = flat })
                    end
                end
            end
            if #out > 0 then
                pages[key] = out
            end
        end
    end
    return { version = EpubStorage.VERSION, pages = pages }
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*all")
    f:close()
    return content
end

local function writeFile(path, content)
    local f, err = io.open(path, "wb")
    if not f then return false, err end
    local ok, werr = f:write(content)
    f:close()
    if not ok then return false, werr end
    return true
end

function EpubStorage:load()
    self.data = { version = EpubStorage.VERSION, pages = {} }
    local content = readFile(self.file_path)
    if not content or content == "" then return end

    -- v2: a Lua chunk, parsed by LuaJIT far faster than any JSON decoder
    if content:sub(1, 6) == "return" then
        local chunk = loadstring(content, "boox_stylus_annotations")
        if chunk then
            local ok, res = pcall(chunk)
            if ok and type(res) == "table" and type(res.pages) == "table"
                    and (tonumber(res.version) or 0) >= 2 then
                self.data = res
                logger.info("BooxPen: loaded annotations from " .. self.file_path)
                return
            end
        end
        logger.warn("BooxPen: could not parse " .. self.file_path .. ", trying legacy formats")
    end

    -- v1: JSON (or an old Lua-literal variant of the same structure)
    local old
    local JSON = require("json")
    local ok, res = pcall(JSON.decode, content)
    if ok and type(res) == "table" then
        old = res
    else
        local chunk = loadstring(content)
        if chunk then
            local ok2, res2 = pcall(chunk)
            if ok2 and type(res2) == "table" then old = res2 end
        end
    end
    if not old then
        -- Never overwrite a file we failed to understand
        logger.err("BooxPen: unreadable annotations file, leaving it untouched: " .. self.file_path)
        self.read_only = true
        return
    end

    self.data = EpubStorage.migrateV1(old)
    -- Keep the original before the first v2 write
    if not lfs.attributes(self.backup_path, "mode") then
        local bok, berr = writeFile(self.backup_path, content)
        if not bok then
            logger.err("BooxPen: failed to back up v1 annotations: " .. tostring(berr))
            self.read_only = true
            return
        end
    end
    logger.info("BooxPen: migrated v1 annotations to v2 for " .. self.file_path)
    self.dirty = true
    self:flush()
end

function EpubStorage.serialize(data)
    local out = { "return {version=", tostring(EpubStorage.VERSION), ",pages={\n" }
    local n = #out
    local keys = {}
    for k in pairs(data.pages) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    for _, k in ipairs(keys) do
        local list = data.pages[k]
        if type(list) == "table" and #list > 0 then
            -- One function per page keeps each chunk's constant table small
            n = n + 1; out[n] = string.format("[%q]=(function() return {\n", tostring(k))
            for _, s in ipairs(list) do
                n = n + 1
                out[n] = "{w=" .. tostring(s.w or 5) .. ",c=" .. tostring(s.c or 0)
                    .. ",p={" .. table.concat(s.p, ",") .. "}},\n"
            end
            n = n + 1; out[n] = "} end)(),\n"
        end
    end
    n = n + 1; out[n] = "}}\n"
    return table.concat(out)
end

function EpubStorage:save()
    if self.read_only then return false end
    self:ensureDir()
    local tmp = self.file_path .. ".tmp"
    local ok, err = writeFile(tmp, EpubStorage.serialize(self.data))
    if not ok then
        logger.err("BooxPen: failed to save annotations to " .. tmp .. ": " .. tostring(err))
        os.remove(tmp)
        return false
    end
    local rok, rerr = os.rename(tmp, self.file_path)
    if not rok then
        -- Some filesystems refuse to rename over an existing file
        os.remove(self.file_path)
        rok, rerr = os.rename(tmp, self.file_path)
    end
    if not rok then
        logger.err("BooxPen: failed to replace " .. self.file_path .. ": " .. tostring(rerr))
        return false
    end
    self.dirty = false
    return true
end

-- Debounced save: coalesces bursts of strokes into one write.
function EpubStorage:markDirty()
    self.dirty = true
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self.save_cb)
    UIManager:scheduleIn(EpubStorage.SAVE_DELAY, self.save_cb)
end

function EpubStorage:flush()
    if self.dirty then
        self:save()
    end
end

function EpubStorage:close()
    local UIManager = require("ui/uimanager")
    UIManager:unschedule(self.save_cb)
    self:flush()
end

function EpubStorage:getStrokes(page_num)
    if not page_num then return EMPTY end
    return self.data.pages[tostring(page_num)] or EMPTY
end

function EpubStorage:hasStrokes(page_num)
    return #self:getStrokes(page_num) > 0
end

-- stroke = { w = width, c = gray, p = {x,y,p, ...} } (normalized coords)
function EpubStorage:addStroke(page_num, stroke)
    if not page_num or not stroke then return end
    local key = tostring(page_num)
    local list = self.data.pages[key]
    if not list then
        list = {}
        self.data.pages[key] = list
    end
    table.insert(list, stroke)
    self:markDirty()
end

function EpubStorage:undo(page_num)
    if not page_num then return end
    local strokes = self.data.pages[tostring(page_num)]
    if strokes and #strokes > 0 then
        table.remove(strokes)
        self:markDirty()
    end
end

function EpubStorage:clearPage(page_num)
    if not page_num then return end
    self.data.pages[tostring(page_num)] = nil
    self:markDirty()
end

return EpubStorage
