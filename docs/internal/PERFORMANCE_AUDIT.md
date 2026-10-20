# FITS Blaster SwiftUI Performance Audit

Generated 2026-10-17 on branch `colour-fix` (head `9780ac9`), with the `swiftui-performance-audit` skill. **Code review first**; all six findings were then measured with Instruments traces on 2026-10-18 (see Measurements). The biggest measured problem is one this review didn't predict: memory at large display sizes (16.3 GB at 4096 for 476 colour frames, audit §7.1). This is the baseline before the [master plan](architecture-plan.md); each finding says which plan step handles it. Overlaps with [CODE_AUDIT.md](CODE_AUDIT.md) are noted, not repeated.

Paths are relative to `FITS Blaster/`.

## Summary

The most likely bottleneck is **moving the cursor** (arrow keys, especially held down) in a large session in Geek mode with the chart visible. Every cursor move makes three things recompute:
- the sidebar's body, which re-filters and re-groups every frame;
- every visible thumbnail cell;
- the whole session chart, which rebuilds one mark per frame.

All three read `store.selectedEntry`, so all three update together. Second: **during a load**, the chart depends on every frame's metrics, so it is rebuilt once per finished frame, about n² mark builds over a session of n frames. Image decoding is already off the main thread, and list identity is stable (UUIDs). The rest is minor.

## Findings

1. **Cursor movement re-renders the sidebar body, all visible cells and the whole chart**
   - Symptom: holding ↓ in a session of several hundred frames may lag or skip frames; worse with several folders or filters (to be measured).
   - Likely cause: observation fan-out from `store.selectedEntry`:
     - the sidebar reads it in `onChange(of: store.selectedEntry?.id)`, so its whole body re-runs;
     - every `ThumbnailCell` reads it for `isCursor`;
     - `ChartBody` reads it for the cursor dot.
   - Evidence: `SidebarViews.swift:132, 152` (dependency), `:72-124` (body work, see 2); `ThumbnailCell.swift:14-16`; `SessionChartView.swift:256` plus `264-289` (one mark per frame, each reading `filterGroup`, `isRejected` and `flaggedEntryIDs`).
   - Fix:
     - give each cell a plain `isCursor` / `isFlagged` value (audit §8.1);
     - drive the sidebar's scroll-to-cursor from a small dedicated view or `ViewerState` value, so the list body doesn't depend on the selection;
     - draw the chart's cursor as a separate overlay mark, so moving it doesn't rebuild all points.
   - Validation: SwiftUI instrument, "Update Groups" and "Show Causes" while holding ↓ for 5 s; count of `ThumbnailSidebar.body` and `ChartBody.body` updates before and after.
   - Plan: step 5.

2. **The sidebar body does O(n) work on every evaluation**
   - Symptom: part of 1; also on flag and reject actions.
   - Likely cause: in multi-folder mode each folder is filtered with `isVisible` twice (list and header count) plus a `flatMap`. In Geek mode with one folder and several filters, `visibilityGroupedSortedEntries` is a **computed** property that groups all frames in a `Dictionary` on every read. `isVisible` and the grouping call `entry.filterGroup`, which re-parses the FILTER header on every access (lowercasing plus up to ~30 substring checks).
   - Evidence: `SidebarViews.swift:72-96, 118`; `ImageStore.swift:293-303, 326-341`; `ImageEntry.swift:35-41`; `FilterGroup.swift:77-110`.
   - Fix: store the visible groupings once per change (like `visibilityFilteredEntries` already is); store `filterGroup` on the entry when headers arrive. Same as audit §7.5 / §8.5.
   - Validation: "Long View Body Updates" for `ThumbnailSidebar.body` in a 3-folder, 3-filter session.
   - Plan: step 5 for the stored `filterGroup` (moved from step 9 on 2026-10-18 after trace 1), step 9 for the stored groupings.

3. **The chart is rebuilt once per finished frame during a load**
   - Symptom: UI hitches during loading while the chart is visible, growing with session size (to be measured).
   - Likely cause: `chartPoints` reads `entry.metrics` of every frame, so each Phase B completion invalidates the chart. Each rebuild recomputes `chartEntries` 3–4 times (`chartPoints` calls it again; `body` and `yAxisDomain` read `chartPoints` repeatedly) and creates one mark per frame, so about n² mark builds per load.
   - Evidence: `SessionChartView.swift:30-47` (computed, nested), `:83-91` (read twice in `body`), `:232-235` (`yAxisDomain` reads it again); `ImageStorePipeline.swift:482-485` (per-frame metrics writes).
   - Fix:
     - compute `chartEntries` and `chartPoints` once per body (local `let`) or in the store;
     - feed the chart from a store value that is refreshed at most every ~250 ms during a batch and once at the end, the way the progress bar polls instead of observing (`MainContent.swift:147-153`).
   - Validation: hitch count and SwiftUI update count for `SessionChartView` during a load of the large test folder.
   - Plan: step 9 (the chart arrays are audit §7.5b; the throttled feed is new).

