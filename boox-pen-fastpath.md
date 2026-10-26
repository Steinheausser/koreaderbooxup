# How Boox Notes / NeoReader get low-latency Wacom ink (Max Lumi, Android 10, fw 3.5 2023-12-12)

Source: pulled from the device over ADB (read-only) and decompiled with jadx:
`knote2-release.apk` (Notes), `kreader2-release.apk` (NeoReader), `framework.jar`,
`libonyx_pen_touch_reader.so`, `libneo_pen.so`, `libsurfaceflinger.so`.
Both apps use the same bundled Onyx pen SDK (`com.onyx.android.sdk.pen.*`). NeoReader enters it
through `readerview/note/eventhandler/PenEventHandler`.

## TL;DR: the app does not draw the live ink at all

```
Wacom /dev/input/event1 ──► SurfaceFlinger (Onyx-patched)
                              ├─ neopen brush engine (pressure, tilt, pen styles)
                              └─ writes strokes straight to the EPD controller (/dev/ebc) in a
                                 handwriting waveform  ← this is the ink you see under the nib
                       └────► the app's own native thread (libonyx_pen_touch_reader.so) reads the
                              same evdev node and collects TouchPoints for the document
pen lifted + ~500 ms idle ─► the app renders the stroke into its own bitmap and does a partial
                              refresh of the dirty rectangle, which replaces SF's temporary ink
```

So the latency comes from skipping all of these: Android InputDispatcher, the app's UI thread,
the GPU/HWUI, BufferQueue and vsync composition, and the normal EPD update queue.
Observed: the `libsurfaceflinger.so` strings include `"Wacom I2C Digitizer"`, `/dev/input/event%d`,
`/dev/ebc`, `HandwritingSchema`, `### startHandwriting`, `neopen_onPenDown/Move/Up` and
`HandlePenTrigger, sid: %d value is: %d pid %d`.

## 1. Control channel: raw Binder transactions to SurfaceFlinger

`android.onyx.ViewUpdateHelper` (in framework.jar) wraps everything. Each call is
`ServiceManager.getService("SurfaceFlinger").transact(code, parcel, reply, 0)`, and each parcel
starts with `writeInterfaceToken("android.ui.ISurfaceComposer")`.

| Call | Code | Parcel payload after the token |
|---|---|---|
| SET_SCREEN_HANDWRITING_PEN_STATE | 16711693 (0xFF000D) | int state, int myPid |
| ENABLE_POST | 16711692 (0xFF000C) | int -1, int enable, int myPid |
| SET_SCREEN_HANDWRITING_REGION_LIMIT | 16711694 | int hasView, int[] {l,t,r,b,...} (**screen px**) |
| SET_SCREEN_HANDWRITING_REGION_EXCLUDE | 16711714 | int hasView, int[] rects |
| SET_SCREEN_HANDWRITING_REGION_MODE | 1048620 | int mode (0 = multi, 1 = single) |
| SET_STROKE_WIDTH | 16711687 | float width |
| SET_STROKE_COLOR | 16711686 | int argb |
| SET_STROKE_STYLE | 16711688 | int style (neopen pen type) |
| SET_STROKE_PARAMETERS | 1049089 | int style, int n, float[n] |
| SET_BRUSH_RAW_DRAWING_ENABLED | 1048834 | int bool |
| SET_ERASER_RAW_DRAWING_ENABLED | 1048833 | int bool |
| SET_ENABLE_PEN_SIDE_BUTTON | 1048832 | int bool |
| HANDWRITING_REPAINT | 1048647 | int bool, int[4] rect (screen px) |
| MAP_FROM_RAW_TOUCH_POINT | 16711725 | float x, y → reply 4 floats |
| GET_EPD_TO_VIEW_MATRIX | 1049344 | → reply int n, float[n] |
| GET_MAX_TOUCH_PRESSURE | 1048618 | → reply float |
| SET_EPD_TURBO | 1048661 | int |

Pen states (`EpdPenManager`): `0 STOP`, `1 START`, `2 DRAWING` (resume), `3 PAUSE`, `4 ERASING`.

### Lifecycle used by `SFTouchRender` (the SurfaceFlinger path on SDM devices)

