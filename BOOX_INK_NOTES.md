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

## What Onyx Notes actually does (2026-10-26, reverse-engineered, untested here)

Decompiled knote2/kreader2, framework.jar and libsurfaceflinger.so from the
Max Lumi (fw 2023-12-12). Live ink is drawn by SurfaceFlinger itself: it opens
the Wacom evdev node, runs the neopen brush engine and writes to `/dev/ebc`.
Apps only drive it with Binder codes (`android.onyx.ViewUpdateHelper`), e.g.
pen state `SET_SCREEN_HANDWRITING_PEN_STATE` 0 stop / 1 start / 2 drawing /
3 pause / 4 erasing. Full write-up: `boox-pen-fastpath.md`.

- **Pen-state regression (fixed):** `openRawDrawing()` sends state 1 and
  `setRawDrawingEnabled(true)` sends 2; the bridge then sent 1 again, knocking
  SF back to START. Now sends 2. Prime suspect for why `primeHardwarePen` was
  "load-bearing".
- **How Notes shows ink after lift:** it never toggles `enablePost`
  (enter/leaveScribbleMode) per stroke. It redraws the dirty rect with update
  mode `HAND_WRITING_REPAINT_MODE` (524290), which the panel commits while the
  handwriting scheme stays active. `View.handwritingRepaint(view,l,t,r,b)`
  exists on this firmware and is the same path.
### Results (2026-10-26/27, on-device)

- State 2 fix: live ink is instant without the prime; `primeHardwarePen`
  is removed.
- Wedge notches in the settled ink fixed by the capsule renderer
  (`drawCapsule`).
- Stroke eraser: rubber end or side button (`enableSideBtnErase(true)`)
  queues the path as `{e=1,p=...}`; `BooxPen:eraseAlong` deletes visible
  strokes within 12px (+ half width) and returns their bounds, so only that
  area is refreshed (it used to repaint the whole screen).

## Refresh path while inking: notes mode is the default (2026-10-27)

Ground truth comes from the display HAL, not KOReader: `logcat | grep SDM`
shows every real panel update (`update_to_display ... waveform_mode,
update_mode, Rect, flags`), and `SWEpdcManager` logs scheme switches.

- **Why everything flashed:** `OnyxEPDController` reports "full-only", so
  KOReader's Android framebuffer (`ffi/framebuffer_android.lua`) sends only
  *full* refreshes to `einkUpdate`; ui/partial/fast refreshes (stroke
  repaints, menus, page turns) are left to the firmware. In the old per-stroke
  model, pen-down entered scribble mode (`setEbcUpdateScheme 3`) and pen-up
  left it (scheme 2), after which the firmware showed KOReader's next frame
  as a **full-screen GC16** update (`waveform_mode = 2, update_mode = 1`):
  one full flash per stroke, queueing up when writing fast. While the
  handwriting scheme is active the firmware drops those refreshes entirely,
  which is why the first notes-mode attempt "froze" the screen (KOReader kept
  running; nothing reached the panel).
- **Refresh hook (`installRefreshHook`, main.lua):** while inking, every
  `refresh*Imp` region is also sent to `android.einkUpdate` with the
  reserved mode `PEN_REPAINT_MODE` (0x40000000), which `MainActivity`
  routes to `OnyxPenBridge.routeRefresh` only.
- **Notes mode (default, `debug.koreader.boox.notes_mode 0` to disable):**
  no enter/leave scribble per stroke; `routeRefresh` sends regions through
  `EpdController.handwritingRepaint`, which the panel commits during the
  handwriting scheme (`waveform_mode = 2, update_mode = 0`, flag 0x80000,
  region only). It is the only path that works: `View.refreshScreen` with
  the handwrite flag (REGAL 0x80006) is dropped, so page turns while inking
  are full-page GC16 (slow, one flash). Leaving the scheme instead triggers
  the firmware's own full GC16 clean-up, so there is nothing faster to fall
  back to.
- **Pen-up refresh (`PEN_UP_REFRESH_DELAY` 0.5s, like Notes' default):** new
  and erased ink is stored at once but pushed to the panel only once the pen
  has rested, as one update over the union of the burst. Live hardware ink
  covers the gap. A panel update per stroke stacked GC16 updates and
  repainted the area next to the letter being written.
- **Settled ink weight** now defaults to "Same as live ink" (1.0; was 1.2),
  with a new "Thinner" (0.8) option. The vector render was correct; 1.2x
  plus the pressure multiplier simply read as much bolder than live ink.
- **USB:** this unit's cable/port corrupts adb pushes (1–2 flipped bytes per
  36MB APK, pulls are clean), so `adb install` fails v2 signature checks.
  Push in hash-verified chunks, `cat` them together on the device, then
  `pm install -r` the local file.
- Builds: `scripts\build_apk.ps1` breaks on the `&` in the folder path and on
  JDK 27; build through an `&`-free junction with JDK 21 instead.

## Doubled strokes + text-anchored ink (2026-10-03, on-device)

