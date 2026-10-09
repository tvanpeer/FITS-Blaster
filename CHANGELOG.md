# Changelog

All notable changes to FITS Blaster are recorded here.

---

## 2026-10-09 — Target Background display control; zoom anchor; chart and metric UI improvements

### Added
- **Target Background slider** replaces the old Brightness slider in the display controls bar. The value (0.05–0.50, default 0.25) sets the desired sky background brightness level in the displayed image, matching the PixInsight MAS convention. The STF stretch already targets ~0.25, so the default produces no visible change. The value persists across app restarts (moved from session-level `ImageStore` to `AppSettings`).
- **Zoom anchor** — click anywhere on the image to pin a point of interest. A crosshair marks the pinned point. All subsequent zoom changes (slider and pinch-to-zoom) keep that point centred in the viewport. The anchor persists across image navigation (same normalised coordinates = same sky position). Click the crosshair again to clear it. The lit scope icon in the zoom toolbar re-centres the viewport on the anchor after scrolling. The Defaults reset button also clears the anchor.
- **Quality Score** added to the inline metric chip row (shown when enabled in Settings → Quality Metrics).

### Fixed
- **Chart y-axis domain for single-image folders**: when only one frame was loaded (or all visible frames had the same metric value), the y-axis fell back to the hardcoded 0–1 range. Values outside that range (e.g. Sky BG = 1296 ADU, FWHM = 3.6 px) rendered as a bar or dot overflowing the chart area and drawing over the image preview. The domain now centres on the actual value with a ±20 % (min 0.5) margin.

### Changed
- **Metric chip row** is now opt-in via Settings → Quality Metrics (default off). The inspector remains the canonical metric display.
- **Per-metric compute toggles** (FWHM/Ecc/SNR/Stars on/off) removed; quality score always uses all available metrics.
- Internal: `Metric` enum introduced as single source of truth for all quality parameters. Each metric declares which UI locations it appears in via a `MetricContext` OptionSet (sort, chart, export, status chip), eliminating separate `ChartMetric` and related enums.

---

## 2026-10-08 — Throughput benchmark framework (BenchmarkTests, run-benchmark.sh)

## 2026-10-08 — Add scripts/compare.py for PI SubframeSelector correlation testing

## 2026-10-08 — Documentation: OSC/Bayer FWHM and eccentricity

### Changed
- Updated `docs/public/Score.md`, `site/score.html`, and `site/faq.html` to reflect the current bilinear-demosaicking implementation: two-pass luminance weighting (Rec. 709 for FWHM, adaptive sky weights for eccentricity), no 2×2 binning, no ×2 scale-back, and equivalent precision to mono cameras.

---

## 2026-10-08 — Bayer mosaic: separate luminance weights for FWHM and eccentricity

### Fixed
- **FWHM on OSC/Bayer files was strongly anti-correlated with PixInsight** (Spearman r = −0.919) after adaptive per-channel sky weights were introduced for eccentricity. Root cause: PI SubframeSelector effectively weights OIII-channel G pixels 2:1 over Ha-channel R pixels on a raw Bayer mosaic (50 % of pixels are G), while adaptive weights give R and G roughly equal weight on dual-narrowband images where OIII falls in the green bandpass. FWHM measurement now uses **ITU-R BT.709 luminance weights** (wG = 0.7152) so the debayered luminance matches PI's effective OIII-channel weighting.
- Eccentricity continues to use **adaptive sky-brightness weights** (estimated from the outer border of each star crop), which correctly normalise Ha and OIII signal for the axis-ratio measurement.
- PSF fitting for Bayer files now runs two debayering passes per star — Rec. 709 for FWHM, adaptive for eccentricity. The overhead is negligible (eight Moffat fits instead of four).
- Validated on three independent datasets: California Nebula (Antlia ALP-T dual narrowband, 60 frames) — FWHM r = +0.990, eccentricity r = +0.875; Gamma Cygni (Antlia ALP-T, 34 frames) — FWHM r = +0.948; M31 broadband (43 frames) — FWHM r = +0.973, eccentricity r = +0.740 (no regression).
- A new `BayerLuminanceWeights` enum (`.rec709` / `.adaptive`) is defined in `BayerPattern.swift`.

---

## 2026-10-06 — App Store: build 199, Sparkle weak-link, App Store entitlements

### Fixed
- App Store builds crashed at launch because `dyld` hard-linked Sparkle at load time. `OTHER_LDFLAGS` is now `-weak_framework Sparkle` so the framework is loaded on demand, matching the sandbox environment's expectations.
- Added `FITS Blaster App Store.entitlements` to the repository (app sandbox, user-selected read/write, app-scope bookmarks). The file was referenced in `project.pbxproj` but not tracked, so clean clones would fail to build for App Store distribution.
- Build number bumped to 199 for the resubmission.

---

## 2026-10-08 — Bayer mosaic: bilinear demosaicking for full-resolution PSF measurement

### Changed
- FWHM and eccentricity on OSC/Bayer files are now measured from a bilinearly debayered luminance crop rather than a 2×2-binned crop. The new path interpolates the missing R, G, B values at every pixel position (using the Bayer pattern from the FITS header), converts to luminance (Rec. 709 coefficients), and fits the PSF on the result at full native resolution. Eccentricity benefits most — the debayered crop has 4× more pixels and avoids the axis-ratio compression that 2×2 binning introduced. FWHM no longer requires a ×2 scale-back factor because the crop is already at native pixel scale. The `BayerPattern?` value is now threaded through the metrics pipeline in place of the previous `Bool`, giving the demosaicker the exact CFA pattern (RGGB, BGGR, GRBG, GBRG) at every call site.

---

## 2026-10-03 — Bayer mosaic: moment-based eccentricity on binned crops