4. **Every scroll frame of the main image writes two observed store properties**
   - Symptom: minor; the cursor's thumbnail redraws on every scroll frame.
   - Likely cause: `onScrollGeometryChange` sets `store.viewportFraction` and `store.viewportCenter` on every geometry change; `ViewportBox` in the cursor cell reads `viewportFraction`. `@Observable` notifies even when the value hasn't meaningfully changed.
   - Evidence: `ImageViewer.swift:89-102`; `ThumbnailCell.swift:105`.
   - Fix: write only when the change is larger than about one thumbnail pixel; `viewportCenter` doesn't need to be observed at all (it is only read in an `onChange` handler), so it can be `@ObservationIgnored`.
   - Validation: update count for `ThumbnailCell` while scrolling the zoomed image.
   - Plan: step 5 (these properties move to `ViewerState` there).

5. **Animated scroll on every cursor move**
   - Symptom: while holding an arrow key, scroll animations restart on every step, which can look jittery and costs layout passes.
   - Likely cause: `withAnimation { proxy.scrollTo(id, anchor: .center) }` on every selection change.
   - Evidence: `SidebarViews.swift:132-135`.
   - Fix: no animation for key-repeat moves (the key handler knows `event.isARepeat`), or scroll only when the cursor leaves the visible area.
   - Validation: visual check plus "Other Long Updates" while holding ↓.
   - Plan: step 5.

6. **Drawing large display images on the main thread (needs a trace)**
   - Symptom: possible hitch when switching frames at large display sizes (2048–8192).
   - Likely cause: display images are `CGImage`s over Metal shared buffers in DeviceGray / RGBX formats. The first draw may need a format conversion or copy on the main thread. Decoding itself is already off the main thread (`ImageStorePipeline.swift:862-885`).
   - Evidence: `ImageStretcher.swift:433-458, 575-594`; drawn by `Image(nsImage:)` in `ImageViewer.swift:51-58` with `brightness` and `contrast` effects.
   - Fix: only if a trace shows it: create the image in the display's native format, or pre-render it off the main thread (step 9 already changes display-image handling, audit §7.1).
   - Validation: Time Profiler on frame switching at display size 4096; look for CoreGraphics conversion frames under the main thread.
   - Plan: step 9, only if confirmed.

**Checked and fine**
- List identity: `ForEach` over entries uses stable UUIDs, plus an explicit `.id(entry.id)` for scroll targets.
- `.id(store.rejectionVisibility)` recreates the list only when the filter changes (intended).
- Thumbnails and display images are created off the main thread.
- The progress bar polls every 200 ms in `.task` instead of observing every frame (deliberate and good).
- `HistogramView` uses `Canvas`.
- No `AnyView`.
- Formatters use `format:` styles, not stored formatter objects.

## Measurements (2026-10-18)

### Trace 1: M81, 355 colour frames

Release build from Xcode 27.0, MacBook Air M1 (16 GB), macOS 27.0.1. SwiftUI template (SwiftUI, Hitches, Time Profiler). Data set: `Test Data/M81 IMX571`, 3 folders × 1 filter, **355 colour frames**, Geek mode, chart visible. The trace (`/Volumes/FITS Blaster/Traces/01-load-and-cursor.trace.trace`, not in git) holds both rows 1 and 2: the load (43.5–80.5 s), then ↓ held for about 5 s (110.5–115.5 s, 52 cursor moves). The tester's impression: "it felt ok"; after the later runs: "fast but not smooth". No hangs were detected.

