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
import android.view.View
import android.view.ViewGroup
import com.onyx.android.sdk.pen.RawInputCallback
import com.onyx.android.sdk.pen.TouchHelper
import com.onyx.android.sdk.data.note.TouchPoint
import com.onyx.android.sdk.pen.data.TouchPointList
import org.json.JSONArray
import org.json.JSONObject
import java.util.concurrent.ConcurrentLinkedQueue

/**
 * OnyxPenBridge manages hardware-accelerated, low-latency stylus drawing
 * via Onyx Boox SDK's TouchHelper for Android 10+ (Boox OS 3.5, Max Lumi, etc.).
 *
 * Uses a transparent SurfaceView overlay that activates only during drawing mode,
 * leaving normal touch and reader operations completely unaffected.
 */
object OnyxPenBridge {
    private const val TAG = "OnyxPenBridge"

    private var overlaySurface: SurfaceView? = null
    private var touchHelper: TouchHelper? = null
    private var isDrawingActive = false

    private var currentStrokeWidth: Float = 3.0f
    private var currentStrokeColor: Int = Color.BLACK

    // Queue of finalized strokes ready to be consumed by the Lua layer
    private val pendingStrokes = ConcurrentLinkedQueue<String>()

    // Current stroke points being gathered between onBegin and onEnd
    private val activePoints = mutableListOf<JSONObject>()
    private val strokeLock = Any()

    private val mainHandler = Handler(Looper.getMainLooper())

    fun isSupported(): Boolean {
        return Build.MANUFACTURER.equals("onyx", ignoreCase = true)
    }

    private var lastExcludeRectsJson: String? = null

