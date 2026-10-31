# Architecture and Fixes — Master Plan

**Date**: 2026-10-17  
**Status**: Ready to start. App Store build 202 was approved, and v1.23 and 1.23.1-beta.1 were released on 2026-10-20. All open questions were answered on 2026-10-20 (see "Decisions").  
**This is the only plan to follow.** It contains (plus the 6 findings of [PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md), mapped at the end):
- the architecture review of 2026-10-17 (decisions: combine with the concurrency plan, do all steps, no RAW / freemium boundaries);
- [concurrency-fixes-plan.md](concurrency-fixes-plan.md), which keeps the detailed design and tests for steps 6 and 7 here;
- every finding of [CODE_AUDIT.md](CODE_AUDIT.md) (76 findings, §3.1–§9.15).

Every audit finding is in exactly one step. The table "Finding → step" at the end is the check. Where a finding touches code in two steps, it says which part goes where.

---

## Assessment (summary)

**The architecture fits. No pattern change.** FITS Blaster is MVVM with one app-wide model:

- `@Observable @MainActor` model objects (`ImageStore`, `AppSettings`, `ImageEntry`), created once in `FitsBlasterApp` and passed down through the SwiftUI environment;
- a stateless engine: `FITSReader`, `ImageStretcher` (Metal), `MetricsCalculator`, plain functions without UI state;
- CLI mode uses the same model, so app and CLI results can't drift apart.

For a single-window Mac app by one developer, with no server, this is the right fit. TCA would add a framework dependency and ceremony; Clean Architecture would add layers with nothing to replace; VIPER and MVP are built for UIKit. No protocols or dependency injection either: the engine is pure functions and the tests use real files. Boundaries for RAW decoding or in-app purchase are left out on purpose (not on the roadmap, Tom 2026-10-17).

**What needs work:** `ImageStore` does too much (about 2,400 lines over three files); batch work has no single owner; the model opens dialogs itself; some logic lives in views and can't be tested; all files sit in one folder. On top of that, the audit found real bugs (Quick Look broken on macOS < 26.2, crashes on malformed FITS files), dead and duplicated code, and performance and memory risks.

---

## Rules for every step

- One commit per step (some steps say they are two), each with a CHANGELOG entry.
- **Behaviour stays the same**, except where a step says otherwise. Behaviour changes are collected in step 13 and need a decision first.
- **Renders and metrics stay byte-identical** (`scripts/run-render-tests.sh`, metric baselines), except in step 13, which updates the targets on purpose.
- Checks after each step: full unit tests; render tests; metric baselines; SwiftLint clean if installed.
- After steps 1, 5, 6, 8, 9, 14 and 15: also `scripts/vm-test-all.sh` with the beta build, and the 👤 manual checks on the 27 VM.
- Performance and Metal: steps 8 and 9 change performance on purpose and are measured with `BenchmarkTests` before and after. Every other step is expected to have no measurable effect; any step that touches Metal says so.

---

## Order at a glance

| # | Step | Kind | Main audit findings |
|---|------|------|---------------------|
| 1 | FITS input hardening and Quick Look on macOS 15 | bug fixes | §5.1, §5.2, §5.3, §5.18–§5.20, §9.7 |
| 2 | Small bug fixes | bug fixes | §5.5, §5.6, §5.8, §5.9, §5.15, §4.7, §8.3, §8.4, §8.7, §8.8 |
| 3 | Dead and vestigial code | cleanup | §9.1–§9.3, §9.10, §9.13 |
| 4 | Dialogs out of the model; open and export | architecture | §4.2, §4.3, §5.7, §5.13, §6.2, §7.4 |
| 5 | `ViewerState` and header facts | architecture | §7.5a, §8.1, §8.6 |
| 6 | `LoadPipeline` with the concurrency fixes | architecture | §3.1, §3.2, §3.4–§3.6, §3.9, §7.6, §9.9 |
| 7 | Swift 6 readiness | concurrency | §3.3, §3.10, §3.11, §4.1 |
| 8 | Engine core: Metal, statistics, measurement | engine | §3.7, §3.8, §5.17, §7.3, §7.8, §7.9, §9.4–§9.6 |
| 9 | Load performance and memory | performance | §7.1, §7.2, §7.5b, §7.7, §8.5 |
| 10 | View logic into tested helpers; accessibility | UI | §8.2, §8.9 |
| 11 | Reject and undo file operations | bug fixes | §5.14, §9.8 |
| 12 | CLI | bug fixes | §5.10, §5.11, §5.12 |
| 13 | Behaviour changes (need decisions) | behaviour | §4.5, §5.4, §5.16 |
| 14 | Configuration, security and release tooling | config | §4.6, §6.1, §6.3–§6.5 |
| 15 | Feature folders, naming, constants | organisation | §9.12 (folders), §9.14, §9.15 |

**Why this order:**
- **1–3** are small and independent and fix what users hit now. Step 1 ships before the rest, as 1.23.1-beta.2 (decision 1).
- **3 comes before the moves (4–6)** so dead code isn't moved, tested and then deleted.
- **6 before 7**, as in the concurrency plan.
- **8 and 9 after 6**, because the pipeline then has one owner to optimise.
- **13 late**, after the code it changes has settled, and only after the decisions.
- **15 last**, because moving files earlier makes every other diff harder to read.

---

## Step 1 — FITS input hardening and Quick Look on macOS 15

**Changes**
- **Quick Look minimum** (§5.1): set `MACOSX_DEPLOYMENT_TARGET = 15.6` on `FITSBlasterQL` and `FITSBlasterQLThumb` in Debug, Release and App Store. Check `LSMinimumSystemVersion` in both built `.appex` bundles.
- **Smoke test** (§5.1, audit §10.5): `scripts/vm-smoke-remote.sh` checks that `pluginkit -m -i` finds both extension IDs after the app has been opened, and that `qlmanage -t` makes a thumbnail of a sample frame. FAIL otherwise.
- **Parsing helpers first** (§9.7): in `FITSReader.swift`, extract card parsing (used by `parseHeader` and `peekBitpix`), "apply BSCALE/BZERO and find min/max" (3 copies) and the byte-swap (2 copies). No behaviour change; the render tests prove it.
- **Validated header** (§5.2, §5.3, §5.19): one place that checks
  - 1 ≤ NAXIS1, NAXIS2 ≤ a maximum (proposal: 65,536);
  - all size products with overflow checks;
  - finite BSCALE and BZERO, and finite after conversion to `Float`;
  - a limit on the number of header blocks without END (proposal: 100).
  Anything outside these throws `FITSError.invalidFormat`.
- **Tiny images** (§5.18): CPU detection returns no candidates below 3 × 3.
- **Test helper**: new `FITS Blaster Tests/TestFITS.swift`, a synthetic FITS writer with optional extra header cards. It replaces the three copies (`IntegrationTests.swift:83-125`, `GPUTests.swift:221-232`, `FITSReaderTests.swift:260-330`). The concurrency tests in step 6 use it too. This is the test-fixture part of §9.11.

**Tests** (§5.20): parameterised malformed-header tests for `read`, `readIntoBuffer` and `readForPreview`: negative, zero and huge NAXIS, overflowing products, missing END, truncated data, non-finite BSCALE/BZERO. Each must throw, not crash. Plus the 2 × 2 image on the CPU detection path.

**Behaviour**: invalid files that used to crash are now skipped with an error message. Valid files: unchanged (render tests, baselines).

**Risk**: low. 👤 Check on `fb-15` and `fb-26`: Finder thumbnails and the Space-bar preview of a FITS file.

---

## Step 2 — Small bug fixes

Each is a few lines. One commit, or two if it reads better.

| Finding | Change | Test |
|---|---|---|
| §5.5 | The key monitor (`ContentView.swift:155-160`) only handles events whose window is the main content window | 👤 in Settings: record a shortcut on a bound key; press the reject key with a toggle focused: nothing happens in the main window |
| §5.6 | REJECTED folder removed only when truly empty (`.DS_Store` allowed) (`ImageStoreFileOperations.swift:238-244`) | unit test on a temp folder with a hidden file |
| §5.8 | Duplicate check matches both `url` and `originalURL` of existing entries (`ImageStorePipeline.swift:43, 134`). Step 6 later moves this snapshot inside the batch; the matching rule moves with it. | unit test: reject, reopen with REJECTED, no duplicate |
| §5.9 | Chart x-domain uses `chartEntries.count + 1` (`SessionChartView.swift:301`) | 👤 chart with frames still processing |
| §5.15 | `removeSelected` subtracts removed IDs from `markedForRejectionIDs`, `rejectedEntryIDs` and the cursor maps (`ImageStore.swift:448-471`) | extend `RemoveSelectedTests` |
| §4.7 | Tooltip delay through `UserDefaults.register(defaults:)` (`FitsBlasterApp.swift:58-62`) | — |
| §8.3 | `scaledFont` instead of fixed sizes (`ThumbnailCell.swift:31, 40`; `SessionChartView.swift:296, 306, 400`) | 👤 largest text size |
| §8.4 | `$settings.exportHeaderKeys` (`ExportSettingsTab.swift:54-57`); an `isShowingError` binding helper for the alert (`ContentView.swift:42-45`) | — |
| §8.7 | Trailing-closure `overlay { }` (`SessionChartView.swift:362`) | — |
| §8.8 | Accessibility trait and label on the zoom-anchor tap (`ImageViewer.swift:71`) | — |

