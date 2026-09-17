local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")

local EpubStorage = {}
EpubStorage.__index = EpubStorage

function EpubStorage:new(doc_path)
    local self = setmetatable({}, EpubStorage)
    self.doc_path = doc_path
    self.sidecar_dir = self:getSidecarDir(doc_path)
    self.file_path = self.sidecar_dir .. "/boox_stylus_annotations.lua"
    self.data = {
        version = 1,
        pages = {}
    }
    self:load()
    return self
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

function EpubStorage:load()
    local f = io.open(self.file_path, "r")
    if not f then
        self.data = { version = 1, pages = {} }
        return
    end

    local content = f:read("*all")
    f:close()

    local chunk, err = loadstring(content)
    if chunk then
        local success, result = pcall(chunk)
        if success and type(result) == "table" then
            self.data = result
            if not self.data.pages then self.data.pages = {} end
            logger.info("BooxPen: loaded annotations from " .. self.file_path)
            return
        end
    end
    logger.warn("BooxPen: could not parse annotations file: " .. tostring(err))
    self.data = { version = 1, pages = {} }
end

-- Compact Lua table serialization
local function serializeTable(val, name, indent)
    indent = indent or ""
    local t = type(val)
    if t == "number" then
        return tostring(val)
    elseif t == "boolean" then
        return tostring(val)
    elseif t == "string" then
        return string.format("%q", val)
    elseif t == "table" then
        local parts = { "{\n" }
        local next_indent = indent .. "  "
        -- Array part
        local is_array = #val > 0
        if is_array then
            for i, v in ipairs(val) do
                table.insert(parts, next_indent .. serializeTable(v, nil, next_indent) .. ",\n")
            end
        else
            for k, v in pairs(val) do
                local key_str = type(k) == "number" and "[" .. k .. "]" or string.format("[%q]", tostring(k))
                table.insert(parts, next_indent .. key_str .. " = " .. serializeTable(v, nil, next_indent) .. ",\n")
            end
        end
        table.insert(parts, indent .. "}")
        return table.concat(parts)
    else
        return "nil"
    end
end

function EpubStorage:save()
    self:ensureDir()
    local f, err = io.open(self.file_path, "w")
    if not f then
        logger.error("BooxPen: failed to save annotations to " .. self.file_path .. ": " .. tostring(err))
        return false
    end

    f:write("return " .. serializeTable(self.data) .. "\n")
    f:close()
    return true
end

function EpubStorage:getStrokes(page_num)
    if not page_num then return {} end
    return self.data.pages[page_num] or {}
end

function EpubStorage:hasStrokes(page_num)
    local strokes = self:getStrokes(page_num)
    return #strokes > 0
end

function EpubStorage:addStroke(page_num, stroke)
    if not page_num or not stroke then return end
    if not self.data.pages[page_num] then
        self.data.pages[page_num] = {}
    end
    table.insert(self.data.pages[page_num], stroke)
    self:save()
end

function EpubStorage:undo(page_num)
    if not page_num or not self.data.pages[page_num] then return end
    local strokes = self.data.pages[page_num]
    if #strokes > 0 then
        table.remove(strokes)
        self:save()
    end
end

function EpubStorage:clearPage(page_num)
    if not page_num then return end
    if self.data.pages[page_num] then
        self.data.pages[page_num] = nil
        self:save()
    end
end

return EpubStorage
