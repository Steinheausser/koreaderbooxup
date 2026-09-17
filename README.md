# KOReader for Onyx Boox (Hardware Low-Latency Stylus)

Custom KOReader distribution and modular plugin providing **hardware-accelerated, low-latency stylus annotations** on Onyx Boox E-ink devices (tested for **Max Lumi 2020**, **Boox OS 3.5+**, **Android 10+**).

---

## The Problem & Solution

### Why standard drawing lags on E-Ink
Drawing through standard Android touch events (`MotionEvent` / `Canvas`) routes through Android's `SurfaceFlinger` compositor and multiple E-ink waveform refreshes. This introduces a **150ms–300ms lag** behind the pen tip, making handwriting feel sluggish and unnatural.

### How this project achieves ~20ms Latency
This project integrates the official Onyx Boox Pen SDK (`TouchHelper` & `RawInputCallback`):
1. **Hardware EPD Bypass**: When stylus inking mode is active, Wacom pen strokes are drawn directly by the E-ink controller hardware buffer at ~20ms latency.
2. **Transparent Overlay**: An overlay `SurfaceView` captures raw inking without interfering with KOReader's underlying rendering loop.
3. **Seamless Vector Handoff**: When the pen lifts, the vector point stream is handed to KOReader's Lua plugin, which permanently stores it in the book's `.sdr/` sidecar and renders it directly over the page text.

---

## Decoupled Architecture (Future-Proof Updates)

One of the primary goals of this repository is to **never get locked into an outdated KOReader version**:

```
koreaderbooxup/
├── android-launcher/                  # Fork of android-luajit-launcher
│   └── app/src/main/java/org/koreader/launcher/
│       └── device/epd/OnyxPenBridge.kt # Standalone hardware bridge (non-invasive)
├── plugins/
│   └── boox_pen.koplugin/             # Standalone Lua plugin (runs in /sdcard/koreader/plugins/)
│       ├── _meta.lua
│       ├── main.lua                   # Inking coordinator & UI menus
│       ├── epub_storage.lua           # Page-level vector persistence in .sdr/
│       └── renderer.lua               # Fast Bresenham BlitBuffer vector rasterizer
└── scripts/
    ├── fetch_upstream_koreader.ps1    # Extracts precompiled assets & .so from official releases
    └── build_apk.ps1                  # Builds target APK in minutes without C toolchains
```

* **No C/C++ cross-compilation required**: You do not need to compile the massive KOReader C/C++ codebase (MuPDF, crengine, LuaJIT). The project reuses the official precompiled libraries from upstream releases.
* **Persistent User Storage**: The plugin stores ink data in `<book_path>.sdr/boox_stylus_annotations.lua`. KOReader updates will never touch or erase your annotations.
* **1-Command Upgrades**: Whenever KOReader releases a monthly update, you simply ingest the new official APK and rebuild the launcher in under 2 minutes.

---

## Features

- **Mandatory EPUB Support**: Reflowable EPUB ink annotations mapped to page view geometry using normalized $(x / \text{width}, y / \text{height})$ coordinate vectors.
- **Hardware Pen Acceleration**: True low-latency inking using Onyx `TouchHelper`.
- **Top & Bottom Bar Exclusion Zones**: Tapping the top menu or bottom status bar does not leave accidental ink marks.
- **In-Reader Controls**:
  - Inking Mode: Toggle On / Off
  - Pen Widths: Fine (1px), Medium (3px), Bold (5px), Heavy (8px)
  - Undo: Roll back the last drawn stroke
  - Clear Page: Clear all ink on current page
  - Visibility: Toggle ink visibility without deleting data

---

## Building the Custom APK

### Prerequisites
1. **JDK 17** installed and configured (`JAVA_HOME`).
2. **Android SDK** installed (`ANDROID_HOME` or `ANDROID_SDK_ROOT`).
3. PowerShell (on Windows).

### Step 1: Ingest Upstream KOReader Assets
Run the ingestion script to automatically download the latest official ARM64 KOReader release from GitHub and extract its precompiled `.so` libraries and Lua assets:

```powershell
.\scripts\fetch_upstream_koreader.ps1
```

*(Alternatively, you can provide a local APK: `.\scripts\fetch_upstream_koreader.ps1 -ApkPath "C:\path\to\koreader.apk"`).*

### Step 2: Build the APK
Compile the launcher with the Onyx Boox SDK:

```powershell
.\scripts\build_apk.ps1 -BuildType Debug
```

The resulting package will be output to:
```
output\KOReader-Boox-Stylus-Debug.apk
```

### Step 3: Install on Device
Connect your Max Lumi via USB with USB Debugging enabled:

```powershell
adb install -r output\KOReader-Boox-Stylus-Debug.apk
```

---

## How to Update to Future KOReader Releases

When a new KOReader version is released (e.g. `v2026.10`):
1. Run:
   ```powershell
   .\scripts\fetch_upstream_koreader.ps1
   ```
2. Run:
   ```powershell
   .\scripts\build_apk.ps1
   ```
3. Install the updated APK. Your existing books, settings, and handwritten `.sdr` annotations will remain completely intact.
