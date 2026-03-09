# Changelog

All notable changes to Simple Claude FITS Viewer are recorded here.

---

## 2026-03-09 — Fix keyboard shortcuts not working after sidebar click (v1.11.3)

### Fixed
- Navigation and action keys (arrow keys, reject, etc.) now work regardless of which subview has keyboard focus. Previously, clicking a thumbnail in the sidebar moved focus to the List, causing all key bindings to produce the macOS error chime. Replaced `onKeyPress` (requires the host view to be first responder) with an `NSEvent` local monitor that intercepts key events before the responder chain.

---

## 2026-03-09 — Colour toggle UX improvements (v1.11.2)

### Fixed
- **Instant grey on first toggle back**: when starting in colour mode, the initial greyscale render (always computed first during load) is now cached in `cachedGreyscaleDisplay`. Toggling back to grey after the initial grey→colour startup cycle is instant with no file re-reads.
- **Immediate status message**: "Rendering colour…" now appears instantly when pressing 'c', before the clip computation phase begins, instead of only after ~10 seconds of silent work on large batches.

---

## 2026-03-09 — View menu fixes + colour toggle cache

### Added
- **Colour/greyscale render cache**: toggling colour mode now caches both the greyscale and colour renders per Bayer image. After the first toggle, subsequent switches are instant (no file re-reads). Initial greyscale load is pre-cached so the very first toggle to colour only needs one pass. Memory overhead is ~3 MB per image (downscaled display size).

### Fixed
- **Duplicate View menu**: Simple Mode and Colour Images commands are now injected into the system View menu via `CommandGroup(after: .sidebar)` instead of creating a second View menu with `CommandMenu`.
- **Greyed-out View menu items**: switched from `focusedValue`/`@FocusedValue` to `focusedSceneValue` (set side) so bindings propagate to menu commands regardless of which subview holds keyboard focus.
- **View menu keyboard shortcuts**: Simple Mode and Colour Images now display the user-configured key binding in the menu (read from `AppSettings` via focused scene values) instead of the hardcoded `⌘⇧M`.
- **Toolbar tooltip**: Simple/Geek mode toggle button now shows the actual configured key in its tooltip instead of the hardcoded `⌘⇧M`.

### Changed
- "Rendering colour…" / "Rendering greyscale…" status is suppressed entirely on subsequent toggles when cached renders are available.

---

## 2026-03-08 — Bayer debayering + chart improvements (v1.11)

### Added
- **GPU Bayer debayering**: colour FITS images (BAYERPAT/COLORTYP/CFA_PAT header) can now be displayed in colour using a single-pass Metal compute shader (`bayerDebayerAndStretch`). Bilinear demosaicing with per-channel percentile stretch eliminates green cast. Toggle in Settings → Image Display.
- **Per-folder colour normalisation**: Bayer images load as greyscale first (instant display), then after the full batch is loaded the app computes per-channel median clip bounds per subfolder and re-renders all images in colour with a consistent shared stretch. File re-reads are fast from the warm OS page cache.
- **`BayerPattern` enum** with `rOffset` bit-encoding and automatic FITS header detection.
- **Resizable session chart**: replaced `VSplitView` with a custom drag handle; chart height defaults to 200 px and is remembered across launches via `@AppStorage`.
- **Dynamic y-axis**: the chart's y-axis now starts near the data minimum (with 10% padding) rather than at zero, so data fills the available chart height.

### Changed
- Settings gains a new **Image Display** tab containing Sizes and Colour Images settings (moved from User Interface).
- Settings window height reduced now that User Interface tab is shorter.

---

## 2026-03-08 — Fix 'Include subfolders' checkbox in Open Folder panel

### Fixed
- The "Include files from subfolders" checkbox in the Open Folder panel now works correctly. The SwiftUI/`@Observable` accessory view didn't wire up bindings properly outside a SwiftUI window hierarchy; replaced with a plain AppKit `NSButton` checkbox which reads back reliably after `runModal()` returns.

---

## 2026-03-08 — Settings reorganisation + key conflict detection (v1.10)