### Fixed
- Eccentricity on OSC/Bayer files was unreliable with 1D Moffat projections on the raw Bayer mosaic: the alternating R/G/B/G channel pattern biases each directional fit differently, producing rankings that are essentially random across sessions (Spearman r as low as −0.15). Eccentricity for Bayer files is now computed as intensity-weighted second moments on the 2×2-binned crop. This uses all 169 crop pixels and is orientation-invariant by construction, compared to only ~20 usable samples across four 1D slices. Both FWHM (from the binned Moffat fit, ×2 scale-back) and eccentricity (from moments) now come from the same binned crop, so no additional crop measurement is needed.

---

## 2026-10-03 — Bayer mosaic: split FWHM/eccentricity measurement

### Fixed
- Eccentricity on OSC/Bayer files regressed after the 2×2-binning fix because the isotropic blur from binning compresses the PSF axis ratio toward 1, flattening all eccentricity values and destroying the ranking. FWHM and eccentricity are now measured from separate crops for Bayer files: FWHM comes from the 2×2-binned crop (eliminating the Bayer checkerboard artefact, ×2 scale-back applied), while eccentricity, SNR, and peakVal come from the raw unbinned crop where the four-direction axis-ratio signal is preserved.

---

## 2026-10-03 — Bayer mosaic: 2×2-bin crops before Moffat fitting

### Fixed
- FWHM and eccentricity were underestimated on colour OSC cameras because metrics were computed on the raw Bayer mosaic. The alternating R/G/B/G pixel pattern along any 1D cross-section looks like a narrower PSF than it really is, causing artificially low FWHM (e.g. 1.7 px where PixInsight measures 2.6 px) and weaker eccentricity correlation. FITS Blaster now detects the Bayer pattern from FITS headers (`BAYERPAT` keyword) and, for those files, bins each star crop 2×2 before fitting. Each 2×2 block averages one R + two G + one B pixel into a single luminance sample, eliminating the checkerboard artefact. FWHM from the binned crop is scaled ×2 to recover native-pixel values.

---

## 2026-10-03 — Eccentricity: orientation-invariant four-direction PSF fit

### Changed
- **Eccentricity** is now computed from a four-direction Moffat fit (0°, 45°, 90°, 135°) with analytic principal-axis reconstruction. The four directional α values satisfy a closed-form system that yields the true major/minor axes of the PSF ellipse at any rotation angle — not just axis-aligned elongation. Previously, only the 0° and 90° fits were used, so diagonal elongation (e.g. trailing at 45°) was missed entirely. The formula and the FWHM value are otherwise unchanged.
- Documentation updated in `Score.md`, `score.html`, and `faq.html`.

---

## 2026-10-03 — PSF Signal Weight formula revised

### Changed
- **PSF Signal Weight formula** revised from `mean(A × α²) / σ` to `mean(A) / σ` — peak amplitude per sky noise unit. The previous formula used the Moffat integrated flux (`A × α²`), which stayed roughly constant as seeing varied (because `A` and `α²` move in opposite directions). The new formula uses the peak amplitude directly, so PSF-SW now rewards both better transparency (more photons → higher `A`) and better seeing (sharper PSF → higher `A`), matching PixInsight SubframeSelector's PSF Signal Weight behaviour.
- Documentation updated accordingly in `Score.md`, `score.html`, and `faq.html`.

---

## 2026-10-03 — PSF Signal Weight metric

### Added
- New **PSF Signal Weight** metric (shown as "PSF·S" in the chart): mean peak star amplitude normalised by sky noise sigma. Rewards both transparency and seeing quality. Computed as a free by-product of the existing Moffat fit (no toggle needed).
- PSF Signal Weight appears in the inspector (below Sky BG), the session chart (new "PSF·S" button), the sort menu ("PSF Signal"), and thumbnail tooltips.

---

## 2026-10-03 — Chart cursor and progress bar label

### Fixed
- The chart cursor dot (white, larger) now moves correctly when navigating between images. The `selectedEntry` check was inside a `@ChartContentBuilder` closure that doesn't participate in SwiftUI's `@Observable` tracking, so the chart wasn't re-rendering on selection changes. Fixed by capturing the selected entry ID before the `Chart {}` block.

### Changed
- Renamed the "Colour" progress bar to "Restretching" — it tracks the full display-image restretch pass, which covers both Bayer→colour and greyscale re-renders (e.g. when toggling the debayer setting on a previously loaded session).

---

## 2026-10-03 — QuickLook thumbnail fixes and iCloud investigation

### Fixed
- Some FITS files in a folder showed the app icon instead of a thumbnail in Finder's icon view, while the same files had a tiny thumbnail in list view. Root cause: the thumbnail extension was always loading a 2048-pixel intermediate Float array (~24 MB) regardless of the requested thumbnail size. In icon view many thumbnails are requested simultaneously, exhausting the QuickLook extension process memory limit; the process was killed and macOS cached the failure as a permanent app icon. The extension now subsamples directly to the requested size — a 512-px icon-view thumbnail uses ~1.5 MB instead of ~24 MB; a 32-px list-view thumbnail uses ~5 KB.
- Added a clean early-exit for iCloud stubs (files with `ubiquitousItemDownloadingStatus == .notDownloaded`). Previously, calling `Data(contentsOf:)` on an undownloaded iCloud file blocked the QL extension indefinitely rather than throwing an error, causing the extension process to be killed by macOS and any other in-flight thumbnail requests in the same batch to fail.
- Added guard against empty pixel buffer in `createImage` to prevent a force-unwrap crash on pathological FITS files with zero-size image dimensions.

### Notes (iCloud thumbnails)
- For FITS files stored in iCloud Drive: thumbnails that survive `qlmanage -r cache` are stored in iCloud's own thumbnail metadata layer, not the local QuickLook cache. `qlmanage` commands have no effect on those. The QL extension generates thumbnails only for files with no iCloud-stored thumbnail and that are locally downloaded. Files that are iCloud stubs (not downloaded) will show the app icon; marking the folder "Keep Downloaded" in Finder is required for persistent thumbnails.