- **Start-to-end connector lines:** the SDK sends each stroke twice — per-move
  callbacks AND one end-of-stroke `TouchPointList` (before `onEnd`). Both
  were appended, so every stroke held its points twice and rendered a line
  from its end back to its start (long ones were hidden by the teleport
  splitter). Verified on-device: second half == first half exactly. Fix: a
  list starting at the stroke's first point replaces the gathered moves.
  Storage v3 repair undoubles saved strokes and drops identical neighbours.
- **Text-anchored ink (storage v4, reflowable docs only):** strokes store
  the xpointer of the nearest word (`a`), the font size at capture (`fs`)
  and px offsets from that word's screen position; render places them at
  the word's current position scaled by the font-size ratio (`anchor.lua`).
  Strokes written within 4s/120px of the previous one share its anchor
  (group height capped at 260px) so handwriting moves as one piece.
  Visibility: anchor page (`getPageFromXPointer`, cached per
  `getDocumentRenderingHash`) within the visible page numbers (dual-page
  view shows 2); scroll mode uses doc-y range. Legacy page-keyed strokes
  are converted the first time their page is shown (assumes the layout on
  screen is the one they were written in). PDFs keep screen-relative coords.
- Verified: 42 legacy strokes on a dual-page portrait spread converted in
  ~45ms; screenshot diff vs. before conversion ~340 px (rounding only).

## Ink performance: cached layer, direct pen-up, journal (2026-10-29, on-device)

Modelled on Onyx Notes/NeoReader (one transparent ink bitmap per page, only
the new stroke drawn at pen-up, incremental saves). Measured with the
in-plugin benchmark (`setprop debug.koreader.boox.perf 1` and
`debug.koreader.boox.bench 40`, test docs under `/sdcard/koreader/inktest/`
only), synthetic page = 800 strokes x 25 points; real books have far less
(largest real sidecar: 106 strokes, ~43 points each).

- **Cached ink layer (`ink_layer.lua`):** one BB8 coverage mask per ink
  colour, composited with `colorblitFrom` (C, the glyph path). LRU of 3
  views keyed by page + screen size + ink weight (+ layout hash / scroll
  position when anchored). Masks are filled with direct `ffi.fill` spans
  (`Renderer.maskFiller`), no `paintRect` per row. Repaint with ink: 45-90ms
  of Lua redraw -> ~20ms composite (constant in ink amount); first view of a
  page builds the layer once (~90ms for 800 strokes).
- **Direct pen-up:** new ink is drawn into the layer at ingest; the pen-up
  refresh composites just the new strokes' box onto `Screen.bb` and does a
  refresh-only `setDirty(nil, "ui", region)`. No ReaderUI repaint, so no
  crengine re-render. Per burst: 40-130ms -> 0.2-0.5ms. Falls back to the
  full repaint after an erase or when any window is above the reader.
- **Local erase/undo:** clear the removed strokes' box in the layer and
  redraw only the strokes overlapping it (`repairInk`, 1.5-2.5ms); per-stroke
  bounding boxes (`Renderer.strokeBox`, memoized as `_b`) also prefilter the
  eraser hit test.
- **Anchors:** positions cached per xpointer per layout, filled lazily; a new
  stroke no longer re-resolves every anchored stroke in the book (that cost
  turned out to be small: 2ms for 400 anchors).
- **Storage v5 + journal:** strokes get ids; each change appends one line to
  `boox_stylus_annotations.journal` (`S`/`A` add, `R{ids}` remove, `C` clear;
  <1ms), and the snapshot is rewritten only on close or when a journal is
  found on load. Replay is idempotent (verified on-device by replaying over a
  snapshot that already held the ops). Old cost: a full-book rewrite every
  3s while writing (30-50ms on the test books). Snapshot pages are now split
  into 400-stroke functions (LuaJIT constant limits). Offline tests: 24 pass.
- `setprop debug.koreader.boox.ink_cache 0` restores the uncached renderer
  for A/B (read at plugin load: restart KOReader).
- Still open: the firmware turns every `handwritingRepaint` into a
  full-panel GC16 partial update (`SDM ... Rect[0 0 2200 1650]`), whatever
  region is requested.
## Faster eraser (2026-10-30, untested on device)

Erasing used to wait for: pen lift (the path was queued only at
`onEndRawErasing`) -> next 100ms poll -> the 0.5s pen-up refresh delay, re-armed
while `isPenActive` (400ms grace) -> a full ReaderUI repaint (crengine
re-render), because removed ink needs the page underneath. Now:

- **Streamed eraser path:** while erasing, `pollStrokesJson` queues the points
  gathered so far as an `{e=1,...}` chunk, so strokes are deleted mid-gesture.
  The SDK's repeated full point list is ignored once per-move points arrived
  (erasing the same path twice is a no-op anyway).
- **Immediate refresh:** an erase batch flushes the pending refresh at once
  (there is no live hardware ink for the eraser to cover a delay).
- **Direct erase repaint:** while a pen session is active, `onPaintPage`
  copies the page (before ink) into `page_snapshot` (screen-sized buffer of
  `Screen.bb`'s type, ~10MB RGB32 on the Max Lumi). `paintInkDirect(region,
  erased)` restores the erased box from it, composites the remaining ink, and
  refreshes only that box. Falls back to the full repaint when the snapshot is
  missing/invalid (e.g. first erase right after opening a book, since the
  session starts after the first paint) or a window is above the reader.
