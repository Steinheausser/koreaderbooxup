local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local loadstring = loadstring or load -- luacheck: ignore

local EpubStorage = {}
EpubStorage.__index = EpubStorage

-- On-disk format version. v1 was JSON with {x,y,p} point objects; v2 is a
-- Lua table literal with flat point arrays {x,y,p, x,y,p, ...}; v3 is the
-- same layout with doubled strokes repaired (see repairDoubled); v4 adds
-- `anchored`: reflowable-document strokes tied to a text position
-- ({w, c, a = xpointer, fs = font size at capture, p = {dx,dy,p,...}} with
-- offsets in px from the anchor at that font size); v5 gives every stroke a
-- unique `id` (with `next_id` in the snapshot) so the journal can refer to
-- strokes.
--
-- Changes are not written by re-serializing the whole book: each one is
-- appended as one line to a journal next to the snapshot (S/A add a page /
-- anchored stroke, R{ids} removes, C(page) clears a page), and the snapshot is only rewritten (compacted) on close, or on
-- load when a journal is left over. Replaying is idempotent (strokes are
-- added only if their id is new), so a crash between writing the new
-- snapshot and deleting the journal loses nothing.
EpubStorage.VERSION = 5

-- Normalized gap above which one point list is split into segments.
-- Must match the capture-time splitter in main.lua (STROKE_SPLIT_GAP).
EpubStorage.SPLIT_GAP = 0.05

local EMPTY = {}

local function floor_div3(n)
    return math.floor(n / 3)
end

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

-- Earlier builds appended the SDK's end-of-stroke point list to the points
-- already gathered while moving, so a stroke holds its own points twice,
-- with a straight connector from the end back to the start. Returns the
-- single copy, or the input when it is not doubled.
function EpubStorage.undouble(flat)
    local n = floor_div3(#flat)
    if n < 4 then return flat end
    local x1, y1 = flat[1], flat[2]
    for h = math.ceil(n / 2), n - 1 do
        local j = h * 3 + 1 -- point h+1
        if flat[j] == x1 and flat[j + 1] == y1 then
            local m = n - h -- length of the second copy
            if m >= h - 1 then
                local match = true
                for k = 1, math.min(h, m) * 3 do
                    if flat[k] ~= flat[h * 3 + k] then match = false break end
                end
                if match then
                    -- keep the longer copy (the second may carry the end point)
                    local keep_from, keep_n = 1, h
                    if m > h then keep_from, keep_n = h + 1, m end
                    local out = {}
                    local base = (keep_from - 1) * 3
                    for k = 1, keep_n * 3 do out[k] = flat[base + k] end
                    return out
                end
            end
        end
    end
    return flat
end

local function sameStroke(a, b)
    if a.w ~= b.w or #a.p ~= #b.p then return false end
    for k = 1, #a.p do
        if a.p[k] ~= b.p[k] then return false end
    end
    return true
end

-- One-time v2 -> v3 repair: undouble strokes and drop back-to-back
-- identical strokes (the doubled copy split off by the teleport splitter).
function EpubStorage.repairDoubled(pages)
    local fixed_strokes, dropped = 0, 0
    for key, list in pairs(pages) do
        local out = {}
        for _, s in ipairs(list) do
            local p = EpubStorage.undouble(s.p)
            if p ~= s.p then
                s.p = p
                fixed_strokes = fixed_strokes + 1
            end
            if #out > 0 and sameStroke(out[#out], s) then
                dropped = dropped + 1
            else
                table.insert(out, s)
            end
        end
        pages[key] = out
    end
    return fixed_strokes, dropped
end

-- Loads `src` as a chunk running in `env` (LuaJIT: setfenv; Lua 5.2+: load).
local function loadWithEnv(src, name, env)
    if setfenv then -- luacheck: ignore
        local chunk = loadstring(src, name)
        if not chunk then return nil end
        setfenv(chunk, env) -- luacheck: ignore
        return chunk
    end
    return load(src, name, "t", env)
end

function EpubStorage:new(doc_path)
    local o = setmetatable({}, EpubStorage)
    o.doc_path = doc_path
    o.sidecar_dir = o:getSidecarDir(doc_path)
    o.file_path = o.sidecar_dir .. "/boox_stylus_annotations.lua"
    o.journal_path = o.sidecar_dir .. "/boox_stylus_annotations.journal"
    o.backup_path = o.sidecar_dir .. "/boox_stylus_annotations.v1.json.bak"
    o.data = { version = EpubStorage.VERSION, next_id = 1, pages = {}, anchored = {} }
    o.by_id = {}
    -- True while the snapshot is behind (changes only in the journal)
    o.dirty = false
    -- Bumped on every change to data.anchored
    o.anchored_rev = 0
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

-- Snapshot, then journal; compacts when anything had to be upgraded or
-- replayed.
function EpubStorage:load()
    self.data = { version = EpubStorage.VERSION, next_id = 1, pages = {}, anchored = {} }
    self.by_id = {}
    self:loadSnapshot()
    if self.read_only then return end
    self:indexIds()
    if self:replayJournal() > 0 then
        logger.info("BooxPen: replayed annotation journal for " .. self.file_path)
        self.dirty = true
    end
    if self.dirty then
        self:compact()
    end
end

function EpubStorage:loadSnapshot()
    local content = readFile(self.file_path)
    if not content or content == "" then return end

    -- v2+: a Lua chunk, parsed by LuaJIT far faster than any JSON decoder
    if content:sub(1, 6) == "return" then
        local chunk = loadstring(content, "boox_stylus_annotations")
        if chunk then
            local ok, res = pcall(chunk)
            if ok and type(res) == "table" and type(res.pages) == "table"
                    and (tonumber(res.version) or 0) >= 2 then
                self.data = res
                res.anchored = res.anchored or {}
                logger.info("BooxPen: loaded annotations from " .. self.file_path)
                if res.version < 3 then
                    local fixed, dropped = EpubStorage.repairDoubled(res.pages)
                    logger.info("BooxPen: repaired doubled strokes:", fixed, "undoubled,", dropped, "duplicates dropped")
                end
                if res.version < EpubStorage.VERSION then
                    res.version = EpubStorage.VERSION
                    self.dirty = true
                end
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
    self.data.anchored = {}
    EpubStorage.repairDoubled(self.data.pages)
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
end

local function sortedPageKeys(pages)
    local keys = {}
    for k in pairs(pages) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        local na, nb = tonumber(a), tonumber(b)
        if na and nb then return na < nb end
        return tostring(a) < tostring(b)
    end)
    return keys