### Changed
- Settings tabs renamed and reorganised: "Keys" → **User Interface** (now also contains Appearance and Sizes); "Images" → **Files & Folders** (subfolders only).
- Apply button moved inside the Sizes section so it visually groups with the size fields.
- Open Folder panel: "Include files from subfolders" checkbox is now always visible without needing to click "Show options".

### Added
- Key conflict detection: trying to assign a key already used by another binding beeps and keeps the recorder open so the user can choose a different key.

---

## 2026-03-08 — Font size control (v1.9)

### Added
- **Text Size picker** in Settings → User Interface: a System Settings–style row of seven "A" buttons (xSmall → xxxLarge). Changes take effect instantly across the whole UI.
- Custom `fontSizeMultiplier` environment key and `scaledFont(size:weight:monospaced:)` ViewModifier (`AppFont.swift`) replace all hard-coded `.font(.caption)` calls throughout the app.
- Buttons and toggles use explicit `Text` labels so macOS native controls also respond to font scaling.

---

## 2026-03-08 — Recursive subfolder support (v1.9)

### Added
- **Include files from subfolders** setting (Settings → Files & Folders, default off). When enabled, opening a folder recursively scans subdirectories for FITS files.
- **Excluded folder names** list (default: FLAT, DARK, BIAS, CALIB). The `REJECTED` folder is always skipped regardless of this list.
- Open Folder panel shows a pre-filled checkbox for the current setting; changes in the panel are session-only and do not write back to Settings.
- Drag & drop respects the `includeSubfolders` setting.
- **Collapsible folder sections** in the thumbnail sidebar: click a folder header to collapse/expand its entries, with an animated chevron.
- **Folder filter pills** in the session chart strip: tap to show only frames from selected folders.
- `ImageEntry.subfolderPath` stores the relative path from the opened root.

---

## 2026-03-07 — Skip float FITS files silently at scan time with alert

### Fixed
- Float FITS files (BITPIX < 0) no longer flash as a spinner in the sidebar before disappearing. `FITSReader.peekBitpix(url:)` reads only the first 2880-byte header block to check BITPIX before an `ImageEntry` is created; float files are skipped entirely in `openFiles`.
- When one or more files are skipped, `ImageStore.errorMessage` is set, surfacing an alert that lists up to 5 filenames and a "and N more" suffix for larger batches.

---

## 2026-03-07 — Drop float FITS support; BZERO-only performance improvement

### Removed
- **Float FITS images (BITPIX=-32, -64)**: `parseHeader` now validates BITPIX immediately and throws `FITSError.unsupportedBitpix` for any value outside `{8, 16, 32}`. The float byte-swap and double→float conversion code is removed from both `readIntoBuffer` and `read`. A float file now shows "Unsupported image format: floating-point FITS files (BITPIX=…)" in the sidebar.

### Improved
- **BZERO-only path uses `vDSP_vsadd` instead of `vDSP_vsmsa`**: integer FITS files always have BSCALE=1. The common BZERO≠0 case (e.g. BITPIX=16 with BZERO=32768) now runs a vectorized add-only pass rather than multiply+add, saving one multiply per pixel across the full image.

## 2026-03-07 — Add configurable Remove-from-List key (R)

### Added
- **Remove selected image(s) from list** (`ImageStore.removeSelected`): removes the current selection from `entries` without touching files on disk. After removal the next entry in sorted order is selected, or the previous one if the removed block was at the end. Works with single and multi-select.
- **Configurable key binding** (`AppSettings.removeKey`, default `R`): stored in UserDefaults, shown as "Remove from List" in Settings → Keyboard.

---

## 2026-03-07 — SNR in Auto-Flag panel + filename above image + toolbar cleanup

### Added
- **SNR threshold in Auto-Flag panel**: new "Signal-to-Noise (SNR)" section in `AutoRejectSheet`. Relative mode rejects frames whose SNR falls below a chosen fraction of the per-group median (default 50%); absolute mode rejects below a fixed floor (default 20, slider 5–1000 to match the `peak/σ` scale where typical values run 10–500+). `GroupStats` gains `medianSNR`; both branches of `previewAutoReject` now check `config.useSNR`.
- **Filename above the main image**: shown in `MainContent` with caption font, middle-truncation, and a divider below. Makes the current frame clear when multiple thumbnails are selected.