    /**
     * Initializes the transparent overlay SurfaceView on the Activity.
     */
    fun init(activity: Activity) {
        if (!isSupported()) return

        mainHandler.post {
            try {
                if (overlaySurface != null) return@post

                val surface = SurfaceView(activity).apply {
                    setZOrderOnTop(true)
                    holder.setFormat(PixelFormat.TRANSPARENT)
                    visibility = View.GONE
                }

                val layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT
                )

                activity.addContentView(surface, layoutParams)
                overlaySurface = surface

                surface.holder.addCallback(object : SurfaceHolder.Callback {
                    override fun surfaceCreated(holder: SurfaceHolder) {
                        initTouchHelper(surface)
                        if (isDrawingActive) {
                            applyRawDrawingState(activity, surface, true, lastExcludeRectsJson)
                        }
                    }
                    override fun surfaceChanged(holder: SurfaceHolder, format: Int, w: Int, h: Int) {}
                    override fun surfaceDestroyed(holder: SurfaceHolder) {
                        touchHelper?.closeRawDrawing()
                    }
                })

                Log.i(TAG, "OnyxPenBridge overlay SurfaceView initialized successfully")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to initialize OnyxPenBridge overlay", e)
            }
        }
    }

    private fun initTouchHelper(surface: SurfaceView) {
        try {
            val callback = object : RawInputCallback() {
                override fun onBeginRawDrawing(b: Boolean, point: TouchPoint) {
                    synchronized(strokeLock) {
                        activePoints.clear()
                        addPoint(point)
                    }
                }

                override fun onEndRawDrawing(b: Boolean, point: TouchPoint) {
                    synchronized(strokeLock) {
                        addPoint(point)
                        if (activePoints.isNotEmpty()) {
                            val strokeObj = JSONObject().apply {
                                put("width", currentStrokeWidth.toDouble())
                                put("color", currentStrokeColor)
                                val ptsArray = JSONArray()
                                for (p in activePoints) {
                                    ptsArray.put(p)
                                }
                                put("points", ptsArray)
                            }
                            pendingStrokes.add(strokeObj.toString())
                            activePoints.clear()
                        }
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

            touchHelper = TouchHelper.create(surface, callback).apply {
                setStrokeWidth(currentStrokeWidth)
                setStrokeColor(currentStrokeColor)
            }
            Log.i(TAG, "TouchHelper created successfully")
        } catch (e: Throwable) {
            Log.e(TAG, "Error initializing TouchHelper", e)
        }
    }

    private fun addPoint(point: TouchPoint) {
        val pt = JSONObject()
        pt.put("x", point.x.toDouble())
        pt.put("y", point.y.toDouble())
        pt.put("p", point.pressure.toDouble())
        activePoints.add(pt)
    }

    /**
     * Toggles hardware inking mode on/off.
     * excludeRectsJson: JSON array of [{x, y, w, h}] representing menu/status bar regions to exclude
     */
    fun setDrawingMode(activity: Activity, enabled: Boolean, excludeRectsJson: String? = null) {
        if (!isSupported()) return

        mainHandler.post {
            try {
                if (overlaySurface == null) {
                    init(activity)
                }

                val surface = overlaySurface ?: return@post

                if (enabled) {
                    isDrawingActive = true
                    lastExcludeRectsJson = excludeRectsJson
                    surface.visibility = View.VISIBLE
                    surface.bringToFront()

                    if (touchHelper != null) {
                        applyRawDrawingState(activity, surface, true, excludeRectsJson)
                    }
                } else {
                    isDrawingActive = false
                    lastExcludeRectsJson = null
                    applyRawDrawingState(activity, surface, false, null)
                    surface.visibility = View.GONE
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error setting drawing mode", e)
            }
        }
    }

    private fun applyRawDrawingState(activity: Activity, surface: SurfaceView, enabled: Boolean, excludeRectsJson: String?) {
        val helper = touchHelper ?: return
        if (enabled) {
            helper.setStrokeWidth(currentStrokeWidth)
            helper.setStrokeColor(currentStrokeColor)

            val displayMetrics = activity.resources.displayMetrics
            val screenW = if (surface.width > 0) surface.width else displayMetrics.widthPixels
            val screenH = if (surface.height > 0) surface.height else displayMetrics.heightPixels
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

            helper.setLimitRect(listOf(screenRect), excludeList)
            helper.openRawDrawing()
            helper.setRawDrawingEnabled(true)
            helper.setRawDrawingRenderEnabled(true)
            Log.i(TAG, "Raw drawing ENABLED on SurfaceView: screen ${screenW}x${screenH}, ${excludeList.size} exclusion zones")
        } else {
            helper.setRawDrawingRenderEnabled(false)
            helper.setRawDrawingEnabled(false)
            helper.closeRawDrawing()
            Log.i(TAG, "Raw drawing DISABLED on SurfaceView")
        }
    }

    fun setPenWidth(width: Float) {
        currentStrokeWidth = width
        touchHelper?.setStrokeWidth(width)
    }

    fun setPenColor(color: Int) {
        currentStrokeColor = color
        touchHelper?.setStrokeColor(color)
    }

    /**
     * Drains all pending completed strokes and returns a JSON array string.
     * Called by Lua layer.
     */
    fun pollStrokesJson(): String {
        if (pendingStrokes.isEmpty()) return ""

        val arr = JSONArray()
        while (true) {
            val stroke = pendingStrokes.poll() ?: break
            try {
                arr.put(JSONObject(stroke))
            } catch (e: Exception) {
                Log.e(TAG, "Error parsing queued stroke", e)
            }
        }
        return arr.toString()
    }

    fun clearPendingStrokes() {
        pendingStrokes.clear()
        synchronized(strokeLock) {
            activePoints.clear()
        }
    }

    fun onPause() {
        if (isDrawingActive) {
            touchHelper?.setRawDrawingEnabled(false)
        }
    }

    fun onResume() {
        if (isDrawingActive) {
            touchHelper?.setRawDrawingEnabled(true)
        }
    }

    fun onDestroy() {
        try {
            touchHelper?.closeRawDrawing()
            touchHelper = null
            overlaySurface = null
            clearPendingStrokes()
        } catch (e: Throwable) {
            Log.e(TAG, "Error in onDestroy", e)
        }
    }
}