**Holding ↓ (52 moves)**
- 49 hitches totalling 3.05 s of the 5.4 s, mostly 50–67 ms each: about 12–15 frames per second instead of 60.
- Main thread busy about 92% (≈ 925 ms per second); SwiftUI update work ≈ 40 ms per move.
- Per move: `ChartBody.body` 1×, `ThumbnailSidebar.body` 1×, `ThumbnailCell.body` ≈ 8× (the visible cells), `ImageViewer.body` 2×, inspector and toolbar 1× each.
- Main-thread time by cause (inclusive, of 4.1 s):
  - **The chart's per-point closure** (`SessionChartView.swift:264-289`), 10%. Of that, **`entry.filterGroup` takes 6.3%** (≈ 5 ms per move): `filterGroup` → `FilterGroup.normalise` → `filterName` → `FITSReader.cleanHeaderString` re-parses the header for each of the 355 points on every move (`SessionChartView.swift:271`, `ImageEntry.swift:35-41`).
  - Swift Charts' own mark collection and drawing (`CollectContent`, `CanvasDisplayList`, `AGChartDisplay`), ≈ 16 ms per move in the SwiftUI lane.
  - Text layout (`StyledTextLayoutComputer`, ≈ 280 text items per move, ≈ 6 ms per move). The source isn't pinned down yet; the inspector's header list (`ForEachChild<(String, String)>`, ≈ 58 rows per move) is a candidate.
  - The sidebar is cheap: `ThumbnailSidebar.body` ≈ 0.09 ms, `ThumbnailCell.body` ≈ 0.05 ms per call; the animated scroll (`UpdatedHostingScrollView`) ≈ 1.5 ms per move.

**Loading 355 frames**
- Wall time ≈ 37 s (worker threads busy 43.5–80.5 s).
- 394 hitches totalling 11.4 s, longest 333 ms. Main thread busy ≈ 24 s of the 37 s.
- **`SessionChartView.body` 165× and Swift Charts' `CollectContent` 164×**: the chart is rebuilt about once per two finished frames, ≈ 3 s of SwiftUI chart work, plus `chartPoints` / `chartEntries` ≈ 0.5 s and `filterGroup` ≈ 0.7 s inside the per-point closure. Text layout another 1.7 s.
- The progress bars update ≈ 360× and are cheap.

### Traces 2 and 3: Rosette, 464 mono frames, several folders and filters

Same build, Mac and settings. Both runs are in `/Volumes/FITS Blaster/Traces/03-load-and-cursor.trace` (runs 2 and 3; the file also holds trace 1 as run 1, and `02-load-and-cursor.trace` holds runs 1–2). Data: `Test Data/NGC 2244-Rosette_Nebula large`, 8 copies of the 58-frame Rosette R/G/B set (identical files).
- **Run 2, 24 folders × 1 filter:** the set as downloaded; every R, G and B subfolder is its own sidebar section, so no filter sub-headers.
- **Run 3, 8 folders × 3 filters:** `… large (mixed)`, the same files as APFS clones with each folder's R, G and B frames together, so Geek mode shows filter sub-headers. Confirmed from the trace (`FolderFilterSubHeader` updates only in run 3).

| | Run 2 (24 × 1) | Run 3 (8 × 3) |
| --- | --- | --- |
| Hold ↓: moves | 66 in 6.0 s | 64 in 5.8 s |
| Hitches while holding ↓ | 64 = 4.15 s, longest 83 ms | 61 = 3.90 s, longest 83 ms |
| Main thread busy while holding ↓ | 92% | 90% |
| Per move: chart mark collection (`CollectContent`) | 16.3 ms | 16.1 ms |
| Per move: `filterGroup` in the chart | 3.8 ms | 3.8 ms |
| Per move: text layout | 5.9 ms (≈ 350 items) | 5.5 ms (≈ 275 items) |
| Per move: `ThumbnailSidebar.body` | 0.10 ms | 0.10 ms |
| Per move: `ThumbnailCell.body` | ≈ 12 cells, 0.6 ms | ≈ 11 cells, 0.6 ms |
| Load: wall time | 15.0 s | 15.4 s |
| Load: hitches | 145 = 5.2 s, longest 267 ms | 140 = 4.9 s, longest 283 ms |
| Load: chart rebuilds (`SessionChartView.body`) | 146 | 152 |
| Load: microhang at the start | 263 ms | 292 ms |

The microhang at the start of each load (trace 1 had a 333 ms hitch at the same point) has no app function behind it: the main thread is creating SwiftUI views (`PlaceholderContentView._makeView`, text) when the new session first appears.

### Trace 4: 476 colour frames, display size 1024 and 4096

