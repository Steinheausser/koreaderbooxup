local JSON = require("json")
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

    if not content or content == "" then
        self.data = { version = 1, pages = {} }
        return
    end

    local success, result = pcall(JSON.decode, content)
    if not success or type(result) ~= "table" then
        local chunk = loadstring(content)
        if chunk then
            local ok, res = pcall(chunk)
            if ok and type(res) == "table" then
                result = res
                success = true
            end
        end
    end

    if success and type(result) == "table" then
        self.data = result
        if not self.data.pages then self.data.pages = {} end
        logger.info("BooxPen: loaded annotations from " .. self.file_path)
    else
        self.data = { version = 1, pages = {} }
    end
end

function EpubStorage:save()
    self:ensureDir()
    local f, err = io.open(self.file_path, "w")
    if not f then
        logger.error("BooxPen: failed to save annotations to " .. self.file_path .. ": " .. tostring(err))
        return false
    end

    local ok, encoded = pcall(JSON.encode, self.data)
    if ok and encoded then
        f:write(encoded .. "\n")
    end
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
