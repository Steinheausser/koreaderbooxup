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
        return Build.MANUFACTURER.equals("onyx", ignoreCase = true) ||
               Build.BRAND.equals("onyx", ignoreCase = true) ||
               Build.FINGERPRINT.contains("onyx", ignoreCase = true)
    }

    /**
     * Initializes the TouchHelper directly on the Activity window decorView.
     */
    fun init(activity: Activity) {
        if (!isSupported()) return

        mainHandler.post {
            try {
                if (touchHelper != null) return@post

                val hostView = activity.window.decorView
                val callback = object : RawInputCallback() {
                    override fun onBeginRawDrawing(b: Boolean, point: TouchPoint) {
                        Log.d(TAG, "onBeginRawDrawing at (${point.x}, ${point.y}, p=${point.pressure})")
                        synchronized(strokeLock) {
                            activePoints.clear()
                            addPoint(point)
                        }
                    }

                    override fun onEndRawDrawing(b: Boolean, point: TouchPoint) {
                        Log.d(TAG, "onEndRawDrawing at (${point.x}, ${point.y}), points: ${activePoints.size}")
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
                                Log.i(TAG, "Stroke queued: ${activePoints.size} points")
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

                // Create TouchHelper bound to the decorView with hardware SurfaceFlinger render enabled
                touchHelper = TouchHelper.create(hostView, true, callback).apply {
                    setStrokeWidth(currentStrokeWidth)
                    setStrokeColor(currentStrokeColor)
                    debugLog(true)
                }
                Log.i(TAG, "TouchHelper created and bound to decorView successfully")
            } catch (e: Throwable) {
                Log.e(TAG, "Error initializing TouchHelper", e)
            }
        }
    }

    private fun addPoint(point: TouchPoint) {
        try {
            val pt = JSONObject().apply {
                put("x", point.x.toDouble())
                put("y", point.y.toDouble())
                put("p", point.pressure.toDouble())
            }
            activePoints.add(pt)
        } catch (e: Exception) {
            Log.e(TAG, "Error adding point", e)
        }
    }

    /**
     * Toggles hardware inking mode on/off.
     * excludeRectsJson: JSON array of [{x, y, w, h}] representing menu/status bar regions to exclude
     */
    fun setDrawingMode(activity: Activity, enabled: Boolean, excludeRectsJson: String? = null) {
        if (!isSupported()) return

        mainHandler.post {
            try {
                if (touchHelper == null) {
                    init(activity)
                }

                val helper = touchHelper ?: return@post
                val hostView = activity.window.decorView

                if (enabled) {
                    helper.setStrokeWidth(currentStrokeWidth)
                    helper.setStrokeColor(currentStrokeColor)

                    val displayMetrics = activity.resources.displayMetrics
                    val screenW = if (hostView.width > 0) hostView.width else displayMetrics.widthPixels
                    val screenH = if (hostView.height > 0) hostView.height else displayMetrics.heightPixels
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
                    isDrawingActive = true
                    Log.i(TAG, "OnyxPenBridge: Drawing mode ENABLED on decorView (${screenW}x${screenH}, ${excludeList.size} exclusion zones)")
                } else {
                    helper.setRawDrawingRenderEnabled(false)
                    helper.setRawDrawingEnabled(false)
                    helper.closeRawDrawing()
                    isDrawingActive = false
                    Log.i(TAG, "OnyxPenBridge: Drawing mode DISABLED on decorView")
                }
            } catch (e: Throwable) {
                Log.e(TAG, "Error setting drawing mode", e)
            }
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
            clearPendingStrokes()
        } catch (e: Throwable) {
            Log.e(TAG, "Error in onDestroy", e)
        }
    }
}
