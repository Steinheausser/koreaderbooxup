# Boox Low-Latency Stylus — Dev Log

Date: 2026-09-17/18. Device: Onyx Boox Max Lumi (MaxLumi, Android 10, sdm660).
App: `org.koreader.launcher.debug` (build `output/KOReader-Boox-Stylus-Debug.apk`).

Goal: hardware-accelerated (~20ms) stylus ink via the Onyx Pen SDK
(`TouchHelper`/`RawInputCallback`, `SFTouchRender` + EPD pen layer), with a
vector handoff to the Lua plugin (`plugins/boox_pen.koplugin/`) that persists
strokes per page in `<book>.sdr/boox_stylus_annotations.lua` and re-renders
them over the text.

## Current state (working)

- App boots, book renders, taps/menus work.
- Pen strokes capture (raw points → JSON queue → Lua poll every 100ms).
- Strokes persist to sidecar (12+ pages of real user ink verified on disk).
- Vector ink paints over the page at the right position.
- Live hardware ink follows the pen tip while down.
- Ink appears on panel ~1s after lift; no page turns, no selection popups.
- Live width == vector width == the pen-width menu setting (fixes the
  "thinner after refresh" mismatch from the width-10 experiment).

## Bugs found and fixed

1. **Blank white screen on launch.** First-run setup dialog was waiting for a
   tap (not a freeze). Separately, `OnyxPenBridge.init()` eagerly added a
   fullscreen clickable `SurfaceView` over `NativeActivity`, which can cover
   content and eat touches. Fix: overlay is created lazily on first enable
   and kept `GONE` (plus transparent background) while idle.
   (`device/epd/OnyxPenBridge.kt`: `init`, `ensureOverlayView`,
   `applyDrawingMode` hide-on-disable, `onDestroy` view removal.)

2. **Pen strokes turned pages (swipe detected).** The Wacom pen also emits
   emulated finger multitouch events, which KOReader reads (evdev) as
   pan/swipe. View-level consuming can't stop this (`NativeActivity` gets a
   parallel native input queue). Fix: Lua `registerEventAdjustHook` voids
   pen *movement* beyond tap slop; taps still work.
   (`plugins/boox_pen.koplugin/main.lua`: `setupGestureSuppression`.)

3. **Pen lifts triggered text selection popups (hold) and taps.** Fix: Lua
   `registerGestureAdjustHook` renames content-area tap/hold/swipe/pan to
   `"none"` (no handler downstream, contact bookkeeping untouched).
   Menu strips (top/bottom 140px) always pass.

4. **Suppression froze menus/dialogs.** The gesture hook ate taps on open
   menus (they live outside the menu strips). Fix: suppression is gated on
   physical pen state — new `booxIsPenDown()` JNI (`OnyxPenBridge.isPenActive`,
   down-latch + 400ms grace for recognition latency) consulted by the hook.
   Finger input passes whenever the pen is up. (`LuaInterface`,
   `MainActivity`, `assets/android.lua` + `scripts/fetch_upstream_koreader.ps1`
   bridge template.)

5. **Inking silently died (surface destroy).** Rotation/screen-off destroys
   the overlay surface; old code closed the session while Lua still believed
   it was on — no ink, no errors. Fix: track `drawingRequested`; on
   `surfaceCreated`, re-establish if requested; drop the dead `TouchHelper`
   for a clean rebuild. Lua `setDrawingMode` gained a `force` flag and
   `onReaderReady` re-asserts. Verified recovery across a sleep/wake cycle
   from logs.

6. **Panel never updated during session (ink only after Home/back).**
   Proved via logs + SDM markers: while the EBC handwriting scheme is
   active, zero panel updates execute; everything queues and flushes on
   teardown. Fix: `enterScribbleMode` on pen-down, `leaveScribbleMode`
   immediately on pen-up — Lua's post-lift repaint then reaches the panel
   (~1s after lift). Pen-state machine left to the SDK.

