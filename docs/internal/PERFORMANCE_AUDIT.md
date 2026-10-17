# FITS Blaster SwiftUI Performance Audit

Generated 2026-10-17 on branch `colour-fix` (head `9780ac9`), with the `swiftui-performance-audit` skill. **Code review only**: no Instruments traces yet, so every finding below is a code-backed suspicion, not a measurement. This is the baseline before the [master plan](architecture-plan.md); each finding says which plan step handles it. Overlaps with [CODE_AUDIT.md](CODE_AUDIT.md) are noted, not repeated.

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
   - Plan: step 9.

3. **The chart is rebuilt once per finished frame during a load**
   - Symptom: UI hitches during loading while the chart is visible, growing with session size (to be measured).
   - Likely cause: `chartPoints` reads `entry.metrics` of every frame, so each Phase B completion invalidates the chart. Each rebuild recomputes `chartEntries` 3–4 times (`chartPoints` calls it again; `body` and `yAxisDomain` read `chartPoints` repeatedly) and creates one mark per frame, so about n² mark builds per load.
   - Evidence: `SessionChartView.swift:30-47` (computed, nested), `:83-91` (read twice in `body`), `:232-235` (`yAxisDomain` reads it again); `ImageStorePipeline.swift:482-485` (per-frame metrics writes).
   - Fix:
     - compute `chartEntries` and `chartPoints` once per body (local `let`) or in the store;
     - feed the chart from a store value that is refreshed at most every ~250 ms during a batch and once at the end, the way the progress bar polls instead of observing (`MainContent.swift:147-153`).
   - Validation: hitch count and SwiftUI update count for `SessionChartView` during a load of the large test folder.
   - Plan: step 9 (the chart arrays are audit §7.5; the throttled feed is new).

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

## Metrics

None yet. To fill in from Release-build traces (SwiftUI template + Time Profiler), before step 5 and again after steps 5 and 9:

| Interaction | Metric | Before | After step 5 | After step 9 | Notes |
| --- | --- | --- | --- | --- | --- |
| Hold ↓ for 5 s, ~500 frames, Geek mode, chart visible, 3 folders × 3 filters | hitches; `ThumbnailSidebar.body` / `ChartBody.body` update counts | | | | findings 1, 2, 5 |
| Load the large test folder with the chart visible | hitches; `SessionChartView` updates; wall time | | | | finding 3 |
| Scroll the zoomed main image for 5 s | `ThumbnailCell` updates; hitches | | | | finding 4 |
| Switch frames at display size 4096 | main-thread time per switch | | | | finding 6 |
| Memory after loading ~500 colour frames | peak / resident memory | | | | audit §7.1 |

## Next step

👤 Record one trace per row above, in a **Release** build on this Mac:
1. Product → Profile → **SwiftUI** template.
2. Do only that one interaction, for about 5 seconds.
3. Stop, then export the trace, or take screenshots of the SwiftUI lanes (Update Groups, Long View Body Updates, Hitches) and the Time Profiler call tree.
4. Add one line saying what you did.

Rows 1 and 2 matter most. With those I can confirm or drop findings 1–3 and set the targets for steps 5 and 9.