**Risk**: low.

---

## Step 3 — Dead and vestigial code

**Changes**
- **Delete** everything in §9.1, each re-checked with a grep across all targets and tests just before deleting:
  - the crop star pipeline;
  - `reprocessAll` and `openFilesPanel` with the flat `openFiles` overload (concurrency question 5 and old question 1 are answered by the audit: remove);
  - `rejectEntries` + `applyAutoReject`, `formatFraction`, `compute(ptr:)`, `makeSharedBuffer`, `estimatePercentiles`, `groupedSortedEntries`, `FolderGroup.totalCount`;
  - the 17 `*KeyEquivalent` properties;
  - `MainContentViews.swift`;
  - `scripts/Create-installer.sh`.
- **Never-read fields** (§9.2): `bzero`/`bscale` on the FITS result types, `FastLoadResult.metalDevice` and `.bitpix`, `GPUDetectionResult.totalFound`, and the unused `device` parameter of `compute(metalBuffer:device:)` (§7.9 keeps only the shared-device part for step 8).
- **Unreachable branches** (§9.3): plain-text quoting, the sky-background export case, and the `bayerBin` kernel parameter. **Touches Metal**: the Bayer kernel loses a parameter that is always 1; renders must stay byte-identical.
- **Vestigial per-metric config** (§9.10): `MetricsConfig` becomes a single on/off; `filtered(by:)`, the partial merge and the open-coded `covers` checks in `recomputeMetrics` go. Done here so step 6 moves less code.
- **Stale comments and docs** (§9.13): all 17 comment sites; `docs/internal/performance.md:68-80`; `SwiftUI-Review.md` moved to `docs/internal/` and marked historical (April 2026). The Metal kernel rename `sqrtStretch` → `mtfStretch` goes with its Swift lookup string.

**Tests**: everything stays green; `FrameMetricsTests` and the `covers` test change with §9.10.

**Risk**: low (deletions of code with no callers). The Metal parameter removal is checked by the render tests.

---

## Step 4 — Dialogs out of the model; open and export

**Changes**
- `ImageStoreFileOperations.swift`:
  - `openFolderPanel(...)` becomes `openFolder(at url: URL, includeSubfolders:includeRejected:settings:) async`. No panel, no alert. The folder scan (`collectFITSURLs`) becomes `@concurrent` and is awaited, so it no longer runs on the main thread (§7.4, folder-scan part). The "already loaded" check becomes `isAlreadyLoaded(_:) -> Bool` for the caller.
  - `openDroppedItems` keeps one bookmark **per source folder**, and each entry gets the bookmark of its own folder (§5.13). For single dropped files, rejecting asks for folder access first (an open panel pointed at the parent folder). Check in the sandboxed App Store build.
  - `export(...)` becomes `export(to url: URL, …) throws`. Write errors reach the user through `errorMessage` (§5.7; a failed export becomes visible, a small behaviour change).
