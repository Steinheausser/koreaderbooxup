package org.koreader.launcher.device.epd

import android.app.Activity
import android.graphics.Color
import android.graphics.PixelFormat
import android.graphics.Rect
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.SurfaceHolder
import android.view.SurfaceView
import android.view.ViewGroup
import com.onyx.android.sdk.pen.RawInputCallback
import com.onyx.android.sdk.pen.TouchHelper
import com.onyx.android.sdk.api.device.epd.EpdController
import com.onyx.android.sdk.data.note.TouchPoint
import com.onyx.android.sdk.pen.data.TouchPointList
import org.json.JSONArray
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * OnyxPenBridge manages hardware-accelerated, low-latency stylus drawing
 * via Onyx Boox SDK's TouchHelper for Android 10+ (Boox OS 3.5, Max Lumi, etc.).
 *
 * Uses a transparent SurfaceView overlay attached to the Activity window,
 * ensuring proper SurfaceFlinger hardware-level scribble acceleration.
 */
object OnyxPenBridge {
    private const val TAG = "OnyxPenBridge"

    private var touchHelper: TouchHelper? = null
    private var isDrawingActive = false

    // Hardware pen width (EPD units). Lua stores the same value per stroke
    // and derives the vector width from it, so live and settled ink match.
    private var currentStrokeWidth: Float = 5.0f
    // Always opaque ARGB. Lua's KOReader gray (0 = black) is converted in
    // setPenColor: a raw 0 here is ARGB transparent and kills live ink.
    private var currentStrokeColor: Int = Color.BLACK

    // Digitizer max pressure, used to normalize TouchPoint.pressure to 0..1
    private var maxPressure: Float = 0f

    // Transparent SurfaceView overlay
    private var overlaySurfaceView: SurfaceView? = null
    private var isSurfaceReady = false
    private var pendingEnable = false
    private var pendingExcludeRectsJson: String? = null

    // Lua-side desire, independent of transient hardware state. The overlay
    // surface can be destroyed at any time (rotation, screen off/on); when it
    // comes back we must re-establish the session instead of staying dead
    // while Lua still believes inking is on.
    private var drawingRequested = false
    private var lastExcludeRectsJson: String? = null

    // Queue of finalized strokes ready to be consumed by the Lua layer.
    // Each entry is a Lua table literal: {w=5,p={x,y,p,x,y,p,...}}
    private val pendingStrokes = ConcurrentLinkedQueue<String>()

    // Current stroke points (flat "x,y,p," triples) gathered between onBegin and onEnd
    private val activePoints = StringBuilder()
    private var activePointCount = 0
    private var firstPointText: String? = null
    private val strokeLock = Any()

    private var lastAddedX = -1f
    private var lastAddedY = -1f

    // Physical pen state, exposed to Lua so gesture suppression can tell
    // pen contacts apart from finger taps (the pen also emits emulated
    // finger events, indistinguishable otherwise). Active = down now, or
    // lifted very recently (covers tap/hold recognition latency).
    @Volatile private var penDown = false
    @Volatile private var lastPenEndUptime = 0L

    private val mainHandler = Handler(Looper.getMainLooper())

