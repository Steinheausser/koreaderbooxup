local JSON = require("json")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local EpubStorage = require("epub_storage")
local Renderer = require("renderer")

local loadstring = loadstring or load -- luacheck: ignore

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
    pen_width = 5,
    pen_color = 0, -- KOReader gray, 0 = black (converted to ARGB natively)
    ink_weight = 1.2,
    show_annotations = true,
    storage = nil,
    poll_timer = nil,
    patched_view = nil,
    orig_paintTo = nil,
    is_duplicate = false,
    pending_auto_enable = false,
    inking_before_hide = nil,
}

-- Pen width presets, in hardware (EPD) units. Live ink and the settled
-- vector ink share this value; 5 is the long-standing known-good width.
local PEN_WIDTHS = {
    { text = _("Fine"), width = 3 },
    { text = _("Medium"), width = 5 },
    { text = _("Bold"), width = 7 },
    { text = _("Heavy"), width = 10 },
}
-- Settled ink thickness relative to live ink
local INK_WEIGHTS = {
    { text = _("Same as live ink"), weight = 1.0 },
    { text = _("Slightly bolder"), weight = 1.2 },
    { text = _("Bolder"), weight = 1.5 },
}

-- Linux evdev constants (stable ABI). Used by the gesture suppression hook.
-- The Boox stylus also emits emulated finger (multitouch) events which KOReader
-- would otherwise interpret as pan/swipe and turn pages mid-stroke.
local EV_ABS = 3
local EV_SYN = 0
local SYN_REPORT = 0
local ABS_X = 0
local ABS_Y = 1
local ABS_MT_SLOT = 47
local ABS_MT_POSITION_X = 53
local ABS_MT_POSITION_Y = 54
local ABS_MT_TRACKING_ID = 57
-- Contacts that move less than this stay usable as taps (menu, dismiss, etc.)
local TAP_SLOP_PX = 24
-- Top menu bar / bottom status bar stay fully touchable while inking
local MENU_ZONE_PX = 140
-- Normalized gap above which one raw stroke is split: pen micro-lifts and
-- stray contacts must not render as long connector lines (~0.05 ~= 80px).
local STROKE_SPLIT_GAP = 0.05
-- Delay between the reader's first paint and auto-enabling inking, so the
-- first page refresh reaches the panel before the pen session starts
local AUTO_ENABLE_DELAY = 1

-- Input hooks chain forever once registered, so they are installed once per
-- process and act on whichever reader instance is currently active.
local hooks_installed = false
local active_instance = nil
local contact_state = {}
local contact_slot = 0

function BooxPen:init()
    -- Reader only: the file manager has no document to annotate
    if not self.ui or not self.ui.document then return end
    -- A second copy of this plugin (e.g. a stale one in koreader/plugins)
    -- must stay inert: two instances fight over painting, polling and the
    -- sidecar file.
    if self.ui.boox_pen then
        logger.warn("BooxPen: duplicate plugin instance from", self.path, "- disabled")
        self.is_duplicate = true
        return
    end
    self.ui.menu:registerToMainMenu(self)
    self:setupGestureSuppression()
    local auto_enable = G_reader_settings:readSetting("boox_pen_auto_enable")
    self.auto_enable_drawing = (auto_enable == nil) or (auto_enable == true)
    self.pen_width = G_reader_settings:readSetting("boox_pen_width") or 5
    self.ink_weight = G_reader_settings:readSetting("boox_pen_ink_weight") or 1.2
    self.show_annotations = G_reader_settings:nilOrTrue("boox_pen_show_annotations")
end

function BooxPen:isInert()
    return self.is_duplicate or not self.ui or not self.ui.document
end

