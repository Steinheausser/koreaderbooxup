local Dispatcher = require("dispatcher")
local JSON = require("json")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local EpubStorage = require("epub_storage")
local Renderer = require("renderer")

local function getAndroid()
    local ok, mod = pcall(require, "android")
    if ok and mod then
        return mod
    elseif package.loaded.android then
        return package.loaded.android
    elseif _G.android then
        return _G.android
    end
    return nil
end

local BooxPen = WidgetContainer:extend{
    name = "boox_pen",
    is_drawing_active = false,
    pen_width = 3,
    pen_color = 0, -- Black in KOReader
    show_annotations = true,
    storage = nil,
    poll_timer = nil,
    patched_view = nil,
    orig_paintTo = nil,
}

function BooxPen:init()
    self.ui.menu:registerToMainMenu(self)
    local auto_enable = G_reader_settings:readSetting("boox_pen_auto_enable")
    if auto_enable == nil then
        self.auto_enable_drawing = true
    else
        self.auto_enable_drawing = (auto_enable == true)
    end
end

function BooxPen:onReaderReady()
    if not self.ui.document or not self.ui.document.file then return end

    -- Initialize document sidecar storage
    self.storage = EpubStorage:new(self.ui.document.file)

    -- Hook into ReaderView:paintTo to render vector ink over the document page
    local reader_view = self.ui.view
    if reader_view and reader_view.paintTo and self.patched_view ~= reader_view then
        self.orig_paintTo = reader_view.paintTo
        local plugin_self = self
        reader_view.paintTo = function(this, bb, x, y)
            plugin_self.orig_paintTo(this, bb, x, y)
            plugin_self:onPaintPage(bb, x, y)
        end
        self.patched_view = reader_view
        logger.info("BooxPen: successfully hooked into ReaderView:paintTo")
    end

    if self.auto_enable_drawing then
        UIManager:scheduleIn(0.5, function()
            self:setDrawingMode(true)
        end)
    end
end

function BooxPen:onCloseDocument()
    self:setDrawingMode(false, true)
    if self.storage then
        self.storage:save()
        self.storage = nil
    end
    if self.patched_view and self.orig_paintTo then
        self.patched_view.paintTo = self.orig_paintTo
        self.patched_view = nil
        self.orig_paintTo = nil
    end
end

function BooxPen:getCurrentPageNumber()
    if self.ui.document and self.ui.document.paging then
        return self.ui.document.paging.current_page or 1
    end
    if self.view and self.view.state then
        return self.view.state.page or 1
    end
    return 1
end

function BooxPen:onPaintPage(bb, x, y)
    if not self.show_annotations or not self.storage then return end

    local current_page = self:getCurrentPageNumber()
    local strokes = self.storage:getStrokes(current_page)
    if strokes and #strokes > 0 then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        Renderer.renderPageStrokes(bb, strokes, screen_w, screen_h)
    end
end

-- Check if device supports Boox low-latency pen
function BooxPen:isSupported()
    local a = getAndroid()
    if a and a.booxIsSupported then
        return a.booxIsSupported()
    end
    return false
end

function BooxPen:setDrawingMode(enable, silent)
    if self.is_drawing_active == enable then return end
    self.is_drawing_active = enable

    local a = getAndroid()
    if a and a.booxSetDrawingMode then
        if enable then
            local screen_w = Screen:getWidth()
            local screen_h = Screen:getHeight()
            -- Exclude top menu bar (top 120px) and bottom status bar (bottom 120px)
            local exclude_rects = {
                { x = 0, y = 0, w = screen_w, h = 120 },
                { x = 0, y = screen_h - 120, w = screen_w, h = 120 }
            }
            local exclude_json = JSON.encode(exclude_rects)
            a.booxSetDrawingMode(true, exclude_json)
            a.booxSetPenWidth(self.pen_width)
            a.booxSetPenColor(self.pen_color)
            self:startPolling()
            if not silent then
                UIManager:show(require("ui/widget/notification"):new{
                    text = _("Stylus Drawing Active (Write with Pen)"),
                    timeout = 1.5,
                })
            end
        else
            self:stopPolling()
            -- Drain remaining strokes before disabling
            self:pollStrokes()
            a.booxSetDrawingMode(false, "[]")
            if not silent then
                UIManager:show(require("ui/widget/notification"):new{
                    text = _("Stylus Drawing Deactivated"),
                    timeout = 1.5,
                })
            end
        end
    else
        logger.warn("BooxPen: android.booxSetDrawingMode not available on this build/platform")
    end

    UIManager:setDirty(self.ui.view, "ui")