    private val callback = object : RawInputCallback() {
        override fun onBeginRawDrawing(b: Boolean, point: TouchPoint) {
            Log.d(TAG, "onBeginRawDrawing at (${point.x}, ${point.y}, p=${point.pressure})")
            penDown = true
            try {
                overlaySurfaceView?.let {
                    EpdController.enterScribbleMode(it)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "OnyxPenBridge: enter scribble on pen-down FAILED", e)
            }
            synchronized(strokeLock) {
                resetActiveStroke()
                addPoint(point)
            }
        }

        override fun onEndRawDrawing(b: Boolean, point: TouchPoint) {
            synchronized(strokeLock) {
                addPoint(point)
                if (activePointCount >= 1) {
                    if (activePointCount == 1) {
                        // Duplicate single point so renderer can draw a dot
                        firstPointText?.let { activePoints.append(it) }
                        activePointCount++
                    }
                    // Drop the trailing comma
                    activePoints.setLength(activePoints.length - 1)
                    val stroke = StringBuilder(activePoints.length + 24)
                        .append("{w=").append(fmt(currentStrokeWidth, 1))
                        .append(",p={").append(activePoints).append("}}")
                        .toString()
                    pendingStrokes.add(stroke)
                    Log.d(TAG, "Stroke queued: $activePointCount points")
                }
                resetActiveStroke()
            }
            penDown = false
            lastPenEndUptime = android.os.SystemClock.uptimeMillis()
            // Drop the handwriting scheme at lift: while it is active the
            // firmware gates every panel update, so the Lua layer's vector
            // repaint (polled ~100ms later) would never reach the panel.
            // Re-entered on the next pen-down.
            try {
                overlaySurfaceView?.let {
                    EpdController.leaveScribbleMode(it)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "OnyxPenBridge: leave scribble on pen-up FAILED", e)
            }
        }

        override fun onRawDrawingTouchPointMoveReceived(point: TouchPoint) {
            synchronized(strokeLock) {
                addPoint(point)
            }
        }

        override fun onRawDrawingTouchPointListReceived(pointList: TouchPointList) {
            synchronized(strokeLock) {
                val pts = pointList.points
                if (pts != null) {
                    for (p in pts) {
                        addPoint(p)
                    }
                }
            }
        }

        override fun onBeginRawErasing(b: Boolean, point: TouchPoint) {}
        override fun onEndRawErasing(b: Boolean, point: TouchPoint) {}
        override fun onRawErasingTouchPointMoveReceived(point: TouchPoint) {}
        override fun onRawErasingTouchPointListReceived(pointList: TouchPointList) {}
    }

    fun isSupported(): Boolean {
        return Build.MANUFACTURER.equals("onyx", ignoreCase = true) ||
               Build.BRAND.equals("onyx", ignoreCase = true) ||
               Build.FINGERPRINT.contains("onyx", ignoreCase = true)
    }

    fun isDrawingActive(): Boolean = isDrawingActive

    /**
     * True while the physical pen is down, or briefly after lift (covers
     * tap/hold/swipe recognition latency, which resolves after the lift).
     */
    fun isPenActive(): Boolean {
        if (penDown) return true
        return android.os.SystemClock.uptimeMillis() - lastPenEndUptime < 400
    }