```
openRawDrawing():   setStrokeStyle(0); RawInputReader.start(); penState(1)
setRawDrawingEnabled(true): penState(2); reader.resume()
   + setLimitRect(view rect, exclude rects)   -> REGION_LIMIT / REGION_EXCLUDE
   + setStrokeWidth / Color / Style
pause (menus, dialogs, zoom): enablePost(1) [leaveScribbleMode]; penState(3); reader.pause()
closeRawDrawing():  setStrokeStyle(0); enablePost(1); penState(3); reader.quit(); penState(0)
```
`enterScribbleMode` = `enablePost(0)` and `leaveScribbleMode` = `enablePost(1)`. My reading of this
(an **inference**, not verified at runtime) is that while posting is disabled, SF stops pushing the
app's own frames to the panel, so a UI redraw can't wipe the live ink.
`AppTouchRender` (the fallback when SF doesn't render) does `enablePost(0)` + `penState(1)` on start
and `enablePost(1)` + `penState(0)` on stop.

Always restore the state with `penState(0)` and `enablePost(1)` in onPause/onDestroy and on crash.
SF tracks the pid (there is an `APP_DIE` code), but don't rely on it.

## 2. Input: read evdev directly, not through Android

`RawInputReader` → `libonyx_pen_touch_reader.so`:
- scans `/dev/input/event%d` for the digitizer (here `/dev/input/event1`, "onyx_emp_Wacom I2C
  Digitizer", **mode crw-rw-rw-**, so any app can read it on this firmware)
- a native `poll()` thread with an eventfd to wake it, and a C++ `PenManager` state machine
  (`DrawReader`, `EraseReader` for BTN_TOOL_RUBBER, `SideEraseReader` for BTN_STYLUS,
  limit/exclude region hit-testing done natively)
- it calls back into Java `onTouchPointReceived(x, y, pressure, size, tilt…, erasing, …, action, ts)`
  with actions 0 = down, 1 = move, 2/3 = up, 5 = hover (pen active), 6 = forced release
- Java side: it maps raw points to the screen with `getRawTouchPointToScreenMatrix()` (from
  `GET_EPD_TO_VIEW_MATRIX`), subtracts `view.getLocationOnScreen()`, and drops "repeat" moves where
  speed < 0.005 px/ms and Δpressure ≤ 2, using a `TouchPointList(600)` buffer per stroke
- if the down event is lost, it promotes the first move to a down

Digitizer ranges on this unit: X 0–27060, Y 0–20295, pressure 0–4095, tilt ±63, distance 0–255.
The axes don't match the framebuffer, so use SF's matrix instead of hand-scaling.

## 3. Committing the stroke

- `onRawDrawingTouchPointListReceived(list)` arrives at pen-up. The app builds the shape with the
  same `libneo_pen.so` engine (`NeoPen.nativeOnPenDown/Move/Up`, pen types brush 1, fountain 2,
  marker 3, charcoal 4/5), so committed ink matches SF's live ink pixel-for-pixel.
- Pen-up refresh: 500 ms by default (range 400–2000, set in Settings). The dirty rect is the union
  of the stroke bounds expanded by the stroke width. It then calls `onPenUpRefresh(rect)` →
  `PartialRefreshRequest`, a normal partial EPD update of the app's bitmap over that rect.
  `HANDWRITING_REPAINT` is the SF-side variant.
- Debounces: the pen counts as "inactive" 100 ms after the last hover. Pen resume delays after UI
  are 150 ms (common), 500 ms (menu), 600 ms (page), and 800 ms (zoom).

## 4. Porting to KOReader (android-luajit-launcher)

KOReader on Android draws into a NativeActivity window, so it can't use Onyx's `View`-based SDK
directly. All the parts it needs are reachable, though:

1. **Java/JNI side of the launcher**: add a small `OnyxPen` helper that either reflects
   `android.onyx.ViewUpdateHelper` (static methods; pass `view = null`, so coordinates are absolute
   screen px) or does the raw `transact()` calls from the table above. Expose it to Lua through the
   existing JNI bridge: `start(rect, width, style)`, `pause()`, `resume()`, `stop()`, `repaint(rect)`.
2. **Input**: open `/dev/input/event1` from Lua with `ffi` (KOReader already has evdev code from its
   Kobo/Kindle ports in `ffi/input`). Run it on its own thread or poll it from the main loop. Keep the
   raw points and map them with the float[] from `GET_EPD_TO_VIEW_MATRIX`. Turn on Android's own
   stylus MotionEvents *off* inside the drawing rect, or ignore them there, to avoid double handling.
3. **Region**: set REGION_LIMIT to the page/canvas rect and REGION_EXCLUDE to the toolbars. SF then
   won't ink over KOReader's UI, which is what "single/multi region mode" is for.
4. **On stroke end**: draw the stroke into KOReader's blitbuffer (or dlopen `libneo_pen.so` for
   identical brushes, though its C ABI is only in SF/JNI, so treat that as optional). After about
   500 ms idle, do a partial refresh of the dirty rect (or call HANDWRITING_REPAINT).
5. **Leave scribble mode** (`enablePost(1)`, `penState(3)`) before KOReader shows menus, dialogs or
   page turns, then resume afterwards. Always send `penState(0)` + `enablePost(1)` on exit.

This needs a separate check on each device and firmware: the transaction codes and the evdev
permissions are Onyx firmware details (taken from this 2023-12 Android 10 build). Probe
`IS_PEN_STATE_VALID` (1048641) and fall back to plain KOReader drawing if it fails.

## Unknowns / not verified
- Nothing was exercised at runtime (to avoid disturbing the session in Notes). Everything above
  is static analysis of the shipped code.
- Exact `enablePost` semantics and the stroke-style IDs SF accepts for `SET_STROKE_STYLE` beyond 0.
- Whether SF enforces any permission or package check on these codes for non-system apps. Onyx's
  public `onyxsdk-pen` uses the same calls from third-party apps, which suggests it doesn't.