7. **No live hardware ink.** Root causes, all in
   `OnyxPenBridge.applyDrawingMode` enable path:
   - `openRawDrawing()` internally resets the stroke style to PENCIL, so
     BRUSH must be (re-)applied AFTER open.
   - `TouchHelper` never sets the EPD render params → style/width/color set
     explicitly on `EpdController`.
   - SDK 1.3.x never enters scribble mode on open; Max Lumi firmware needs
     explicit `EpdController.enterScribbleMode(view)`.
   - **Load-bearing, mechanism not fully understood (2026-09-18):** a
     delayed (5s post-enable) `startStroke/addStrokePoint/finishStroke`
     call with explicit width is REQUIRED — without it (or with an
     equivalent synchronous rewrite!) live ink silently dies. Leading
     theory: it primes EPD pen width/state that full refreshes otherwise
     reset. Do NOT remove/rewrite `primeHardwarePen` without re-testing
     live ink on-device.
   - Pen-up firmware refresh left OFF (caused mosaic-type differential
     artifacts on lift).

8. **Teleport jumps in strokes (long straight lines across pages).**
   Finger/palm contacts merged into the raw stream. Fix:
   `TouchHelper.enableFingerTouch(false)` (pen-only). Capture verified
   unaffected via `onBegin/onEnd` logs.

9. **Mosaic/clone-stamp artifacts.** Ruled OUT the vector renderer
   (`BlitBuffer.paintRect` clips via `getBoundedRect` — no OOB possible).
   Artifacts came from the EPD update path churning (pen-up refresh +
   scheme flips); resolved by the settle above.

## SDK notes (reverse-engineered, onyxsdk-pen 1.3.6 + onyxsdk-device 1.2.8)

- `TouchHelper.create(view, boolean, cb)`: boolean = "device has stylus"
  (2-arg version auto-detects via `DeviceFeatureUtil.hasStylus`). `true` =
  `SFTouchRender` (hardware EPD path via `EpdPenManager`), `false` =
  `AppTouchRender` (MotionEvent path).
- `openRawDrawing()` = style reset to PENCIL + start native reader +
  `EpdPenManager.startDrawing()`; render/input enables are separate flags
  that no-op unless opened.
- All `EpdController.*` calls delegate to `Device.currentDevice()`
  (Max Lumi → `SDMDevice` via `ro.board.platform=sdm660`) and then to hidden
  firmware `View` methods via reflection that silently no-ops when missing.
  Probed on-device: `moveTo/quadTo/startStroke/finishStroke/...` present;
  `View.setStrokeWidth` and `enter/leaveScribbleMode` **absent**.
- `MainActivity.dispatchTouchEvent` consuming does NOT stop KOReader input
  (parallel native evdev queue) — gesture work must happen in Lua hooks.

## NeoReader control experiment (2026-09-18)

Same test sentence written in Onyx NeoReader on the same file also drops
letters mid-word ("good m..g"). Verdict: pen data dropouts happen at
digitizer/firmware level; the first-party app suffers identically. Not
fixable in our config — mitigate (split, no connectors) rather than chase.
Related: `TouchPoint` carries no contact/tool ID (only x/y/pressure/size/
timestamp), so pen vs palm cannot be separated in callbacks; pressure
clustering (teleport targets at ~0 pressure) is the only forensic trace.

## Teleport-split repair (2026-09-18)

- New strokes: `pollStrokes` splits on normalized gaps > 0.05 (~80px).
- Old saves: `EpubStorage:load` runs the same split as a migration
  (`EpubStorage.splitSegments`, shared; idempotent), repointing both the
  numeric and string page keys at the new lists.
- Side effect (intentional): Undo is now per-segment (finer granularity).

## Next steps (toward "good")

1. **Live ink confirmed working 2026-09-18** with delayed priming +
   width-10 restore. Next: calibrate the hardware width mapping (10 live
   vs 3 vector mismatch = "thinner after refresh") and drive hardware
   width from the pen setting. Do NOT touch `primeHardwarePen`
   timing/content until then.
2. **Data safety confirmed 2026-09-18**: a "previous lines are gone" scare
   turned out to be panel staleness — sidecar grew 684KB → 1.35MB, page 110
   went 16 → 21 strokes, all coordinates sane. Nothing is ever deleted
   except via explicit Undo/Clear Page.