### Changed
- **Toolbar**: the filename label between Reset and Auto-Flag has been removed (now shown above the image instead). The "N selected" multi-select counter is still shown in the toolbar when more than one thumbnail is selected.

---

## 2026-03-07 — Multi-select thumbnails for batch reject / undo

### Added
- **Multi-select in the thumbnail sidebar**: click to select a single image as before; Cmd+click to toggle individual entries in or out of the selection; Shift+click to range-select from the last clicked entry to the clicked entry. All selected thumbnails are highlighted.
- **Batch reject / undo**: when more than one thumbnail is selected, the reject key rejects all non-rejected entries in the selection; the undo key restores all rejected entries in the selection. The toggle-reject key rejects non-rejected or undoes all-rejected depending on state.
- **Selection count in toolbar**: when multiple entries are selected, the filename label becomes "N selected".
- Keyboard navigation (↑/↓/Home/End) clears the multi-selection.

---

## 2026-03-07 — Remove star rating system + add configurable Simple/Geek mode toggle key

### Removed
- **Star rating system**: removed `RatingView`, all 1–5 star rating key bindings, the Rating section in Settings, `ImageEntry.rating`, `setRating`, `loadSidecarRatings`, `saveSidecar`, the `.rating` sort order, and the minimum-rating filter from the Export sheet. The CSV export header is updated (`rating` column removed). `.culling.json` sidecar files are no longer written.

### Added
- **Configurable Simple/Geek mode toggle key** (`AppSettings.toggleModeKey`): defaults to `G`. Assignable in Settings → Keyboard. Toggles `isSimpleMode` on key press, same as the existing ⌘⇧M menu shortcut and toolbar button.

---

## 2026-03-07 — Fix star counts ~38% too low + rename app to Claude FITS Viewer

### Fixed
- **Star counts ~38% too low for BITPIX=16 images** (`MetricsCalculator.measureFWHMOnly` + `measureCandidates`): two root causes, both fixed.

  1. **Wing pre-filter threshold too aggressive**: `minWing = peak × 0.15` was rejecting real stars. For a Moffat β=4 PSF with FWHM ≈ 2 px detected 0.5 px off-centre in Y, the Y-direction immediate neighbours carry only ~10% of the detected peak flux — right below the 15% cutoff. This caused ~38% of real stars to fail the pre-filter and return FWHM = 0. Lowered threshold to `peak × 0.05`: a real star with FWHM ≥ 1.3 px has ≥ 8% flux in each neighbour even when off-centre, so all real stars pass. An isolated noise spike at 5σ has P(all 4 neighbours > 0.25σ) ≈ 2.6%, so most noise is still rejected.

  2. **Extrapolation amplified any residual noise**: Phase 2 sampled ~600 of the ~49 700 remaining candidates and extrapolated `rate × 49 700`. Even a 1% noise false-positive rate adds ~497 phantom stars, and the multiplication by the huge tail makes the count extremely sensitive to the pre-filter threshold. Replaced sample+extrapolate with a direct sequential count of `allCandidates.dropFirst(200).prefix(6000)`: since candidates are sorted brightest-first, real stars dominate the top of the list, and directly counting them avoids any amplification regardless of the total candidate list size. Handles up to ~6 200 total stars before undercounting begins.

### Changed
- **App display name**: set `CFBundleDisplayName = "Claude FITS Viewer"` in Info.plist. Finder, Dock, and menu bar now show "Claude FITS Viewer" instead of the internal product name.

---

## 2026-03-07 — Fix star counts wildly inflated (~27×) for BITPIX=16 images

### Fixed
- **Phase 2 extrapolation poisoned by noise false positives** (`MetricsCalculator.measureFWHMOnly`): for many BITPIX=16 images the GPU `detectLocalMaxima` kernel finds 50 000+ local maxima (hitting the candidate cap), because at the `background + 5σ` threshold many background noise pixels qualify. NMS with `minSep=3` barely reduces this sparse set. `measureFWHMOnly` then accepts ~50% of those noise peaks as "stars" (isolated noise spikes produce a flat, wide profile that happens to fall in the FWHM [0.5, 20] range), and Phase 2 extrapolates that rate across ~47 000 candidates → ~21 000 reported stars regardless of the true count.

  Fix: added a cheap 4-neighbour cross-section pre-filter at the top of `measureFWHMOnly`. All four immediate neighbours (±1px in X and Y, background-subtracted) must exceed 15% of the peak. A real star (Moffat β=4, FWHM ≥ 1.7 px) has ≥ 16% flux in each immediate neighbour; an isolated noise spike has neighbours near sky level (~0 after background subtraction). The check rejects ≈ 99.7% of isolated noise peaks with 4 array lookups, before the 20-point Moffat loop runs.