end

-- Builds the id index, giving id-less (pre-v5) or duplicate strokes new ids.
-- Assignment order is deterministic (sorted pages, then anchored), so even
-- if the upgraded snapshot cannot be written, the next load hands out the
-- same ids again and the journal still refers to the right strokes.
function EpubStorage:indexIds()
    local d = self.data
    d.pages = d.pages or {}
    d.anchored = d.anchored or {}
    local max_id = 0
    local function scan(s)
        if type(s.id) == "number" and s.id > max_id then max_id = s.id end
    end
    for _, list in pairs(d.pages) do for _, s in ipairs(list) do scan(s) end end
    for _, s in ipairs(d.anchored) do scan(s) end
    local next_id = math.max(tonumber(d.next_id) or 1, max_id + 1)
    local by_id = {}
    local function take(s, key)
        if type(s.id) ~= "number" or by_id[s.id] then
            s.id = next_id
            next_id = next_id + 1
            self.dirty = true
        end
        s._k = key
        by_id[s.id] = s
    end
    for _, key in ipairs(sortedPageKeys(d.pages)) do
        for _, s in ipairs(d.pages[key]) do take(s, key) end
    end
    for _, s in ipairs(d.anchored) do take(s, nil) end
    d.next_id = next_id
    self.by_id = by_id
end