3. **Eraser support**: eraser callbacks are stubbed; wire BTN/tool-eraser to
   an erase mode (EpdPenManager `PEN_ERASING` + vector stroke deletion).
3. **Pressure curve**: `addPoint` maps Wacom 0..4096 → 0.3..1.8 width
   multiplier; tune feel per pen-width setting.
4. **Code health**: `OnyxPenBridge.kt` accumulated many incremental tweaks
   (pen-state 0/1/2/3 calls in pause/resume/disable) — reconcile into one
   coherent session model; re-check `onPause` (leaves scribble mode) vs
   quick screen-off/on scribble gaps.
5. **Pen-width sync**: confirm Java `currentStrokeWidth` always matches the
   Lua setting across enable/disable/menu changes (Lua currently re-sends
   after enable).
6. **Upstream rebase**: `scripts/fetch_upstream_koreader.ps1` injects the
   Lua bridge (now incl. `booxIsPenDown`) and bundles the plugin; re-run +
   rebuild on each monthly KOReader release; keep `plugins/` as source of
   truth (it is copied over `android-launcher/assets/plugins/`).
7. **UX**: in-reader ink color choice (currently black only), per-page
   undo already exists — expose redo; consider stroke smoothing for the
   vector render (teleports are suppressed at capture, residual jitter
   remains).

## Thickness / toggle / performance pass (2026-10-02, untested on device)

Root causes found by code reading (KOReader v2026.07.1 sources + onyxsdk jars):

- **Plugin loaded twice.** `Assets.extractBundledPlugins` copied the plugin
  to `filesDir/plugins` AND `/sdcard/koreader/plugins`; `PluginLoader` scans
  both and does not dedupe by name. Two instances = double sidecar parse on
  open, two paint/poll/gesture hooks, menu controlling only one of them, and
  last-writer-wins saves (strokes polled by the other instance could be lost).
  Fix: copy to filesDir only (skipped unless APK `lastUpdateTime` changed),
  delete the sdcard copy, plus a Lua guard (`is_duplicate`). Verify: logcat
  shows `hooked into ReaderView:paintTo` once per open.
- **Show Annotations did nothing:** `setDirty(self.ui.view)` — UIManager only
  honours dirty flags on top-level widgets. Now `setDirty(self.ui, ...)`.
  Hiding annotations also pauses inking.
- **Thinner after lift:** live width hard-coded 5, vector = 3 x (raw/2048,
  floored) = 1-2px. Now one width (hardware units, presets 3/5/7/10) drives
  both; pressure normalized with `EpdController.getMaxTouchPressure()`;
  vector width = W x weight x (0.75 + 0.6p), "Ink After Lift" menu
  (1.0/1.2/1.5, default 1.2). Renderer draws spans + round caps.
- **Pen color was ARGB transparent:** Lua gray 0 went straight to
  `EpdController.setStrokeColor(0)`. `primeHardwarePen` sets `Color.BLACK` —
  strong suspect for why the prime is "load-bearing". `setPenColor` now
  converts gray to opaque ARGB; the prime is kept verbatim but re-applies the
  user's width/color afterwards. TODO A/B on device: disable the prime.
- **Stale screen until touch at startup:** enable path (and `onResume`)
  called `enterScribbleMode`, which freezes panel updates (see #6). Removed;
  pen-down still enters, pen-up leaves. Auto-enable now starts 1s after the
  reader's first paint, and silent mode switches no longer force a refresh.
- **Per-stroke cost:** every segment re-encoded the whole sidecar as JSON on
  the UI thread. Storage v2: Lua literal with flat `{x,y,p,...}` arrays
  (`loadstring`, atomic tmp+rename), saves debounced 3s and flushed on
  close/FlushSettings/Suspend. v1 files are migrated once (width +2,
  pressure /2, teleport split) after backing up to
  `boox_stylus_annotations.v1.json.bak`. Native strokes are built directly as
  Lua literals (no JSONObject per point), `debugLog(false)`, refresh limited
  to the new strokes' bounding box.
- Input adjust hooks chain forever; they are now installed once per process
  and dispatch to the active reader instance.