---

## 2026-03-07 — Fix star counts inflated 3× for integer FITS images

### Fixed
- **NMS skipped for integer images** (`MetricsCalculator`): the GPU detection path bypassed non-maximum suppression for BITPIX > 0 images on the assumption that integer ties prevent multiple local maxima per star. In practice, read noise causes adjacent integer-valued PSF pixels to differ by one ADU, so each star still produces 2–3 competing local maxima. The result was a 3× star-count inflation for BITPIX=8/16/32 images. Removed the `bitpix`-gated NMS logic — NMS now runs unconditionally on both GPU and CPU paths, consistent with the CPU-only `computeImpl` path which already applied NMS for all BITPIX values.

---

## 2026-03-07 — Fix FWHM/Ecc/SNR missing from session chart

### Fixed
- **Saturation filter excluded all stars** (`MetricsCalculator`): the saturation threshold was computed from a 5000-pixel stratified sample max. In sparse star fields most of the sample hits sky background, so the sample max is close to sky level — making `threshold = sampleMax × 0.90` lower than virtually all star peaks. The condition `candidate.peak < saturationThreshold` was therefore false for every candidate, leaving `fwhmValues`, `eccValues`, and `snrValues` empty. Removed the saturation filter entirely; genuinely clipped/saturated stars are already excluded by the `fwhm <= 20` guard on the Moffat fit result (flat-topped profiles produce degenerate fits or halo FWHM well above 20 px). Also reverted the `estimateBackground` return type to the simpler `(median, sigma)` tuple.

---

## 2026-03-06 — Two-phase loading, NMS bypass, and render-trigger reduction

### Changed
- **Two-phase loading pipeline** (`ImageStore.processParallel`): loading is now split per image into Phase A (I/O + histogram + GPU stretch → `isProcessing = false`, image visible) and Phase B (metrics, runs after the image appears, reusing the already-loaded Metal buffer without a second disk read). Previously metrics were computed before `createImage`, so any regression in metrics speed directly delayed image display.
- **NMS bypass for integer FITS images** (`MetricsCalculator.compute`): non-maximum suppression is now skipped when `BITPIX > 0`. In integer images, adjacent pixels often share the same ADU value, so the strict-greater-than local-maximum test naturally produces at most one candidate per stellar PSF — NMS was ~20 ms of unnecessary overhead per image. Float images (`BITPIX < 0`) still require NMS because IEEE 754 uniqueness creates multiple local maxima per star.
- **Single MainActor hop per image**: the task group return type changed from `Void` to `(ImageEntry, FrameMetrics?)`. Phase B results are now applied directly on the main actor in the collection loop instead of via a second `await MainActor.run` from a background thread. This halves the number of SwiftUI render triggers during a batch load, reducing thumbnail and chart re-render churn.
- **Phase 1 reduced to 200 candidates**: shape-statistic measurement (FWHM/eccentricity/SNR) uses the top 200 candidates (was 300), matching the original pre-session behaviour.
- **Moffat fit: `pow(x, 0.25)` → two `squareRoot()` calls** in both `fitMoffat1D` and `measureFWHMOnly`: avoids the transcendental `powf` function (~5× faster for this specific exponent).
- **Uniform-sampled star count** (`MetricsCalculator.measureCandidates`): Phase 2 star counting replaced the per-candidate parallel `withTaskGroup` (which was measuring all remaining candidates with the full `measureShape` including the expensive 21×21 eccentricity loop) with a sequential uniform sample of ~600 candidates measured by `measureFWHMOnly`. Extrapolation gives accurate star counts in < 2 ms instead of 4–6 seconds.
- **`measureFWHMOnly`**: new lightweight helper — 1D Moffat β=4 fit along X only at integer pixel coordinates; no bilinear centroid, no Y-axis fit, no eccentricity loop. ~10× cheaper per call than the full `measureShape`.