-- Applies a stroke add: page stroke when `key` is given, anchored otherwise.
-- Ignored when the id is already present (journal replay is idempotent).
function EpubStorage:applyAdd(key, s)
    if type(s) ~= "table" or type(s.id) ~= "number" or type(s.p) ~= "table" then return end
    if self.by_id[s.id] then return end
    self.by_id[s.id] = s
    if s.id >= self.data.next_id then self.data.next_id = s.id + 1 end
    s._k = key
    if key then
        local list = self.data.pages[key]
        if not list then
            list = {}
            self.data.pages[key] = list
        end
        list[#list + 1] = s
    else
        local list = self.data.anchored
        list[#list + 1] = s
        self.anchored_rev = self.anchored_rev + 1
    end
end

-- Removes the strokes with the given ids (unknown ids are ignored).
function EpubStorage:applyRemove(ids)
    local set, pages_hit, anchored_hit = {}, {}, false
    for _, id in ipairs(ids) do
        local s = self.by_id[id]
        if s then
            set[s] = true
            self.by_id[id] = nil
            if s._k then pages_hit[s._k] = true else anchored_hit = true end
        end
    end
    for key in pairs(pages_hit) do
        local kept = {}
        for _, s in ipairs(self.data.pages[key] or EMPTY) do
            if not set[s] then kept[#kept + 1] = s end
        end
        self.data.pages[key] = #kept > 0 and kept or nil
    end
    if anchored_hit then
        local kept = {}
        for _, s in ipairs(self.data.anchored) do
            if not set[s] then kept[#kept + 1] = s end
        end
        self.data.anchored = kept
        self.anchored_rev = self.anchored_rev + 1
    end
end

function EpubStorage:applyClear(key)
    for _, s in ipairs(self.data.pages[key] or EMPTY) do
        self.by_id[s.id] = nil
    end
    self.data.pages[key] = nil
end

-- Journal lines (ops) per replayed chunk
local JOURNAL_BATCH = 100

-- Replays the journal onto the loaded snapshot. Returns the number of ops.
function EpubStorage:replayJournal()
    local content = readFile(self.journal_path)
    if not content or content == "" then return 0 end
    local ops = 0
    local env = {
        S = function(key, s) ops = ops + 1; self:applyAdd(tostring(key), s) end,
        A = function(s) ops = ops + 1; self:applyAdd(nil, s) end,
        R = function(ids) ops = ops + 1; if type(ids) == "table" then self:applyRemove(ids) end end,
        C = function(key) ops = ops + 1; self:applyClear(tostring(key)) end,
    }
    local function run(src)
        local chunk = loadWithEnv(src, "boox_stylus_journal", env)
        return chunk ~= nil and pcall(chunk)
    end
    -- Batches of lines keep each chunk well inside LuaJIT's per-function
    -- constant limits. A line torn by a crash mid-append breaks its batch:
    -- that batch is redone line by line, skipping what does not parse (ops
    -- are idempotent, so anything the failed pass applied is harmless).
    local lines = {}
    for line in content:gmatch("[^\n]+") do lines[#lines + 1] = line end
    local damaged = false
    for i = 1, #lines, JOURNAL_BATCH do
        local batch = table.concat(lines, "\n", i, math.min(i + JOURNAL_BATCH - 1, #lines))
        if not run(batch) then
            damaged = true
            for j = i, math.min(i + JOURNAL_BATCH - 1, #lines) do run(lines[j]) end
        end
    end
    if damaged then
        logger.warn("BooxPen: skipped damaged lines in annotation journal " .. self.journal_path)
    end
    return ops
end

local function serializeStroke(s)
    local head = "{id=" .. tostring(s.id) .. ",w=" .. tostring(s.w or 5) .. ",c=" .. tostring(s.c or 0)
    if s.a then
        head = head .. string.format(",a=%q,fs=%s", s.a, tostring(s.fs or 0))
    end
    return head .. ",p={" .. table.concat(s.p, ",") .. "}}"
end

-- Strokes per generated function: keeps every chunk's constant table small
local CHUNK = 400

function EpubStorage.serialize(data)
    local out = { "return (function()\nlocal P={}\nlocal d={version=", tostring(EpubStorage.VERSION),
        ",next_id=", tostring(data.next_id or 1), ",pages=P}\n",
        "local function addp(k,t) local l=P[k] if not l then l={} P[k]=l end ",
        "for i=1,#t do l[#l+1]=t[i] end end\n" }
    local n = #out
    for _, k in ipairs(sortedPageKeys(data.pages)) do
        local list = data.pages[k]
        if type(list) == "table" then
            -- At most CHUNK strokes per function, even on heavily inked pages
            for i = 1, #list, CHUNK do
                n = n + 1; out[n] = string.format("addp(%q,(function() return {\n", tostring(k))
                for j = i, math.min(i + CHUNK - 1, #list) do
                    n = n + 1; out[n] = serializeStroke(list[j]) .. ",\n"
                end
                n = n + 1; out[n] = "} end)())\n"
            end
        end
    end
    n = n + 1; out[n] = "local A={} d.anchored=A\n"
        .. "local function add(t) for i=1,#t do A[#A+1]=t[i] end end\n"
    local anchored = data.anchored or EMPTY
    for i = 1, #anchored, CHUNK do
        n = n + 1; out[n] = "add((function() return {\n"
        for j = i, math.min(i + CHUNK - 1, #anchored) do
            n = n + 1; out[n] = serializeStroke(anchored[j]) .. ",\n"
        end
        n = n + 1; out[n] = "} end)())\n"
    end
    n = n + 1; out[n] = "return d\nend)()\n"
    return table.concat(out)
end

-- Writes the full snapshot (atomic: tmp file + rename).
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

-- Folds the journal into a new snapshot, then deletes the journal.
function EpubStorage:compact()
    if self.read_only then return false end
    if self.journal then
        self.journal:close()
        self.journal = nil
    end
    if not self:save() then return false end
    os.remove(self.journal_path)
    return true
end

-- Appends one op to the journal: O(size of the change), not of the book.
function EpubStorage:append(line)
    if self.read_only then return end
    self.dirty = true
    if not self.journal then
        self:ensureDir()
        local f, err = io.open(self.journal_path, "ab")
        if not f then
            logger.err("BooxPen: cannot open annotation journal " .. self.journal_path .. ": " .. tostring(err))
            return
        end
        self.journal = f
    end
    self.journal:write(line)
    self.journal:flush()
end

-- Every op is already on disk once append returns; kept for callers that
-- flush on suspend / settings flush.
function EpubStorage:flush()
    if self.journal then self.journal:flush() end
end

function EpubStorage:close()
    if self.dirty then
        self:compact()
    elseif self.journal then
        self.journal:close()
        self.journal = nil
    end
end

function EpubStorage:newId()
    local id = self.data.next_id
    self.data.next_id = id + 1
    return id
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
    stroke.id = self:newId()
    self:applyAdd(key, stroke)
    self:append(string.format("S(%q,%s)\n", key, serializeStroke(stroke)))
end

local function removeIds(self, ids)
    if #ids == 0 then return end
    self:applyRemove(ids)
    self:append("R{" .. table.concat(ids, ",") .. "}\n")
end

-- Removes the page's newest stroke; returns it (nil when the page is empty)
function EpubStorage:undo(page_num)
    if not page_num then return nil end
    local strokes = self.data.pages[tostring(page_num)]
    if strokes and #strokes > 0 then
        local s = strokes[#strokes]
        removeIds(self, { s.id })
        return s
    end
    return nil
end

-- Removes the page's strokes in `set` (stroke tables mapped to true)
function EpubStorage:removeStrokes(page_num, set)
    if not page_num then return end
    local ids = {}
    for _, s in ipairs(self.data.pages[tostring(page_num)] or EMPTY) do
        if set[s] then ids[#ids + 1] = s.id end
    end
    removeIds(self, ids)
end

function EpubStorage:clearPage(page_num)
    if not page_num then return end
    local key = tostring(page_num)
    if not self.data.pages[key] then return end
    self:applyClear(key)
    self:append(string.format("C(%q)\n", key))
end

-- Removes and returns a page's screen-positioned strokes (for converting
-- them to anchored strokes), or nil when there are none.
function EpubStorage:takePage(page_num)
    local key = tostring(page_num)
    local list = self.data.pages[key]
    if not list or #list == 0 then return nil end
    self:applyClear(key)
    self:append(string.format("C(%q)\n", key))
    return list
end

function EpubStorage:getAnchored()
    return self.data.anchored
end

function EpubStorage:addAnchored(stroke)
    stroke.id = self:newId()
    self:applyAdd(nil, stroke)
    self:append("A(" .. serializeStroke(stroke) .. ")\n")
end

-- `set` maps stroke tables to true
function EpubStorage:removeAnchored(set)
    local ids = {}
    for _, s in ipairs(self.data.anchored) do
        if set[s] then ids[#ids + 1] = s.id end
    end
    removeIds(self, ids)
end

return EpubStorage