---

## 2026-10-02 — Folder drop and full-screen traffic lights

### Fixed
- Dropping a folder onto the app icon in the Dock or Applications folder now opens that folder in FITS Blaster. The app was missing `public.folder` in its document type registration, so macOS never forwarded folder drops to the app.
- In full-screen mode, moving the mouse to the top of the screen now reveals the traffic-light window controls (and the menu bar). A hidden `NSToolbar` is now attached to the window; without it, macOS has no hover zone to activate in full-screen mode.

---

## 2026-10-02 — STF auto-stretch (PixInsight-style)

### Improved
- Replaced gamma 2.2 stretch with a PixInsight-style Screen Transfer Function (STF). The new algorithm computes the image's median and MAD (Median Absolute Deviation) to set an intelligent black point, then applies a Midtone Transfer Function (MTF) that places the sky background at ~25% grey. The result: darker background, more contrast in faint nebulosity, no blown-out highlights. Applies to all paths — GPU (Metal), CPU fallback, colour (Bayer), QuickLook, and thumbnails.

---

## 2026-10-02 — Fix full-screen mode/inspector layout issues

### Fixed
- Switching between Geek and Simple mode in full screen no longer leaves a black dead column where the inspector panel used to be. The inspector now uses SwiftUI's `.inspector` modifier, which handles full screen correctly instead of relying on window resizing.
- The image now auto-fits to the newly available space when switching modes or showing/hiding the inspector.
- The inspector panel now correctly reappears when switching back to Geek mode after having been in Simple mode.

---

## 2026-10-02 — Sky BG sort and auto-flag, stable beta app name

### Added
- Sky BG sort option in the thumbnail sort menu.
- Sky background threshold in the Auto-Flag sheet: flag frames where sky brightness exceeds a multiple of the group median (relative mode) or a fixed ADU ceiling (absolute mode).

### Fixed
- Beta builds are now distributed as `FITS Blaster Beta.app` instead of a versioned name (e.g. `FITS Blaster 1.23-beta.6.app`). The versioned name prevented Sparkle from renaming the bundle on update, leaving users with a stale app name after every in-place upgrade.

---

## 2026-10-02 — Consistent stretch and sky background chart

### Improved
- Greyscale (mono) images in the same folder and filter group are now rendered with a consistent shared stretch, eliminating the brightness flickering when scrolling quickly through a session.
- Sky background value is now shown in the inline metrics row above the chart alongside FWHM, Ecc, SNR, and Stars.

### Added
- **Sky BG** chart metric: plot the sky background ADU level across the session, with per-filter-group median lines.

---

## 2026-10-01 — Filter pills, sky background, and 1:1 zoom

### Improved
- Filter pills in the thumbnail sidebar now wrap onto multiple rows when many filter groups are active, instead of overflowing into a single cramped line.
- The thumbnail sidebar can now be dragged up to 360 px wide (previously capped at 220 px).
- The zoom percentage label (e.g. "0.5×") is now a button — click it to jump instantly to 1:1 (100%) for pixel peeping. Tooltip reads "Click for 1:1 (100%)".

### Added
- **Sky background** metric in the inspector panel: the median ADU level of the sky background, estimated as a free side-effect of star detection. Useful as a relative sky-darkness indicator across a session.

---

## 2026-10-01 — Single-letter filter codes recognised

### Fixed
- Filter names consisting of a single letter — **H**, **O**, **S** — were shown as "Unfiltered" instead of being mapped to Hα, OIII, and SII respectively. Also added **IR** as an alias for Luminance. Affects users whose capture software writes short codes in the FITS FILTER header (common with N.I.N.A., SGP, and some ASIAIR configurations).

---

## 2026-04-29 — Beta update channel actually works now

### Fixed
- The "Beta updates" preference promised on the website was never actually wired up: every beta build was checking the stable appcast (`appcast.xml`) and reporting "you're up to date" by comparing the beta build number against the latest stable (1.22 / build 168). A new `BetaChannelUpdaterDelegate` now routes Sparkle's feed at `appcast-beta.xml` when the toggle is on. Beta builds default the toggle on; stable builds default it off.

