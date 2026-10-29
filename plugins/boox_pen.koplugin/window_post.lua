--[[
Dirty-rect window posts for KOReader's Android framebuffer
(ffi/framebuffer_android.lua).

Stock `_updateWindow` locks the whole ANativeWindow and copies the whole
screen buffer into it on every refresh, however small the refresh is
(2200x1650 RGB32 = 14.5 MB on the Max Lumi). While inking, nearly every
refresh is small: pen-up ink, erased strokes, undo. So instead, the window
is locked with the refresh rect as its dirty bounds: Android's Surface copies
everything outside them back from the previous frame, and only the bounds it
hands back are copied from KOReader's buffer.

Only used for unrotated, non-inverted buffers (anything else takes the stock
path), and only while `enabled()` says so.
]]

local BB = require("ffi/blitbuffer")
local ffi = require("ffi")
local logger = require("logger")

local WindowPost = {
    installed = false,
}

-- Refreshes that carry a rect (refreshFullImp always posts everything)
local RECT_IMPS = {
    "refreshPartialImp", "refreshFlashPartialImp",
    "refreshUIImp", "refreshFlashUIImp", "refreshFastImp",
}

-- fb: the framebuffer (Device.screen); android: the android module;
-- enabled(): true when refreshes should post their rect only.
function WindowPost.install(fb, android, enabled)
    if WindowPost.installed then return true end
    local orig_update = fb._updateWindow
    if type(orig_update) ~= "function" then return false end
    local lib = android and android.lib
    local ok = lib and pcall(function() return lib.ANativeWindow_lock and lib.ANativeWindow_unlockAndPost end)
    if not ok then return false end
    local C = ffi.C
    local buffer = ffi.new("ANativeWindow_Buffer[1]")
    local bounds = ffi.new("ARect[1]")

    -- Rect of the refresh being run, consumed by the next _updateWindow
    -- (every refresh*Imp starts with self:_updateWindow())
    local rx, ry, rw, rh

    for _, name in ipairs(RECT_IMPS) do
        local imp = fb[name]
        if type(imp) == "function" then
            fb[name] = function(self, x, y, w, h)
                rx, ry, rw, rh = x, y, w, h
                return imp(self, x, y, w, h)
            end
        end
    end

    fb._updateWindow = function(self)
        local x, y, w, h = rx, ry, rw, rh
        rx, ry, rw, rh = nil, nil, nil, nil
        if not (x and y and w and h) or not enabled() then
            return orig_update(self)
        end
        local ext = self.full_bb or self.bb
        if ext:getRotation() ~= 0 or ext:getInverse() ~= 0 then
            return orig_update(self)
        end
        local window = android.app.window
        if window == nil then
            return orig_update(self)
        end
        x, y, w, h = ext:getBoundedRect(x, y, w, h)
        if w <= 0 or h <= 0 then return end

        local d = bounds[0]
        d.left, d.top, d.right, d.bottom = x, y, x + w, y + h
        if lib.ANativeWindow_lock(window, buffer, bounds) < 0 then
            logger.warn("BooxPen: unable to lock window buffer")
            return
        end
        local b = buffer[0]
        local bb
        if b.format == C.WINDOW_FORMAT_RGBA_8888 or b.format == C.WINDOW_FORMAT_RGBX_8888 then
            bb = BB.new(b.width, b.height, BB.TYPE_BBRGB32, b.bits, b.stride * 4, b.stride)
        elseif b.format == C.WINDOW_FORMAT_RGB_565 then
            bb = BB.new(b.width, b.height, BB.TYPE_BBRGB16, b.bits, b.stride * 2, b.stride)
        else
            logger.warn("BooxPen: unsupported window format", b.format)
        end
        if bb then
            if b.width == ext:getWidth() and b.height == ext:getHeight() then
                -- Bounds as returned by the lock: whole buffer when the
                -- previous frame could not be copied back
                bb:blitFrom(ext, d.left, d.top, d.left, d.top, d.right - d.left, d.bottom - d.top)
            else
                bb:blitFrom(ext)
            end
        end
        lib.ANativeWindow_unlockAndPost(window)
    end

    WindowPost.installed = true
    logger.info("BooxPen: dirty-rect window posts installed")
    return true
end

return WindowPost
