# Concurrency fixes — Implementation Plan

**Date**: 2026-10-17  
**Status**: Planned, now part of [architecture-plan.md](architecture-plan.md) (decided 2026-10-17). Steps 1–2 below are done inside the new `LoadPipeline` (master plan step 6) instead of inside `ImageStore`; steps 3–4 are master plan step 7. The design and tests here still apply; the order, the open questions and the release timing are in the master plan.  
**Source**: concurrency review of 2026-10-17 (strict build: `SWIFT_STRICT_CONCURRENCY=complete`, Xcode with the macOS 27.0 SDK, 4 warnings, no errors).

---

## Overview

The review found two real bugs in the loading pipeline, both in how batches of work overlap, and four compiler warnings that only matter for Swift 6 language mode. Neither bug can corrupt memory. Both make the screen disagree with what the user did:

| # | Problem | What the user sees | Priority |
|---|---------|--------------------|----------|
| 1 | A new batch replaces `processingTask` without waiting for, or stopping, the running one. `reset()` does not stop it either. | Open or drop a second folder during a load: the progress bars disappear and Cancel greys out while the second load is still running. Reset during a load: the old load keeps the GPU busy. | High |
| 2 | Colour and grey re-renders (`recolorImages`, the per-folder colour tasks) are not tracked and cannot be cancelled. | Turn colour off during a load, or on and off quickly: the images end up in colour while the setting is grey. Turn colour on during a load: frames that were not loaded yet stay grey. | High |
| 3 | 4 compiler warnings (data-race checks) | Nothing today. They become errors in Swift 6 mode. | Medium |
| 4 | A pointer escapes `withUnsafeBufferPointer` (CPU fallback only) | Nothing today. Formally undefined behaviour. | Low |

Problem 2 has a part the review did not mention; I found it while writing this plan. `recolorImages` picks the Bayer frames with `entries.filter { $0.isBayer }`, and `isBayer` reads the FITS headers, which are only set after a frame is loaded (Phase A). So turning colour on during a load leaves out every frame not loaded yet. This is from reading the code, not tested yet; step 2 adds a test for it.

Each step below is one commit with its own CHANGELOG entry.

---

## Step 1 — One batch at a time (problem 1)

### Idea

All batch work goes through a single queue in `ImageStore`. A new batch waits for the batch before it, then runs. Only the last batch in the queue clears "busy". Cancel stops the running batch and everything queued behind it.

### Changes

**`ImageStore.swift`**

1. New stored state next to `processingTask`:
   ```swift
   /// Identifies the newest batch; only that batch may clear the busy state when it ends.
   var processingBatchID: UUID?
   ```
2. New helper that the four batch functions use instead of writing `processingTask = Task { … }` themselves:
   ```swift
   /// Queues a batch behind any batch already running and returns at once.
   /// `body` returns true when it did work, so timing is recorded.
   func enqueueBatch(priority: TaskPriority = .utility,
                     _ body: @escaping @MainActor (ImageStore) async -> Bool) {
       let previous = processingTask
       let batchID = UUID()
       processingBatchID = batchID
       isBatchProcessing = true
       batchElapsed = nil
       batchMegapixels = nil
       processingTask = Task(priority: priority) { [weak self] in
           // Cancelling this batch also cancels the batches queued before it.
           await withTaskCancellationHandler {
               await previous?.value
           } onCancel: {
               previous?.cancel()
           }
           guard let self, !Task.isCancelled else { return }
           let startTime = CFAbsoluteTimeGetCurrent()
           let didWork = await body(self)
           guard !Task.isCancelled, processingBatchID == batchID else { return }
           if didWork {
               batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
               batchMegapixels = entries.reduce(0.0) { … }   // the existing calculation, now in one place
           }
           isBatchProcessing = false
           processingTask = nil
           processingBatchID = nil
       }
   }
   ```
   The timer now starts when the batch starts, not when it was queued, so the time shown is the batch's own time.
3. `cancelProcessing()`: also set `processingBatchID = nil`.
4. `reset()`: call `cancelProcessing()` first.

**`ImageStorePipeline.swift`**

