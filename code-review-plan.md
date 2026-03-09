# Code Review & Improvement Plan

Generated: 2026-03-09
Codebase: Claude FITS Viewer v1.11 (build 31)

---

## Priority 1 — Correctness / Guideline violations

### 1.1 Replace `DispatchQueue.main.async` with `Task @MainActor`
**File:** `ContentView.swift` lines 833 & 838
**Issue:** Project guidelines explicitly forbid old-style GCD (`DispatchQueue.main.async`). Two occurrences remain in the `WindowAccessor` NSViewRepresentable helper.
**Fix:**
```swift
// Before
DispatchQueue.main.async { self.onWindow(view.window) }

// After
Task { @MainActor in self.onWindow(nsView.window) }
```
**Effort:** 5 min. Zero risk.

---

### 1.2 Add `defer` for temp buffer deallocations in `FITSReader`
**File:** `FITSReader.swift` lines 260–287 (BITPIX 16 and 32 cases)
**Issue:** `temp16` and `temp32` are manually deallocated at the end of each `case` block. If future edits add a `guard` / early return between `allocate()` and `deallocate()`, the buffer leaks silently. Using `defer` makes the cleanup robust.
**Fix:**
```swift
case 16:
    let temp16 = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount)
    defer { temp16.deallocate() }
    // ... rest unchanged

case 32:
    let temp32 = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
    defer { temp32.deallocate() }
    // ... rest unchanged
```
**Effort:** 5 min. Zero risk.

---

## Priority 2 — Performance

### 2.1 Cache `groupMedians` in `ImageStore` instead of recomputing in the view
**File:** `SessionChartView.swift` (computed `groupMedians` property)
**Issue:** `groupMedians` sorts all metric values per filter group on every SwiftUI render pass. With 500+ images and frequent layout passes, this is O(n log n) per frame. Currently triggered by any state change — not just metric changes.
**Fix:** Move the computation to `ImageStore` as a stored `[FilterGroup: [MetricKey: Double]]` dictionary, updated inside `updateGroupStatistics()` (which already runs at batch boundaries). The chart reads pre-computed values.
**Effort:** 30 min. Low risk.

---

### 2.2 Pass pre-computed min/max to CPU-path histogram
**File:** `ImageStore.swift` line 1191
**Issue:** The CPU fallback path calls `computeHistogram(pixels:)`, which runs two full vDSP min/max passes to find the histogram range — even though `FITSMetadata.minValue/maxValue` are already computed and available. The GPU path correctly uses the pre-computed bounds (line 1159); the CPU branch misses this optimization.
**Fix:** Add a `(pixels:[Float], minVal:Float, maxVal:Float) -> [Int]` overload to `MetricsCalculator.computeHistogram` and use it in the CPU fallback branch.
**Effort:** 20 min. Low risk.

---

### 2.3 Avoid full-array copy in percentile estimation for small images
**File:** `ImageStretcher.swift` (`estimatePercentiles` function)
**Issue:** For images ≤ `percentileSampleCount` pixels, the code copies the entire array into a new `[Float]` and sorts it. For large images it stride-samples. The stride-sample path is always at least as fast and produces equivalent accuracy; the small-image branch adds an unnecessary O(n) allocation.
**Fix:** Remove the small-image branch; always stride-sample:
```swift
let sampleStride = max(1, count / percentileSampleCount)
var sample = [Float]()
sample.reserveCapacity(min(count, percentileSampleCount))
for i in Swift.stride(from: 0, to: count, by: sampleStride) {
    sample.append(ptr[i])
}
```
**Effort:** 10 min. Zero risk (percentiles are robust to uniform sampling).

---