---

## 2026-03-06 — BITPIX=-32 metric fixes + parallel star measurement

### Fixed
- **BITPIX=-32 images showed no metrics ("No stars detected")**: Background estimation used a hardcoded sigma floor of `1.0` which overshot all pixel values in float FITS images (range 0.0–1.0). Replaced with a data-relative floor of `dataRange × 0.0001`.
- **SNR too low for float images (value ~2)**: Aperture photometry SNR (`iNet / sqrt(iNet + nAp·σ²)`) is not scale-invariant and collapses for small-valued float data. Replaced with peak SNR (`peakVal / sigma`), which gives consistent results across BITPIX=16/32/-32/-64.
- **Star count 10× too high for BITPIX=-32**: IEEE 754 floats are almost always unique (no integer ties), so every background fluctuation created a unique local maximum. Fixed with non-maximum suppression (NMS, `minSep=3px`, grid-based O(n), brightest-first) followed by PSF-verified counting (only candidates where Moffat FWHM ∈ [0.5, 20px] are counted).
- **Computation took 4–5 seconds after removing star cap**: Measuring all 15 000+ candidates sequentially was O(15k × Moffat fit). Fixed with a two-phase approach: Phase 1 — sequential top-300 for shape statistics (FWHM/ecc/SNR medians, up to 200 unsaturated); Phase 2 — parallel FWHM-only check across CPU cores via `withTaskGroup` chunked by `ProcessInfo.activeProcessorCount`. Uses `PixelBuffer: @unchecked Sendable` to safely share the read-only pixel pointer across task-group children.
- **Inspector always showed "Computing…"**: The text was unconditional below the metrics toggles. Now shows "Computing…" only while `entry.isProcessing`, otherwise "No stars detected".
- **Session chart showed "Computing metrics…" indefinitely**: The placeholder was a static fallback for any empty `chartPoints`. Now checks `store.isBatchProcessing` first, falling back to "No \(metric) data for this session".

---

## 2026-03-06 — Performance refactor: cached sort/filter + vectorized BITPIX=-64

### Changed
- **`sortedEntries` cached**: previously a fully-computed property that sorted all entries on every SwiftUI render pass — O(n log n) on every frame for metric-based sort orders. Replaced with a `cachedSortedEntries` stored property updated only when sort settings change (`didSet`) or at batch/recompute boundaries. `sortedEntries` is now a trivial forwarding property.
- **`activeFilterGroups` cached**: previously recomputed a `Set` + filter on every sidebar render — O(n) per frame. Now a stored `private(set)` property updated via `updateActiveFilterGroups()` at batch boundaries.
- **`thumbnailSortOrder` / `thumbnailSortAscending`**: added `didSet` triggers calling `updateCachedSort()` so the cache stays current when the user changes sort settings interactively.
- **`setRating` triggers resort**: changing a star rating now calls `updateCachedSort()` when the current sort order is `.rating`.
- **`openFiles` seeds the cache**: `updateActiveFilterGroups()` + `updateCachedSort()` called synchronously after new entries are appended, so the sidebar renders with loading spinners immediately rather than waiting for batch completion.
- **`recomputeMetrics` refreshes sort after Pass 1**: the synchronous cache-restore pass now calls `updateCachedSort()` before the background batch starts, ensuring the sort reflects the restored metrics instantly.
- **BITPIX=-64 vectorized byte swap** (`FITSReader.swift`, both `readIntoBuffer` and `read` paths): replaced a scalar `for i in 0..<pixelCount { temp[i] = temp[i].byteSwapped }` loop with a two-step `vImage` SIMD technique — (1) `vImagePermuteChannels_ARGB8888([3,2,1,0])` reverses bytes within each 4-byte group across the whole buffer; (2) `vImageHorizontalReflect_ARGB8888` on a `width=2, height=pixelCount` view swaps the two 4-byte halves within each 8-byte double. Together these reproduce a full 64-bit byte reversal entirely in Accelerate SIMD.

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
