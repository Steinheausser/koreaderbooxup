local JSON = require("json")
local Geom = require("ui/geometry")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("gettext")
local logger = require("logger")

local Anchor = require("anchor")
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
    ink_weight = 1.0,
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
    { text = _("Thinner"), weight = 0.8 },
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
-- A stroke written within this many seconds and px of the previous stroke
-- shares its text anchor, so a handwritten word or sentence moves as one
-- piece when the text reflows instead of being torn apart across lines.
-- Groups stop growing past ANCHOR_GROUP_MAX_H tall (about two lines of
-- handwriting), so separate marks further down get their own anchors.
local ANCHOR_GROUP_SECONDS = 4
local ANCHOR_GROUP_GAP_PX = 120
local ANCHOR_GROUP_MAX_H = 260
-- The eraser deletes strokes passing within this many px of its path
-- (plus half the stroke's width)
local ERASER_REACH_PX = 12
-- Seconds the pen must rest before new ink is pushed to the panel
local PEN_UP_REFRESH_DELAY = 0.5

local EMPTY = {}

-- Smallest {x, y, w, h} covering both regions; either may be nil.
local function unionRegion(a, b)
    if not a then return b end
    if not b then return a end
    local x0, y0 = math.min(a.x, b.x), math.min(a.y, b.y)
    local x1 = math.max(a.x + a.w, b.x + b.w)
    local y1 = math.max(a.y + a.h, b.y + b.h)
    return { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
end

-- Input hooks chain forever once registered, so they are installed once per
-- process and act on whichever reader instance is currently active.
local hooks_installed = false
local active_instance = nil
local contact_state = {}
local contact_slot = 0

-- KOReader's Android framebuffer sends only full refreshes to the Onyx EPD
-- ("full-only" mode, ffi/framebuffer_android.lua); ui/partial/fast ones are
-- left to the firmware, which flashes the whole screen in GC16 and, while the
-- handwriting scheme is active, drops them altogether. While inking, every
-- refresh region is also handed to the pen bridge under this mode value,
-- which only MainActivity.einkUpdate understands (OnyxPenBridge.PEN_REPAINT_MODE;
-- it acts on it in notes mode only).
local PEN_REPAINT_MODE = 0x40000000
local REFRESH_IMPS = {
    "refreshPartialImp", "refreshFlashPartialImp",
    "refreshUIImp", "refreshFlashUIImp", "refreshFastImp",
}
local refresh_hook_installed = false

local function installRefreshHook()
    if refresh_hook_installed then return end
    local a = getAndroid()
    if not (a and a.einkUpdate) then return end
    for _, name in ipairs(REFRESH_IMPS) do
        local orig = Screen[name]
        if type(orig) == "function" then
            Screen[name] = function(fb, x, y, w, h)
                orig(fb, x, y, w, h)
                local plugin_self = active_instance
                if not (plugin_self and plugin_self.is_drawing_active) then return end
                local bb = fb.full_bb or fb.bb
                if not (x and y and w and h) then
                    x, y, w, h = 0, 0, fb:getWidth(), fb:getHeight()
                end
                x, y, w, h = bb:getBoundedRect(x, y, w, h)
                x, y, w, h = bb:getPhysicalRect(x, y, w, h)
                if w > 0 and h > 0 then
                    pcall(a.einkUpdate, PEN_REPAINT_MODE, 0, x, y, w, h)
                end
            end
        end
    end
    refresh_hook_installed = true
    logger.info("BooxPen: pen refresh hook installed")
end

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
    installRefreshHook()
    local auto_enable = G_reader_settings:readSetting("boox_pen_auto_enable")
    self.auto_enable_drawing = (auto_enable == nil) or (auto_enable == true)
    self.pen_width = G_reader_settings:readSetting("boox_pen_width") or 5
    self.ink_weight = G_reader_settings:readSetting("boox_pen_ink_weight") or 1.0
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
    -- Reflowable documents (EPUB, FB2, ...) anchor ink to the text;
    -- fixed-layout ones (PDF, CBZ) keep screen-relative page coordinates.
    self.anchored_mode = Anchor.isSupported(self.ui)
    logger.info("BooxPen: text-anchored ink", self.anchored_mode and "enabled" or "disabled")
    self.anchor_cache = nil
    self.anchor_group = nil

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
    if self.pen_up_refresh then
        UIManager:unschedule(self.pen_up_refresh)
    end
    self.pending_refresh = nil
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

-- Anchored strokes visible in the current view, as { stroke, tx } items
-- placing each at its anchor's current screen position.
function BooxPen:getVisibleAnchored()
    local list = self.storage:getAnchored()
    if #list == 0 then return EMPTY end
    local doc = self.ui.document

    -- Page and document position of every anchor, recomputed only when the
    -- layout (or the stroke list) changes
    local key = Anchor.layoutKey(doc) .. ":" .. self.storage.anchored_rev
    local cache = self.anchor_cache
    if not cache or cache.key ~= key then
        cache = { key = key, ay = {}, page = {} }
        for _, s in ipairs(list) do
            local ok, ay = pcall(doc.getPosFromXPointer, doc, s.a)
            if ok and ay then cache.ay[s] = ay end
            local okp, pg = pcall(doc.getPageFromXPointer, doc, s.a)
            if okp and pg then cache.page[s] = pg end
        end
        self.anchor_cache = cache
    end

    -- Page mode: the pages on screen (two in dual-page view). Scroll mode:
    -- anchors within a screen above/below the current position.
    local page_mode = self.view.view_mode == "page"
    local first_page, last_page, lo, hi
    if page_mode then
        first_page = doc:getCurrentPage()
        local okn, n = pcall(doc.getVisiblePageNumberCount, doc)
        last_page = first_page + ((okn and tonumber(n) or 1) - 1)
    else
        local top = doc:getCurrentPos()
        local screen_h = Screen:getHeight()
        lo, hi = top - screen_h, top + screen_h
    end
    local fs_now = Anchor.fontSize(doc)
    local out = {}
    for _, s in ipairs(list) do
        local visible
        if page_mode then
            local pg = cache.page[s]
            visible = pg and pg >= first_page and pg <= last_page
        else
            local ay = cache.ay[s]
            visible = ay and ay >= lo and ay < hi
        end
        if visible then
            local rx, ry = Anchor.screenPos(doc, s.a)
            if rx then
                local scale = (s.fs and s.fs > 0 and fs_now > 0) and fs_now / s.fs or 1
                table.insert(out, { stroke = s, tx = { sx = scale, sy = scale, ox = rx, oy = ry } })
            end
        end
    end
    return out
end

-- Anchors a stroke given in screen px, sharing the previous stroke's anchor
-- when it belongs to the same burst of writing. Returns the anchored stroke
-- or nil when no text position could be found.
function BooxPen:anchorStroke(px_points, w, c, ignore_time)
    local doc = self.ui.document
    local box = { Anchor.bbox(px_points) }
    local view_key = Anchor.layoutKey(doc) .. "@" .. tostring(doc:getCurrentPos())
    local now = os.time()
    local g = self.anchor_group
    local joins = g and g.view_key == view_key
        and (ignore_time or now - g.t <= ANCHOR_GROUP_SECONDS)
        and Anchor.boxGap(g.last_box, box) <= ANCHOR_GROUP_GAP_PX
        and math.max(g.box[4], box[4]) - math.min(g.box[2], box[2]) <= ANCHOR_GROUP_MAX_H
    if joins then
        g.box = { math.min(g.box[1], box[1]), math.min(g.box[2], box[2]),
                  math.max(g.box[3], box[3]), math.max(g.box[4], box[4]) }
    else
        local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
        local xp, rx, ry = Anchor.find(doc, (box[1] + box[3]) / 2, (box[2] + box[4]) / 2, screen_w, screen_h)
        if not xp then return nil end
        g = { view_key = view_key, xp = xp, rx = rx, ry = ry, fs = Anchor.fontSize(doc), box = box }
        self.anchor_group = g
    end
    g.last_box = box
    g.t = now
    return Anchor.makeStroke(px_points, w, c, g.xp, g.rx, g.ry, g.fs)
end

-- Strokes saved before anchoring existed are screen-positioned per page
-- number. Convert the current page's ones, assuming the layout they were
-- written in is the one on screen now (it is what they were drawn over).
function BooxPen:convertLegacyPage(page)
    if not self.storage or not self.anchored_mode then return end
    -- Legacy strokes were captured per screen in page mode (one key per
    -- screen, also in dual-page view); only convert them on that screen.
    local view_mode = self.view.view_mode
    local current = self:getCurrentPageNumber()
    if view_mode ~= "page" or page ~= current then
        logger.info("BooxPen: not anchoring legacy page", page, "view_mode", view_mode, "current", current)
        return
    end
    local list = self.storage:takePage(page)
    if not list then return end
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local kept = {}
    local converted = 0
    -- Legacy strokes carry no timing: group them by proximity only
    self.anchor_group = nil
    for _, s in ipairs(list) do
        local px = {}
        for j = 1, #s.p - 2, 3 do
            px[j] = s.p[j] * screen_w
            px[j + 1] = s.p[j + 1] * screen_h
            px[j + 2] = s.p[j + 2]
        end
        local a = self:anchorStroke(px, s.w, s.c, true)
        if a then
            self.storage:addAnchored(a)
            converted = converted + 1
        else
            table.insert(kept, s)
        end
    end
    self.anchor_group = nil
    for _, s in ipairs(kept) do self.storage:addStroke(page, s) end
    logger.info("BooxPen: anchored", converted, "legacy strokes on page", page, "kept", #kept)
    self:refreshView()
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
        Renderer.renderPageStrokes(bb, strokes,
            Renderer.screenTransform(Screen:getWidth(), Screen:getHeight(), x, y), self.ink_weight)
        self.legacy_tried = self.legacy_tried or {}
        if self.anchored_mode and not self.legacy_pending and not self.legacy_tried[current_page] then
            -- Converted outside of painting; drawn as-is in the meantime.
            -- Once per page per session: strokes that cannot be anchored
            -- stay screen-positioned instead of retrying on every repaint.
            self.legacy_tried[current_page] = true
            self.legacy_pending = true
            logger.info("BooxPen: scheduling legacy anchoring for page", current_page)
            UIManager:nextTick(function()
                self.legacy_pending = false
                self:convertLegacyPage(current_page)
            end)
        end
    end

    if self.anchored_mode then
        local items = self:getVisibleAnchored()
        for _, it in ipairs(items) do
            local tx = it.tx
            tx.ox, tx.oy = tx.ox + x, tx.oy + y
            Renderer.renderStroke(bb, it.stroke, tx, self.ink_weight)
        end
        if #items > 0 then
            logger.dbg("BooxPen: rendered", #items, "anchored strokes")
        end
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
        self:flushPenUpRefresh(true)
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

-- Pen-up refresh, as in Onyx Notes (500 ms default): new and erased ink is
-- pushed to the panel once the pen has rested, as one update over the union
-- of everything written meanwhile. Live hardware ink covers the gap; a panel
-- update per stroke cost time and repainted the area next to the letter
-- being written.
function BooxPen:schedulePenUpRefresh()
    if not self.pen_up_refresh then
        self.pen_up_refresh = function() self:flushPenUpRefresh() end
    end
    UIManager:unschedule(self.pen_up_refresh)
    UIManager:scheduleIn(PEN_UP_REFRESH_DELAY, self.pen_up_refresh)
end

-- force: refresh now even if the pen is still active (session ending)
function BooxPen:flushPenUpRefresh(force)
    if self.pen_up_refresh then
        UIManager:unschedule(self.pen_up_refresh)
    end
    local region = self.pending_refresh
    if not region then return end
    if not force and self:isPenActive() then
        -- Still writing: wait for the pen to rest
        self:schedulePenUpRefresh()
        return
    end
    self.pending_refresh = nil
    logger.dbg("BooxPen: pen-up refresh", region.x, region.y, region.w, region.h)
    self:refreshView(region)
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
    local erased -- screen region covering everything the eraser removed

    for _, stroke in ipairs(strokes) do
        local pts = stroke.p
        if stroke.e then
            if type(pts) == "table" and #pts >= 3 then
                erased = unionRegion(erased, self:eraseAlong(pts))
            end
        elseif type(pts) == "table" and #pts >= 3 then
            -- Normalize coordinates (0..1) so annotations scale across orientations/resolutions
            local norm = {}
            for j = 1, #pts - 2, 3 do
                norm[j] = round(pts[j] / screen_w, 10000)
                norm[j + 1] = round(pts[j + 1] / screen_h, 10000)
                norm[j + 2] = round(pts[j + 2] or 0.5, 100)
            end
            -- Guard against a doubled point list (see EpubStorage.undouble)
            norm = EpubStorage.undouble(norm)
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
                    local anchored
                    if self.anchored_mode then
                        local px = {}
                        for j = 1, #seg - 2, 3 do
                            px[j] = seg[j] * screen_w
                            px[j + 1] = seg[j + 1] * screen_h
                            px[j + 2] = seg[j + 2]
                        end
                        anchored = self:anchorStroke(px, s.w, s.c)
                    end
                    if anchored then
                        self.storage:addAnchored(anchored)
                    else
                        self.storage:addStroke(current_page, s)
                    end
                    table.insert(added, s)
                end
            end
        end
    end

    -- Repaint and refresh only the area the new and erased strokes cover
    -- (strokesBounds pads by the stroke width, which also wipes the panel's
    -- copy of erased ink).
    local region = erased
    if #added > 0 then
        region = unionRegion(region, Renderer.strokesBounds(added,
            Renderer.screenTransform(screen_w, screen_h), screen_w, screen_h, self.ink_weight))
    end
    if region and self.show_annotations then
        logger.dbg("BooxPen:", #added, "strokes added, erased", erased ~= nil,
            "pending refresh", region.w, region.h)
        self.pending_refresh = unionRegion(self.pending_refresh, region)
        self:schedulePenUpRefresh()
    end
end

-- True when any point of `stroke` (drawn with transform tx) lies within
-- `reach` px of a point of the eraser path `ex` (flat screen px {x,y,p,...}),
-- whose bounding box is `ebox` = {x0, y0, x1, y1}.
local function strokeHit(stroke, tx, ex, ebox, reach)
    local pts = stroke.p
    local sx, sy, ox, oy = tx.sx, tx.sy, tx.ox, tx.oy
    local r2 = reach * reach
    for j = 1, #pts - 2, 3 do
        local x = ox + pts[j] * sx
        local y = oy + pts[j + 1] * sy
        if x >= ebox[1] - reach and x <= ebox[3] + reach
                and y >= ebox[2] - reach and y <= ebox[4] + reach then
            for k = 1, #ex - 2, 3 do
                local dx, dy = x - ex[k], y - ex[k + 1]
                if dx * dx + dy * dy <= r2 then return true end
            end
        end
    end
    return false
end

-- Stroke eraser: deletes every visible stroke the eraser path (screen px,
-- flat {x,y,p,...}) passes over. Returns the screen region the removed
-- strokes covered, or nil when nothing was removed.
function BooxPen:eraseAlong(ex)
    if not self.storage then return nil end
    local ebox = { Anchor.bbox(ex) }
    local removed = 0
    local screen_w, screen_h = Screen:getWidth(), Screen:getHeight()
    local region

    local page = self:getCurrentPageNumber()
    local page_tx = Renderer.screenTransform(screen_w, screen_h)
    local set, hits = {}, {}
    for _, s in ipairs(self.storage:getStrokes(page)) do
        local reach = ERASER_REACH_PX + Renderer.pointWidth(s.w or 5, 1, self.ink_weight) / 2
        if strokeHit(s, page_tx, ex, ebox, reach) then
            set[s] = true
            hits[#hits + 1] = s
            removed = removed + 1
        end
    end
    if removed > 0 then
        region = Renderer.strokesBounds(hits, page_tx, screen_w, screen_h, self.ink_weight)
        self.storage:removeStrokes(page, set)
    end

    if self.anchored_mode then
        local aset, n = {}, 0
        for _, it in ipairs(self:getVisibleAnchored()) do
            local s = it.stroke
            local reach = ERASER_REACH_PX + Renderer.pointWidth(s.w or 5, 1, self.ink_weight) / 2
            if strokeHit(s, it.tx, ex, ebox, reach) then
                aset[s] = true
                n = n + 1
                region = unionRegion(region,
                    Renderer.strokesBounds({ s }, it.tx, screen_w, screen_h, self.ink_weight))
            end
        end
        if n > 0 then
            self.storage:removeAnchored(aset)
            removed = removed + n
        end
    end
    logger.info("BooxPen: eraser removed", removed, "strokes")
    return region
end

function BooxPen:undo()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    local removed = false
    if self.anchored_mode then
        -- Newest anchored stroke in view (the list is in writing order)
        local visible = {}
        for _, it in ipairs(self:getVisibleAnchored()) do visible[it.stroke] = true end
        local list = self.storage:getAnchored()
        for i = #list, 1, -1 do
            if visible[list[i]] then
                self.storage:removeAnchored({ [list[i]] = true })
                removed = true
                break
            end
        end
    end
    if not removed then
        self.storage:undo(current_page)
    end
    self:refreshView()
    UIManager:show(require("ui/widget/notification"):new{
        text = _("Undid last stroke"),
        timeout = 1,
    })
end

function BooxPen:clearPage()
    if not self.storage then return end
    local current_page = self:getCurrentPageNumber()
    if self.anchored_mode then
        local set = {}
        for _, it in ipairs(self:getVisibleAnchored()) do set[it.stroke] = true end
        self.storage:removeAnchored(set)
    end
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