end

function BooxPen:startPolling()
    if self.poll_timer then return end

    local poll_interval = 0.1 -- 100ms
    local plugin_self = self

    self.poll_timer = function()
        if not plugin_self.is_drawing_active then return end
        plugin_self:pollStrokes()
        UIManager:scheduleIn(poll_interval, plugin_self.poll_timer)
    end

    UIManager:scheduleIn(poll_interval, self.poll_timer)
end

function BooxPen:stopPolling()
    if self.poll_timer then
        UIManager:unschedule(self.poll_timer)
        self.poll_timer = nil
    end
end

function BooxPen:pollStrokes()
    local a = getAndroid()
    if not a or not a.booxPollStrokes or not self.storage then return end

    local json_str = a.booxPollStrokes()
    if not json_str or json_str == "" or json_str == "[]" then return end

    local success, strokes = pcall(JSON.decode, json_str)
    if not success or type(strokes) ~= "table" or #strokes == 0 then return end

    local current_page = self:getCurrentPageNumber()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()

    for _, stroke in ipairs(strokes) do
        if stroke.points and #stroke.points > 0 then
            -- Normalize coordinates (0..1) so annotations scale across orientations/resolutions
            local norm_points = {}
            for _, pt in ipairs(stroke.points) do
                table.insert(norm_points, {
                    x = pt.x / screen_w,
                    y = pt.y / screen_h,
                    p = pt.p or 1.0,
                })
            end
            local stored_stroke = {
                width = stroke.width or self.pen_width,
                color = stroke.color or self.pen_color,
                points = norm_points,
            }
            self.storage:addStroke(current_page, stored_stroke)
        end
    end

    -- Trigger page redraw so the normalized vector stroke is rendered by KOReader
    UIManager:setDirty(self.ui.view, "ui")
end

function BooxPen:undo()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    self.storage:undo(current_page)
    UIManager:setDirty(self.ui.view, "ui")
    UIManager:show(require("ui/widget/notification"):new{
        text = _("Undid last stroke"),
        timeout = 1,
    })
end

function BooxPen:clearPage()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    self.storage:clearPage(current_page)
    UIManager:setDirty(self.ui.view, "ui")
    UIManager:show(require("ui/widget/notification"):new{
        text = _("Cleared page annotations"),
        timeout = 1,
    })
end

function BooxPen:addToMainMenu(menu_items)
    menu_items.boox_pen = {
        text = _("Boox Stylus Annotations"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable Stylus Inking"),
                checked_func = function() return self.is_drawing_active end,
                callback = function()
                    self:setDrawingMode(not self.is_drawing_active)
                end,
            },
            {
                text = _("Auto-enable on document open"),
                checked_func = function() return self.auto_enable_drawing end,
                callback = function()
                    self.auto_enable_drawing = not self.auto_enable_drawing
                    G_reader_settings:saveSetting("boox_pen_auto_enable", self.auto_enable_drawing)
                end,
            },
            {
                text = _("Show Annotations"),
                checked_func = function() return self.show_annotations end,
                callback = function()
                    self.show_annotations = not self.show_annotations
                    UIManager:setDirty(self.ui.view, "ui")
                end,
            },
            {
                text = _("Undo Last Stroke"),
                callback = function()
                    self:undo()
                end,
            },
            {
                text = _("Clear Page"),
                callback = function()
                    self:clearPage()
                end,
            },
            {
                text = _("Pen Width"),
                sub_item_table = {
                    { text = _("Fine (1px)"), checked_func = function() return self.pen_width == 1 end, callback = function() self.pen_width = 1 local a = getAndroid() if a and a.booxSetPenWidth then a.booxSetPenWidth(1) end end },
                    { text = _("Medium (3px)"), checked_func = function() return self.pen_width == 3 end, callback = function() self.pen_width = 3 local a = getAndroid() if a and a.booxSetPenWidth then a.booxSetPenWidth(3) end end },
                    { text = _("Bold (5px)"), checked_func = function() return self.pen_width == 5 end, callback = function() self.pen_width = 5 local a = getAndroid() if a and a.booxSetPenWidth then a.booxSetPenWidth(5) end end },
                    { text = _("Heavy (8px)"), checked_func = function() return self.pen_width == 8 end, callback = function() self.pen_width = 8 local a = getAndroid() if a and a.booxSetPenWidth then a.booxSetPenWidth(8) end end },
                }
            }
        }
    }
end

return BooxPen