### Added
- Settings → Interface → Software Updates section with a "Receive beta releases" toggle. Available in non-App-Store builds only (App Store builds don't ship Sparkle).

### Note
- This fix can only help users running this build forward; existing users on beta.3 (which has the bug) won't see this build via auto-update and will need to download once manually from the beta page.

---

## 2026-04-29 — Export path styles, padded text report, Simple-mode column tidy-up

### Added
- File path style option for exports: absolute path (current behaviour), relative to the longest folder shared by all exported frames, or filename only. Default is configurable in Settings → Export, with a per-export override in the export sheet. Relative mode collapses a single-folder session to bare filenames automatically.

### Changed
- The plain text (.txt) export is now a space-padded human-readable report rather than a bare list of file paths. It includes the same columns as CSV/TSV (path, optional status, metrics when available, selected FITS header columns) but every cell is padded so the file lines up cleanly in any text editor — numeric columns right-aligned, text columns left-aligned. Use CSV or TSV when you need a machine-parseable file.

### Fixed
- CSV/TSV exports left FWHM, eccentricity, SNR, stars, and score blank when a metric was disabled or the user had switched out of compute-everything mode after the first batch. The exporter now falls back to the cached metric values that are preserved for the lifetime of the session.

### Improved
- Simple-mode exports (and any session where no frame has any metrics data) now omit the `fwhm`, `eccentricity`, `snr`, `stars`, and `score` columns entirely instead of emitting empty cells, so the resulting CSV/TSV jumps straight from `path` to the selected FITS header columns.
- FITS header column picker (Settings → Export and the export sheet) now dims keys that aren't present in any currently-loaded file, so it's clear before exporting which keys will produce data and which won't. Selected-but-absent keys are dropped from the output, and the .txt report lists them in a `# Skipped columns with no data: …` footer so the omission is auditable when re-reading the file later.

---

## 2026-04-28 — FITS header export columns, export defaults, CSV decimal fix

### Added
- Configurable FITS header columns in CSV/TSV exports. Choose which header keys appear as columns in Settings → Export, or override per-export via the new export sheet. Defaults cover acquisition, focus, weather, and pointing fields (OBJECT, DATE-OBS, EXPTIME, FILTER, GAIN, OFFSET, CCD-TEMP, FOCUSPOS, AIRMASS, OBJCTALT, AMBTEMP, HUMIDITY).
- Tab-separated (.tsv) export format alongside CSV — handy for opening in plain text editors with aligned columns.
- Optional inclusion of rejected frames in exports. Plain text adds a `# REJECTED` suffix; CSV/TSV add a `status` column (`kept` / `rejected`).
- Quality score column in CSV/TSV exports.

### Fixed
- CSV exports could emit integer values for FWHM and eccentricity on systems with comma-decimal locales (Dutch/German/French), because the formatter used the user's region. Numbers now use a fixed `en_US_POSIX` locale and always have the configured decimal places.

### Improved
- Export sheet redesigned with format picker, rejected-frames toggle, and a FITS header column list. All values pre-populate from Settings → Export defaults; if you change anything, an orange notice signals "applies to this export only" (same pattern as the Open Folder panel).
- Export plain text retains its file-list-only output, but now includes a per-line marker for rejected frames when they are exported.

---

## 2026-04-12 — QuickLook previews and thumbnails for all FITS formats

### Added
- QuickLook preview and thumbnail support for floating-point FITS files (BITPIX -32 and -64). Previously these showed blank icons in Finder.
- QuickLook preview and thumbnail support for 3-channel RGB colour FITS files (NAXIS3=3), such as stacked integrations from Astro Pixel Processor.
- Asinh stretch (beta=50) for float FITS previews — compresses bright cores while revealing faint nebulosity in linear astrophotography data.
- Large-file subsampling: files over 2048px are stride-sampled during preview to stay within QuickLook's memory limit (~120 MB), enabling previews of 1+ GB stacked integrations.
- `FITSReader.readForPreview(from:)` — dedicated read path that accepts float BITPIX and multi-channel files without affecting the main app's integer-only pipeline.

### Improved
- Zero-pixel exclusion in percentile estimation prevents stacking artifacts (unfilled corners) from skewing the preview stretch.

---

## 2026-04-12 — SwiftUI review fixes, accessibility, tests, and rejected-view cursor fix

### Added
- 111 unit and integration tests covering FITSReader, quality scoring, filter group normalisation, frame metrics, Bayer pattern parsing, histogram computation, and star detection with synthetic images (single star FWHM accuracy, multi-star count, gradient background robustness, noise rejection, elongated star eccentricity, FITS round-trip pipeline, CPU image stretch).

### Fixed
- Undo-reject and reject actions now advance the cursor to the next visible entry, matching the flagged-view behaviour.
- VoiceOver: inspector toggle and chart style buttons now have accessible labels instead of empty strings.
- VoiceOver: session chart tap overlay now declares `.isButton` trait.
- VoiceOver: filter strip chips are individually focusable (replaced ScrollView with HStack) and announce selected state.
- VoiceOver: inspector panel exposes children to VoiceOver navigation.

### Improved
- Settings tabs migrated from deprecated `.tabItem()` to the `Tab` API.
- Filter group header uses cached `GroupStats` instead of recomputing O(n log n) median on every render.
- `.filter { }.count` replaced with `.count(where:)` in ExportPanel and BatchProgressBar.
- Drag handle uses semantic `.quinary`/`.quaternary` colours instead of manual opacity.
- `AppDelegate` annotated `@MainActor` for strict concurrency.
- Unnecessary explicit `return` removed from single-expression switch cases.
- Menu command views extracted from `FitsBlasterApp.swift` into `MenuCommands.swift`.

---

## 2026-04-09 — Session chart bars, filter fix, play mode, flip, and beta channel

### Added
- Session chart: optional bar chart mode as alternative to dots. Toggle via the chart header button. Preference is persisted.
- Play mode: press P to auto-advance through images at a configurable speed (0.2–5.0 seconds per frame). A speed slider appears in the toolbar during playback. Manual navigation stops playback automatically.
- Flip 180°: press V to rotate the current image (or batch selection) 180 degrees for display. A rotation indicator appears on the thumbnail. Does not modify FITS files.
- Cursor memory per filter group: switching between filter buttons (R, G, B, etc.) remembers and restores the selected image for each group.
- Beta release channel: tag a version as `v1.23-beta.1` to publish a test build without updating the homepage. Beta builds get their own page (`beta.html`), appcast feed (`appcast-beta.xml`), and are marked as pre-releases on GitHub.
- Beta page on the website with download link and release notes for the latest beta build.
- Release & issue workflow guide (`guide-releases.html`) documenting the tag-based release process and GitHub Issues workflow.

### Fixed
- Filter buttons above the thumbnail sidebar now work correctly in multi-folder sessions.
- Switching filter group or rejection visibility now auto-selects the first visible entry when the cursor is hidden.
- Unflagging an image in the Flagged view now advances the cursor to the next flagged image instead of losing the selection.
- Playback stops automatically when switching filter group or rejection visibility.
- Playback timer moved out of SwiftUI view modifier to prevent task cancellation during view rebuilds.

### Improved
- O(n²) search in image removal replaced with O(n) scan for selecting the next entry.
- GitHub Actions pipeline detects beta tags and adjusts behaviour: marks releases as pre-release, writes to separate appcast and site files.
- Site navigation now includes a Beta link on all pages.

---

## 2026-04-08 — Sparkle auto-update

### Added
- Automatic update checking via the Sparkle framework. FITS Blaster now checks for new versions once every 24 hours in the background.
- "Check for Updates..." menu item in the FITS Blaster menu for manual update checks.
- Updates are downloaded, installed, and relaunched automatically — no manual DMG drag required.

### Improved
- FAQ updated: "Does FITS Blaster require an internet connection?" now mentions the lightweight update check.

---

## 2026-04-08 — Image viewer controls

### Added
- Zoom slider (0.25×–4×) with live readout; trackpad pinch-to-zoom also supported.
- Brightness slider for quick exposure adjustment without re-rendering.
- Stretch slider to boost or reduce image contrast.
- "Defaults" button to reset all three adjustments in one click.
- Scrollbars appear automatically when the image is zoomed beyond the viewport.
- Viewport indicator: a yellow box on the sidebar thumbnail shows which part of the image is currently visible when zoomed in.

### Improved
- Scroll position is now preserved when navigating between frames at the same zoom level.
- Zooming via the slider keeps the viewport centre fixed instead of jumping to the top-left.
- Zoom level persists across app launches; brightness and stretch reset when opening a new folder.
- Swift 6 concurrency fixes: key-event monitor, `PanelAccessoryHelper`, `FolderTracker.init`, concurrent `self` capture, and unused weak-capture removals.
- QL extension `CFBundleVersion` now tracks the main app version automatically via `$(CURRENT_PROJECT_VERSION)`.

---

## 2026-04-08 — v1.20 QuickLook support and Bayer screen-door fix

### Added
- QuickLook preview: press Space on any FITS file in Finder to get a rendered preview without opening FITS Blaster. The preview uses the same percentile-clip + square-root stretch as the app.
- QuickLook thumbnails: Finder icon view now shows rendered FITS images as file icons, in colour for Bayer (e.g. Seestar, Dwarf) files.

### Fixed
- Screen-door grid pattern in colour (debayer) mode for raw Bayer FITS files. The `bayerDebayerAndStretch` Metal kernel now applies the same 2×2 Bayer cell alignment as the greyscale path: each output pixel's footprint is guaranteed to span at least one complete Bayer cell, so every pixel receives a proper R, G, B value. Colour Bayer images are displayed at half the sensor resolution (the true colour resolution). Confirmed fixed with test images from the **Seestar S30**, **Seestar S30 Pro**, **Seestar S50**, and **Dwarf 3**.

### Improved
- Release builds (local `build-release.sh` and CI) now produce a universal binary (arm64 + x86_64), so the same DMG runs natively on both Apple Silicon and Intel Macs.

---

## 2026-04-07 — Fix screen-door effect in colour mode for Bayer FITS files

### Fixed
- Colour (debayer) display of raw Bayer FITS files (e.g. ZWO Seestar S30/S50) no longer shows a screen-door grid pattern. The `bayerDebayerAndStretch` Metal kernel now uses the same 2×2 Bayer cell alignment that greyscale mode uses: each output pixel's footprint is guaranteed to cover at least one complete Bayer cell, so every pixel receives a proper R, G, B value rather than a single raw channel. Colour Bayer images are displayed at half the sensor resolution (the true colour resolution the sensor can produce).

---

## 2026-04-05 — Per-folder streaming colour rendering and progress bar improvements

### Improved
- Colour rendering now starts per-folder as soon as all entries in a folder are sampled, both during initial load and when switching from grey to colour mode. Previously the entire set had to be sampled before any rendering began.
- The Colour progress bar is now visible for the entire duration of colour rendering (no more flickering in/out between folders).
- All progress bars (Loaded, Metrics, Sampling, Colour) now stay on screen until the complete batch finishes, rather than disappearing individually as each pipeline completes.
- Progress bar count text now uses its natural width so 4-digit counts (1000+) are never clipped.
- Removed the now-redundant `normalizeBayerStretch` function; `renderFolderInColour` covers both the initial load and colour-toggle paths.

---

## 2026-04-04 — v1.19.5 switch CI to Xcode 26, restore @concurrent

### Improved
- CI now builds with Xcode 26.3 (previously Xcode 16.4). `@concurrent` pipeline annotations and `SWIFT_APPROACHABLE_CONCURRENCY` are fully effective under Xcode 26 and no longer cause the slowdown seen with the older compiler.

---

## 2026-04-04 — v1.19.4 concurrency revert

### Fixed
- Reverted all `@concurrent` annotations back to `nonisolated`. The `@concurrent` attribute causes a ~2× slowdown when compiled with Xcode 16 (Swift 6.0/6.1), regardless of whether `SWIFT_APPROACHABLE_CONCURRENCY` is enabled. Restores the pipeline throughput of 1.19.1.

---

## 2026-04-04 — v1.19.3 concurrency performance hotfix

### Fixed
- Disabled `SWIFT_APPROACHABLE_CONCURRENCY` (SE-0461) to restore full pipeline throughput when built with Xcode 16.4. The `@concurrent` annotations added in 1.19.2 are silently ignored by the Xcode 16 compiler, causing nonisolated async functions to inherit `@MainActor` and serialise metrics computation. The `@concurrent` annotations are retained for forward-compatibility when the CI migrates to Xcode 26.

---

## 2026-04-04 — v1.19.2 concurrency performance fix

### Fixed
- Restored full parallel pipeline throughput when building with Xcode 26 (Swift 6.2). All async functions in the image loading, stretching, and metrics pipeline are now marked `@concurrent`, guaranteeing they always run on the cooperative thread pool rather than the main actor. This fixes a ~3× slowdown introduced by the Swift 6.2 SE-0461 concurrency model changes.

---

## 2026-04-04 — v1.19.1 progress bar and colour rendering fixes

### Improved
- Progress bars (Loaded, Metrics, Sampling, Colour) are now shown below the main image again, next to the elapsed-time indicator, instead of in the toolbar.
- The currently selected image now switches to colour immediately when colour rendering begins, rather than waiting for its turn in the batch queue.
- Release builds are now arm64-only, matching the GitHub-distributed binary and restoring native Apple Silicon performance for local builds.

---

## 2026-04-04 — v1.19.0 batch progress bars

### Added
- **Batch progress bars** in the toolbar during image loading: Loaded, Metrics, Sampling, and Colour bars show live progress for each pipeline phase and disappear automatically when complete.

### Fixed
- In Simple mode with a multi-folder session, folder sections now appear in the sidebar (previously only Geek mode showed folder groupings). Filter sub-headers within folders remain Geek-mode only.

---

## 2026-04-03 — v1.18.1 keyboard navigation follows sidebar order

### Fixed
- Keyboard navigation (↑/↓/Home/End/Shift+↑/Shift+↓) now steps through entries in the same order they appear in the thumbnail strip, not the flat sort order. In sessions with multiple filter types (Ha, OIII, SII), pressing ↓ now advances within the current filter group section before moving to the next, matching what you see on screen.
- In multi-folder mode, keyboard navigation skips entries inside collapsed folder sections, so the cursor can no longer land on a hidden thumbnail.

---

## 2026-04-02 — v1.18.0 flag/deflag keys, toolbar & chart improvements

### Added
- **F key**: toggle flag/unflag on the current entry or orange range selection (configurable in Settings → Keyboard).
- **D key**: deflag all — clears the entire flagged set in one keystroke (configurable).
- **(De)flag** toolbar button: toggles the flag state of the current entry or orange range, always visible next to the Cancel button.
- **(De)flag** and **Deflag All** items in the Select menu, separated from the range-selection commands by a divider.
- Session chart brightness sliders in Settings → Display: independently control the opacity of rejected dots and non-flagged dots when a flagged set is active.
- Tooltips on all toolbar buttons, session chart metric buttons, and sidebar sort button; tooltip delay reduced from ~1.5 s to 0.5 s.
- **Getting Started** guide page on the website (`guide.html`) — full workflow walkthrough, interface overview, key hints, and tips.
- **Keyboard Shortcuts** reference page on the website (`keys.html`) — all default bindings in one place.
- Top-level navigation bar on all website pages, replacing scattered footer links.

### Improved
- Mode toggle button now shows **Simple** or **Geek** (the current mode) instead of a blank label, matching the Colour/Grey button convention.
- Session chart brightness contrast: rejected dots now render at 15 % opacity and non-flagged dots at 50 %, making the three-level hierarchy (rejected → non-flagged → flagged/cursor) clearly readable.
- Conflict detection for key bindings in Settings now correctly separates plain keys from ⌘-modifier keys, preventing false conflicts (e.g. plain D vs ⌘D).

### Removed
- **File → Open File(s)… (⌘⇧O)** menu item removed (the open-files path has sandbox limitations that prevent it from working reliably).

---

## 2026-04-01 — v1.17.1

### Fixed
- ⌘A, ⌘D, and ⌘I now operate on the orange range selection (consistent with ⇧+click and ⇧+arrow) rather than the flag set.

### Improved
- FAQ: ⌘A / ⌘D / ⌘I documented in the Flagged view entry and the keyboard shortcuts entry.

---

## 2026-04-01 — v1.17.0 selection redesign

### Added
- SO (SII+OIII) dual-narrowband filter group with emerald colour — recognises Askar C2 and similar filters.

### Improved
- Selection model fully redesigned for consistency: **cursor** (blue, always one frame) and **range selection** (orange, built with ⇧+click or ⇧+arrow) are now independent concepts with no side effects between views.
- ⇧+click and ⇧+arrow build an orange range selection in any view (All or Selected).
- ⌘+click adds the range (or single frame) to the Flagged view from All; removes it from Flagged view.
- Reject acts on the orange range if one is active, otherwise on the cursor.
- In the Flagged view, rejected frames stay visible (orange) so the reject can be undone immediately by pressing Reject again.
- Session chart cursor dot is now white for instant position recognition; all other dots remain filter-group coloured.
- Session chart cursor dot is smaller (less dominant); rejected frames always shown at 30% opacity.
- Sidebar thumbnail shows a checkmark badge on flagged frames; orange border on range-selected frames.
- FAQ: updated session chart and Flagged view entries to reflect new selection model; added full filter-group colour table with swatches.

---

## 2026-03-31 — v1.16.3 improvements

### Added
- Help menu: new "Ask Support" item opens the GitHub bug report form directly.

### Improved
- FAQ: added "What do the colours and brightness levels in the session chart mean?" entry explaining filter-group dot colours, dashed median lines, and the spotlight brightness hierarchy.
- FAQ: corrected "What is the session chart?" — dot colour represents the filter group, not the quality badge.

---

## 2026-03-31 — v1.16.2 improvements

### Fixed
- Auto-Flag sheet: all "Reject if …" threshold labels corrected to "Select if …"; subtitle updated to "Flag frames below quality thresholds for review."
- Cmd+Click in the Flagged view with an active multi-selection (e.g. after Cmd+A) now removes all selected entries at once instead of only the clicked one.

### Improved
- Session chart spotlight: when a multi-selection is active, non-selected dots dim to 0.40 opacity and rejected dots dim further to 0.15, creating a clear three-level brightness hierarchy (rejected → non-selected → selected).
- Session chart drag-select now triggers the spotlight correctly (previously only sidebar Cmd/Shift-click selections activated it).
- Auto-Flag sheet: SNR threshold is now enabled by default.

---

## 2026-03-31 — v1.16.1 bug fixes

### Fixed
- Website feature list said "drag-to-reject" and "Auto-reject" instead of "drag-to-select" and "Auto-select".
- Folder count badge in the thumbnail sidebar showed the total file count regardless of the active view (All / Flagged / Rejected); it now reflects only the entries visible in the current view.
- Metric buttons above the session chart (Score, FWHM, Ecc, SNR, Stars) did not visually indicate the selected button; the active metric now uses a filled (prominent) button style.
- Cmd+Click in the Flagged view was toggling multi-selection instead of removing the entry from the selection; it now always unflag the clicked entry.
- Shift-click multi-select did not work at first open until the user clicked the first thumbnail explicitly; the shift-click anchor is now seeded when the first image is auto-selected on load.

---

## 2026-03-29 — Include REJECTED: undo and selection fixes

### Fixed
- Undo reject now correctly moves files back to their pre-rejection folder when they were loaded via "Include REJECTED". Previously `originalURL` was set to the REJECTED path itself, so the move was a no-op.
- Cmd+A (Select All) and other command-key shortcuts now work reliably across all keyboard layouts. The key monitor was using `event.characters` which can return a control character for Cmd+letter on some systems; switched to `event.charactersIgnoringModifiers`.
- Thumbnail selection highlight now updates instantly after Cmd+A and other multi-selection operations. `ThumbnailCell` now observes `selectedEntryIDs` directly rather than relying on a parameter passed from the parent view.

---

## 2026-03-29 — v1.16 bug fixes and features

### Fixed
- Reset now always switches back to "All frames" mode (was left in Flagged/Rejected if active).
- Cmd+click in "Flagged" mode with an active multi-selection now toggles the clicked entry instead of unflagging everything (unflag-on-cmd-click is still the default for single-entry actions).
- Shift+click range selection now works from the very first open; it no longer requires re-clicking the first image first.
- Session chart now enlarges dots for all multi-selected thumbnails, not just the focused entry.

### Added
- **Sort by Rejected** added to the thumbnail sort picker; rejected entries sort to the bottom (ascending) or top (descending), with alphabetical tie-breaking.
- **Cmd+R — Select All Rejected**: selects all rejected frames in one keystroke. Configurable in Settings → Keyboard.
- **Colour/Grey toolbar button** now shows a `camera.filters` icon (multicolour in colour mode, monochrome in grey mode) instead of plain text.
- **Ko-fi link** added to the About FITS Blaster panel.
- Opening a folder with the subfolders checkbox set differently from Settings now shows a one-time info alert pointing to Settings → Files & Folders.
- **Include REJECTED folder** checkbox added to the Open Folder dialog; when ticked, FITS files inside the `REJECTED/` subdirectory are loaded and automatically marked as rejected. A permanent toggle for this is in Settings → Files & Folders.
- **"How Scores Work"** page added to the website, explaining background estimation, star detection, shape measurement, the composite score formula, and badge-colour logic.

---

## 2026-03-28 — Repository housekeeping

### Improved
- Source assets (`Book of Galaxies.png/icns`, `installer-background.png`) moved to `resources/` and are now tracked.
- Installer scripts moved to `scripts/`.
- Screenshots tracked in `Screenshots/`.
- `.github/` added: bug report and feature request issue templates, and a `release.yml` workflow that builds, notarises, and uploads a DMG to GitHub Releases on version tags.
- Removed stray DMG binary and legacy `Simple Claude fits viewer.xcodeproj/` from disk.
- `.gitignore` cleaned up; only built artefacts (`bin/`, `site/Downloads/`, `*.dmg`) remain excluded.

---

## 2026-03-28 — Track all remaining docs in repository

### Improved
- `readiness.md` moved to `docs/internal/` and is now version-controlled. All markdown docs are now tracked.

---

## 2026-03-28 — Track public docs in repository

### Improved
- `privacy-policy.md` and `RAW-support.md` moved to `docs/public/` and are now version-controlled.

---

## 2026-03-28 — Reorganise documentation layout

### Improved
- Markdown docs split into `docs/public/` (user-facing) and `docs/internal/` (developer notes).
- Moved to `docs/public/`: `FAQ.md`.
- Moved to `docs/internal/`: `FWHM-comparison.md`, `Score.md`, `performance.md`.

---

## 2026-03-28 — Track website in repository

### Improved
- `site/` is now committed to the repository (Option A); `site/Downloads/` remains gitignored so DMG binaries are never stored in git.

---

## 2026-03-27 — Fix main-thread I/O hang on file open

### Fixed
- Opening a folder no longer blocks the main thread on slow I/O (iCloud Drive materialisation,
  SMB mounts, heavy disk pressure). The BITPIX pre-flight check (`peekBitpix`) is now performed
  in a `nonisolated` background function instead of synchronously on the main actor, eliminating
  the spinning beach ball that occurred when files were stored in iCloud Drive.

---

## 2026-03-27 — Website updates

### Added
- `site/changelog.html` — full changelog web page styled to match the site, with colour-coded
  section labels (Added / Fixed / Improved / Changed / Removed).
- Download button on homepage linking to `Downloads/FITS-Blaster-1.15.dmg`.
- Changelog link in homepage footer.

### Changed
- Replaced App Store badge with Ko-fi donation link (`https://ko-fi.com/tomvp`).
- FAQ "Subscription" section replaced with "Support & Donations" (free app, Ko-fi link).
- FAQ "Does FITS Blaster require an internet connection?" updated: no longer mentions subscription.
- FAQ "What data does FITS Blaster collect?" updated: no longer mentions App Store network requests.

---

## 2026-03-25 — Switch to donationware; remove StoreKit (v1.15)

### Removed
- `PurchaseManager`, `PaywallView`, and `Configuration.storekit` deleted entirely.
- 50-frame free-tier cap removed from `ImageStore.openFiles` — all images load without restriction.
- Subscription tab removed from Settings.
- Paywall sheet and `PurchaseManager` environment removed from `ContentView` and `FitsBlasterApp`.

### Fixed
- Sandbox permission error on rejection: `accessDirectory(for:)` now falls back to creating a fresh
  security-scoped bookmark from the entry's parent directory when the stored bookmark is missing or
  stale. `rejectEntry` and `undoRejectEntry` now fail fast with a clear error message if directory
  access cannot be established, instead of proceeding silently without sandbox scope.

---

## 2026-03-25 — Flagged view + selection overhaul (v1.14)

### Added
- **Flagged view** — a dedicated sidebar filter that shows only flagged frames. Frames enter the list via ⌘+click, ⇧+click, chart drag-select, or Auto-Flag; ⌘+click inside the view removes them. Flagged frames persist across filter switches and are only cleared on folder reset.
- **Flag-then-inspect workflow** — chart drag-select and Auto-Flag now add frames to the Flagged view instead of rejecting them immediately. Rejection happens explicitly inside the Flagged view after inspection.
- **Select menu** — top-level menu with Select All, Deselect All, and Invert Selection, each with configurable key bindings (defaults: ⌘A / ⌘D / ⌘I).
- **Shift+↑/↓ extend selection** — grows the multi-selection one step at a time using the configured navigation keys.
- **Configurable selection key modifiers** — Settings → UI lets you choose ⌘ or ⌘⇧ independently for each selection shortcut.
- **Drag tooltip** — while drag-selecting in the session chart, a floating label shows the metric value of the frame under the cursor.

### Fixed
- Arrow-key navigation (previous / next / first / last) now respects the active visibility filter, stopping at the boundary of the visible set rather than crossing into hidden frames.

### Improved
- Session chart left edge has breathing room before the first dot, making drag-select starting from frame 1 easier.

### Updated
- FAQ: new "What is the Flagged view?" entry; updated chart drag-select and Auto-Flag descriptions to reflect the new workflow.


---

## 2026-03-24 — v1.9–v1.12 series — pipeline, Bayer colour, and subfolder support

### Added
- **GPU downscale** in Metal stretch kernels — renders directly to display size (1024 px) in a single pass, eliminating post-GPU CPU scaling. Load time cut ~50%.
- **Bayer colour debayering** — colour FITS images rendered via single-pass Metal shader with bilinear demosaicing and per-channel percentile stretch; per-folder normalisation for consistent batch display.
- **Phase A/B pipeline** — I/O and GPU stretch (Phase A) fully decoupled from metrics computation (Phase B) so images appear immediately without waiting for Moffat fitting; MTLBuffer passed directly to Phase B.
- **Subfolder scanning** — recursive subfolder support with collapsible folder sections in the sidebar and folder filter pills in the session chart.
- **Text size picker** in Settings (xSmall → xxxLarge, Dynamic Type-based).
- **Resizable session chart** with a custom drag handle; dynamic y-axis starts near the data minimum.
- Cancel and Colour/Grey toggle buttons added to the toolbar.

### Fixed
- Keyboard shortcuts work after clicking a thumbnail (replaced `onKeyPress` with an `NSEvent` local monitor).
- Colour/grey toggle is instant on the second press (greyscale image cached on first load).
- Duplicate folder detection; subfolder name collision tracked by full path.
- Session chart: folder pills wrap instead of overflow; x-axis domain capped to actual frame count.
- Open Folder "Include subfolders" checkbox reads back reliably (AppKit `NSButton`).

### Improved
- Settings reorganised: **User Interface** and **Files & Folders** tabs; key conflict detection added.
- Phase B semaphore tuned to `max(4, cpuCount-2)`; star-measurement task group parallelised with 4 inner workers.

---

## 2026-03-04 — Early development and initial commit

### Added
- Simple/Geek mode, filter-group sidebar, quality badges, auto-reject sheet, session chart, dock-icon drag & drop.
- Multi-select in thumbnail sidebar (⌘+click, ⇧+click); batch reject and undo.
- SNR threshold in Auto-Flag panel; filename displayed above the main image.
- Configurable Remove-from-List key (R) and Simple/Geek mode toggle key (G).
- Full FITS file viewer for macOS 15.7+ built on Swift 6 / SwiftUI. **`FITSReader`** parses FITS headers and pixel data (BITPIX 8/16/32) with zero-copy GPU (`readIntoBuffer`) and CPU (`read`) paths. **`ImageStretcher`** renders via Metal compute shader (percentile clipping + sqrt gamma). **`MetricsCalculator`** detects stars via GPU Metal kernel and measures FWHM (1D Moffat β=4), eccentricity (2D moments), and SNR. **`ImageStore`** triple-buffered concurrent pipeline with sandbox security-scoped bookmarks and rejection to `REJECTED/` subdirectory.

### Fixed
- **Star count accuracy** — multiple rounds of fixes: wing pre-filter threshold (38% undercount), NMS bypass (3× inflation for BITPIX=16), Phase 2 extrapolation noise amplification (27× inflation), and over-aggressive saturation filter (missing FWHM/Ecc/SNR metrics).
- Float FITS files (BITPIX=−32/−64) silently skipped at scan time with a user alert.
- `vDSP_vsadd` instead of `vDSP_vsmsa` for BZERO-only path (BSCALE is always 1 for integer FITS).

### Improved
- Two-phase loading pipeline: display then metrics; single MainActor hop per image; `sortedEntries` and `activeFilterGroups` cached as stored properties.
- Moffat fitting: `pow(x, 0.25)` → two `squareRoot()` calls; uniform-sampled star count replaces per-candidate parallel extrapolation.
- BITPIX=−64 byte-swap vectorised with `vImage` SIMD.