    /**
     * Ensures the transparent SurfaceView overlay exists and is attached to the Activity.
     * The overlay stays GONE (fully detached from compositing and touch dispatch)
     * until drawing mode is actually enabled, so normal KOReader startup, dialogs
     * and touch handling are never affected.
     */
    private fun ensureOverlayView(activity: Activity): SurfaceView {
        overlaySurfaceView?.let { return it }

        val surfaceView = SurfaceView(activity).apply {
            setZOrderOnTop(true)
            holder.setFormat(PixelFormat.TRANSPARENT)
            setBackgroundColor(Color.TRANSPARENT)
            visibility = android.view.View.GONE
            setOnTouchListener { v, event ->
                if (isDrawingActive) {
                    val y = event.y
                    val h = v.height
                    val isMenuZone = y < 140f || (h > 0 && y > (h - 140f))
                    if (isMenuZone) {
                        false // Pass through to allow menu and status bar taps
                    } else {
                        true // Consume input so NativeActivity does not interpret pen strokes as page flips
                    }
                } else {
                    false
                }
            }
            isClickable = false
            isFocusable = false
        }

        surfaceView.holder.addCallback(object : SurfaceHolder.Callback {
            override fun surfaceCreated(holder: SurfaceHolder) {
                Log.i(TAG, "OnyxPenBridge: Overlay SurfaceView created (${surfaceView.width}x${surfaceView.height})")
                isSurfaceReady = true
                if (pendingEnable) {
                    pendingEnable = false
                    applyDrawingMode(activity, true, pendingExcludeRectsJson)
                } else if (drawingRequested && !isDrawingActive) {
                    // Surface was destroyed mid-session (rotation, screen
                    // off/on) while Lua still wants inking: re-establish.
                    Log.i(TAG, "OnyxPenBridge: re-establishing requested drawing session after surface recreation")
                    applyDrawingMode(activity, true, lastExcludeRectsJson)
                }
            }

            override fun surfaceChanged(holder: SurfaceHolder, format: Int, width: Int, height: Int) {
                Log.d(TAG, "OnyxPenBridge: Overlay SurfaceView changed: ${width}x${height}")
            }

            override fun surfaceDestroyed(holder: SurfaceHolder) {
                Log.i(TAG, "OnyxPenBridge: Overlay SurfaceView destroyed")
                isSurfaceReady = false
                // Tear down the hardware session, but remember Lua's desire
                // (drawingRequested) so surfaceCreated can revive it. Drop the
                // TouchHelper so the next enable starts from a clean object.
                try {
                    touchHelper?.let { helper ->
                        try {
                            helper.setRawDrawingRenderEnabled(false)
                        } catch (_: Throwable) {}
                        try {
                            helper.setRawDrawingEnabled(false)
                        } catch (_: Throwable) {}
                        try {
                            helper.closeRawDrawing()
                        } catch (_: Throwable) {}
                    }
                } catch (e: Throwable) {
                    Log.e(TAG, "Error closing raw drawing on surface destroy", e)
                }
                touchHelper = null
                pendingEnable = false
                pendingExcludeRectsJson = null
                penDown = false
                isDrawingActive = false
                Log.i(TAG, "OnyxPenBridge: Drawing mode suspended (surface gone, requested=$drawingRequested)")
            }
        })

        val params = ViewGroup.LayoutParams(
            ViewGroup.LayoutParams.MATCH_PARENT,
            ViewGroup.LayoutParams.MATCH_PARENT
        )
        activity.addContentView(surfaceView, params)
        overlaySurfaceView = surfaceView
        Log.i(TAG, "OnyxPenBridge: Overlay SurfaceView added to window")
        return surfaceView
    }

    /**
     * No eager overlay creation: the overlay SurfaceView is created lazily on
     * the first setDrawingMode(true) call. Creating it in onCreate puts a
     * fullscreen clickable SurfaceView above NativeActivity's content view,
     * which blanks the display and swallows touches (e.g. first-run dialogs).
     */
    fun init(activity: Activity) {
        if (!isSupported()) return
        Log.d(TAG, "OnyxPenBridge supported on this device; overlay will be created lazily")
    }

    private fun resetActiveStroke() {
        activePoints.setLength(0)
        activePointCount = 0
        firstPointText = null
        lastAddedX = -1f
        lastAddedY = -1f
    }

    // Compact, locale-independent number formatting for the Lua literal
    private fun fmt(v: Float, decimals: Int): String {
        val scale = if (decimals == 1) 10.0 else 100.0
        val r = Math.round(v * scale) / scale
        return if (r == Math.floor(r)) r.toLong().toString() else r.toString()
    }

    private fun normalizedPressure(raw: Float): Float {
        if (maxPressure <= 0f) {
            maxPressure = try {
                EpdController.getMaxTouchPressure()
            } catch (_: Throwable) {
                0f
            }
            if (maxPressure <= 0f) maxPressure = 4096f
            Log.i(TAG, "Max touch pressure: $maxPressure")
        }
        if (raw <= 0f) return 0.5f
        // Some firmwares already report 0..1
        if (raw <= 1.0f) return raw
        return (raw / maxPressure).coerceIn(0f, 1f)
    }