-- While inking is on, the pen's emulated finger events must not drive the
-- reader (page turns, scrolling, text selection). Two layers:
--   1. evdev layer: pen *movement* is voided so no pan/swipe is recognized
--      (taps keep working, menus stay reachable).
--   2. gesture layer: any residual tap/hold/swipe/pan whose position is in
--      the content area is swallowed, so pen lifts never select text or turn
--      pages. Top/bottom menu zones always pass through untouched.
function BooxPen:setupGestureSuppression()
    if hooks_installed then return end
    local ok, Device = pcall(require, "device")
    if not ok or not Device or not Device.input then
        logger.warn("BooxPen: input hook API unavailable, pen strokes may turn pages")
        return
    end
    if type(Device.input.registerEventAdjustHook) == "function" then
    Device.input:registerEventAdjustHook(function(_, ev)
        local plugin_self = active_instance
        if not plugin_self or not plugin_self.is_drawing_active then return end
        if ev.type ~= EV_ABS then return end
        local code = ev.code
        if code == ABS_MT_SLOT then
            contact_slot = ev.value
            return
        end
        if code == ABS_MT_TRACKING_ID then
            if ev.value == -1 then
                contact_state[contact_slot] = nil
            else
                contact_state[contact_slot] = {}
            end
            return
        end
        local is_x = (code == ABS_MT_POSITION_X or code == ABS_X)
        local is_y = (code == ABS_MT_POSITION_Y or code == ABS_Y)
        if not (is_x or is_y) then return end

        local st = contact_state[contact_slot]
        if not st then
            st = {}
            contact_state[contact_slot] = st
        end
        if st.menu then return end -- menu-zone contact: leave fully alone

        local val = ev.value
        if is_x then
            if st.x0 == nil then st.x0 = val end
            st.x = val
        else
            if st.y0 == nil then st.y0 = val end
            st.y = val
        end
        if st.x == nil or st.y == nil then return end -- need both axes first
        if st.x0 == nil then st.x0 = st.x end
        if st.y0 == nil then st.y0 = st.y end

        -- Menu zones (top/bottom bars) stay fully touchable
        local screen_h = Screen:getHeight()
        if st.y < MENU_ZONE_PX or st.y > (screen_h - MENU_ZONE_PX) then
            st.menu = true
            return
        end

        local dx = st.x - st.x0
        local dy = st.y - st.y0
        if (dx * dx + dy * dy) > (TAP_SLOP_PX * TAP_SLOP_PX) then
            -- Real movement: a pen stroke, not a tap. Void the coordinate so
            -- no pan/swipe gesture is recognized. The Onyx SDK raw path still
            -- receives the full stroke independently of this event stream.
            ev.type = EV_SYN
            ev.code = SYN_REPORT
            ev.value = 0
        end
    end)
    end
    if type(Device.input.registerGestureAdjustHook) == "function" then
    Device.input:registerGestureAdjustHook(function(_, ges)
        local plugin_self = active_instance
        if not plugin_self or not plugin_self.is_drawing_active then return end
        if type(ges) ~= "table" or type(ges.pos) ~= "table" then return end
        local pos = ges.pos
        if type(pos.x) ~= "number" or type(pos.y) ~= "number" then return end
        -- Menu zones stay fully interactive so inking can be toggled back off
        local screen_h = Screen:getHeight()
        if pos.y < MENU_ZONE_PX or pos.y > (screen_h - MENU_ZONE_PX) then return end
        -- Only suppress while the physical pen is involved. The pen also
        -- emits emulated finger events, so shape alone cannot tell pen from
        -- finger: consult the native pen state instead. Finger taps (menus,
        -- dialogs, dismissal) pass through untouched.
        if not plugin_self:isPenActive() then return end
        -- Swallow content-area gestures from the pen's emulated finger
        -- stream. "none" matches no touch zone/handler, so this is a no-op
        -- downstream, while contact bookkeeping stays consistent.
        logger.dbg("BooxPen: swallowing", ges.ges, "gesture at", pos.x, pos.y)
        ges.ges = "none"
    end)
    end
    hooks_installed = true
    logger.info("BooxPen: pen gesture suppression hook installed")
end

-- True while the physical stylus is down (or was, very recently, to cover
-- tap/hold recognition latency). Fail-open: on any JNI trouble, report
-- inactive so finger input keeps working.
function BooxPen:isPenActive()
    local a = getAndroid()
    if a and a.booxIsPenDown then
        local ok, active = pcall(a.booxIsPenDown)
        if ok then return active end
    end
    return false
end

function BooxPen:onReaderReady()
    if self:isInert() or not self.ui.document.file then return end
    active_instance = self

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
        if self.show_annotations then
            -- Started from the first paint (see onPaintPage), not from a
            -- fixed timer: starting the pen session before the first page
            -- refresh reached the panel left a stale screen until a touch.
            self.pending_auto_enable = true
        else
            self.inking_before_hide = true
        end
    end
end

function BooxPen:onCloseDocument()
    if self:isInert() then return end
    self.pending_auto_enable = false
    self:setDrawingMode(false, true)
    if self.storage then
        self.storage:close()
        self.storage = nil
    end
    if self.patched_view and self.orig_paintTo then
        self.patched_view.paintTo = self.orig_paintTo
        self.patched_view = nil
        self.orig_paintTo = nil
    end
    if active_instance == self then
        active_instance = nil
    end