- New `FileDialogs.swift`: choose folder, confirm "open again", choose export destination. These use the asynchronous panel APIs (`begin` / sheet-modal), and the 300 ms `Task.sleep` before the open panel goes away (§4.2).
- One FITS `UTType` and one extension list (`fits`, `fit`, `fts`), used by the panels, drops and scans (§4.3 and the extension-list part of §9.11).
- **Export cleanup** (export parts of §9.11, and §6.2): build the rows once and render them as delimited or padded text. One CSV quoting helper is shared with `CLIRenderer`; it also quotes `\r`, and text cells starting with `=`, `+`, `-` or `@` get a leading `'` (metric number columns don't). The default export keys become one `static let`, and there is one header-key catalogue and picker for `ExportPanel` and `ExportSettingsTab`, with one column-ordering rule (decision 9: the order chosen in Settings).
- Path APIs in the code rewritten here use URLs (the `ImageStoreFileOperations` part of §4.4).
- Callers: `FITSToolbar.swift` (Open Folder) and `ExportPanel.swift` (Export) call `FileDialogs` first, then the store.

**Tests**: `openFolder(at:)` on a temp folder with a REJECTED subfolder; `isAlreadyLoaded`; `export(to:)` matches `exportContent`; a write failure sets `errorMessage`; CSV escaping (formula prefixes, `\r`, quotes); dropped files from two folders keep their own bookmarks.

**Risk**: medium (sandbox access). 👤 Checks: Open Folder, open the same folder twice, drag-and-drop (folders, files, a mix), Export in all three formats; reject a dropped single file in the App Store build.

---

## Step 5 — `ViewerState` and header facts

**Changes**
- New `ViewerState.swift` (`@Observable @MainActor`). It takes `displayStretch`, the viewport and zoom-anchor state, the two triggers, and playback from `ImageStore`. `startPlayback(store:settings:)` takes the store as a parameter, so it holds no reference to it.
- `FitsBlasterApp` creates it and puts it in the environment, also for the Settings window. Reset calls `store.reset()` and `viewer.reset()` together.
- Views that change: `ContentView`, `ImageAdjustControls`, `ImageViewer`, `PlaybackControls`, `ThumbnailCell` (recheck with a grep at the start).
- **Thumbnail redraws** (§8.1): `ThumbnailCell` gets `isCursor`, `isFlagged`, `isMarked` and its group stats as plain values from the parent, so moving the cursor or flagging redraws only the affected cells. Measure with the `swiftui-performance-audit` skill before and after.
- **Zoom anchor** (§8.6): positioned from the known image size × zoom, without `GeometryReader`.
- **Selection fan-out beyond the cells** (performance audit P1): the sidebar's scroll-to-cursor moves into a small view or `ViewerState` value, so the list body no longer depends on `selectedEntry`. The chart's cursor becomes a separate overlay mark, so a cursor move doesn't rebuild every point.
- **Scroll writes** (P4): `viewportFraction` is written only on a visible change; `viewportCenter` becomes `@ObservationIgnored` (read only in an `onChange` handler).
- **Scroll animation** (P5): no animated scroll for key-repeat cursor moves, or scroll only when the cursor leaves the visible area.
- **Header facts stored once** (§7.5a, and the header-cleaning and `BayerPattern.parse` parts of §9.11; the header part of P2). Moved here from step 9 on 2026-10-18, because the trace showed it is a main cost of a cursor move: the chart reads `entry.filterGroup` for every point, which re-parses the header (about 5 ms per move with 355 frames).
  - `filterName`, `filterGroup` and `bayerPattern` are stored on `ImageEntry` when headers arrive.
  - Header values are cleaned at parse time.
  - Step 6 moves the code that sets the headers and must keep this.

**Tests**: playback and viewport tests move to `ViewerStateTests`; `reset()` restores the defaults; the stored `filterGroup` and `bayerPattern` equal what the old computed properties returned, for every test-data frame. Re-record trace 1 of the performance audit (hold ↓) and compare.

**Risk**: medium (many views). 👤 Checks: zoom, scroll, the viewport box in the thumbnail, zoom anchor, fit to window, contrast, playback, Reset, cursor movement speed in a large session.

---

## Step 6 — `LoadPipeline` with the concurrency fixes

Design and tests: [concurrency-fixes-plan.md](concurrency-fixes-plan.md) steps 1–2 (batch queue, render generation), built inside the new type.

**Changes**
- New `LoadPipeline.swift` (`@MainActor`, `@Observable` for progress), owned by `ImageStore` (`let pipeline`). It keeps a weak reference back to the store.
  - From `ImageStore`: `processingTask`, `isBatchProcessing`, `batchElapsed`, `batchMegapixels`, the progress counters, `restretchingMessage`, `cancelProcessing`, `waitForProcessing`.
  - From `ImageStorePipeline.swift`: `openFiles`, `regenerateSizes`, `recomputeMetrics`, `recolorImages`, `processParallel`, grey and colour normalisation, `FolderTracker`, `AsyncSemaphore`.
  - New: `enqueueBatch`, `processingBatchID`, `renderGeneration` (§3.1, §3.2).
- `@concurrent` helpers and `FastLoadResult` move to `FrameLoading.swift`.
- **Fixes done here, all in the same code:**
  - `reset()` cancels first (§3.1);
  - the semaphore handles cancellation, and cancellation is checked before Phase B starts (§3.4);
  - **one shared limiter** for all file reads and renders, instead of a limit per group or folder (§3.5);
  - security-scoped access ends in a `defer` placed before every early return, after all spawned work (§3.6);
  - workers read `entry.url` on the main actor right before the file read and skip it if it changed (§3.9);
  - bookmarks are resolved **once per directory**, and access is stopped only when start succeeded (§7.6);
  - helpers for the bounded task-group loop, the colour-render spawn and the megapixels block (§9.9), with the concurrency caps as named constants (concurrency-cap part of §9.14).
- Callers read `store.pipeline.…` (`MainContent`, `FITSToolbar`, `SessionChartView`, `ContentView`, `SettingsView`, `CLIRunner`).
- **Behaviour changes** (concurrency questions 1–2): a second folder during a load is queued; a colour toggle during a load runs after it; Cancel also stops a colour re-render.

**Commits**: 6a moves code without changing behaviour; 6b adds the queue, the generation and the fixes above.

**Tests**: `BatchQueueTests`, `RenderGenerationTests` (concurrency plan), using `TestFITS` from step 1. Also: Cancel during Phase B starts no new detection; reject during a load leaves no stale render.

**Performance and Metal**: one load at a time and one shared limiter. Peak GPU memory goes down; total time should stay the same (`BenchmarkTests` before and after). No Metal code changes.

**Risk**: highest of the plan. Safety net: the 6a/6b split, the byte-identical renders, the baselines and the VM run.

---

## Step 7 — Swift 6 readiness

The concurrency plan steps 3–4, unchanged:
- the four warnings (§3.3), including the drop handler, which moves to `dropDestination` if that keeps sandboxed folder access (§4.1, concurrency question 4);
- the pointer escape (§3.10).

Then a scratch build with `SWIFT_STRICT_CONCURRENCY=complete` shows 0 warnings. **Swift 6 language mode** (§3.11) is a separate commit at the end of this step (decision 3: yes).

---

## Step 8 — Engine core: Metal, statistics, measurement

**Changes**
- **One `MetalContext`** (device, library, queues, pipelines, a shared 2-D dispatch with the async commit, the zero-copy image wrap) used by `ImageStretcher` and `MetricsCalculator`. This covers:
  - §9.5;
  - §7.9 (one device; buffers used on their own `device`);
  - §5.17: completion checks `commandBuffer.status`, and on error falls back to the CPU path; detection's threadgroup is clamped. **Touches Metal setup, not the kernels.**
- **One stretch-statistics function** (§9.6). The grey/colour differences stay as explicit parameters, so renders stay byte-identical. Making grey and colour behave the same is a behaviour change and would go to step 13 (decision 10: not planned).
- **One shape-measurement implementation** (§9.4), reading pixels through a small sampler, with named constants for the FWHM range and the Moffat parameters. Possible after step 3 removed the dead copy.
- **Star counting in 4 chunked tasks** instead of thousands of tiny ones (§3.8). Metrics stay identical (ordered aggregation, as now).
- **Reads** (§3.7, §7.3): read straight into the destination buffer with an in-place byte-swap, without the whole file as `Data`. Keep blocking reads below the thread-pool width.
- **Quick Look** (§7.8, and the Quick Look part of §9.11): one shared "read and stretch for preview" helper; the preview decodes at 1024 instead of 2048; thumbnails use `request.scale`. Quick Look thumbnails get sharper on Retina, which is intended.
- **Engine file splits** (§9.12, engine part): `ImageStretcher` into statistics, Metal (app target only) and CPU parts, with the Quick Look targets compiling only statistics and CPU; `FITSReader` into types, header parser and readers; `MetricsCalculator` into types and Bayer helpers. The Quick Look membership exceptions change with this.
- Engine tunables as named constants (engine part of §9.14).

**Tests**: render tests and metric baselines byte-identical; `GPUTests`; a forced command-buffer error takes the CPU path; Quick Look thumbnail size test.

**Performance and Metal**: the goal is lower peak memory per read and less task overhead in Phase B. Measure with `BenchmarkTests` and on the large test folders (`FB_TEST_DATA_FULL=1`). Kernels unchanged.

**Risk**: medium-high. 👤 Check: Quick Look preview and thumbnails on `fb-15` and `fb-27`.

---

## Step 9 — Load performance and memory

**Changes**
- **Arrays computed once** (§7.5b, the rest of performance audit P2; the header facts are already stored in step 5). One `median` helper and one grouping helper replace the copies in `ImageStore` and `SessionChartView` (visibility/grouping/median part of §9.11). Sidebar and chart arrays are computed once per change, not per render (§8.5; performance audit P2). This includes `visibilityGroupedSortedEntries`, which becomes a stored property like `visibilityFilteredEntries`.
- **Chart during a load** (performance audit P3): the chart reads its points from a store value refreshed at most every ~250 ms during a batch and once at the end, instead of observing every frame's metrics.
- **Display-image drawing** (performance audit P6): **not needed** — the trace before step 9 (2026-10-26) shows no image-format conversion on the main thread when switching frames (as on 2026-10-18).
- **Left over from step 5** (trace 5, 2026-10-25): `ThumbnailCell.body` still runs ≈ 9× per cursor move (≈ 0.9 ms) instead of only for the two cells whose values changed; find out why. The chart's cursor is still part of the chart, which costs ≈ 9 ms of mark collection per move; drawing it on top would change how it looks with bars and on rejected frames, so decide together with the measurements here.
- **Reads at once below the thread-pool width** — **closed 2026-10-27, not needed**: on the network (1 Gb/s SMB) six instead of eight reads gave the same throughput (85–93 vs 88–90 MB/s, alternated), and loading is limited by the link. (§3.7, moved from step 8 on 2026-10-26): on the internal SSD, Phase A at cores − 2 instead of max(8, cores) was neither clearly faster nor slower (M81 12.7–13.4 s vs 10.2–13.9 s, 1.3 vs 1.5 GB peak). Measure on a network share, where blocked reads can starve the pool, together with `loadFast` over the network (below).
- **Fewer reads per load** (§7.2): render the normalised grey and colour images without re-reading every file. Two ways, decided with measurements (decision 7: (a), confirmed by measuring):
  - (a) keep a display-size float proxy per frame from Phase A;
  - (b) keep each folder's full buffers until its clips are known.
  (b) conflicts with the memory goal of §7.3, so (a) is the expected choice. Renders must stay byte-identical, or the difference goes to step 13.
- **Display images in memory** (§7.1): full display images only for the selected frame and its neighbours (LRU); the rest keep thumbnails and re-render on demand. The CLI, `CLIRenderer` and the render tests need every frame's image, so the pipeline keeps a "keep all" mode for them.
- **CLI without display work** (§7.7) — **done 2026-10-29 (9e)**: without `--render` the CLI loads with `rendersImages` false (no display images, thumbnails, histograms or clips, so no grey re-read). CSVs byte-identical (apart from the pre-existing star-count variation in m31-night, noted for later). SSD: mono sets ≈ 2× faster, colour 13–24 %; network (1 Gb/s): unchanged, the link is the limit.
- **Start loading while checking** — **done 2026-10-27 as option (b)**, the separate check removed; `loadFast` over the network measured at 85–93 MB/s (network-bound). (Tom's request, 2026-10-25): the first frames should start loading as soon as their header check is done, instead of after all files are checked (over a network the check of 1147 files took 13 s, after the speed-up of 2026-10-25). Options, decided with measurements: feed checked files into the loading pipeline as they come, or drop the separate check and test the bit depth during Phase A (the header is read there anyway; float files would then appear briefly before being dropped, a behaviour change). Also measure here whether `loadFast` (whole-file reads) has the same Foundation overhead on a network share as the scan and header read had.

### 9f proposal (2026-10-29) — display memory (§7.1) and fewer reads (§7.2)

Proposed to Tom on 2026-10-29; answered 2026-10-30 (see Answers); **not started.** It replaces the
two bullets "Fewer reads per load" and "Display images in memory" above where they differ.

**Findings that change the earlier plan**
- **The float proxy of decision 7 (a) costs more memory than the display image it
  replaces.** A colour proxy needs three floats per display pixel (12 bytes), against
  5 bytes for the colour image plus its grey copy. Kept for every frame, it works against §7.1.
- **Renders from such a proxy can be byte-identical.** Both stretch kernels
  (`mtfStretch`, `bayerDebayerAndStretch`) first box-average the source pixels in
  Float32 and only then apply the stretch, so a proxy of exactly those averages gives the
  same bytes.

**Where we are** (M81, IMX571, binned 2×2 for display; colour image + grey copy per frame):

| Display size | Per frame | 355 frames |
|---|---|---|
| 1024 (default) | 3.5 MB | 1.2 GB (measured 1.19 GB Metal) |
| 2048 | 14 MB | 5 GB |
| 4096 and up | 33 MB (binned frame is 3124 px wide) | 11.6 GB (measured only 3.15 GB) |

Every file is read twice per load: mono in Phase A and the grey normalisation, colour in
Phase A and the colour render. Locally the second read usually comes from the file
cache; for large folders and over a network it costs a second full read.

**Step 0 — measure first (no app change; Claude runs it headless, through the test setup)**
1. Memory of M81 at 1024, 2048 and 4096, compressed and uncompressed. Hypothesis (not
   checked): macOS compresses the dark star-field images, which would explain 3.15 GB
   instead of 11.6 GB at 4096 (the "to be explained" in PERFORMANCE_AUDIT.md).
2. Cost of the second reads: M81 colour and Rosette mono, locally and over the network,
   with the file cache flushed — read or render work?

**Part 1 — display images within a memory budget (§7.1)**
- Display images and their grey/colour copies are kept within a memory budget instead of
  for every frame: the cursor frame and its neighbours always stay; the least recently
  viewed go first.
- Kept for every frame: thumbnails, metrics, headers and the stretch values. The shared
  clips per folder (grey per folder+filter, colour per folder) must be stored first, so a
  re-render is byte-identical.
- A frame without an image is rendered again from its file when it is shown (about
  20–50 ms on the SSD, about 0.5 s per frame over a network); with the arrow keys the
  next frames are prepared ahead.
- At the default 1024, a 2 GB budget holds about 600 colour frames, so normal sessions
  behave as now; re-rendering starts only at large display sizes or very large sessions.
- The CLI, `--render`, `CLIRenderer` and the render tests use a "keep all" mode.
- Side effects above the budget: jumping far shows the frame a moment later (more over a
  network); a thumbnail-size change must re-read the files of frames without a display
  image (today it uses the images in memory); playback meets the same delay.
- Metal: existing kernels, no new ones. Memory drops sharply at large display sizes;
  time unchanged while everything fits the budget.

**Part 2 — fewer reads (§7.2), decided with the step 0 numbers**

| Option | What | Memory | Reads |
|---|---|---|---|
| (a′) temporary proxy | Phase A keeps the averaged proxy until its folder's shared stretch is known, renders from it, then drops it | Briefly frames in folder × 8.4 MB (colour at 1024): ≈ 1.2 GB for 140 frames; at 4096 ≈ 11 GB, too much | 1 |
| (a′ with budget) | (a′) while the proxies fit a budget, otherwise re-read as now | within the budget | 1 at normal sizes, 2 at large ones |
| (b) leave as is | close §7.2 if step 0 shows the re-reads are cheap | — | 2 |

(a′) needs a kernel split ("average only" and "stretch from the average"); render tests
must stay byte-identical. The colour toggle and part-1 re-renders still read the file.

**Recommendation:** step 0; then part 1 with a memory budget; part 2 (a′ with budget)
if the second read is a large share of the load time (especially over a network),
otherwise (b) with the reason written down.

**Open questions for Tom**
1. Order: step 0, then part 1, then part 2 decided with the step 0 numbers?
2. Budget: fixed (e.g. 2 GB), a share of the Mac's memory (e.g. 1/8: 2 GB on 16 GB,
   1 GB on 8 GB), or a setting? Proposed: share of memory, no setting.
3. While a frame is re-rendered: (a) the thumbnail enlarged (blurry for a moment),
   (b) the previous frame until ready, or (c) a small spinner? Proposed: (a).
4. Is the delay above the budget (thumbnail-size change, playback) acceptable? At the
   default size it doesn't occur.

**Answers (Tom, 2026-10-30)**
1. Order agreed: step 0, then part 1, then part 2 decided with the step 0 numbers.
2. The budget is a **setting**. Most astrophotography Macs have plenty of memory (forums
   typically start at "at least 32 GB"), so a budget mainly matters on small machines,
   which are not typical. Tom (2026-10-30): a **slider** for the share of the Mac's memory,
   **default 50 %**, range 10–90 % in steps of 10 %, shown with the size in GB, next to the
   display size in Settings (agreed 2026-10-30); in its own "Memory" section, since it applies at
   once and the size fields' Apply button doesn't cover it (Tom, 2026-10-30). Later, beside the slider: a small
   calculator showing how many frames fit, by display size and memory setting, colour and grey.
3. While a frame is re-rendered: (a), the enlarged thumbnail.
4. The delay above the budget is acceptable.

**Step 0 results (2026-10-30)** — temporary test target file, not committed; Release build.

Memory of M81 (355 frames, binned 3124×2088), `footprint` of the loaded process:

| Display size | Grey mode | Colour mode |
|---|---|---|
| 1024 | 353 MB | 1.3 GB |
| 2048 | 1.1 GB | 4.9 GB |
| 4096 | 2.3 GB | 11 GB |

Almost all of it is Metal memory for the display images (1 byte/pixel grey; colour 4 + its
grey copy 1). The load briefly peaks 1.3–1.4 GB above the end value. The earlier "3.15 GB
at 4096" is not reproduced and memory compression plays no visible part; the 11.6 GB
estimate holds.

Second reads, file cache flushed first (17 GB of other files read), 1024:

| Set | With images | Metrics only | Read |
|---|---|---|---|
| Rosette large mono, SSD (464, 7.4 GB) | 5.7–5.8 s | 2.8–2.9 s | 1.0× the files from disk |
| M81 2025-04-04 colour, SSD (141, 7.0 GB) | 5.5–5.8 s | 2.7 s | 1.0× from disk |
| same, grey mode | 2.9 s | 2.7–2.8 s | 1.0× from disk |
| M81 2025-04-06 colour, share, cable (142, 7.0 GB) | 70.6–72.7 s | 63.0–63.7 s | 1.17–1.21× vs 1.05× over the network |

Locally the second read always comes from the file cache; making the images (second read +
display, thumbnail, histogram) adds about 2.8 s. A cached single-threaded re-read of the
same files takes 1.1–1.3 s. Over the network about 1 GB of the 7 GB is fetched again, which
adds 7–9 s (11–14 %). The mono set on the share (Rosette, 930 MB) stayed in the file cache
despite the flush, so it has only one cold run (9.4 s with images) and no comparison.
Larger than memory: the three M81 nights 2025-03-26/04-03/04-04 on the share (355 frames,
17.6 GB, colour, cable), 2 rounds: with images 282.5–282.8 s, metrics only 156.9–157.3 s,
plain read 172.8–175.2 s; network read 1.88× the files with images against 1.05× metrics
only. Here the second read almost entirely misses the cache and adds about 125 s (+80 %).
The same 17.6 GB from the SSD, 2 rounds: with images 24.0–24.7 s, metrics only 9.1–9.7 s,
plain read 5.8 s; disk read 1.93× the files with images against 1.00×.

Timeline of one such SSD load (per 0.5 s: disk MB/s, file cache size, per night the frames
past Phase A and the frames in colour): the file cache stays at 7.6–8.7 GB on this 16 GB
Mac. Night 1 (71 frames, 3.4 GB) finishes Phase A at 2.7 s; its colour render then runs
from 3.3 to 12.2 s, at the same time as Phase A of night 2, and the disk keeps reading at
about 1.0–1.4 GB/s throughout, more than night 2's Phase A alone needs. Night 2's colour
render overlaps night 3's Phase A in the same way; only night 3's colour render runs
after all Phase A work (19.7–26 s). One night on its own (above) re-reads from the cache.


### 9f part 1 plan (2026-10-30) — display images within a memory budget

Proposed to Tom on 2026-10-30; answered and 1a started the same day.

**What is kept per frame today:** `displayImage` plus, for Bayer frames, `cachedGreyscaleDisplay`
and `cachedColourDisplay` (the shown image is one of them), and the four thumbnails.
The display images are the memory (step 0); the thumbnails are small (13 MB for M81).

**How a frame is drawn again from its file, byte-identical** (a "recipe" stored on the entry
when its display image is made; the kernels are unchanged):
- mono in a (folder, filter) group of two or more: `createImage` with the group's shared
  `GreyClips` (the median, computed in `normalizeGreyStretch`; today not stored);
- mono on its own, or before the grey pass ran: `createImage` without clips, as in Phase A;
- Bayer in grey: `createImage` with the Bayer pattern, as in Phase A;
- Bayer in colour: `createBayerImage` with the folder's shared `BayerClips` (today not stored);
- without Metal: the CPU path, as in Phase A.
The display pixel size is stored too (in 1b, with the placeholder that uses it), so the
viewer's zoom and fit stay the same.

**Sub-steps (one commit each, checks before each):**
- **1a — recipes and re-render, no behaviour change.** Store the recipe per entry; a
  function (`FrameLoading.renderAgain`) that renders one frame again from its file with its
  recipe. Tests: for every recipe the re-render is byte-identical to the image made by the
  load (RGBA bytes). Nothing is evicted yet. The 9f plan text is committed with 1a.
- **1b — budget, eviction, placeholder, slider.**
  - `AppSettings.displayMemoryPercent` (10–90, step 10, default 50). Settings → Image
    Display → Sizes, under "Max display size": a slider with "50 % — 8 GB of 16 GB"
    (`ProcessInfo.physicalMemory`) and one line of explanation. A change applies at once:
    lowering it drops images, raising it renders nothing.
  - A budget object owned by `ImageStore` counts the bytes of each entry's display images
    (each image once). Over the budget it drops the least recently viewed frames' display
    images (all three); never viewed counts as viewed at load time. The cursor frame and
    the two before and after it in sidebar order are never dropped. Thumbnails, metrics,
    headers and recipes stay.
  - `ImageStore()` defaults to "keep all"; only the app sets the budget from the setting. So
    the CLI, `--render`, `CLIRenderer`, the render tests and the existing unit tests behave
    as now.
  - Viewing a frame without a display image: `MainContent` shows its thumbnail enlarged to
    the display size (blurry for a moment, answer 3a) and the pipeline renders it again.
    The cursor's neighbours (±2) are rendered ahead. One owned task with a generation check:
    a result for a frame that was rendered meanwhile, or whose recipe changed, is dropped;
    frames being processed by a batch are skipped.
- **1c — features that use the images in memory.**
  - Thumbnail-size change: frames without a display image are read and rendered again for
    their new thumbnail (the image is then subject to the budget like any other).
  - Colour toggle: frames whose other render was dropped are rendered from their files, as
    for frames that never had one (the existing paths already do that). Found in 1a: the
    grey path of the toggle (`renderBayerEntriesInGrey`) renders a frame without a cached grey
    image *without* the Bayer pattern: unbinned, so up to twice the size of the load's grey image.
    Today it hardly runs (Phase A always caches the grey image); with dropped images it would,
    so 1c renders such frames from their stored grey recipe instead.
  - Playback: the frame ahead is rendered ahead; above the budget a frame can show the
    placeholder briefly (answer 4).

**Behaviour changes, only above the budget** (at 50 % on 16 GB: only M81 colour at 4096 of
the step 0 sets): placeholder when jumping to a dropped frame; a thumbnail-size change and a
colour toggle read files; playback can show a placeholder. Below the budget nothing changes.
Not covered by the budget: the brief load peak (1.3–1.4 GB above the end value for M81).

**Performance / Metal:** existing kernels, no new ones. Memory: at most the budget for display
images. Time: unchanged below the budget; above it, one file read + render per frame shown
(to measure in 1b: SSD and network). Checks per commit: unit tests, render tests --full,
10 metric baselines, strict build; after 1b/1c a step-0 style memory run (M81 colour 4096
at 50 %) and the VM run.

**Answers (Tom, 2026-10-30)**
1. A dropped frame that can't be read again (file moved outside the app, share disconnected)
   keeps its enlarged thumbnail, **dimmed**, with "Couldn't read the file again" in the info
   bar; the next visit tries again.
2. Read ahead **in the direction of travel** (for example 8 ahead and 2 behind, within the
   budget) instead of two on each side. The depth is set in 1b from measurements: redraw
   throughput at 4096 from the SSD and over the network, and the cursor rate with key repeat
   held (Tom: about 11 fps, so ≈ 91 ms per frame). Over the network (≈ 110 MB/s, ≈ 49 MB per
   M81 frame, ≈ 2 frames/s) no depth keeps up with sustained key repeat; there the (undimmed) enlarged
   thumbnail shows until the frame arrives.

Go-ahead for 1a: 2026-10-30.

**Status (2026-10-30):** 1a committed (bba3672), with a separate fix found on the way:
colour images now follow a new display size (08cb6c2). 1b committed (4588e8b; slider in its own
"Memory" section, Tom tested a build). 1c committed (98006fd): thumbnails of dropped frames from their files,
the grey toggle path binned via its recipe, the read-ahead triggered by `ImageStore.selectedEntry`
so playback is covered. Part 1 measured: M81 colour at 4096 with the 50 % limit holds 8.0 GB of
display images instead of 11 GB; no consistent load-time difference; at 1024 nothing changes.
Redraw at 4096 from the SSD: 2 at a time ≈ 32 frames/s (colour), so 8 ahead / 2 behind.
Part 1 is complete. Part 2 started 2026-10-31 with the cache/order experiment (a temporary
switch, not committed): the next folder's Phase A waits for the previous folder's colour render
and grey normalisation.

### 9f part 2 plan (2026-10-31) — fewer reads

**Experiment results (2026-10-31).** Temporary switch: a folder's Phase A starts only after the
previous folder's Phase A, colour render and grey normalisation are done. Cache flushed before
every run, the two orders alternated, 2 rounds each.

| Set | Order | Load time | Read |
|---|---|---|---|
| M81, 3 nights, 355 colour frames, 17.6 GB, SSD | current | 16.9 / 15.5 s | 1.98× / 1.95× |
| | folder by folder | 16.4 / 15.7 s | 1.81× / 1.80× |
| Rosette large, 464 mono frames, 7.4 GB, SSD (8 folders) | current | 11.6 / 9.5 s | 1.71× / 1.67× |
| | folder by folder | 10.6 / 9.7 s | 1.00× / 1.02× |
| Rosette large, share, wired (24 folders, R/G/B subfolders) | current | 111.7 / 109.7 s | 1.71× / 1.71× |
| | folder by folder | 66.3 / 71.1 s | 0.97× / 1.05× |

- Mono: the grey pass runs after the whole load today, when about 70 % of the files have left
  the file cache. Per folder, each folder is still cached: one read, −37 % load time over the
  network, the same time on the SSD.
- Colour: the order hardly matters. In the timeline the 3.4 GB night renders in colour without
  disk reads, the 6.9 and 6.8 GB nights read again at about 2.5 GB/s although nothing else ran
  meanwhile. On this 16 GB Mac (file cache ≈ 7.5 GB) a folder of ≈ 7 GB read once does not stay
  cached; the exact limit is not known. Typical nights are that size, so colour needs (a′).
- The files are read with plain `pread` (no `F_NOCACHE`), so the cache is not bypassed.
- Mono folders the size of a colour night (≈ 7 GB) would miss the cache too; 2a helps folders
  that fit, (a′) for grey (question 3) would cover the rest.

**2a — grey normalisation per folder (behaviour change, small)**
- In `processParallel`, at each folder boundary (to check first: entries arrive grouped by folder
  from every open path; if not, group them in sidebar order before Phase A): wait until
  the folder's Phase A is done, then run `normalizeGreyStretch` for that folder before the next
  folder's Phase A starts, as measured. The pass after the whole load goes.
- Colour folders (Colour on) keep today's order: their colour render stays a separate task, the
  next folder does not wait for it (the experiment showed no gain).
- Phase B (star detection) keeps running across folders; it does not read files.
- What Tom sees: a mono folder gets its shared stretch while the next folder loads, instead of
  every frame at the end. Final images byte-identical (same clips, same kernel), metrics untouched.
- Cancel: no grey pass starts after Cancel (as now); a folder already in its pass finishes.
- Tests: a unit test that a two-folder mono load gives every frame the shared-grey recipe and the
  same pixels as today's end-of-load pass; render tests --full; metric baselines; the SSD and
  network measurement above repeated with the real code.

**2b — colour from a kept proxy within a budget (a′ with budget)**
- Kernel split in `FITSStretch.metal`:
  - `bayerAverage`: the first half of `bayerDebayerAndStretch` (footprint, flip, per-channel box
    average), writes R, G, B as float32 per output pixel (12 B/px: 8.4 MB at 1024, 134 MB at 4096).
  - `bayerStretchFromAverage`: reads the floats, `stretchByte` per channel with the shared clips,
    writes RGBA as now.
  - The fused kernel stays for the paths that still read the file (colour toggle, part-1
    redraws, `renderAgain`), so those don't change.
- **2b-0, first: prove byte identity.** `MTL_FAST_MATH = YES`, so the compiler may reorder the
  arithmetic across the point where the kernel is split. A test renders every Bayer frame of the
  render-test sets both ways at 1024, 2048 and 4096 and compares the bytes. If they differ:
  stop and come back with the options (for example `stretchByte` made non-reorderable in both
  kernels, which would change today's renders and needs agreement).
- Phase A (Colour on, Bayer frame): after the grey render, while the frame is still in its Metal
  buffer, `bayerAverage` runs if the proxy fits the budget; the proxy is kept off the main actor in
  a small `ColourProxies` actor (key: entry ID, with the display size and Bayer pattern), not on
  `ImageEntry`.
- Folder colour render: a frame with a proxy is stretched from it (no file read) and its proxy
  is dropped at once; a frame without one is read as today.
- Budget: the sum of all proxies kept (several folders may overlap). A frame whose proxy doesn't
  fit gets none; it is re-read, as now. See question 2 for the size.
- Proxies are dropped on Cancel, Reset, a display-size or colour change during the load, and
  when the batch ends, so none outlive the load. A rejected frame (file moved) keeps its proxy:
  the pixels are the same.
- CPU fallback: there is no CPU colour path today (§5.17); without Metal no proxies are made
  and nothing changes.
- Tests: byte identity (2b-0); budget accounting (fits, doesn't fit, released on Cancel/Reset and
  at the end); a load with a too-small budget gives the same images as with a large one; render
  tests --full; metric baselines; memory peak (step-0 style run) at 1024 and 4096; reads and
  time, alternated with today's build: M81 17.6 GB from the SSD and from the share.
- Performance and Metal: Phase A gets one extra small dispatch per colour frame (the averaging
  that the second pass does today, now without the read); the folder colour render becomes a
  cheap pass over the proxies. Expected: the second read goes for frames whose proxy fits; the
  gain is largest over a network (step 0: 283 s for the 17.6 GB set against 157 s for a plain
  read). To be measured, not promised. Memory: temporarily up to the budget during a load.

Answers (2026-10-31): 1 yes; 2 (a), a fixed share (¼ of the Mac's memory), no setting; 3 later.
Go-ahead for 2a: 2026-10-31.

**Status (2026-10-31):** 2a committed (Tom tested a build): frames grouped by folder first (a scan can mix a
folder's files with a subfolder's), mono folders decided from the frames already read at the
boundary; the last folder and undecided ones keep the pass after the load. SSD against the build
before: 9.2/9.2 s and 0.96/1.01× read, against 9.5/9.8 s and 1.60/1.57×. Share, wired: 67.0/72.2 s and
0.98/1.06×, against 107.7/108.5 s and 1.69×.

2b-0 (2026-10-31): kernels `bayerAverage` and `bayerStretchFromAverage` added (the fused kernel
unchanged); `ColourProxyIdentityTests`: 640 renders of the 160 render-test colour frames (1024, 2048,
4096 with the folder's clips; 1024 with their own) byte-identical. 2b can go ahead as planned.
2b (2026-10-31): built as planned, with one change: the proxy is a `Sendable` copy in memory of its
own (`mmap`), not an `MTLBuffer` (not `Sendable`) and not a Swift array (the allocator kept the freed
blocks: 514 MB after an M81 load at 1024). M81 colour from the SSD: 16.9–17.1 s and 1.00× read
against 24.0–24.7 s and 1.86× (2a); peak memory at 1024 3.5 GB against 2.6 GB, the same after the load.
Share, wired: 159.3/162.7 s and 1.06× against 286.6/286.5 s and 1.91× (plain read: 157 s).
2b committed after Tom's test. On the way a separate bug was found and fixed (8046657): a Reset kept
every frame alive through the stored sidebar lists of 9b (M81 at 4096: 11 GB after a Reset, now 111 MB).
Part 2 is complete; `Step0MemoryTests.swift` (temporary, never committed) can be deleted.

**Order:** 2a, then 2b-0; 2b only if 2b-0 shows identical bytes. Each with its own commit,
the temporary switch removed in 2a, `Step0MemoryTests.swift` deleted after 2b.

**Questions for Tom**
1. 2a: is the per-folder stretch during the load (instead of at the end) fine as a behaviour change?
2. 2b budget: (a) a fixed share of the Mac's memory, e.g. 1/4 (4 GB on 16 GB: 1.2 GB per
   140-frame night at 1024, ≈ 120 frames at 2048), no setting; or (b) inside the memory slider's
   limit together with the display images (one number, but proxies and display images then
   compete). Proposed: (a).
3. Grey proxies for mono folders too large for the cache (same mechanism with `mtfStretch`):
   now in 2b, or later only if a real mono session shows the second read? Proposed: later.

**Tests**: memory and time with `BenchmarkTests` before and after; render tests (use "keep all"); a test that the LRU re-renders on selection.

**Performance and Metal**: this step is about performance; target numbers are set at the start from a baseline measurement. No kernel changes.

**Risk**: medium-high. 👤 Checks: fast scrolling through a large session, switching colour and grey, the zoomed viewer after jumping far.

---

## Before 1.24-beta.3 (2026-10-31) — four items from the notes

Chosen by Tom from the later-items list. Each its own commit, in this order.

**B1 — star counts reproducible again (investigation first)**
- m31-night frame `…#0026.fits` gives 3371–3373 stars over identical runs (found during 9e,
  also with the 9d build); 1.23.1 fixed this (random tie order in the star sort).
- Bisect the 51 commits since v1.23.1 in a separate worktree, so the working tree stays free:
  first confirm v1.23.1 gives one value in 10 CLI runs and HEAD doesn't, then about 6 bisect steps,
  10 runs per build (a CLI run of m31-night takes a few seconds).
- Then a fix plan with the cause, and its own go-ahead: a metric change only if the values
  themselves change (they should not: the goal is the same value every run). `testing.md`
  corrected in the same commit.

**B1 findings (2026-10-31).** Not a regression: v1.23.1 varies too (3372/3373 over 10 runs;
HEAD 3371–3373), so no bisect. Cause: the GPU detection kernel stores at most 50,000 candidates
(`maxDetectionCandidates`); #0026 has 50,455 local maxima above the threshold, and which 50,000 are
stored depends on the GPU's thread order (10 runs: 9 different sets). All other baseline frames stay
under the cap; the densest: ASI294MM SHO 46,213, M42 36,917, California 24,706. Dense or noisy frames
of other sessions can pass it, so users can meet this too.

**B1 fix (proposed):** when the counter says more maxima were found than stored, run the kernel once
more with room for exactly that many (the count is the same: same data, same threshold). Frames
under the cap: no change, no extra cost. Over it: one extra pass (a few ms) and 8 bytes per
candidate, and every candidate is used, so the result is the same every run. Metrics change only
for frames over the cap (in the baselines: #0026, within its tolerance). The CPU path has no cap.
Tests: a synthetic frame with more maxima than a test cap gives the same candidates every run
(the cap made injectable for the test); 10 CLI runs of m31-night identical; render tests; baselines.
`testing.md` corrected (results reproducible again, and why they weren't); the baselines script's
tolerance note ("stars vary slightly between identical runs") updated. Whether to tighten the
stars/PSF·S tolerances afterwards: a question for Tom, not part of the fix.
Done 2026-10-31 (Tom: build it; update the m31-night baseline, 3373 → 3389, the only value that
changed across the 10 sets; tighten the tolerances afterwards as a separate step).

**B2 — Settings window follows the appearance setting**
- `Window("Settings")` (`FitsBlasterApp.swift:143`) lacks the `.preferredColorScheme` the main
  window has (`ContentView.swift:30`). Add it there.
- Check by eye (Light, Dark, System with the Mac in both), also in the App Store build where it
  was seen. No test: SwiftUI scene modifier.

**B3 — zoom and pan shortcuts**
- Zoom in / zoom out in steps of ×1.25 (the slider's range 0.25–4× stays), centred on the zoom
  anchor if set, otherwise on the view's centre (`adjustScroll`, as the slider does). Zoom to fit
  and 1× (actual size).
- Pan: moves the view by a quarter of the visible area per press; key repeat keeps it moving;
  nothing happens when the image fits.
- Proposed default keys, following Preview: ⌘+ (also ⌘=) zoom in, ⌘− zoom out, ⌘9 zoom to fit,
  ⌘0 1×; pan with ⌥ + arrow keys (the plain arrows stay for frame navigation).
- Configurable in Settings → Interface like the other ⌘ shortcuts (`cmdKeyBindings`), and listed
  in a View menu group with their keys, so they can be found.
- `ImageViewer` keeps its scroll position as view state; the shortcuts send requests through
  `ViewerState` (as `fitToContainerTrigger` does now). The zoom maths (next step, clamp, pan
  offset within the image) in a small tested helper.
- Tests: the helper (steps, clamps, pan limits at the edges, no pan when the image fits); a
  key-dispatch test for the new bindings; by eye in the app.

**B4 — Open Folder with several folders**
- `NSOpenPanel.allowsMultipleSelection = true`; the two checkboxes apply to every folder chosen.
- One folder: exactly as now. Several: the drag-and-drop path (a sidebar section per folder),
  extended with the REJECTED checkbox (drops never include REJECTED today).
- Folders already in the session: one question naming them ("Open Anyway" / "Skip those").
- Tests: opening two folders gives two sections with the right root names; with REJECTED on,
  the rejected frames of each folder are marked; an already-open folder is asked about once.

**Questions for Tom**
1. B3 keys: the proposed defaults (⌘+/⌘−/⌘9/⌘0, ⌥+arrows), configurable, in a View menu — fine?
2. B3 pan step: a quarter of the visible area per press — fine, or another amount?
3. B4: several folders where some are already open — one question for all of them, as proposed?

Answers (2026-10-31): 1. plain keys, no ⌘: `=` (and `+`) zoom in, `-` zoom out, `0` zoom to fit,
`9` 1×; ⌥ + arrow keys pan. None of them is bound by default (checked; ⌥ keys never reach the plain
bindings). Configurable, conflicts shown in Settings as for the other keys. 2. A single press pans
a quarter of the visible area; held down (key repeat) much smaller steps, proposed 1/20 of the view
per repeat (about half a view per second at the default repeat), tuned by eye. 3. Yes, one question.

## Step 10 — View logic into tested helpers; accessibility

**Changes**
- **View logic** (§8.9):
  - `SessionChartData` takes the chart points, medians and y-range (whatever step 9 didn't already move);
  - `KeyDispatcher` maps a key and modifiers to an action, with **one key-binding mapper** for the key monitor, the recorder and the menu shortcuts (key-mapping part of §9.11);
  - the header-key discovery is already shared since step 4.
- **Auto-Reject sheet** (AutoRejectSheet part of §9.15): one generic threshold section driven by a table next to `AutoRejectConfig`, instead of seven copies.
- **Accessibility** (§8.2): every thumbnail is one VoiceOver element labelled with file name, filter, score, flagged and rejected; the main image is labelled; flag and rejected state have a non-colour cue.

**Tests**: `SessionChartDataTests`, `KeyDispatcherTests` (every bound key, shift variants, text fields ignored); 👤 a VoiceOver pass over the sidebar.

**Risk**: low-medium.

---

## Step 11 — Reject and undo file operations

**Changes**
- One `RejectedFolder` helper for the folder name, the "is rejected" test, the original-URL derivation and the rejected-URL list. Used by the app and the CLI (§9.8).
- Batch reject and undo (§5.14):
  - file moves run off the main actor, and the URL updates are applied back on it;
  - visibility is rebuilt once at the end;
  - failures are collected into one message ("3 of 40 could not be moved: …").

**Tests**: batch reject with one locked file gives a summary naming that file; undo puts every file back; app and CLI agree on which files are rejected.

**Risk**: medium (moves user files). 👤 Checks: reject/undo of many frames on a local disk and on SMB.

---

## Step 12 — CLI

**Changes**
- One-pass argument parsing. Flag values are consumed; the remaining argument is the folder, relative or absolute (§5.10). `main.swift` uses the same rule to decide CLI mode.
- Unknown flags and bad values give a usage error. Files that fail to load are listed on stderr. Exit codes are documented in `--help` (§5.12).
- "No frame passes the filter" (§5.11, decision 6): a CSV with only the header row and its own exit code, documented in `--help`.
- CLI option duplication (CLI part of §9.11 and of §4.4): `AutoRejectConfig.allDisabled` and a public `anyEnabled`, one mode parser, and a shared path-expansion helper using URLs instead of `expandingTildeInPath`.

**Tests**: a CLI argument-parsing test file; extend `vm-smoke-remote.sh` with `-o` before the folder, a relative folder and an unknown flag.

**Risk**: low. **Behaviour**: scripts that relied on unknown flags being ignored now get an error. That is intended.

---

## Step 13 — Behaviour changes (need decisions)

All decided on 2026-10-20 (see "Decisions").

- **Frames with no stars** (§5.4, decision 4: yes): return metrics with star count 0 and score 0, so Auto-Flag and the CLI filters can reject them. Do this together with the "score ignores cloudy frames" investigation (memory note; same root cause area). Changes CSV output and the metric baselines: regenerate them in the same commit and say so in the CHANGELOG.
- **Small groups** (§5.16, decision 5): true median for even counts; relative checks skipped for groups under 3 frames.
- **Colour spaces** (§4.5, decision 8: yes): named sRGB / grey spaces instead of device spaces. Changes rendered pixels: update the render-test targets and check `TARGET_LEVEL` / offsets in the smoke test.
- If step 8 or 9 chose to unify grey and colour statistics or accept render differences, those changes land here too.
- **Input, not decided yet** (2026-10-23, [FWHM-comparison set 3](FWHM-comparison.md)): on colour (OSC) frames the background σ includes the R/G/B sky spread, which raises the detection threshold and lowers SNR and PSF Signal Weight more the longer the exposure; and saturated stars are missed (METAL_REVIEW M3). Possible fixes: background and σ per Bayer channel, and counting a saturated top as one star. Both need a decision before they join this step.

**Tests**: updated baselines and render targets, reviewed by eye before committing.

---

## Step 14 — Configuration, security and release tooling

**Changes**
- Quick Look entitlements: only `app-sandbox`; drop `ENABLE_USER_SELECTED_FILES` for those targets (§6.1).
- Direct-build entitlements: remove the sandbox-only keys (§6.3).
- App Store build: strip the `SU*` Sparkle keys from its Info.plist, with a separate plist or a build-phase step (§6.4). Do it after build 202 is approved, not during review.
- FITS type moved to `UTImportedTypeDeclarations` (§6.5).
- Sparkle: delegate marked `@MainActor`, one key constant, Check for Updates disabled while a check runs (§4.6).
- Release scripts (scripts part of §9.11): `build-release.sh` calls `build-dmg.sh` instead of copying it; shared Python helpers in `scripts/_common.py`; `make-dmg-background.swift` without `lockFocus` (script part of §4.4).

**Tests**: notarised beta build through `vm-test-all.sh` (Gatekeeper, Sparkle update check against the beta feed); App Store archive validates in Xcode; Quick Look still works.

**Risk**: medium (signing and entitlements). One change at a time, each checked in a VM.

---

## Step 15 — Feature folders, naming, constants

**Changes**
- Move files into feature folders with `git mv` (no code change). The Quick Look `membershipExceptions` paths are updated in Xcode's target membership panel. Proposal (final list at the start of the step, after the new files of steps 4–12 exist):

```text
FITS Blaster/
  App/          FitsBlasterApp, main, MenuCommands, FocusedAction, ContentFocusedValues, UpdaterDelegate
  Session/      ImageStore, ImageEntry, FilterGroup, FolderGroup, RejectionVisibility, ThumbnailSortOrder, ImageStoreFileOperations, RejectedFolder
  Loading/      LoadPipeline, FrameLoading
  Viewer/       ViewerState, ImageViewer, ImageAdjustControls, PlaybackControls, ZoomAnchorIndicator, RejectionOverlay
  Sidebar/      SidebarViews, ThumbnailCell, FolderSectionHeader, FilterGroupHeader, FilterChip, WrappingChips
  Chart/        SessionChartView, SessionChartData, ResizableChartLayout
  Inspector/    InspectorView, HistogramView, QualityBadge, TooltipView
  Export/       ExportSheet, ExportFormat, PathStyle, FileDialogs, header-key catalogue and picker
  AutoReject/   AutoRejectSheet, AutoRejectConfig
  Settings/     AppSettings, SettingsView, ExportSettingsTab, KeyRecorderView, KeyDispatcher, AppearanceMode, AppFont, TargetBackgroundControl, UserDefaultsHelpers
  Engine/       FITSReader (split), BayerPattern, ImageStretcher (split), FITSStretch.metal, MetalContext, MetricsCalculator (+ extensions), FrameMetrics, Metric
  CLI/          CLIRunner, CLIRenderer, RenderedPixels
  Layout/       ContentView, ContentSplitLayout, MainContent, FITSToolbar
```

- Naming (§9.15): one spelling for identifiers (British, matching the UI). UserDefaults key strings stay unchanged for compatibility. `ExportPanel.swift` → `ExportSheet.swift`. `MetricsConfig`, `GroupStats` and `BadgeProblem` get their own files.
- Remaining constants (sizes, timings, URLs; rest of §9.14): `DisplayDefaults`, `AppLinks` (stable feed URL read from Info.plist), named timings.
- Remaining small duplicates (rest of §9.11): one main-window lookup, one text-size table, shared quality thresholds for badge and Auto-Reject defaults.

**Risk**: low for the code; check both Quick Look targets, `release.yml` and `scripts/build-beta.sh` for hard-coded paths. Clean build of all configurations and both extensions.

---

## When

1. App Store build 202 approved → tag v1.23 (204) → merge `colour-fix` into `main` → release 1.23.1-beta.1 (205). Done 2026-10-20.
2. Then this plan on a new branch `architecture` from `main`.
3. Step 1 goes first and ships on its own as 1.23.1-beta.2 (decision 1).

---

## Decisions

Answered by Tom on 2026-10-20 (the earlier open questions, same numbers):
1. **Step 1 timing:** early. Step 1 ships on its own as **1.23.1-beta.2**, before the rest of the plan.
2. **Second folder during a load:** queue it (as planned in step 6).
3. **Swift 6 mode:** yes, as a separate commit at the end of step 7.
4. **§5.4** frames with no stars: yes, star count 0 and score 0, so they can be rejected (step 13, with the "score ignores cloudy frames" investigation).
5. **§5.16** small groups: true median for even counts, and relative checks skipped for groups under 3 frames (absolute checks still apply) (step 13).
6. **§5.11** CLI when no frame passes: write a CSV with only the header row and exit with its own exit code, documented in `--help` (step 12).
7. **§7.2** fewer reads: (a), a display-size proxy per frame; confirmed with a measurement at the start of step 9. **Reopened 2026-10-29:** a proxy kept per frame costs more memory than the display image; see the 9f proposal in step 9.
8. **§4.5** colour spaces: switch to named sRGB / grey spaces (step 13, render targets updated and checked by eye).
9. **§9.11** export column order: the order chosen in Settings → Export, also in the Export sheet (step 4).
10. **§9.6** grey and colour statistics: keep their current differences as explicit parameters; no render change (step 8). Making them the same is not planned.

Still assumed from the concurrency plan (not asked again):
- Cancel also stops a colour re-render (its question 2).
- The drop handler (its question 4): try `dropDestination` first, keep `onDrop` as fallback.
- `reprocessAll` and `openFilesPanel`: removed in step 3.

**Release split:** a beta after each group. Step 1 as 1.23.1-beta.2. Steps 2–15 are version **1.24** (decided 2026-10-23): 1.24-beta.1 after steps 2–3 (build 210), then a beta after steps 4–7, 8–9, 10–12 and 13–15, and stable 1.24 (with an App Store build) at the end.

---

## Finding → step

Every audit finding, exactly once. "a/b" marks a finding split between two steps, with the part named.

| § | Step | § | Step | § | Step | § | Step |
|---|---|---|---|---|---|---|---|
| 3.1 | 6 | 5.1 | 1 | 6.1 | 14 | 8.1 | 5 |
| 3.2 | 6 | 5.2 | 1 | 6.2 | 4 | 8.2 | 10 |
| 3.3 | 7 | 5.3 | 1 | 6.3 | 14 | 8.3 | 2 |
| 3.4 | 6 | 5.4 | 13 | 6.4 | 14 | 8.4 | 2 |
| 3.5 | 6 | 5.5 | 2 | 6.5 | 14 | 8.5 | 9 |
| 3.6 | 6 | 5.6 | 2 | 7.1 | 9 | 8.6 | 5 |
| 3.7 | 8 | 5.7 | 4 | 7.2 | 9 | 8.7 | 2 |
| 3.8 | 8 | 5.8 | 2 | 7.3 | 8 | 8.8 | 2 |
| 3.9 | 6 | 5.9 | 2 | 7.4 | 4 | 8.9 | 10 |
| 3.10 | 7 | 5.10 | 12 | 7.5 | 5 (a: header facts) / 9 (b: sidebar and chart arrays) | 9.1 | 3 |
| 3.11 | 7 | 5.11 | 12 | 7.6 | 6 | 9.2 | 3 |
| 4.1 | 7 | 5.12 | 12 | 7.7 | 9 | 9.3 | 3 |
| 4.2 | 4 | 5.13 | 4 | 7.8 | 8 | 9.4 | 8 |
| 4.3 | 4 | 5.14 | 11 | 7.9 | 8 (unused `device` parameter: 3) | 9.5 | 8 |
| 4.4 | 4 (file operations) / 12 (CLI) / 14 (script) | 5.15 | 2 | | | 9.6 | 8 |
| 4.5 | 13 | 5.16 | 13 | | | 9.7 | 1 |
| 4.6 | 14 | 5.17 | 8 | | | 9.8 | 11 |
| 4.7 | 2 | 5.18 | 1 | | | 9.9 | 6 |
| | | 5.19 | 1 | | | 9.10 | 3 |
| | | 5.20 | 1 | | | 9.12 | 8 (engine splits) / 15 (folders) |
| | | | | | | 9.13 | 3 |
| | | | | | | 9.14 | 6 (concurrency caps) / 8 (engine tunables) / 15 (rest) |
| | | | | | | 9.15 | 10 (Auto-Reject sections) / 15 (naming, files) |

**§9.11 by part:** test fixtures → 1; FITS extension list, export columns, CSV quoting, default export keys, header-key picker → 4; header cleaning, `BayerPattern.parse` → 5; visibility/grouping/median → 9; Quick Look read-and-stretch → 8; key mapping → 10; CLI options → 12; release scripts → 14; main-window lookup, text-size steps, badge thresholds → 15.

**[PERFORMANCE_AUDIT.md](PERFORMANCE_AUDIT.md)** (findings 1–6, called P1–P6 here): P1 → 5 (the cell part is §8.1, also in step 5); P2 → 5 (header re-parsing, §7.5a) / 9 (grouping, §7.5b / §8.5); P3 → 9; P4 → 5; P5 → 5; P6 → 9, only if a trace confirms it. Its metrics table is the before/after measurement for steps 5 and 9.

**Audit §10 (cross-cutting):** 1 untrusted input → step 1; 2 one owner for batch work → step 6; 3 header facts once → step 5; 4 shared engine core → step 8; 5 VM checks of what users see → step 1.

**Conflicts resolved in this version:**
- **TestFITS helper:** the test-fixture helper is created in step 1 (needed for the malformed-input tests); step 6 uses it instead of creating it.
- **Dead code:** `reprocessAll` and `openFilesPanel` are removed in step 3, no longer in the dialog and pipeline steps.
- **`MainContentViews.swift`** is deleted in step 3, so it no longer appears in the folder proposal.
- **Byte-identical rule vs behaviour changes:** every change that alters renders or metrics (§4.5, §5.4, §5.16, a possible §9.6 unification or §7.2 difference) is in step 13, which updates targets on purpose; all other steps keep the rule.
- **§7.1 vs the CLI and render tests:** the display-image LRU keeps a "keep all" mode for the CLI and the render tests.
- **§7.2 vs §7.3:** keeping full buffers to avoid re-reads would raise memory; the plan prefers the display-size proxy, decided by measurement.
- **§5.8 vs step 6:** step 2 fixes the matching rule; step 6 moves the snapshot inside the batch and keeps the rule.
- **§6.4 timing:** after App Store approval, not during review.
- **Header facts (§7.5a) moved from step 9 to step 5** (2026-10-18, after trace 1). Step 6 moves the header-setting code and keeps the stored values; step 9 keeps the array work (§7.5b).