    private fun addPoint(point: TouchPoint) {
        try {
            val dx = point.x - lastAddedX
            val dy = point.y - lastAddedY
            // Downsample: skip redundant points within 3.0px distance to prevent point explosion
            if (lastAddedX >= 0f && (dx * dx + dy * dy) < 9.0f) {
                return
            }
            lastAddedX = point.x
            lastAddedY = point.y

            // Pressure normalized to 0..1 against the digitizer maximum;
            // the Lua renderer maps it to a width multiplier.
            val text = fmt(point.x, 1) + "," + fmt(point.y, 1) + "," +
                fmt(normalizedPressure(point.pressure), 2) + ","
            if (firstPointText == null) firstPointText = text
            activePoints.append(text)
            activePointCount++
        } catch (e: Exception) {
            Log.e(TAG, "Error adding point", e)
        }
    }

    private fun applyDrawingMode(activity: Activity, enabled: Boolean, excludeRectsJson: String?) {
        if (enabled) {
            val surfaceView = ensureOverlayView(activity)
            // Make the overlay part of layout/compositing so its Surface is
            // created; surfaceCreated() resumes the pending enable.
            if (surfaceView.visibility != android.view.View.VISIBLE) {
                surfaceView.visibility = android.view.View.VISIBLE
                surfaceView.isClickable = true
            }
            if (!isSurfaceReady) {
                Log.i(TAG, "SurfaceView not ready yet, deferring drawing mode enable")
                pendingEnable = true
                pendingExcludeRectsJson = excludeRectsJson
                return
            }

            try {
                val helper = touchHelper ?: TouchHelper.create(surfaceView, true, callback).also {
                    touchHelper = it
                    it.setStrokeStyle(TouchHelper.STROKE_STYLE_BRUSH)
                    it.setStrokeWidth(currentStrokeWidth)
                    it.setStrokeColor(currentStrokeColor)
                    it.setPostInputEvent(false)
                    it.setPenUpRefreshEnabled(false)
                    it.debugLog(false)
                }

                val screenW = if (surfaceView.width > 0) surfaceView.width else activity.resources.displayMetrics.widthPixels
                val screenH = if (surfaceView.height > 0) surfaceView.height else activity.resources.displayMetrics.heightPixels
                val screenRect = Rect(0, 0, screenW, screenH)

                val excludeList = mutableListOf<Rect>()
                if (!excludeRectsJson.isNullOrEmpty()) {
                    try {
                        val jsonArr = JSONArray(excludeRectsJson)
                        for (i in 0 until jsonArr.length()) {
                            val item = jsonArr.getJSONObject(i)
                            val x = item.getInt("x")
                            val y = item.getInt("y")
                            val w = item.getInt("w")
                            val h = item.getInt("h")
                            excludeList.add(Rect(x, y, x + w, y + h))
                        }
                    } catch (e: Exception) {
                        Log.w(TAG, "Failed parsing exclude rects", e)
                    }
                }

                helper.setStrokeStyle(TouchHelper.STROKE_STYLE_BRUSH)
                helper.setStrokeWidth(currentStrokeWidth)
                helper.setStrokeColor(currentStrokeColor)
                helper.setLimitRect(listOf(screenRect), excludeList)
                helper.openRawDrawing()
                helper.setRawDrawingEnabled(true)
                helper.setRawDrawingRenderEnabled(true)
                helper.setPostInputEvent(false)
                helper.setPenUpRefreshEnabled(false)
                // Pen-only: keep finger/palm contacts out of the raw stream
                // (they used to merge into strokes as long teleport jumps).
                helper.enableFingerTouch(false)
                isDrawingActive = true
                Log.i(TAG, "OnyxPenBridge: Drawing mode ENABLED on SurfaceView (${screenW}x${screenH}, ${excludeList.size} exclusion zones)")
                try {
                    // Scribble mode is NOT entered here: while the handwriting
                    // scheme is active the panel executes no updates, which
                    // froze the first book refresh at startup until a touch.
                    // onBeginRawDrawing enters it at every pen-down (and
                    // onEndRawDrawing leaves it), which covers the first
                    // stroke as well.
                    EpdController.setScreenHandWritingPenState(surfaceView, 1)
                } catch (e: Throwable) {
                    Log.e(TAG, "OnyxPenBridge: setScreenHandWritingPenState FAILED", e)
                }
                try {
                    // openRawDrawing() internally resets the stroke style to
                    // PENCIL, so (re-)apply AFTER open. The hardware EPD render
                    // params live on EpdController, which TouchHelper never
                    // touches, so set them explicitly as well. Width follows
                    // the Lua pen-width setting (default 5, known working).
                    helper.setStrokeStyle(TouchHelper.STROKE_STYLE_BRUSH)
                    helper.setStrokeWidth(currentStrokeWidth)
                    EpdController.setStrokeStyle(TouchHelper.STROKE_STYLE_BRUSH)
                    EpdController.setStrokeWidth(currentStrokeWidth)
                    EpdController.setStrokeColor(currentStrokeColor)
                    Log.i(TAG, "OnyxPenBridge: hardware stroke params set (BRUSH, w=$currentStrokeWidth)")
                } catch (e: Throwable) {
                    Log.e(TAG, "OnyxPenBridge: setting hardware stroke params FAILED", e)
                }
                primeHardwarePen(surfaceView)
            } catch (e: Throwable) {
                Log.e(TAG, "Error enabling drawing mode on SurfaceView", e)
            }
        } else {
            pendingEnable = false
            pendingExcludeRectsJson = null
            try {
                overlaySurfaceView?.let { surfaceView ->
                    EpdController.leaveScribbleMode(surfaceView)
                    EpdController.setScreenHandWritingPenState(surfaceView, 0)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error leaving scribble mode", e)
            }
            try {
                touchHelper?.let { helper ->
                    helper.setRawDrawingRenderEnabled(false)
                    helper.setRawDrawingEnabled(false)
                    helper.closeRawDrawing()
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error closing raw drawing", e)
            }
            touchHelper = null
            isDrawingActive = false
            // Hide overlay so it neither composites over KOReader nor
            // intercepts touches while inking is off.
            try {
                overlaySurfaceView?.let {
                    it.visibility = android.view.View.GONE
                    it.isClickable = false
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error hiding overlay view", e)
            }
            Log.i(TAG, "OnyxPenBridge: Drawing mode DISABLED")
        }
    }

    /**
     * Diagnostic + workaround restored verbatim: with this delayed
     * startStroke-family call present, live ink works; without it, it does
     * not (mechanism still under investigation — prime suspect is EPD pen
     * width/state setup that only this API family performs on this
     * firmware). Delayed past enable-time refreshes; remove once the
     * minimal sufficient trigger is isolated.
     */
    private fun primeHardwarePen(surfaceView: SurfaceView) {
        mainHandler.postDelayed({
            try {
                EpdController.setStrokeStyle(TouchHelper.STROKE_STYLE_BRUSH)
                EpdController.setStrokeWidth(5f)
                EpdController.setStrokeColor(Color.BLACK)
                // Guess at arg order: x0, y0, x1, y1, pressure, width.
                EpdController.startStroke(200f, 500f, 1400f, 600f, 1.0f, 5f)
                EpdController.addStrokePoint(600f, 520f, 1000f, 560f, 1.0f, 5f)
                EpdController.finishStroke(1000f, 560f, 1400f, 600f, 1.0f, 5f)
                Log.i(TAG, "OnyxPenBridge: stroke-API test line issued")
                // Restore the user's pen settings the prime overrode above
                EpdController.setStrokeWidth(currentStrokeWidth)
                EpdController.setStrokeColor(currentStrokeColor)
                touchHelper?.setStrokeWidth(currentStrokeWidth)
            } catch (e: Throwable) {
                Log.e(TAG, "OnyxPenBridge: stroke-API test line FAILED", e)
            }
        }, 5000)
    }

    /**
     * Toggles hardware inking mode on/off.
     * excludeRectsJson: JSON array of [{x, y, w, h}] representing menu/status bar regions to exclude
     */
    fun setDrawingMode(activity: Activity, enabled: Boolean, excludeRectsJson: String? = null) {
        if (!isSupported()) return
        drawingRequested = enabled
        if (enabled) {
            lastExcludeRectsJson = excludeRectsJson
        } else {
            lastExcludeRectsJson = null
        }

        mainHandler.post {
            if (isDrawingActive == enabled && !pendingEnable) {
                Log.d(TAG, "Drawing mode already $enabled, ignoring redundant call")
                return@post
            }
            applyDrawingMode(activity, enabled, excludeRectsJson)
        }
    }

    fun setPenWidth(width: Float) {
        currentStrokeWidth = width
        touchHelper?.setStrokeWidth(width)
        try {
            EpdController.setStrokeWidth(width)
        } catch (_: Throwable) {}
    }

    /**
     * color: KOReader 8-bit gray (0 = black, 255 = white), converted to opaque
     * ARGB. Values outside 0..255 are taken as ARGB already.
     */
    fun setPenColor(color: Int) {
        currentStrokeColor = if (color in 0..255) Color.rgb(color, color, color) else color
        touchHelper?.setStrokeColor(color)
        try {
            EpdController.setStrokeColor(color)
        } catch (_: Throwable) {}
    }

    /**
     * Drains all pending completed strokes and returns them as one Lua table
     * literal ({{w=5,p={...}},...}), or "" when nothing is pending.
     * Called by Lua layer.
     */
    fun pollStrokesJson(): String {
        if (pendingStrokes.isEmpty()) return ""

        val sb = StringBuilder("{")
        while (true) {
            val stroke = pendingStrokes.poll() ?: break
            if (sb.length > 1) sb.append(',')
            sb.append(stroke)
        }
        return sb.append('}').toString()
    }

    fun clearPendingStrokes() {
        pendingStrokes.clear()
        synchronized(strokeLock) {
            resetActiveStroke()
        }
    }

    fun onPause() {
        if (isDrawingActive) {
            try {
                touchHelper?.setRawDrawingEnabled(false)
                overlaySurfaceView?.let { surfaceView ->
                    EpdController.leaveScribbleMode(surfaceView)
                    EpdController.setScreenHandWritingPenState(surfaceView, 3)
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error in onPause", e)
            }
        }
    }

    fun onResume() {
        if (isDrawingActive) {
            try {
                // No enterScribbleMode here (see applyDrawingMode): it would
                // freeze panel updates after wake until the next pen stroke.
                overlaySurfaceView?.let { surfaceView ->
                    EpdController.setScreenHandWritingPenState(surfaceView, 2)
                }
                touchHelper?.setRawDrawingEnabled(true)
            } catch (e: Throwable) {
                Log.e(TAG, "Error in onResume", e)
            }
        }
    }

    fun onDestroy() {        try {
            overlaySurfaceView?.let { surfaceView ->
                EpdController.leaveScribbleMode(surfaceView)
                EpdController.setScreenHandWritingPenState(surfaceView, 0)
            }
        } catch (_: Throwable) {}
        try {
            touchHelper?.closeRawDrawing()
            touchHelper = null
            isDrawingActive = false
            isSurfaceReady = false
            pendingEnable = false
            pendingExcludeRectsJson = null
            drawingRequested = false
            lastExcludeRectsJson = null
            overlaySurfaceView?.let { v ->
                try {
                    (v.parent as? ViewGroup)?.removeView(v)
                } catch (e: Throwable) {
                    Log.e(TAG, "Error removing overlay view", e)
                }
            }
            overlaySurfaceView = null
            clearPendingStrokes()
        } catch (e: Throwable) {
            Log.e(TAG, "Error in onDestroy", e)
        }
    }
}
