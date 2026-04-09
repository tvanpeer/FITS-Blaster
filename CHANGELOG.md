# Changelog

All notable changes to FITS Blaster are recorded here.

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