### 2.4 `BayerClips.median(of:)` — avoid 6 redundant sorts
**File:** `ImageStretcher.swift` (`BayerClips.median(of:)` static method)
**Issue:** Each of the 6 clip channels sorts the full `clips` array independently — 6 × O(n log n) allocations and sorts where 6 × O(n) would suffice if we compute the median index once.
**Fix:** Use a KeyPath-based helper closure to sort once per channel but share the index:
```swift
static func median(of clips: [BayerClips]) -> BayerClips {
    guard !clips.isEmpty else { return BayerClips(loR:0,hiR:1,loG:0,hiG:1,loB:0,hiB:1) }
    let mid = clips.count / 2
    func med(_ kp: KeyPath<BayerClips, Float>) -> Float {
        clips.map { $0[keyPath: kp] }.sorted()[mid]
    }
    return BayerClips(loR: med(\.loR), hiR: med(\.hiR),
                      loG: med(\.loG), hiG: med(\.hiG),
                      loB: med(\.loB), hiB: med(\.hiB))
}
```
This also eliminates the 6-line repetition. Not a real-world bottleneck for folder sizes ≤200, but a clean improvement.
**Effort:** 10 min. Zero risk.

---

## Priority 3 — Architecture / Maintainability

### 3.1 Extract shared filter/folder state conditions to `ImageStore`
**Files:** `ContentView.swift`, `SessionChartView.swift`, `InspectorView.swift`
**Issue:** At least 3 view files independently check `store.activeFilterGroups.count > 1` and `store.activeFolderPaths.count > 1` to gate layout decisions. These checks are duplicated and will drift if the thresholds change.
**Fix:** Add two read-only computed properties to `ImageStore`:
```swift
var isMultiFilter: Bool { activeFilterGroups.count > 1 }
var isMultiFolder: Bool { activeFolderPaths.count > 1 }
```
**Effort:** 15 min. Low risk.

---

### 3.2 Named constants for magic numbers in `MetricsCalculator`
**File:** `MetricsCalculator.swift`
**Issue:** Values like `50_000`, `5000`, `200`, `6000`, `3` appear inline with no explanation of their origin, units, or tuning rationale. This makes future calibration edits opaque.
**Fix:** Declare a private `enum Constants` at the top of `MetricsCalculator`:
```swift
private enum Constants {
    static let maxDetectionCandidates  = 50_000
    static let histogramSampleCount    = 5_000
    static let topCandidatesForFit     = 200
    static let fallbackCandidates      = 6_000
    static let minStarSeparationPx     = 3
}
```
**Effort:** 15 min. Zero risk.

---

### 3.3 Factor out duplicated byte-swap boilerplate in `FITSReader`
**File:** `FITSReader.swift`
**Issue:** The pattern (allocate → memcpy → vImage swap → vDSP convert → defer deallocate) is repeated nearly verbatim for BITPIX=16 and BITPIX=32 in both `read()` and `readIntoBuffer()` — four near-identical blocks.
**Fix:** Extract a `nonisolated private static` helper that takes a typed integer pointer and a vImage swap function, and returns a `[Float]` or fills a destination buffer. This reduces ~120 lines to ~40 and makes future BITPIX additions straightforward.
**Effort:** 45 min. Medium risk — requires careful testing across all BITPIX variants (8, 16, 32).

---

## Priority 4 — UX improvements

### 4.1 Remember selected chart metric across launches
**File:** `SessionChartView.swift`
**Issue:** The chart metric selector is `@State private var selectedMetric`, which resets to `.fwhm` on every launch. Users who prefer SNR or eccentricity must reselect every time.
**Fix:** Change `@State` to `@AppStorage("sessionChartMetric")`. Requires making the metric enum `RawRepresentable` with a `String` raw value (likely already the case if it has a `displayName`).
**Effort:** 5–15 min. Zero risk.

---

### 4.2 Show progress indicator during Bayer colour re-render (Phase B)
**Files:** `ImageStore.swift`, `ContentView.swift`
**Issue:** After the initial grey display, the colour re-render pass (`normalizeBayerStretch`) runs silently. Users may think loading is complete, then see thumbnails flicker unexpectedly to colour. There is no indication that a second pass is in progress.
**Fix:** Add a `var isRecolouring: Bool` flag to `ImageStore`. Set it to `true` before `normalizeBayerStretch`, `false` after. Display a `ProgressView` (small, in the toolbar or status bar) when `isRecolouring` is `true`.
**Effort:** 30 min. Low risk.