- `openFiles`, `regenerateSizes`, `recomputeMetrics` call `enqueueBatch` (`reprocessAll` is already deleted in master plan step 3). Their duplicated tails (timing, megapixels, clearing busy) go away.
- `openFiles`: the `existingURLs` snapshot moves **inside** the batch body. Today it is taken when the call is made. With queueing, the previous batch adds its entries later, so a snapshot taken at call time would miss them, and the same folder dropped twice quickly would load twice.
- `recomputeMetrics` keeps its `guard !isBatchProcessing` (unchanged behaviour).

### What does not change

- Work already running on the GPU or reading a file when Cancel comes still finishes (it can't be interrupted mid-flight). Master plan step 6 adds that no **new** Phase B work starts after Cancel (audit §3.4). Step 2 below stops finished-but-stale work from changing the display.
- CLI: `waitForProcessing()` waits for the newest `processingTask`, which waits for all earlier ones, so it still waits for everything.

### Tests — new `BatchQueueTests.swift` (Swift Testing, `@MainActor`)

The tests use `enqueueBatch` with test bodies held by gates, so nothing depends on timing:

| Test | Checks |
|------|--------|
| Second batch waits for the first | Body 2 does not start before body 1 finishes (order recorded in an array) |
| Busy until the last batch ends | After body 1 ends and body 2 is still held: `isBatchProcessing == true`, `processingTask != nil` |
| Cancel stops running and queued | `cancelProcessing()` while body 1 runs: body 2 never starts; busy is false |
| Reset stops the batch | `reset()` while a batch runs: same as above, entries empty |
| Same folder opened twice quickly | Two `openFiles` calls with the same synthetic FITS files, then `waitForProcessing()`: no duplicate URLs, every entry loaded |

The gate is a small test helper (a `CheckedContinuation` the test resumes). The synthetic FITS writer is the shared `TestFITS.swift` helper created in master plan step 1, with optional extra header cards (needed for `BAYERPAT` in step 2).

---

## Step 2 — Re-renders that cannot go stale (problem 2)

### Idea

Two parts:

1. **`recolorImages` becomes a batch** through the step 1 queue. A colour toggle during a load then runs after the load, when every frame's headers are known (fixes "frames not loaded yet stay grey"), and two re-renders never mix the progress counters (`batchRestretchTotal/Count`, `batchSamplingTotal/Count`) any more.
2. **A render generation number.** Work that can still be running after it has been replaced (the colour tasks of a cancelled batch, a re-render still in flight) must not change what is on screen:
   ```swift
   // ImageStore
   /// Raised whenever the wanted rendering changes (colour toggle, new load, reset).
   /// A render only updates the display if its generation is still current.
   var renderGeneration = 0
   ```
   - Raised in: `recolorImages` (when called, before queueing), `processParallel` (at start), `reset()`.
   - Checked before every write to `displayImage` / `thumbnail` in `renderFolderInColour` (both the selected-frame pass and the group tasks), `renderGroupWithSharedGreyClips`, and the grey branch of `recolorImages`.
   - The caches (`cachedColourDisplay`, `cachedGreyscaleDisplay`, …) are still filled when the generation is old. They are correct renders, so the next toggle can use them.
   ```swift
   await MainActor.run {
       entry.cachedColourDisplay = display
       entry.cachedColourThumb   = thumb
       guard self.renderGeneration == generation else { return }
       entry.displayImage = display
       entry.thumbnail    = thumb
       self.batchRestretchCount += 1
   }
   ```

Quick toggles (on, off, on) queue three re-renders. Only the last one's result stays on screen. The older ones still render, which is wasted work but correct. Option: a newer re-render cancels an older **re-render** that is still queued or running (never a load). I'd add that only if quick toggling feels slow in testing.

### Behaviour change (assumed yes in the master plan)

A re-render that is a batch shows in the batch UI: the Cancel button becomes active during a colour toggle, and Cancel stops it. Today a colour toggle cannot be cancelled. I think that is fine, or even better, but it is visible.

### Tests — new `RenderGenerationTests.swift`

Synthetic Bayer FITS files (`BAYERPAT = 'RGGB'`) in a temporary folder:

| Test | Checks |
|------|--------|
| On then off at once | `recolorImages` with colour on, then off, without waiting; after `waitForProcessing()` every Bayer frame shows its grey render (`displayImage === cachedGreyscaleDisplay`) |
| Off then on at once | Reverse: every Bayer frame shows its colour render |
| Colour on during a load | `openFiles` (colour off), then colour on right away; after waiting, every Bayer frame has a colour render, including the ones not loaded yet when the toggle came |
| Reset during a colour render | No frame of the old session is shown; no crash |

These depend on order, not on timing, because the queue from step 1 runs the batches one after another.

---

## Step 3 — The four compiler warnings (problem 3)

| Where | Change |
|-------|--------|
| `ImageStorePipeline.swift:423` "sending 'fast'" | Before the hop to the main actor, copy the fields the UI needs (`display`, `thumb`, `info`, `error`, `histogram`, `headers`, `bayerClips`, `greyClips`) into `let`s and use only those inside `MainActor.run`. `FastLoadResult` cannot just be made `Sendable`: on the macOS 27 SDK, `MTLBuffer` is not `Sendable` (`NSImage` and `MTLDevice` are; checked with `swiftc -swift-version 6`). |
| `ContentSplitLayout.swift:47` (drop handler) | **Option A (recommended):** `.dropDestination(for: URL.self) { urls, _ in … } isTargeted: { isDragTarget = $0 }`. This removes the task group and the continuation. Unverified: that sandboxed access to dropped folders still works with it. Test it first. **Option B, if A fails:** keep `onDrop`, but load the providers one after another on the main actor (no task group), so no provider crosses to another task. |
| `MetricsCalculator.swift:474, 545` (pointer captured by child tasks) | Not a real race (read-only; the group ends before the function returns). Copy each candidate's crop into an array on the parent before `addTask`, as `measureFromCrops` already does, and pass the array to the child. Only the CPU fallback uses this path. |

**Check:** a scratch build with `SWIFT_STRICT_CONCURRENCY=complete` shows 0 warnings (same command as the review; build output in the scratchpad, not in the repo).

## Step 4 — Pointer escape (problem 4)

`MetricsCalculator.swift:209`: `compute(pixels:)` takes `baseAddress` out of `withUnsafeBufferPointer` and uses it across `await`s. Fix: copy the pixels into an `UnsafeMutableBufferPointer` allocated here and freed with `defer` after `computeImpl` returns. This is the CPU fallback only (Metal unavailable), so the extra copy costs nothing in normal use.

---

## Performance and Metal

| Step | Effect |
|------|--------|
| 1 | One load at a time instead of two at once. Each load already saturates the SSD and GPU (`ioConcurrency = max(8, cores)`, Phase B bounded by its semaphore), so total time should stay the same. The first images of the **second** folder appear later. Peak GPU memory goes **down**: today two parallel loads each have their own Phase B semaphore, so up to twice the live `MTLBuffer`s. Check: `BenchmarkTests` before and after, and a manual two-folder drop timed with the elapsed-time display. |
| 2 | One integer compare per write: nothing measurable. A colour toggle during a load now starts after the load instead of during it. That is less GPU work in total (no frame is rendered twice) but colour appears later. |
| 3 | A few reference copies. Nothing measurable. |
| 4 | One pixel copy, CPU fallback only. |

No Metal kernel, buffer layout or pipeline-state change. Nothing here is a candidate for Metal.

---

## Validation

1. Full unit test suite (`xcodebuild test`), including the new tests.
2. `scripts/run-render-tests.sh`: renders must be byte-identical to before (the fixes change when renders happen, not how).
3. Metric baselines: unchanged.
4. Scratch strict-concurrency build: 0 warnings.
5. `scripts/vm-test-all.sh` with the beta build (`scripts/build-beta.sh`).
6. 👤 Manual checks on the 27 VM (`--keep`), each with a large folder:
   - drop a second folder during a load: the bars stay until both are done, Cancel stays active, the timing is right;
   - Reset during a load: everything stops, the list is empty;
   - toggle colour off during a load: grey at the end; on during a load: all colour at the end;
   - toggle colour quickly 3×: ends on the last setting;
   - change the display size in Settings during a load;
   - drag-and-drop from Finder: folders, single files, a mix (step 3 drop change).

---

## When and questions

See the master plan, [architecture-plan.md](architecture-plan.md): "When" and "Open questions". The questions this plan used to list are there:
- second folder during a load → master question 2;
- Swift 6 mode → master question 3;
- Cancel stopping a colour re-render → assumed yes;
- drop handler → try `dropDestination` first;
- `reprocessAll` → removed in master step 3;
- release split → the master plan's release question.
