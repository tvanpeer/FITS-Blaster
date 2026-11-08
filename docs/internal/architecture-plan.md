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

### Step 10 plan (2026-11-05)

Agreed by Tom on 2026-11-05. Four parts, one commit each. No engine code changes, so renders and metrics stay byte-identical. Performance: no measurable effect (a table lookup per key press; the chart helpers do today's work in another place).

**10a — chart logic into `SessionChartData`.** The y-axis range (`yAxisDomain`), the dot style (cursor, dimmed, rejected) and the conversion of a tap or drag position to frames move out of `SessionChartView` into `SessionChartData`. The y-range is computed once with the data instead of on every body pass. VoiceOver (Tom, 2026-11-06, after a test): Swift Charts bundles the dots into ranges, so per-dot labels never reach VoiceOver; instead the chart is one element with a summary (frames, median, lowest, highest) and an audio graph (`AXChartDescriptor`) with one point per frame (file name, frame number, value), and the click layer is hidden from VoiceOver. Tests: `SessionChartDataTests` (the existing chart test moves there).

**10b — `KeyDispatcher` and one key-binding table.** Today the list of shortcuts exists four times (ContentView's tables, Settings' conflict lists, the menu items with 12 focused values, the recorder) and key strings become `KeyEquivalent`s three ways.
- `KeyBinding.all`: one row per action (label, key path to the key, ⇧ key path for ⌘ shortcuts, plain or ⌘); one special-key mapping (↑ ↓ ← → ⇱ ⇲); `KeyEquivalent.fromSetting` as the only `KeyEquivalent` builder.
- `KeyBindings`: a `Sendable` value with every key and ⇧ flag, the dispatcher's input and the one focused value for the menus.
- `KeyDispatcher.action(for:bindings:)`: pure; the order of checks stays as it is (system shortcuts, text field, ⌘(⇧), ⇧ + previous/next, ⌥ + arrow, no other modifiers, plain keys and the "+" alias). Kept as they are: ⇧ + a plain key does its plain action; Undo in toggle-reject mode lets the key through.
- ContentView keeps the window check and carrying out the actions. Settings keeps its hand-written rows; the conflict lists come from the table. The recorder keeps its own rules and uses the shared special-key mapping.
- **Behaviour change (Tom: yes):** menu items bound to an arrow, Home or End key show the right glyph; they showed the first character only.
- Tests: `KeyDispatcherTests` (every row with default and changed keys, ⇧ variants, extend selection, pan, other modifiers, text field, ⌃⌘F, "+" alias, table complete and without duplicates).

**10c — Auto-Flag sheet.** `AutoRejectThreshold.all` next to `AutoRejectConfig` drives one generic `ThresholdSection` instead of seven copies; texts, ranges and steps unchanged. The preview count is computed when the settings change instead of in `body` (Tom: yes). Tests: `AutoRejectThresholdTests` (every check once, defaults inside their range and on a step, value texts as today). Details agreed 2026-11-07: the sheet can be open during a load, so the count is also refreshed every 250 ms while a batch runs and once when it ends (as the session chart); Flag still uses a fresh preview. Also in 10c (issue #12, a user setting, not a bug): the note under Settings → Session Chart Brightness said rejected dots are only dimmed with a flagged set; new text: "Rejected frames are always drawn at the first brightness, also when flagged or selected. Non-flagged frames are dimmed only while some frames are flagged. Flagged frames and the current frame are otherwise at full brightness."

**10d — accessibility.**
- Thumbnails: one label from a pure function (file name, filter, score, badge problem, flagged, rejected, flipped, processing / could not load); `.isSelected` for the cursor and the orange range selection.
- Main image: "Frame, <file name>" plus flagged / rejected; label only, no new visible marker (Tom).
- Non-colour cues only when macOS "Differentiate without color" is on (Tom): a ★ in top-third badges and a dashed outline for the orange selection. Flagged (checkmark), rejected (✕), badge problems (icon) and rejected chart dots (faded) already have one.
- Session chart (added 2026-11-07, Tom): with Differentiate without color on, every filter group gets its own dot shape, fixed per filter (8 solid built-in shapes + 5 outlines = 13): L circle, R square, G triangle, B diamond, Ha pentagon, OIII plus, SII cross, Hβ asterisk, HO / SO / SHO / Quad-NB / Unfiltered the outlined circle / square / triangle / diamond / pentagon. Dots drawn larger while the setting is on (about 50 instead of 28, cursor 70 instead of 40; tuned by eye), the legend shows the same shapes. Bar mode unchanged; with the setting off nothing changes. Test: all 13 shapes different. Colours (Tom, 2026-11-07, after before/after renders incl. simulated protanopia): while the shapes are shown, dot and legend colours with less than 6:1 contrast against the window background are lightened (dark mode, #1E1E1E) or darkened (light mode, white), keeping their hue (`FilterGroup.chartColor`); test: every colour at least 6:1 in both modes. Later item (not 10d): today's light-mode colours are weak for everyone (SO, Quad-NB 1.8:1 on white).
- Added during the test (Tom, 2026-11-08): the cursor dot is drawn in the text colour (it was white, invisible in light mode); folder headers read "Folder B, 20 frames, expanded/collapsed" and filter headers "Filter L, 12 frames, median FWHM 3.2 pixels, median score 72" (marked as headings); fix: the chart reads the bar/dot setting, the brightness settings and the flagged set outside the Chart builder, so switching bars ↔ dots redraws at once (before: only after a theme change; the same code was in beta.4).
- Tests: `FrameAccessibilityTests`; 👤 a VoiceOver pass over the sidebar and the main image, and a look with Differentiate without color on.

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

### Step 11 plan (2026-11-08)

Agreed by Tom on 2026-11-08. Two parts, one commit each. No engine code changes, so renders and metrics stay byte-identical; Metal not involved.

**11a — `RejectedFolder` (§9.8).** Plain functions, no app state: the folder name, `isRejectedFolder(name)` (case-insensitive, as now), `rejectedURL(for:)` (destination of a move), `originalURL(for:)` (the way back) and `rejectedURLs(in:)`. Used by the move, the folder scan, the load pipeline and the CLI (which already shares `ImageStore.rejectedURLs` with the app). No behaviour change. Tests: case variants, nested folders, both path directions, app and CLI pick the same files from a test tree.

**11b — batch reject and undo (§5.14).**
- One reject and one undo function for any number of frames, used by R, U, toggle-reject, the frame menu and the frames waiting for folder access. Folder access is started once per folder (`accessFolders(for:)`).
- **Single frames stay synchronous on the main actor, as today** (Tom: yes), so a quick second R always reaches the advanced cursor. Batches of 2 or more frames move off the main actor; the results are applied back by frame ID (a frame removed from the list meanwhile is skipped), the list is rebuilt once, empty REJECTED folders are removed once per folder.
- **A batch shows as rejected (or restored) when all its files have moved** (Tom: yes); then the cursor advances as today.
- **Progress** (Tom): a "Rejecting" or "Restoring" bar with "n / total" in the info bar, where the load progress bars are, not a separate window; below the load bars if a load runs at the same time.
- **Errors** (Tom: yes): one message, e.g. "3 of 40 frames could not be moved to REJECTED:", up to 5 lines "a.fits — <reason>", then "and N more". A single frame keeps today's text.
- The sandbox folder question (App Store build) works as today.
- The batch task is owned by `ImageStore`; frames being moved are in a set, and a second reject or undo of a frame still moving is skipped.
- Tests: 40 temporary files with one locked (immutable) file → the message names it and the other 39 move; undo restores every file and removes the empty REJECTED folder; a frame removed during the move; a second reject while moving.
- Performance: one list rebuild per batch instead of one per frame, one bookmark lookup per folder instead of per frame. One-off timing of a 500-file reject before and after.
- Measured 2026-11-08 (500 small frames, one-off test, not kept): local disk — main actor blocked 1.02 s (reject) / 1.33 s (undo) before, < 1 ms after, batch 0.17 s / 0.16 s; SMB (Astrofotografie) — frozen 38 s / 84 s before, < 2 ms after, batch 35 s / 33 s.
- Added during the test (Tom, 2026-11-08): short failure reasons (a file locked in Finder said "no permission to access REJECTED"; locked no longer counts as a folder-permission problem), also for a single frame; rejected frames sorted in by name with their folder's frames when a folder is opened (`FolderScanItem`), instead of after them.
- 👤 Checks: reject and undo of many frames on a local disk, on the external drive and on SMB (Tom's Mac Studio "Astrofotografie" volume).

---

## Step 12 — CLI

**Changes**
- One-pass argument parsing. Flag values are consumed; the remaining argument is the folder, relative or absolute (§5.10). `main.swift` uses the same rule to decide CLI mode.
- Unknown flags and bad values give a usage error. Files that fail to load are listed on stderr. Exit codes are documented in `--help` (§5.12).
- "No frame passes the filter" (§5.11, decision 6): a CSV with only the header row and its own exit code, documented in `--help`.
- CLI option duplication (CLI part of §9.11 and of §4.4): `AutoRejectConfig.allDisabled` and a public `anyEnabled`, one mode parser, and a shared path-expansion helper using URLs instead of `expandingTildeInPath`.

**Tests**: a CLI argument-parsing test file; extend `vm-smoke-remote.sh` with `-o` before the folder, a relative folder and an unknown flag.

**Risk**: low. **Behaviour**: scripts that relied on unknown flags being ignored now get an error. That is intended.

### Step 12 plan (2026-11-08)

Agreed by Tom on 2026-11-08. Two parts, one commit each. No engine code, so renders and metrics stay byte-identical (the metric baselines run through the CLI and also check the CSV); Metal not involved; no performance effect. App Store build unchanged (no CLI).

**12a — arguments (§5.10, §4.4, CLI part of §9.11).**
- `CLIArguments` (own file, pure, tested without running the CLI): one pass; each flag takes its value; exactly one argument is left, the folder, absolute, `~` or relative (to the current directory). `-m` may come after the thresholds.
- `main.swift` uses the same rule for CLI mode: an argument that is one of the CLI's flags (or starts with `--`), or a folder that exists. macOS's own arguments (`-NSDocumentRevisionsDebugMode YES`) still open the window.
- Usage error (exit 1, names the problem, points to `--help`): unknown flag, missing or non-numeric value, bad `-m`/`-P` value, no folder, two folders, `--score` in relative mode (Tom: error, was a warning).
- `~` and `~/…` expanded with `URL.homeDirectory` (`~otheruser/…` no longer); folder check with URL resource values instead of `ObjCBool`.
- Duplicates: the CLI's private `anyEnabled` → `AutoRejectConfig.isAnyCheckOn`; `AutoRejectConfig.allDisabled`; one `rel|relative|abs|absolute` parser for `-m` and `-P`.
- Done 2026-11-08: the CLI's Auto-Flag settings are built by `CLIArguments.autoRejectConfig` and the CSV filter is `CLIRunner.framesToExport`, out of `run`. CSVs checked byte-identical to the 11b binary on the Sh2 201 set (unfiltered, absolute and relative filters); the metric baselines pass.

**12b — results and exit codes (§5.11, §5.12).**
- `CLIRunner.run` returns an exit code; `main.swift` calls `exit` with it.
- Exit codes, documented in `--help`: 0 fine; 1 usage error or folder missing, unreadable or without FITS files; 2 CSV or renders not written; 3 no frame passes the filter (CSV with only the header row; decision 6); 4 CSV written but some files could not be read. Both 3 and 4: 3 (Tom).
- Files that could not be read (including the skipped floating-point stacks) are listed on stderr, up to 10 with the reason, then "and N more".
- A filtered run leaves files that could not be read out of the CSV, with a message saying so (Tom); an unfiltered run keeps them as rows without metric values, as now. Before, they passed the filter (no metrics to fail) and ended up in the keep-list.
- `--help`: exit codes and relative folders.
- Done 2026-11-08: the header-only CSV takes its columns from all frames, so a script sees the same columns. Broken file passing the filter confirmed on the 12a binary (10 rows for 9 frames, exit 0) before the change. CSVs byte-identical to the 12a binary in four normal cases on the Sh2 201 set.

**Tests**: `CLIArgumentsTests` (`-o` before the folder, relative folder, `-m` after thresholds, unknown flag, missing value, bad number, bad mode, two folders, no folder, `--score` relative, the CLI-mode rule incl. macOS's own arguments); `CLIRunTests` on temporary folders (no frame passes → header-only CSV, code 3; a broken file → listed, code 4, out of the filtered CSV with a message; a normal run gives the same CSV as before); `vm-smoke-remote.sh`: `-o` before the folder, relative folder, unknown flag (1), no frame passes (3).

**Site**: the FAQ's "must start with / or ~" goes on the FAQ list for stable 1.24.

---

## Step 13 — Behaviour changes (need decisions)

All decided on 2026-10-20 (see "Decisions").

- **Frames with no stars** (§5.4, decision 4: yes): return metrics with star count 0 and score 0, so Auto-Flag and the CLI filters can reject them. Do this together with the "score ignores cloudy frames" investigation (memory note; same root cause area). Changes CSV output and the metric baselines: regenerate them in the same commit and say so in the CHANGELOG.
- **Small groups** (§5.16, decision 5): true median for even counts; relative checks skipped for groups under 3 frames. **Done 2026-11-05:** group statistics only (badges, Auto-Flag and CLI relative mode, header, chart line); the stretch clip medians stay as they are (Tom, 2026-11-05: a true median there changes renders, the sample set too). Groups under 3 frames with stars skip every check against the median and the focus-fail and low-star badges; the Auto-Flag sheet and the CLI (stderr) name those groups. No test set has such a group; baselines and renders unchanged.
- ~~**Colour spaces** (§4.5, decision 8: yes): named sRGB / grey spaces instead of device spaces.~~ **Dropped 2026-11-05 (Tom):** colour accuracy is not a primary goal of culling, so renders stay on device spaces.
- If step 8 or 9 chose to unify grey and colour statistics or accept render differences, those changes land here too.
- **Input, not decided yet** (2026-10-23, [FWHM-comparison set 3](FWHM-comparison.md)): on colour (OSC) frames the background σ includes the R/G/B sky spread, which raises the detection threshold and lowers SNR and PSF Signal Weight more the longer the exposure; and saturated stars are missed (METAL_REVIEW M3). Possible fixes: background and σ per Bayer channel, and counting a saturated top as one star. Both need a decision before they join this step.

**Tests**: updated baselines and render targets, reviewed by eye before committing.

### 13a plan (2026-11-01) — background and noise per Bayer channel

Agreed by Tom on 2026-11-01 (after [FWHM-comparison set 4](FWHM-comparison.md)). Colour (Bayer) frames only; mono frames stay byte-identical.

**Problem**: `estimateBackground` takes one median and one σ (MAD) over the raw mosaic. In broadband light the R/G/B sky levels differ, and that spread counts as noise. The single σ sets the detection threshold (background + 5σ) and divides SNR and PSF·S. The single background also goes into the star fits and into the star-count check (`measureFWHMOnly`), whose 4 neighbours of a peak are pixels of another colour.

**Changes**
1. Background and σ (MAD × 1.4826) for each of the four positions of the 2×2 pattern, 5,000 samples each.
2. Detection: pixel minus its channel's background against 5 × its channel's σ; the local-maximum test and the brightness order of the candidates use background-subtracted values. Mono frames get offset 0 and the current threshold, so their arithmetic is unchanged.
3. Star-count check: each neighbour minus its own channel's background.
4. ~~Star fits on the luminance crops: the matching luminance background (channel backgrounds with the crop's weights, Rec. 709 or adaptive). Tom: yes, although FWHM on colour frames changes too.~~ **Dropped** (Tom, 2026-11-01) after measuring: it made FWHM and eccentricity agree less with PixInsight (see the results below). The star fits keep the single background.
5. SNR and PSF·S: σ = the luminance noise (channel σ's with the same weights). What SNR should measure is decided separately (open question 2).
6. Unchanged: the sky-background value (Sky BG filter), mono frames, rendered images.
7. **Added during (b)** (Tom, 2026-11-01): saturated stars on colour frames. With the channel backgrounds subtracted, a saturated R or B pixel beats its saturated G neighbours, so saturated stars are now detected and filled the 200 measured stars (M42 180 s: all 200; FWHM 9.9 px). A candidate with a pixel at ≥ 98 % of the frame's highest value in its 3×3 neighbourhood is saturated: left out of FWHM, eccentricity, SNR and PSF·S and counted as a star. A large saturated star has several such candidates (M42 180 s: 243 candidates on 122 stars), so each saturated area (pixels at most 2 px apart) counts once (`SaturatedStars`). Mono frames: unchanged until M3 itself (13d).

**Checks**: (a) measure first, no code change; (b) the change, compared with M81 set 4 (ImageAnalysis, debayered; FWHM with 200 fits), M42 10 s against 180 s (180 s should get more stars), mono sets byte-identical. Unit tests: per-channel background on a synthetic mosaic, detection with a coloured sky, mono unchanged. Baselines of the colour sets (sample-m31, m31-night, california, gamma-cygni-0304, m42-10, m42-180) regenerated in the same commit, old and new shown to Tom first.

**Release**: all step 13 metric changes ship together in one beta (Tom, 2026-11-01).

**Performance**: four small sorts instead of one, one subtraction per pixel in the detection kernel. No new GPU work.

**(a) Results (2026-11-01)**: first and middle frame of each colour set, plus M81 2025-03-26. σ(MAD) per channel agrees with the pixel-to-pixel noise within about 20 %, so it is a fair noise estimate.

| Set | Exposure | Sky R / G / B (ADU) | σ now | σ R / G / B | σ now ÷ σ G |
|---|---|---|---|---|---|
| sample-m31 | 120 s | 485 / 528 / 340 | 49 | 37 / 42 / 27 | 1.12–1.16 |
| m31-night | 120 s | 489 / 532 / 342 | 47 | 39 / 42 / 28 | 1.12–1.18 |
| california (ALP-T) | 180 s | 294 / 324 / 271 | 30 | 24 / 24 / 18 | 1.19–1.25 |
| gamma-cygni (ALP-T) | 180 s | 273 / 342 / 282 | 52 | 19 / 25 / 19 | 1.74–2.06 |
| m42-10 | 10 s | 250 / 278 / 256 | 25 | 16 / 19 / 18 | 1.08–1.31 |
| m42-180 | 180 s | 1,020 / 1,432 / 1,052 | 320 | 71 / 88 / 68 | 2.86–3.63 |
| M81 2025-03-26 | 180 s | 437 / 486 / 343 | 43 | 31 / 36 / 25 | 1.21–1.42 |

The σ inflation is large on M42 180 s and Gamma Cygni, and modest (1.1–1.4) on the other sets. But the channel backgrounds differ by several σ on most sets: B sky is 140–190 ADU (5–7 × σ B) below G on M31, M81 and the sample. With one shared background a B or R neighbour of a faint G peak lies below that background, so the star-count check (change 3) and the local-maximum test (change 2) are probably affected more than the threshold. Measured in (b).

**(b) Results (2026-11-01)**: changes 1–3, 5 and 7; change 4 dropped. Mono sets byte-identical (Rosette R/G/B, ASI294MM); unit tests 383 (6 new in `BayerSkyLevelsTests`); render tests full pass; the six colour baselines regenerated.

Change 4 measured against PixInsight ImageAnalysis (debayered, 200 PSF fits; Spearman r over the frames, old → with change 4 → without it):

| | California (87) | M81 2025-03-26 (59) |
|---|---|---|
| Eccentricity | +0.84 → −0.47 → +0.82 | +0.68 → +0.63 → +0.68 |
| FWHM | +0.65 → +0.43 → +0.52 | +0.94 → +0.94 → +0.95 |

Final, against PixInsight (old → new):

| | California (87) | M81 (59) |
|---|---|---|
| FWHM | +0.65 → +0.52 | +0.94 → +0.95 |
| Eccentricity | +0.84 → +0.82 | +0.68 → +0.68 |
| Stars | +0.97 → +0.98 | +0.58 → +0.75 |
| SNR vs SNR | +0.88 → +0.89 | +0.06 → +0.44 |
| PSF·S vs PSF Signal Weight | +0.97 → +0.99 | +0.68 → +0.94 |
| Score vs PSF Signal Weight | +0.69 → +0.89 | +0.40 → +0.46 |

Colour baselines, medians old → new (standard filter: frames kept):

| Set | FWHM | Ecc. | SNR | Stars | PSF·S | Score | Kept |
|---|---|---|---|---|---|---|---|
| sample-m31 | 3.23 → 3.24 | 0.514 → 0.514 | 532 → 558 | 3,290 → 3,855 | 626 → 623 | 56 → 56 | 2 → 2 of 8 |
| m31-night | 3.28 → 3.28 | 0.487 → 0.483 | 499 → 518 | 3,255 → 3,704 | 594 → 584 | 56 → 57 | 27 → 26 of 39 |
| california | 3.90 → 4.06 | 0.343 → 0.362 | 63 → 70 | 447 → 429 | 148 → 127 | 48 → 46 | 87 → 75 of 87 |
| gamma-cygni-0304 | 3.29 → 3.33 | 0.463 → 0.480 | 197 → 327 | 1,302 → 1,264 | 286 → 443 | 57 → 57 | 33 → 30 of 34 |
| m42-10 | 3.99 → 4.00 | 0.520 → 0.516 | 249 → 271 | 2,769 → 2,974 | 476 → 480 | 51 → 51 | 10 → 10 of 39 |
| m42-180 | 4.28 → 4.27 | 0.504 → 0.507 | 127 → 359 | 1,312 → 1,462 | 138 → 390 | 41 → 49 | 3 → 3 of 9 |

Open after 13a: California's FWHM orders the frames less like PixInsight (+0.65 → +0.52; median 3.90 → 4.06), from the different choice of the 200 measured stars (ranked on background-subtracted values, saturated ones left out). The absolute star count stays far below PixInsight's (M81 1,976 against 3,494; California 429 against 2,993), and M42 180 s still has fewer stars than 10 s; a likely next suspect is the detection itself (5σ on single raw pixels, where PixInsight detects on smoothed luminance).

### 13b (2026-11-01) — what SNR measures

Agreed by Tom on 2026-11-01: SNR should show signal strength (transparency, exposure, sky) **without** the seeing, which FWHM already covers; Auto-Flag absolute floors reset (in practice nothing to reset: the Auto-Flag sheet doesn't store its settings).

**Problem**: SNR was the median over the measured stars of peak ÷ σ. A peak falls as flux ÷ FWHM², so SNR mostly repeated the FWHM (−0.76 on M81) and ranked frames against PixInsight's star SNR on only half the sets. `docs/public/Score.md` still described the aperture SNR the code used before April 2026 (`769c670`).

**(a) Measurement** (temporary build, not committed; details in [FWHM-comparison set 6](FWHM-comparison.md)): six candidates against PixInsight ImageAnalysis (debayered for colour, Maximum PSF fits 200) on 12 groups. Mean Spearman r against PSF SNR: A peak ÷ σ +0.24 (worst −0.79), B aperture flux ÷ (σ √n) +0.52 (−0.81), C aperture flux ÷ σ +0.70 (+0.34), D whole-image ((σL + σH)/2σn)² +0.22 (−0.47), **E fitted Moffat flux ÷ σ +0.67 (+0.26)**, F fitted flux ÷ (σ √area) +0.47 (−0.84). Tom chose E: level with C, no aperture (no crop limit on colour frames, no nebula), no extra work.

Trailed frames (M42 10 s REJECTED): E is 7 × the kept frames (also C; A 1.5 ×), because the fitted profile overestimates a trail's flux and the faint stars drop out. PixInsight's detection rejects elongated sources (maximum distortion 0.6), finds 18 objects and gives PSF SNR ≈ 0, but then its eccentricity misses the trailing (0.40 against 0.51 kept; FITS Blaster 0.97). Tom chose option 1: E as is. Trailed frames already got full SNR points with A; eccentricity and FWHM (70 % of the score) and Auto-Flag catch them.

**(b) Change**: SNR = median over the measured stars of peak · π · α_major · α_minor / 3 ÷ σ (Moffat β = 4). Score: log scale, `clamp(log₁₀(SNR / 100) / log₁₀(200), 0, 1)` (a 5σ star of FWHM 3 px gives about 60). Auto-Flag absolute SNR floor 200 (slider 100–10,000). `Score.md` and `FAQ.md` rewritten; `site/faq.html` at stable 1.24. Tests: 386 (3 new in `StarFluxSNRTests`, 3 in `QualityScoreTests` moved to the new scale). All 10 baselines regenerated: only SNR and score change, the standard filter keeps the same frames.

| Set | SNR median old → new | Score median (range) old → new |
|---|---|---|
| sample-m31 | 558 → 8,314 | 56 (52–58) → 52 (49–55) |
| m31-night | 518 → 8,206 | 57 (55–64) → 53 (50–61) |
| california | 70 → 1,016 | 46 (30–53) → 48 (35–54) |
| gamma-cygni-0304 | 327 → 4,989 | 57 (54–59) → 51 (49–54) |
| m42-10 | 271 → 7,604 | 51 (44–53) → 47 (41–50) |
| m42-180 | 359 → 10,203 | 49 (46–51) → 46 (44–48) |
| rosette-r / g / b | 189 / 189 / 148 → 1,420 / 1,272 / 1,362 | 67 / 68 / 61 → 57 / 58 / 57 |
| asi294mm-sho | 688 → 3,411 | 72 (65–77) → 65 (56–71) |

### 13c (2026-11-01) — star count

Goal (Tom): counts close to PixInsight's, with its default star detection as the reference.

**(a) Measurement**: per-stage counts and PixInsight StarDetector lists (V8 `StarDetector`, ImageAnalysis defaults, colour frames on the debayered HSI intensity) for one frame each of M81, California, M42 10 s and 180 s, SHO H and Rosette R. Findings:
- 97–99 % of PixInsight's stars were already FITS Blaster candidates: detection on single raw pixels is not the problem.
- **PixInsight counts hot pixels as stars on uncalibrated colour frames**: the demosaic smears a hot pixel into a small blob. Recognised by an exact integer position and a centre more than 3 × the brightest neighbour above the sky: M81 1,187 of 3,270, California 2,629 of 3,543, M42 180 s 224 of 1,672. ImageAnalysis's "Stars" includes them, so the target is PixInsight's **real** stars. On mono, integer positions are real small stars (centre 1.4–1.7 × the neighbour).
- FITS Blaster checked only the first 6,200 candidates; on uncalibrated frames thousands of hot pixels came first in the brightness order, so faint real stars were never checked (M81: 415, California: 305, M42 180 s: 431). FITS Blaster's neighbour check rejects hot pixels correctly.
- Too many: noise peaks on nebula (M42 10 s: 2,459 extras with the local sky 4.4 σ above the background and a peak only 2.6 × the local noise above it) and faint peaks below PixInsight's sensitivity on mono (SHO 17 ×, Rosette 8 × the local noise).
- Mono saturated stars (M3) are not detected: Rosette R misses 43 % of PixInsight's brightest quarter. Done in 13d.

**(b) Change**: every candidate is checked (no 6,200 limit); a candidate counts when the quick profile check accepts it and its peak stands ≥ 12 × the local noise above the local sky (median and 1.4826 × MAD of the same-cell pixels in a ring of 6–10 px). k = 12 was chosen from k = 5–20 on the six frames. Result with the real code against PixInsight's real stars: M81 2,311 / 2,083 (1.11), California 875 / 914 (0.96), M42 10 s 695 / 682 (1.02), M42 180 s 1,547 / 1,448 (1.07), SHO H 4,539 / 3,937 (1.15), Rosette R 2,641 / 2,868 (0.92). Only the star count changes; scores stay the same (above 500 stars the score's star part is full); the standard filter keeps the same frames. Tests 390 (4 new in `StarCountTests`); all baselines regenerated.

Baseline medians old → new: sample-m31 3,855 → 5,348; m31-night 3,704 → 4,910; california 429 → 502; gamma-cygni-0304 1,264 → 2,079; m42-10 2,974 → 695; m42-180 1,462 → 1,562; rosette-r/g/b 4,734 / 3,630 / 2,429 → 2,708 / 2,163 / 1,402; asi294mm-sho 5,776 → 5,964 (up to 10,769).

**Performance**: about 8 ms more per frame (command line, 61 M81 frames cached: 2.1 → 2.6 s), from the ring median per checked candidate on the CPU. Later, if wanted (Tom, 2026-11-01): move the ring calculation to the GPU.

### 13d (2026-11-01) — saturated stars on mono frames (METAL_REVIEW M3)

Decided (Tom): the rule only applies at saturation; elsewhere the local-maximum test stays strict.

**(a) Measurement**: on Rosette R #0000 FITS Blaster missed 43 % of PixInsight's brightest quarter: a clipped top is a plateau of equal pixels, and the strict "higher than all 8 neighbours" test finds no maximum in it. Colour frames were already covered by 13a (with the channel backgrounds subtracted a saturated R or B pixel beats its G neighbours).

**(b) Change**:
- **Tie rule at saturation** (GPU kernel and CPU, the same rule): at a pixel at or above the saturation level, a maximum must be ≥ the 4 neighbours after it in reading order and > the 4 before it, so a flat top gives one candidate, its top-left pixel. Below the saturation level the test stays strict. The level is passed to the kernel in the field that was padding, so the parameter layout is unchanged.
- **Saturation level**: 98 % of the frame's highest value, and only when at least 3 pixels have exactly that value; otherwise the frame counts as unsaturated (one hot pixel at the maximum doesn't make a frame saturated).
- **Mono and colour alike**: saturated candidates are counted once per saturated area (`SaturatedStars`, as in 13a) and left out of FWHM, eccentricity, SNR and PSF·S.
- **Saturated hot pixels don't count**: a saturated candidate counts only when its neighbours carry part of its light (`hasStarNeighbours`, the same 5 % check as for unsaturated candidates).

**Results**: star count against PixInsight's real stars (set 7): Rosette R 2,641 → 2,896 / 2,868 (0.92 → 1.01), SHO H 4,539 → 4,558 / 3,937 (1.16), M81 2,311 → 2,304 (1.11), California 875 → 865 (0.95), M42 10 s 695 (1.02), M42 180 s 1,547 → 1,541 (1.06). Colour counts drop by about 5–10 per frame (saturated hot pixels).

On mono sets SNR and PSF·S drop by 10–20 %: the brightest stars used to be measured although they were saturated (a strict maximum on a clipped top with one pixel slightly higher), and their flux and peak are clipped. On colour sets SNR and PSF·S change on 2–8 frames per set: a saturated pair that the tie rule now detects suppresses (3 px duplicate removal) an unsaturated candidate next to it, so one of the 200 measured stars is swapped for the next one. Expected, not a bug.

Baseline medians old → new:

| Set | Stars | SNR | PSF·S | Score |
|---|---|---|---|---|
| sample-m31 | 5,348 → 5,344 | 8,314 → 8,300 | 623 → 621 | 52 → 52 |
| m31-night | 4,910 → 4,906 | 8,206 → 8,198 | 584 → 584 | 53 → 53 |
| california | 502 → 492 | unchanged | unchanged | 48 → 48 |
| gamma-cygni-0304 | 2,079 → 2,071 | unchanged | unchanged | 51 → 51 |
| m42-10 | 695 → 695 | 7,604 → 7,573 | 480 → 471 | 47 → 47 |
| m42-180 | 1,562 → 1,566 | unchanged | unchanged | 46 → 46 |
| rosette-r | 2,708 → 2,965 | 1,420 → 1,196 | 188 → 159 | 57 → 56 |
| rosette-g | 2,163 → 2,400 | 1,272 → 1,022 | 186 → 152 | 58 → 57 |
| rosette-b | 1,402 → 1,572 | 1,362 → 1,222 | 156 → 135 | 57 → 55 |
| asi294mm-sho | 5,964 → 6,006 | 3,411 → 3,093 | 894 → 766 | 65 → 65 |

The standard filter keeps the same frames, except one fewer on Rosette G (18 → 17) and Rosette B (20 → 19). Tests 394 (4 new in `SaturatedStarTests`: flat top on CPU and GPU, the saturation rule, saturated mono stars including a saturated hot pixel). All baselines regenerated.

**Performance**: about 3 ms more per frame on M81 (61 frames cached: 2.62 → 2.80 s), no measurable difference on Rosette.

### 13e (2026-11-01) — measure only stars

**Why** (measured with a temporary test that repeats the app's shape phase; it reproduces the baselines on all 296 frames of the nine sets): FWHM, eccentricity, SNR and PSF·S are measured on the 200 brightest unsaturated candidates, and on uncalibrated frames many of those are hot pixels, which the shape fit accepts. Hot pixels among the 200 (median per frame): California 130 (#0000: 87, #0102: 193), Gamma Cygni 26, SHO H/O/S 40/27/31, M42 10 s 9, M31 6, Rosette 1–2. Their fits give 1–2.5 px or junk at 5–8 px, so the median FWHM depends on the mix: California #0102 reads 3.69 px where its real stars give about 6 (the "California FWHM ranking +0.52"). PixInsight's own California reference fails on the same frames: from #0095 its FWHM is 1.35 px, its star lists of #0098 and #0102 are 95–97 % hot pixels (66 and 43 real stars), and 139–159 of its 200 brightest are hot pixels. On #0000–#0089 FITS Blaster's FWHM ranks the frames like PixInsight's (+0.99).

**Change**: the shape set is the first 200 candidates (brightest first) that **count as stars**: unsaturated, accepted by the quick profile check (`measureFWHMOnly`, all four neighbours carry light) and local contrast ≥ 12. One pass over the candidates does the count and fills the shape set, so a star means the same thing for the count and for the measurements. The star count doesn't change. A frame with fewer than 200 stars measures fewer; a frame with none gets no FWHM/eccentricity/SNR/PSF·S (today hot pixels may give values; how such frames score is the decided item "no-star frames score 0").

**Expected effect** (temporary test, variant C; Spearman against ImageAnalysis, today → 13e):

| Set | FWHM | Eccentricity | SNR (vs PSF SNR) | PSF·S | FWHM median (PixInsight) |
|---|---|---|---|---|---|
| California #0–#89 | +0.99 → +0.99 | +0.80 → −0.11 | +0.95 → +0.88 | +0.98 → +0.99 | 3.87 → 4.38 (3.45) |
| California #90–#102 | 5.71 → 7.14 px, no drop at the end | | | | |
| Gamma Cygni | +0.95 → +0.96 | +0.26 → +0.28 | +0.92 → +0.94 | +0.97 → +0.97 | 3.32 → 3.38 (2.54) |
| M31 | +0.91 → +0.91 | +0.86 → +0.87 | +0.90 → +0.89 | +0.95 → +0.96 | 3.28 → 3.29 (2.99) |
| M42 10 s | +0.99 → +0.99 | +0.83 → +0.88 | +0.53 → +0.73 | +0.03 → +0.55 | 4.00 → 4.18 (3.58) |
| SHO H / O / S | ≈ +1.00 | +0.90 → +0.93 / = / = | +0.95 → +0.89 / +0.65 → +0.78 / +0.73 → +0.79 | = | +0.01–0.02 px |
| Rosette R / G / B | = | = | = | = | = |

California's eccentricity ranked well only because of the hot pixels: they are round, and their share grows through the night (Spearman +0.97 with time, −0.84 with FITS Blaster's eccentricity), while PixInsight's eccentricity also falls through the night. On real stars the two disagree; that is 13f.

A variant with the neighbour check only (no contrast) gave nearly the same results; the full count check is chosen so there is one definition of a star.

**Performance**: no extra work (the checks already run for the count; the shape fits stay at most 200). No Metal question.

**Tests**: unit test with a synthetic mono frame and a Bayer frame where hot pixels are brighter than the stars: FWHM, eccentricity and SNR equal those of the same frame without hot pixels; star count unchanged. Unit tests, render tests (full), metric baselines: FWHM, eccentricity, SNR, PSF·S and score change on the colour sets and SHO, stars don't; Rosette about unchanged. Baselines regenerated after review.

**Docs**: `Score.md` (which stars are measured), FWHM-comparison set 8 (this measurement, including PixInsight's hot-pixel fits on California #0090–#0102), CHANGELOG.

**Done (with 13f, one commit)**: the shape set is the first 200 stars of the count, from the same loop. Result: see 13f.

### 13f (2026-11-01) — eccentricity and FWHM as stars fade

**(a) Measurement**: with 13e alone, California's eccentricity rose through the night (0.49 → 0.59) where PixInsight's fell (0.54 → 0.42), and California and Gamma Cygni crossed the standard filter's eccentricity limit of 0.5 (California 75 → 23 of 87 frames kept, Gamma Cygni 30 → 14 of 34).
- Synthetic round Moffat stars (temporary test, the app's `measureShape`): eccentricity 0.16–0.21 when bright (peak SNR 160–500), 0.31–0.48 at peak SNR 80, 0.5–0.75 at peak SNR 5–40; FWHM of a 3 px star reads 4.5 px at peak SNR 40. Noise widens and elongates faint stars' fits.
- Real frames, per star: eccentricity and FWHM fall with local contrast on every frame (California #0000: contrast 12–20 → 0.90, 20–40 → 0.66, 40–80 → 0.55, ≥ 160 → 0.46). Late on California most of the 200 measured stars are faint.
- A brightness floor for all four metrics improves eccentricity but breaks SNR and PSF·S (they follow the transparency through the faint stars too: California SNR +0.88 → −0.77 at contrast ≥ 40). So the floor applies to FWHM and eccentricity only.
- Fallback when few stars reach the floor (per-star dump of all 296 frames; only California #0091–#0102 need it): all stars brings the noisy ones back (eccentricity +0.14 to +0.19 on the whole set); the N stars with the highest contrast is better (+0.28 to +0.36). N = 20 chosen: the same as 10 wherever there are enough stars, and a steadier median.

**(b) Change** (Tom: K = 40, fallback 20): SNR and PSF·S use every fitted star (up to 200); FWHM and eccentricity use the fitted stars with local contrast ≥ 40 (`shapeContrast`), or the 20 with the highest contrast when fewer reach it (`shapeMinimumStars`, `brightStarsForShape`). No extra fits.

**Result, 13e + 13f** (Spearman against ImageAnalysis, before → after): California #0–#89 FWHM +0.99 → +0.99, eccentricity +0.80 (hot pixels; −0.11 on real stars with 13e alone) → +0.56, SNR +0.95 → +0.88, PSF·S +0.98 → +0.99; M42 10 s SNR +0.53 → +0.73, PSF·S +0.03 → +0.55; SHO O/S SNR +0.65/+0.73 → +0.78/+0.79; Gamma Cygni, M31, Rosette and SHO otherwise within ±0.04. California's FWHM keeps rising to the end of the night (#0082 → #0101: 4.99 → 6.29 px; was 5.32 → 5.00 with a drop to 3.69 on #0102); #0102 (3 stars at contrast ≥ 40, a glow in one corner) reads 9.28 px.

Baseline medians 13d → 13e + 13f:

| Set | FWHM | Eccentricity | SNR | PSF·S | Score | Standard filter keeps |
|---|---|---|---|---|---|---|
| sample-m31 | 3.24 → 3.25 | 0.514 → 0.518 | 8,300 → 8,300 | 621 → 614 | 52 → 52 | 2 → 1 of 8 |
| m31-night | 3.28 → 3.29 | 0.483 → 0.487 | 8,198 → 8,206 | 584 → 576 | 53 → 53 | 26 → 24 of 39 |
| california | 4.06 → 4.27 | 0.362 → 0.490 | 1,016 → 1,564 | 127 → 94 | 48 → 40 | 75 → 48 of 87 |
| gamma-cygni-0304 | 3.33 → 3.38 | 0.479 → 0.502 | 4,989 → 4,922 | 443 → 421 | 51 → 50 | 30 → 15 of 34 |
| m42-10 | 4.00 → 4.12 | 0.516 → 0.529 | 7,573 → 5,906 | 471 → 372 | 47 → 45 | 10 → 7 of 39 |
| m42-180 | 4.27 → 4.30 | 0.507 → 0.507 | 10,203 → 7,821 | 390 → 278 | 46 → 45 | 3 → 3 of 9 |
| rosette-r / g / b | unchanged | ≈ | within 0.5 % | ±1 | ≈ | unchanged |
| asi294mm-sho | 1.92 → 1.92 | 0.395 → 0.401 | 3,093 → 2,866 | 766 → 721 | 65 → 64 | 29 → 29 of 30 |

Star counts are unchanged on every frame. Gamma Cygni's eccentricity sits at the 0.5 limit (PixInsight 0.48): its 26 hot pixels per frame had pulled it down a little. Our eccentricity has a noise floor of its own (round stars 0.16–0.5), so the 0.5 default is strict; a later item (Tom, 2026-11-01).

Tests 398 (4 new in `ShapeSetTests`: hot pixels brighter than the stars on mono and colour frames, the selection rule, faint stars left out of FWHM and eccentricity; each fails without its change). All baselines regenerated. Performance: no extra fits.

### 13g (2026-11-02) — frames without stars (§5.4)

Decision 4 (2026-10-20): star count 0 and score 0, so they can be rejected. Measured on the three FLAT folders in Test Data (60 flats, current code after 13f):
- No flat has zero candidates: all give metrics. 51 get star count 0, empty FWHM/eccentricity/SNR/PSF·S and score 0; today only the star-count check rejects them (the other checks skip empty values, so the CLI standard filter `-f -e -p` keeps them).
- 9 flats count 1–2 spurious "stars" (noise or a defect). With one, FWHM is 0.9–1.3 px, which gets full FWHM points: score 28–44, higher than California's last real frames (14–31). With one counted star and no fit: score 11.
- Real frames in the test sets have at least 80 stars (California #0099).

**Changes** (Tom, 2026-11-02: N1–N3, minimum 10, plus a FLAT baseline set):
- **N1, no candidates:** `compute` returns metrics with star count 0 (sky background kept) instead of nil, in both entry points. Metrics off (`needsStarDetection` false) still returns nil. Ends the re-reading of such files on every metric toggle (§5.4).
- **N3, minimum stars:** a frame with fewer than 10 counted stars (`Constants.minimumStars`) is a frame without stars: star count as counted, FWHM, eccentricity, SNR and PSF·S empty, score 0. One helper on `FrameMetrics` (`hasNoStars`: star count present and below the minimum) is used everywhere below.
- **N2, checks:** in `previewAutoReject` (Auto-Flag and the CLI filters) a frame without stars is rejected as soon as any check is on, in both modes. Group medians (`updateGroupStatistics`) leave frames without stars out, so a few of them don't drag the session's star-count median down.
- **Badge:** a frame without stars gets the low-stars badge (amber, cloud) whatever the group statistics; today a FLAT folder on its own would show grey (its median is 0 too). `FAQ.md`: the badge text says grey means "no stars", which is wrong today and after; corrected (site FAQ at stable 1.24).
- **Unchanged:** the session chart shows score 0 and gaps for the empty metrics, as for any missing value; CSV export writes empty cells and score 0.

**Test data:** new baseline set `california-flat` = `California Nebula IMX571/2026-02-25_Antlia ALP-T/FLAT` (20 frames) in `scripts/testdata.py`; clone and manifest with `scripts/baseline-data.py --only california-flat`; not a render-test set. Expected baseline: all 20 frames star count 0–1, empty metrics, score 0, none kept by the standard filter.

**Tests:** unit tests (Swift Testing): a synthetic frame with no candidates (flat sky without noise peaks) gives star count 0 and score 0, not nil; a frame with 3 stars gives empty metrics and score 0; a frame with 10 stars is measured as usual; `previewAutoReject` rejects a frame without stars with only the FWHM check on, and with only the eccentricity check on, in both modes; group medians leave it out; badge = low stars. Then unit tests, render tests (full), metric baselines: the ten existing sets unchanged (none has frames under 10 stars), the new set as expected.

**Performance:** none (a comparison per frame).

**Result:** as planned. `california-flat` baseline: 18 flats star count 0, 2 with 1, all with empty metrics and score 0, none kept (before: 2 flats scored 36 and 40). The ten existing sets are unchanged (all metrics match). Tests 406: 9 new in `NoStarFrameTests`; 12 existing tests updated: the 4 that expected nil for a starless frame now expect star count 0 and score 0, and the synthetic fixtures with 1–5 stars now plant 10–12 (with peaks that differ, so they don't count as saturated), with `#require` where an `if let` would have let them pass without measuring anything (IntegrationTests, GPUTests, FITSMalformedInputTests, MetricsModeSwitchTests, MetricsOnlyLoadTests).

### 13h plan (2026-11-04) — Auto-Flag defaults for cloud and elongation; eccentricity in the score

Measured with the current code (after 13g) on all baseline sets, the REJECTED folders (measured separately, the tests don't read them) and three references: Tom's culling by eye, PixInsight ImageAnalysis (PSF Signal Weight, Eccentricity, CloudExtinction, ElongationCoherence) and, for M42 10 s, Astro Pixel Processor. New test set `lobster-cloud` (55be2de): LBN 537, L-Enhance, 121 frames, high clouds in waves at airmass 1.01–1.36.

**Cloud (relative SNR and star count).** Yardstick on seven sessions: PixInsight PSF Signal Weight < 0.5 × median (28 frames, 21 of them California's setting target). Stars 0.4 | SNR 0.5 (now) catches 20, stars 0.5 | SNR 0.6 catches 25, no good frame flagged in either. On `lobster-cloud` against Tom's culling (20 cloudy frames): now 15, stars 0.5 | SNR 0.6 17, plus #1 (usable) and #2 (edge), no ok frame flagged. SNR 0.7 would catch all 20 but flags #0, #60, #69 (ok to Tom) and SHO S #0010 (PixInsight 1.00 ×). The three missed (#28, #47, #103: thin cloud with halos) look like usable frames in every metric, PixInsight's included (later item: halo metric). PSF·S adds nothing over SNR.

**Elongation (eccentricity, absolute).** Since 13e/13f normal frames measure 0.49–0.53 on colour (80 % within ± 0.04) and 0.40–0.44 on mono; the default 0.5 flags 15–81 frames per colour session (California 0 → 29, Gamma Cygni 3 → 18 with 13e/13f). PixInsight would also flag many at 0.5 (M31 37 of 39). Against Tom's eye:
- elongated: Lobster #62, #75, #77, #78 (0.66–0.74), M81 #89, #91, #66 (0.80, 0.71, 0.65, small differences), the trails in M42 10 s and 180 s REJECTED (0.93–0.98);
- not elongated: Lobster #18, #61, #67, #71 (0.60–0.64), M81 #27, #65, #90 (0.66–0.68), Rosette G #8 (0.65), M42 10 s #39 (0.75).
- Limit 0.65 catches all of Lobster's four and the trails and leaves Rosette G #8 alone; 0.6 adds four round Lobster frames and Rosette G #8; 0.7 misses Lobster #62 and #75; a relative rule (median + 0.15) flags Rosette G #8 and misses Lobster #62.
- M42 10 s #39: PixInsight 0.78, APP star shape 0.40 (lowest), PixInsight elongation coherence 0.93 (median 0.32): an even stretch in one direction over the whole frame. All three programs put #16, #17, #23, #39 as the four least round. Known case: 0.65 flags it.
- Not caught by any eccentricity rule: M42 180 s REJECTED #8 and #13 (0.56, 0.45), "a well-defined star with a stripe attached" (Tom): the core dominates the fit (later item).

**Score.** Eccentricity is 35 % of the score with full points at 0 and none from 0.5, so half the colour frames get no eccentricity points and a trail (0.97) loses no more than a normal frame (0.55). With none from 0.9: kept frames +10–15 points (Lobster median 52 → 66, M31 53 → 68, SHO 64 → 77), trails stay 30, so the gap kept → trailed grows from 15 to 30 points and kept → elongated (Lobster) from 5 to 10. The order of frames within a session is unchanged.

**Changes** (Tom, 2026-11-02 → 04):
- **H1, Auto-Flag defaults** (`AutoRejectConfig`, not saved, so every user gets them the next time the sheet opens): `snrMultiplier` 0.50 → **0.60**, `starCountMultiplier` 0.40 → **0.50**, `eccentricityThreshold` 0.5 → **0.65**. Slider ranges (SNR 0.1–0.8, stars 0.1–0.7, eccentricity 0.3–0.9) hold the new values; the meaning of every slider stays the same. FWHM 1.5 ×, sky, PSF·S and score floor unchanged.
- **H2, score scale for eccentricity** (`qualityScore`): `s = clamp(1 − e / 0.9, 0, 1)` instead of `1 − e / 0.5`; the bad end as one named constant (`Scale.eccentricityZero = 0.9`). Weights and the other three sub-scores unchanged.
- **H3, badge** (to be agreed): the red "trailing" badge (`badgeProblem`, `ecc > 0.5`) uses the same 0.65 as Auto-Flag, as one shared constant, so a red badge and an Auto-Flag flag mean the same. Without it half the thumbnails of a colour session stay red. The amber low-stars badge (40 %, 30 % narrowband) stays as it is: it marks clearly low counts, Auto-Flag's 50 % is for checking.
- **Unchanged:** the CLI has no defaults (every check is off until a threshold is passed, `-e` stays absolute), so the standard filter `-f 1.5 -e 0.5 -p 0.5` and every baseline's `kept` column are unchanged. Score floor 40 in absolute mode: kept (trails 30, California's cloudy end from 22); to check after the change. The inspector's score colours (80/60/40) are unchanged; scores rise, so more frames show yellow than orange.

**Docs:** `Score.md` (eccentricity row of the score table, badge row), `FAQ.md` (badge colours, "What is Eccentricity?": 0.65 instead of ~0.5; the Auto-Flag defaults if mentioned), CHANGELOG; site FAQ at stable 1.24 (with SNR, ⌘-click and the badge). `FWHM-comparison.md`: a set 9 with the cloud and eccentricity measurements above.

**Tests:** `AutoRejectConfig()` defaults (0.6, 0.5, 0.65); `QualityScoreTests` updated to the new scale (mid-range eccentricity 0.45 → 50, worst at 0.9, the "typical bad frame" fixture still ≤ 30); badge tests at 0.65 (0.66 → trailing, 0.65 not); the existing Auto-Flag tests set their thresholds explicitly and don't change. Then unit tests, render tests (full; renders don't depend on metrics), metric baselines: `score` changes on every frame of every set, all other metrics and every `kept` column unchanged; regenerate with `--update` after checking that only `score` moved.

**Performance:** none (constants).

**Later items from this measurement:** halo metric for thin cloud and moisture; "core with a stripe" frames measured round (M42 180 s #8, #13); NINA's ImageMetaData as a third reference (offered).

**Result:** as planned (H3 agreed 2026-11-04). One shared constant `Constants.trailingEccentricity = 0.65` for the badge and Auto-Flag's default, `Scale.eccentricityZero = 0.9` in the score. Baselines: only `score` changed, on every frame (+6 to +16, average about +14; flats stay 0); every other metric and every `kept` column unchanged. Auto-Flag with the defaults flags, per set, old → new: Lobster 84 → 23, California 38 → 20, M31 15 → 5, M42 10 s 32 → 1, Gamma Cygni 18 → 0, M42 180 s 5 → 0, Rosette and SHO 1–2 → 0. Tests 408 (2 new: defaults, eccentricity scale); updated: the badge tests (0.66 trailing, 0.65 and 0.55 not), the score tests to the 0.9 end, and the "typical bad frame" fixture's eccentricity from 0.4 to 0.8 (0.4 is a normal frame on the new scale and would score 40). Also removed an unused local (`columnNeighbourBackground` in `measureFWHMOnly`, left over from 13d), the build's only warning. Set 9 in `FWHM-comparison.md`.

### 13i (2026-11-04; plan B done 2026-11-05) — large stars (long focal length, oversampled data)

**Found on** four frames from a CDK14 at 2563 mm with a full-frame mono camera (0.30"/px, 9576 × 6388, one frame per filter, no guiding; NGC 253). PixInsight and APP measure FWHM 10.7–13.0 px; we measure 7.4–8.2 px, in a different order (PixInsight and APP: G best, B worst; we: B best, L worst). Eccentricity: PixInsight 0.50–0.60 on L, G and B (elongation coherence 0.91–0.97), we 0.26–0.34. Stars: we 466–866, PixInsight 56–106, APP 136–184.

**Synthetic test** (temporary `TmpLargeStarTests`, not committed): mono 1024², σ ≈ 11.5, 81 Moffat β = 4 stars, peaks 150–30,000, round and true eccentricity 0.6.
- FWHM 3–6 px: 77–78 of 81 counted, FWHM within 0.03 px, eccentricity 0.10–0.13 round and 0.60 elongated. 8 px: 64–67 counted, FWHM 8.0, eccentricity 0.22 round and 0.60 elongated.
- **FWHM 10–16 px: no star counted**, so the frame counts as a frame without stars (13g).
- Cause: `localContrast` (ring at 6–10 px, `Constants.contrastRingInner/Outer`) lies on the star's own flank. On the brightest star the contrast is 1307 at 3 px, 38 at 6, 12.3 at 8, 8.9 at 9, 7.3 at 10, 4.2 at 16 px, independent of brightness from about 8 px; `countContrast` needs 12. `measureFWHMOnly` and `hasStarNeighbours` pass at every size (16 px measures 15.99).
- So on the real frames the 11–13 px stars drop out, and what is left (smaller and fainter sources, possibly knots in the galaxy) gives the low FWHM and the high count. Not yet confirmed on the real frames.

**Other fixed pixel sizes to check** for large stars: the Moffat fit (±10 px, `Shape.moffatHalfWidth`), the crop around each star (25 × 25, `cropHalf = 12`), the centroid window (5 × 5), NMS separation (3 px: several local maxima on a wide, noisy star top?), `acceptedFWHM` up to 20 px.

**Next, when more frames of this session are in** (Tom asks the owner for at least 10 per filter, rejected frames with the reason, and permission to use them as a test set; the header names the observer, so only file names and our measurements may go in the repo):
1. Star positions on the real frames: what the counted sources are, against PixInsight's star list.
2. The synthetic test extended to the other fixed sizes above (crop and fit window at 12–16 px, NMS on wide tops), with and without noise.
3. A plan: scale the ring (and where needed the crop and fit window) with the star size, e.g. a ring from about 1.5–2 × the `measureFWHMOnly` FWHM, keeping 6–10 px for stars up to about 6 px so the existing sets stay byte-identical (checked with the baselines). Performance: larger rings only on frames with large stars.
4. A test set from the session, if the owner agrees, under a name without his name.

**Done 2026-11-05:**
- 40 frames arrived (L, R, G, B × 10; the owner deletes bad frames, so there is no reject list) and the owner agreed to a test set: `ngc253-cdk14` (Test Data "NGC 253 CDK14 C3-61000/LIGHT", PixInsight's ImageAnalysis, its R_0001 star list and APP's table in the set's `reference` folder, outside the repo).
- Step 1 (R_0001 against PixInsight's 71 stars): we count 1 of them; 65 fail the contrast check (median contrast 5, needed 12). Our fit on them gives 12.8 px (PixInsight 13.0): the fit works, the count check doesn't. 742 of our 873 "stars" lie on the galaxy (knots, quick FWHM 7–10 px), so our frame FWHM of 7.5 px is the knots' size. FWHM rank against PixInsight −0.22…0.08 per filter; APP against PixInsight 0.99–1.00.
- Step 2 (synthetic, with a scaled ring and fit window): round stars of 10–20 px counted 78–83/81, FWHM within 0.16 px. Elongated (eccentricity 0.6) 18–20 px drop out: the quick check's upper limit of 20 px applies to the long axis.
- **A frame-level switch (option A) was tried and dropped.** Neither a frame star size (median quick FWHM of the 50 brightest: sky-spread #0040 8.22 px, CDK B_0001 8.00) nor "the brightest stars fail the 6–10 px contrast" separates the CDK frames from cloudy and hazy ones (sky-spread dusk frames and #0040, California's last frames): halos make stars look large. A switch would move cloudy frames onto the large-star path and raise their star count, against 13h.
- **Siril 1.4.5** (installed with Homebrew; GPL-3 sources read, no code taken) sizes each star from its own profile: inflection points of a σ = 2 px smoothed profile give a width per star, the fitting box is 3.7 × that width, symmetry checks reject lopsided sources, and a Gaussian with free background is fitted. On CDK14 its FWHM ranks agree with PixInsight at 0.98–1.00 and it counts 93–152 stars (PixInsight 41–137, APP 131–189). On our other sets Siril and we rank frames alike (FWHM 0.95–1.00; Rosette and SHO both 0.92–1.00 against PixInsight) and our star counts are closer to PixInsight than Siril's (Siril 30–50 % of PixInsight on Rosette and SHO). Exception: sky-spread (cloudy frames), ours against Siril 0.47.

**Plan B: size the ring and the fit window per star (approved by Tom 2026-11-05 with these factors; done, see the results below)**

Keep detection, the 13c count calibration (contrast ≥ 12) and the Moffat fit; only the fixed pixel sizes become per-star, from the star's own quick FWHM *w* (`measureFWHMOnly`, already computed for every candidate before the contrast check):
- Contrast ring: inner max(6, round(1.5 *w*)), outer max(10, round(2.5 *w*)). Stars up to *w* = 4 px keep exactly 6–10 px. On R_0001 this gives FWHM 12.27 px (PixInsight 12.97), eccentricity 0.45 (0.49); L_0001 15.61 px (16.36), 0.54 (0.57); 65 of 70 PixInsight stars counted (simulated).
- Fit window (`moffatHalfWidth`): max(10, round(1.5 *w*)), and the colour crop half-side fit + 2. Unchanged up to *w* ≈ 6.7 px.
- Quick-FWHM window and upper limit: when *w* comes out near the 10-step window, measure again with a window of 1.5 *w*; the accepted upper limit becomes max(20, 2.5 × the frame's typical *w*) so elongated large stars aren't dropped (synthetic 18–20 px case). Exact rule fixed with the synthetic test.
- The star count stays as it is (Tom, 2026-11-05: leave the galaxy knots for a separate investigation).

**Expected effect:** frames whose stars measure up to 4 px: byte-identical (most sets). California, M42, lobster-cloud and the cloudy sky-spread frames (quick FWHM 4–9 px): the ring grows for their larger stars, so counts and FWHM move — to be measured, not assumed. CDK14: FWHM and eccentricity close to PixInsight.

**Performance:** no new pass over the frame (*w* is already computed). Larger rings only for stars above 4 px: on CDK14 about 15 × the ring samples for those candidates; estimated a few tens of ms per CDK frame, nothing on normal frames. Measured with `BenchmarkTests`; budget ≤ 5 % load time on the normal sets. Metal not needed.

**Steps:**
1. Commit the test set `ngc253-cdk14` with today's metrics as its baseline (they record the problem, like M42's).
2. Implement behind the per-star sizes; synthetic tests 3–20 px, round and elongated, with and without noise (permanent unit tests replacing `TmpLargeStarTests`).
3. Run every baseline and list the changes per set, before committing anything. Checks:
   - CDK14: FWHM rank against PixInsight ≥ 0.9 per filter, FWHM within 10 % of PixInsight, eccentricity rank ≥ 0.8.
   - Cloudy frames still caught: Auto-Flag with its defaults on lobster-cloud (Tom's cull list in `testdata.py`) and sky-spread flags the same frames as before, or Tom accepts the difference.
   - Render tests unchanged (stretch is not involved).
4. Tom decides on the changes; then baselines updated with the reason in the CHANGELOG, as for 13c–13h.

**Decisions for Tom:** the factors (1.5–2.5 × for the ring, 1.5 × for the fit window); whether a rise in star count on cloudy frames is acceptable if FWHM gets closer to PixInsight there (decided after step 3 with the numbers).

**Results of plan B (2026-11-05, accepted by Tom):**
- CDK14: FWHM within 2–4 % of PixInsight; FWHM rank against PixInsight L 0.90, R 0.99, G 1.00, B 1.00 (APP 0.83–0.99); eccentricity rank L 0.72, R 0.85, G 0.87, B 0.99. L stays below the 0.8 target: accepted for now, on the later list. Star count 551–1001 (galaxy knots still counted; left for a separate investigation). The standard filter keeps 30 of 40 (10 above eccentricity 0.5; PixInsight 0.50–0.60).
- Other sets: star count median −2.5 % to +1.1 % per set, FWHM within 0.05 px, eccentricity within 0.005, frame order kept (rank old~new 0.88–1.00). M42 SNR −9.5 %; its rank against PixInsight PSF SNR (M42 10 s, `DEBAYERED-10/ImageAnalysis-psf200.csv`) 0.73 → 0.74, so a level shift, accepted. Auto-Flag defaults flag the same frames on lobster-cloud, California, M42, Gamma Cygni and M31; sky-spread #0005 is no longer flagged (eccentricity 0.667 → 0.644). Standard filter: California 48 → 41, Gamma Cygni 15 → 14, M31 night 24 → 25, M42 180 s 3 → 4, sky-spread 3 → 4. Renders unchanged. Baselines updated.
- Synthetic (`LargeStarTests`): round stars of 3–20 px counted 77–80 of 81 (the test requires ≥ 75), FWHM within 5 %; elongated (eccentricity 0.6) within 0.05.
- Speed: the larger rings first cost +25 % (California) and +160 % (Rosette R). The ring scan now visits only the ring's own pixels and uses selection instead of sorts, with identical values. Remaining: California +4 %, Rosette R +25 % (about 3 ms per frame; faint candidates with a noisy quick FWHM above 4 px get the larger ring), CDK14 +27 %. Tom accepted this (option A) over limiting the larger ring to candidates near the frame's typical star size (a behaviour change). Ring on the GPU stays a later option.

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
8. **§4.5** colour spaces: switch to named sRGB / grey spaces (step 13, render targets updated and checked by eye). **Reversed 2026-11-05:** skipped; colour accuracy is not a primary goal of culling.
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