---

### 4.3 Keyboard shortcut to toggle colour debayering
**Files:** `AppSettings.swift`, `ContentView.swift`
**Issue:** The "Colour Images" toggle is only accessible in Settings → Image Display. Toggling between grey and colour previews is a useful culling action that should be reachable without leaving the workflow.
**Fix:** Add a `⌘⇧C` menu item (`SimpleModeCommand`-style) that toggles `appSettings.debayerColorImages` and calls `store.reprocessAll()`.
**Effort:** 30 min. Low risk.

---

### 4.4 Show pixel value and image coordinate under cursor
**File:** `ContentView.swift` (main image view area)
**Issue:** There is no readout of x/y coordinates or raw pixel value when hovering over the main image. Useful for verifying star positions and checking background level.
**Fix:** Add an `NSTrackingArea`-based hover readout (via `NSViewRepresentable`) that maps the cursor position back to FITS pixel coordinates and shows `x: N  y: N` in a small overlay or the inspector panel. Raw pixel value requires keeping the source float buffer accessible (already possible since `ImageEntry` has the URL).
**Effort:** 2–3 hr. Low risk, significant UX value for power users.

---

## Priority 5 — Future architectural work (larger scope)

### 5.1 Two-phase loading: display first, metrics second
**Tracked in:** `plan-remainder.md` (detailed plan already written)
**Summary:** `processParallel` currently computes star detection metrics synchronously before marking an image as visible (`isProcessing = false`). On a 20+ MP star field, star detection alone adds 300–500 ms. Splitting into Phase A (GPU decode + display) and Phase B (metrics) would reduce time-to-first-image from ~400 ms to ~80 ms.
**Files affected:** `ImageStore.swift`, `ImageStretcher.swift`, `FITSReader.swift`, `MetricsCalculator.swift`
**Effort:** 4–6 hr. High impact, medium risk. The detailed implementation plan is in `plan-remainder.md`.
**Note:** Implement this after all Priority 1–3 items are done.

---

### 5.2 Star centroid overlay in main image view
**Issue:** The app detects local maxima (GPU kernel) and fits Moffat profiles, but these positions are never visualised. An optional overlay showing detected stars as circles would help users calibrate and trust the metrics, and immediately flag cases where star detection is failing (e.g. near nebula emission).
**Fix:** After `MetricsCalculator.compute()`, store the top N centroid positions on `FrameMetrics`. In the main image view, draw `Canvas` circles over the NSImage when the overlay is enabled (toggleable via inspector checkbox or `⌘⇧O`).
**Effort:** 3–4 hr. Medium complexity, high debugging value.

---

## Summary table

| # | File(s) | Priority | Effort | Category |
|---|---------|----------|--------|----------|
| 1.1 | ContentView.swift | High | 5 min | Correctness |
| 1.2 | FITSReader.swift | Medium | 5 min | Safety |
| 2.1 | SessionChartView.swift, ImageStore.swift | Medium | 30 min | Performance |
| 2.2 | ImageStore.swift, MetricsCalculator.swift | Low | 20 min | Performance |
| 2.3 | ImageStretcher.swift | Low | 10 min | Performance |
| 2.4 | ImageStretcher.swift | Low | 10 min | Performance |
| 3.1 | ContentView.swift, SessionChartView.swift | Low | 15 min | Maintainability |
| 3.2 | MetricsCalculator.swift | Low | 15 min | Maintainability |
| 3.3 | FITSReader.swift | Low | 45 min | Maintainability |
| 4.1 | SessionChartView.swift | Low | 10 min | UX |
| 4.2 | ImageStore.swift, ContentView.swift | Low | 30 min | UX |
| 4.3 | AppSettings.swift, ContentView.swift | Low | 30 min | UX |
| 4.4 | ContentView.swift | Medium | 2–3 hr | UX |
| 5.1 | ImageStore + 3 files | High | 4–6 hr | Architecture |
| 5.2 | ContentView.swift, FrameMetrics.swift | Low | 3–4 hr | Feature |