Same build and Mac, in a window (not full screen). Data: `M81 IMX571`, `California Nebula IMX571` and `Gamma Cygni Nebula IMX571`, **476 colour frames** (all 6224 × 4168), debayer on, opened one after the other. Instruments restarts the app for every recording, so each run loads the folders again. All three runs are in `/Volumes/FITS Blaster/Traces/04-load-and-cursor.trace`. Memory was read with `footprint` and `vmmap` while the app was running.
- **Run A:** display size 1024 (the tester's normal setting). Load only, then the memory reading.
- **Run B:** display size 4096. Load, then ↓ pressed once a second, 10 times (not held).
- **Run C:** display size 4096. Load, the memory reading, then panning the zoomed image for about 10 s (zoom 0.9, which at 4096 shows less than a quarter of the image). Notification Center slid in a few times during right pans; the measurement uses a steady 4.5 s stretch.

The tester's impression of run C: "smooth enough", but they noted that's what they said about the cursor list too.

**Memory (row 5)**

| | Display size 1024 | Display size 4096 |
| --- | --- | --- |
| Physical footprint after loading | 2.6 GB | **16.3 GB** |
| Peak during loading | 4.2 GB | **17.7 GB** |
| Metal buffers (`IOAccelerator`): display images and thumbnails | 1.7 GB (1,149 regions) | **15.3 GB** (1,171 regions), 15.0 GB of it compressed or swapped out |
| Large `malloc` blocks | 0.8 GB in 19 blocks, which `vmmap` lists as empty (freed, not yet returned) | 0.8 GB in 16 blocks, same |
| Free memory, system-wide | 51% | 36% |

At 4096 the app holds about as much memory as the Mac has (16 GB) and keeps running only because macOS compresses and swaps out almost all of it. This is audit §7.1 (up to three display-size images per colour frame, kept for every frame). §7.1 estimates "hundreds of MB at 8192"; the measurement is far higher. Not measured: 8192, a Mac with 8 GB, and what holds the large freed `malloc` blocks.

**Frame switching at 4096 (row 4)**

Ten single ↓ presses, 1–1.3 s apart. Per press:
- **Main thread: 118–159 ms of work** (median ≈ 155 ms), spread over the first ≈ 250 ms after the key press. Almost all of it is SwiftUI updating and laying out the window (`NSHostingView.layout`). App code inside it:
  - the chart's per-point closure ≈ 11 ms, of which `filterGroup` ≈ 7 ms (finding 2);
  - text layout ≈ 7 ms;
  - the sidebar's animated scroll, spread over ≈ 250 ms (finding 5).
- **Drawing the 4096 image costs under 0.1 ms on the main thread.**
- **On a background thread, SwiftUI converts every new image: ≈ 40 ms per switch** (`_SwiftUIProxyImage prepare` → `CA::Render::copy_image` → `CGContextDrawImage`, with a colour-space conversion through `vImageConvert_AnyToAny`). The display image isn't in a format Core Animation can use directly, so each one is copied and converted before it can be shown.
- Hitches: 5 in total over 10 presses (longest 67 ms), so switching looks smooth.

**Panning the zoomed image at 4096 (row 3)**

In 4.5 s of steady panning:
- `ImageViewer.body`, `ThumbnailCell.body` (the cursor cell) and `ViewportBox.body` each ran **230 times, once per scroll frame** (≈ 51 per second). This confirms finding 4.
- The cost is small: `ThumbnailCell.body` ≈ 0.15 ms per frame, `ImageViewer.body` and `ViewportBox.body` together ≈ 0.02 ms, the `viewportFraction` write ≈ 0.13 ms.
- Main thread busy 36%, mostly AppKit and SwiftUI scrolling (`NSHostingView.layout` ≈ 2.8 ms per frame). 2 hitches (33 ms in total).
- The cursor cell's tooltip text (`FrameMetrics.tooltipString`) is rebuilt on every frame, ≈ 0.05 ms.

**Loading, per folder**

| Folder | Display size 1024 (run A) | 4096 (run B) | 4096 (run C) |
| --- | --- | --- | --- |
| M81, 355 frames | 37.9 s; 398 hitches = 9.7 s | 51.9 s; 446 hitches = 10.7 s | 49.6 s; 247 hitches = 7.7 s |
| California, 87 frames | 10.8 s | 16.9 s | 16.8 s |
| Gamma Cygni, 34 frames | 4.7 s | 7.8 s | 6.8 s |

Loading at 4096 takes about 30–65% longer than at 1024. Each run also has 3–5 hangs or microhangs (0.25–0.70 s); they are not broken down yet.

### Verdict per finding (traces 1–4)
- **1 — confirmed, but the chart is the cost, not the sidebar.** The chart re-runs on every move and is the biggest single cost (≈ 16 ms of mark collection plus ≈ 4–5 ms of `filterGroup` per move, in all three runs). The sidebar body and cells do re-run on every move, but cost under 1 ms together.
- **2 — header part confirmed, sidebar part not measurable.** `filterGroup` re-parsing costs ≈ 4–5 ms per move, paid in the chart. The sidebar's grouping costs ≈ 0.1 ms per move with 24 folders and with 8 folders × 3 filters, so storing the sidebar groupings (step 9) is cleanup, not a speed fix.
- **3 — confirmed.** 146–164 chart rebuilds per load (355–464 frames), ≈ 2.5–3 s of SwiftUI chart work per load.
- **5 — confirmed, minor** (≈ 1.5 ms per move).
- **4 — confirmed, minor** (trace 4): the cursor cell, `ImageViewer` and `ViewportBox` re-run on every scroll frame, but cost under 0.5 ms per frame together.
- **6 — not on the main thread** (trace 4): drawing a 4096 image costs under 0.1 ms there. Instead SwiftUI copies and colour-converts every new display image on a background thread, ≈ 40 ms per switch. It adds latency and a temporary full-size copy, but no hitches. The fix in finding 6 (create the image in a format the display can use directly) still applies; step 9, as planned.
- **New: memory at large display sizes** (trace 4): 16.3 GB at 4096 for 476 colour frames, against 2.6 GB at 1024. Audit §7.1, step 9.
- **New: text layout** of ≈ 275–350 items per move (≈ 5.5–6 ms); source to be found. It is larger with more folder sections.
- **New: microhang at load start**, ≈ 0.3 s, from SwiftUI view creation. Not in the plan; worth one look in step 9.

## Metrics

To fill in from Release-build traces (SwiftUI template + Time Profiler), before step 5 and again after steps 5 and 9:

| Interaction | Metric | Before | After step 5 | After step 9 | Notes |
| --- | --- | --- | --- | --- | --- |
| Hold ↓ for 5 s, ~500 frames, Geek mode, chart visible, 3 folders × 3 filters | hitches; `ThumbnailSidebar.body` / `ChartBody.body` update counts | Rosette 464 frames, 8 × 3: 61 hitches = 3.90 s of 5.8 s; main thread 90% busy; per move `ChartBody` 1×, `ThumbnailSidebar` 1× (0.1 ms), chart ≈ 16 ms + `filterGroup` 3.8 ms. M81 355 frames, 3 × 1: 49 hitches = 3.05 s of 5.4 s | | | findings 1, 2, 5; traces 1 and 3 |
| Load the large test folder with the chart visible | hitches; `SessionChartView` updates; wall time | M81 355 colour frames: 37 s; 394 hitches = 11.4 s (max 333 ms); `SessionChartView.body` 165×. Rosette 464 mono frames (8 × 3): 15.4 s; 140 hitches = 4.9 s (max 283 ms); 152× | | | finding 3; traces 1 and 3 |
| Scroll the zoomed main image for 5 s | `ThumbnailCell` updates; hitches | 476 colour frames, display size 4096, zoom 0.9: `ThumbnailCell.body` 1× per scroll frame (≈ 51/s, 0.15 ms each); main thread 36% busy; 2 hitches in 4.5 s | | | finding 4; trace 4 run C |
| Switch frames at display size 4096 | main-thread time per switch | 476 colour frames: main thread ≈ 155 ms per switch (image drawing < 0.1 ms; chart ≈ 11 ms); ≈ 40 ms image conversion on a background thread; 5 hitches in 10 switches | | | finding 6; trace 4 run B |
| Memory after loading ~500 colour frames | peak / resident memory | 476 colour frames: footprint 2.6 GB (peak 4.2 GB) at display size 1024; 16.3 GB (peak 17.7 GB) at 4096 | | | audit §7.1; trace 4 runs A and C |

## Next step

👤 Record one trace per row above, in a **Release** build on this Mac:
1. Product → Profile → **SwiftUI** template.
2. Do only that one interaction, for about 5 seconds.
3. Stop, then export the trace, or take screenshots of the SwiftUI lanes (Update Groups, Long View Body Updates, Hitches) and the Time Profiler call tree.
4. Add one line saying what you did.

All five rows were recorded on 2026-10-18 (traces 1–4). Record them again after steps 5 and 9.
