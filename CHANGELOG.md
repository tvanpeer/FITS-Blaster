# Changelog

All notable changes to Simple Claude FITS Viewer are recorded here.

---

## 2026-03-06 — Dock-icon drag & drop + documentation
*Commit `18b05c2`*

### Added
- **Dock-icon drag & drop**: dropping FITS files or folders onto the app icon now opens them, whether the app is already running or being cold-launched by the drop. URLs received before the main view is ready are buffered and delivered as soon as the window appears.
- **`Info.plist`**: custom Info.plist added to the project, declaring `.fits`, `.fit`, and `.fts` as supported document types so Finder recognises the app and allows dock-icon drops even when the app is closed.
- **`Score.md`**: full technical explanation of how quality metrics and the composite 0–100 score are calculated — background estimation, star detection (GPU and CPU paths), FWHM via 1D Moffat β=4 fit, eccentricity via 2D intensity-weighted moments, SNR via aperture photometry, weighted score formula, and badge colour logic.

---

## 2026-03-06 — Performance overhaul + UI fixes
*Commit `e4b02d0`*

### Fixed
- **Beachball / UI sluggishness during metric computation**: the star-measurement stage previously created up to 200 async tasks per image. With 4–8 images loading concurrently this produced 800–1 600 micro-tasks simultaneously, flooding the cooperative thread pool and starving the main thread. Replaced with a sequential loop — per-star work (~10 µs) is far smaller than task-creation overhead.
- **Simple → Geek mode recompute was extremely slow**: `recomputeMetrics` was using the CPU path (`FITSReader.read` + CPU star detection). Switched to the GPU path (`readIntoBuffer` + Metal kernel), matching the speed of the initial Geek-mode load.
- **`groupStatistics` causing mass re-renders**: converting from a computed property (read all entries' metrics on every call, registering every visible thumbnail cell as a dependency on all entries) to a stored property updated only at batch boundaries. Eliminated O(n²) render churn during metric updates.
- **Elapsed time missing after Simple/Geek switch**: a guard that hid the elapsed-time display in Simple mode was incorrectly also hiding it in Geek mode. Removed.
- **Session chart covering the main image**: capped chart height and gave the main image layout priority.

### Changed
- **Background task priority**: batch loading and metric recomputation tasks now run at `.utility` priority, leaving more CPU headroom for UI responsiveness.
- **Concurrent image loading**: reduced from 4–8 simultaneous tasks to 3, avoiding disk thrashing on large FITS files.

### Added
- **No wrap-around at list boundaries**: pressing next on the last image (or previous on the first) now beeps and stays, instead of wrapping to the other end.
- **Single-key reject/undo toggle**: a new option in Settings makes the reject key act as a toggle — pressing it on a rejected frame undoes the rejection, and on a non-rejected frame rejects it. The separate undo key is hidden when this mode is active.
- **Space bar as a key binding**: the space bar can now be assigned to any action in the keyboard settings. It is recorded, stored, displayed as "Space", and matched correctly by the key-press handler.

---

## 2026-03-06 — Simple/Geek mode, filter groups, quality badges, auto-reject, drag & drop
*Commit `89bf054`*

### Added
- **Simple / Geek mode switch**: icon-only toolbar button (`⌘⇧M`, also in the View menu). Simple mode shows a stripped-down UI — flat thumbnail list, no metrics computation, no badges, no ratings, no chart, no inspector, reject/undo only. Switching back to Geek mode restores cached metrics instantly without re-reading files. Mode is remembered between launches.
- **Filter-group sidebar**: thumbnails are grouped by filter (Ha, OIII, SII, Hβ, broadband, etc.) with a filter strip for quick narrowing. `FilterGroup` enum normalises raw FILTER header values to canonical groups.
- **Quality badges**: two-tier system — colour encodes the worst detected problem (red = trailing/focus failure, amber = low stars, green = top third of group, grey = neutral). A small SF Symbol icon overlays the badge to identify the problem type. Thresholds are group-relative so narrowband frames are not unfairly penalised.
- **Auto-reject sheet**: one-click culling with relative (× group median) or absolute thresholds for FWHM, eccentricity, star count, and score. Live preview count before committing. Per-metric enable toggles.
- **Window drag & drop**: FITS files and folders can be dragged onto the app window. A blue highlight overlay appears during the drag.
- **Session chart**: scrollable dot chart showing the selected metric across all frames in the session, with tap-to-select and drag-to-batch-reject.
- **Parallelised star measurement**: `withTaskGroup` across star candidates for maximum CPU utilisation during metrics computation (later superseded by the sequential fix above for better overall throughput).
- **`GroupStats`**: per-filter-group medians for FWHM, star count, and top-third score floor, used by badges and auto-reject.
- **`BadgeProblem` enum**: trailing, focus failure, low stars — drives badge colour and icon independently of the numeric score.

---

## 2026-03-04 — Initial Commit
*Commit `8729ff1`*

### Added
- Full FITS file viewer for macOS 15.7+, written in Swift 6.2 / SwiftUI.
- **`FITSReader`**: parses FITS headers (80-character cards, 2 880-byte blocks) and pixel data. Supports BITPIX 8, 16, 32, −32, −64. Two read paths: `readIntoBuffer` (Metal shared buffer, zero-copy GPU path) and `read` (CPU `[Float]` array).
- **`ImageStretcher`**: GPU path via a Metal compute shader (`FITSStretch.metal`) with percentile clipping (0.1 %/99.9 %) and power-law gamma stretch. CPU fallback using Accelerate (`vImage`) with vectorised LUT interpolation, byte-swap, vertical flip, and optional downscaling. Images downscaled to 1 024 px max for display; thumbnails capped at 120 px.
- **`MetricsCalculator`**: GPU star detection (full-frame Metal kernel), CPU fallback (4 096² crop with vectorised row-max pre-filter). Per-star FWHM (1D Moffat β=4), eccentricity (2D intensity-weighted moments), SNR (aperture photometry). Composite quality score 0–100.
- **`ImageStore`**: triple-buffered concurrent pipeline (FITS I/O → GPU stretch → CGImage), semaphore-capped concurrency. Security-scoped bookmarks for sandbox file access. Rejection moves files to a `REJECTED/` subdirectory; undo restores them. Star ratings 1–5, persisted to a `.culling.json` sidecar file per folder.
- **`ContentView`**: `HSplitView` sidebar + main viewer. Keyboard navigation (↑/↓, Home/End), configurable key bindings, `Cmd+O` / `Cmd+Shift+O` to open folder or files.
- **`InspectorView`**: per-frame metrics, histogram, FITS header table.
- **`SettingsView`**: configurable key bindings (recorded via `KeyRecorderView`), image size limits, per-metric toggles, appearance mode.
- **`ExportPanel`**: export kept frames as a plain-text file list or CSV with metrics, filtered by minimum star rating.
- **`SessionChartView`** (initial version): metric strip chart.
- App icon (M33 galaxy).