end

-- Persist pending strokes whenever KOReader flushes its own settings
-- (app backgrounded, suspend) instead of waiting for the debounce timer.
function BooxPen:onFlushSettings()
    if self.storage then self.storage:flush() end
end

function BooxPen:onSuspend()
    if self.storage then self.storage:flush() end
end

function BooxPen:getCurrentPageNumber()
    if self.view and self.view.state and self.view.state.page then
        return self.view.state.page
    end
    if self.ui then
        if self.ui.rolling and self.ui.rolling.current_page then
            return self.ui.rolling.current_page
        end
        if self.ui.paging and self.ui.paging.current_page then
            return self.ui.paging.current_page
        end
        if self.ui.document then
            if type(self.ui.document.getCurrentPage) == "function" then
                local ok, page = pcall(self.ui.document.getCurrentPage, self.ui.document)
                if ok and page then return page end
            end
            if self.ui.document.paging and self.ui.document.paging.current_page then
                return self.ui.document.paging.current_page
            end
        end
    end
    return 1
end

function BooxPen:onPaintPage(bb, x, y)
    if self.pending_auto_enable then
        self.pending_auto_enable = false
        UIManager:scheduleIn(AUTO_ENABLE_DELAY, function()
            if self.storage and self.show_annotations then
                -- Forced: re-asserts the native session even if our flag
                -- claims it is already on (native side may have lost it).
                self:setDrawingMode(true, true, true)
            end
        end)
    end

    if not self.show_annotations or not self.storage then return end

    local current_page = self:getCurrentPageNumber()
    local strokes = self.storage:getStrokes(current_page)
    if #strokes > 0 then
        logger.dbg("BooxPen: rendering", #strokes, "strokes on page", current_page)
        Renderer.renderPageStrokes(bb, strokes, Screen:getWidth(), Screen:getHeight(), self.ink_weight)
    end
end

-- Repaints the reader and refreshes `region` (whole screen when nil).
-- ReaderUI is the top-level widget; UIManager ignores dirty flags on
-- anything below it (such as ReaderView).
function BooxPen:refreshView(region)
    UIManager:setDirty(self.ui, "ui", region and Geom:new(region) or nil)
end

-- Check if device supports Boox low-latency pen
function BooxPen:isSupported()
    local a = getAndroid()
    if a and a.booxIsSupported then
        return a.booxIsSupported()
    end
    return false
end

function BooxPen:setDrawingMode(enable, silent, force)
    if self.is_drawing_active == enable and not force then return end
    self.is_drawing_active = enable

    local a = getAndroid()
    if not (a and a.booxSetDrawingMode) then
        logger.warn("BooxPen: android.booxSetDrawingMode not available on this build/platform")
        return
    end
    if enable then
        local screen_w = Screen:getWidth()
        local screen_h = Screen:getHeight()
        -- Exclude top menu bar (top 120px) and bottom status bar (bottom 120px)
        local exclude_rects = {
            { x = 0, y = 0, w = screen_w, h = 120 },
            { x = 0, y = screen_h - 120, w = screen_w, h = 120 }
        }
        -- Pen params first: the native enable runs later on the UI thread
        -- and reads them when configuring the hardware pen.
        a.booxSetPenWidth(self.pen_width)
        a.booxSetPenColor(self.pen_color)
        a.booxSetDrawingMode(true, JSON.encode(exclude_rects))
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

-- Decodes the native stroke batch into { {w=, p={x,y,p,...}}, ... } in
-- screen pixels. Native sends a Lua table literal; a JSON array of
-- {width, points={{x,y,p}}} objects is accepted from older builds.
local function decodeStrokes(s)
    if s:sub(1, 1) == "{" then
        local chunk = loadstring("return " .. s, "boox_strokes")
        if not chunk then return nil end
        local ok, res = pcall(chunk)
        return ok and type(res) == "table" and res or nil
    end
    local ok, arr = pcall(JSON.decode, s)
    if not ok or type(arr) ~= "table" then return nil end
    local out = {}
    for _, st in ipairs(arr) do
        if type(st) == "table" and type(st.points) == "table" then
            local flat = {}
            for _, pt in ipairs(st.points) do
                local n = #flat
                flat[n + 1] = pt.x or 0
                flat[n + 2] = pt.y or 0
                flat[n + 3] = math.max(0, math.min(1, (pt.p or 1) / 2))
            end
            table.insert(out, { w = st.width, p = flat })
        end
    end
    return out
end

function BooxPen:pollStrokes()
    local a = getAndroid()
    if not a or not a.booxPollStrokes or not self.storage then return end

    local raw = a.booxPollStrokes()
    if not raw or raw == "" or raw == "[]" then return end

    local strokes = decodeStrokes(raw)
    if not strokes or #strokes == 0 then return end

    local round = EpubStorage.round
    local current_page = self:getCurrentPageNumber()
    local screen_w = Screen:getWidth()
    local screen_h = Screen:getHeight()
    local added = {}

    for _, stroke in ipairs(strokes) do
        local pts = stroke.p
        if type(pts) == "table" and #pts >= 3 then
            -- Normalize coordinates (0..1) so annotations scale across orientations/resolutions
            local norm = {}
            for j = 1, #pts - 2, 3 do
                norm[j] = round(pts[j] / screen_w, 10000)
                norm[j + 1] = round(pts[j + 1] / screen_h, 10000)
                norm[j + 2] = round(pts[j + 2] or 0.5, 100)
            end
            -- Split on teleport jumps (pen micro-lifts, stray contacts):
            -- a single raw stroke with a huge gap would otherwise render as
            -- a long straight connector line across the page.
            for _, seg in ipairs(EpubStorage.splitFlat(norm, STROKE_SPLIT_GAP)) do
                if #seg == 3 then
                    seg[4], seg[5], seg[6] = seg[1], seg[2], seg[3]
                end
                if #seg >= 6 then
                    local s = {
                        w = stroke.w or self.pen_width,
                        c = self.pen_color,
                        p = seg,
                    }
                    self.storage:addStroke(current_page, s)
                    table.insert(added, s)
                end
            end
        end
    end

    -- Repaint and refresh only the area the new strokes cover
    if #added > 0 and self.show_annotations then
        local region = Renderer.strokesBounds(added, screen_w, screen_h, self.ink_weight)
        logger.dbg("BooxPen:", #added, "strokes added, refreshing", region and region.w, region and region.h)
        self:refreshView(region)
    end
end

function BooxPen:undo()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    self.storage:undo(current_page)
    self:refreshView()
    UIManager:show(require("ui/widget/notification"):new{
        text = _("Undid last stroke"),
        timeout = 1,
    })
end

function BooxPen:clearPage()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    self.storage:clearPage(current_page)
    self:refreshView()
    UIManager:show(require("ui/widget/notification"):new{
        text = _("Cleared page annotations"),
        timeout = 1,
    })
end

function BooxPen:setShowAnnotations(show)
    self.show_annotations = show
    G_reader_settings:saveSetting("boox_pen_show_annotations", show)
    if not show then
        -- Pause inking: strokes written now would vanish on pen lift
        self.inking_before_hide = self.is_drawing_active
        if self.is_drawing_active then
            self:setDrawingMode(false, true)
        end
    elseif self.inking_before_hide then
        self.inking_before_hide = nil
        if self.storage then
            self:setDrawingMode(true, true)
        end
    end
    self:refreshView()
end

function BooxPen:setPenWidth(width)
    self.pen_width = width
    G_reader_settings:saveSetting("boox_pen_width", width)
    local a = getAndroid()
    if a and a.booxSetPenWidth then a.booxSetPenWidth(width) end
end

function BooxPen:addToMainMenu(menu_items)
    local width_items = {}
    for _, preset in ipairs(PEN_WIDTHS) do
        table.insert(width_items, {
            text = preset.text,
            checked_func = function() return self.pen_width == preset.width end,
            callback = function() self:setPenWidth(preset.width) end,
        })
    end
    local weight_items = {}
    for _, preset in ipairs(INK_WEIGHTS) do
        table.insert(weight_items, {
            text = preset.text,
            checked_func = function() return self.ink_weight == preset.weight end,
            callback = function()
                self.ink_weight = preset.weight
                G_reader_settings:saveSetting("boox_pen_ink_weight", preset.weight)
                self:refreshView()
            end,
        })
    end

    menu_items.boox_pen = {
        text = _("Boox Stylus Annotations"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Enable Stylus Inking"),
                enabled_func = function() return self.show_annotations end,
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
                    self:setShowAnnotations(not self.show_annotations)
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
                sub_item_table = width_items,
            },
            {
                text = _("Ink After Lift"),
                sub_item_table = weight_items,
            },
        }
    }
end

return BooxPen
