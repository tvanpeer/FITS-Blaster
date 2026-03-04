# Plan: Speed up FITS image loading and rendering

## Context

The app has a well-designed GPU path (Metal compute shader + zero-copy MTLBuffer → CGDataProvider) that was never wired into the actual loading pipeline. `ImageStore.loadEntry` always calls the CPU-only path. Additionally, metrics computation (star detection, FWHM, eccentricity) runs synchronously before any image appears — on a busy 20MP star field this can add 300–500ms per image. Together these are the two dominant bottlenecks.

User confirmed: images are typically >20MP and two-phase loading (display first, metrics second) is preferred.

---

## Changes

### 1. `FITSReader.swift` — Vectorize BITPIX=32 byte swap

**Problem:** BITPIX=32 uses a scalar `for` loop to byte-swap each UInt32. The BITPIX=-32 case already uses `vImagePermuteChannels_ARGB8888([3,2,1,0])` which is the correct vectorized approach.

**Fix:** Replace the scalar loop in both `read()` and `readIntoBuffer()` with the same `vImagePermuteChannels_ARGB8888` permute trick (both formats are just 4-byte big-endian values).

```swift
// Replace in case 32: (both read paths)
// BEFORE:
for i in 0..<pixelCount { temp32[i] = temp32[i].byteSwapped }

// AFTER:
var swapBuf = vImage_Buffer(data: temp32, height: vImagePixelCount(header.height),
                             width: vImagePixelCount(header.width), rowBytes: header.width * 4)
var permuteMap: [UInt8] = [3, 2, 1, 0]
vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
```

---

### 2. `MetricsCalculator.swift` — Add pointer-based histogram overload

**Problem:** `computeHistogram` takes `[Float]`, but in Phase 1 the pixel data lives in a Metal shared buffer. We don't want to allocate a full `[Float]` array just for the histogram.

**Fix:** Add a `computeHistogram(ptr: UnsafePointer<Float>, count: Int) -> [Int]` overload. The existing `[Float]` variant becomes a thin wrapper calling through.

```swift
// New primary implementation
static func computeHistogram(ptr: UnsafePointer<Float>, count: Int) -> [Int] { ... }

// Existing signature now just calls the new one
static func computeHistogram(pixels: [Float], width: Int, height: Int) -> [Int] {
    pixels.withUnsafeBufferPointer {
        computeHistogram(ptr: $0.baseAddress!, count: $0.count)
    }
}
```

---

### 3. `ImageStretcher.swift` — Add `maxDisplaySize` to GPU path + post-GPU scale

**Problem:** `createImage(inputBuffer:width:height:)` always produces a full-resolution image. For >20MP images this creates ~20MB NSImages and causes excessive SwiftUI layout work.

**Fix:** Add `maxDisplaySize: Int = 0` parameter. After `commandBuffer.waitUntilCompleted()`:
- If `max(width, height) > maxDisplaySize`: copy output buffer contents → `vImageScale_Planar8` → scaled CGImage (same logic as CPU path's Pass 4)
- If within size limit: keep current zero-copy `CGDataProvider` path

```swift
// Updated signature
static func createImage(inputBuffer: MTLBuffer, width: Int, height: Int,
                        maxDisplaySize: Int = 0) -> NSImage?

// Inside metalStretch, after waitUntilCompleted():
if maxDisplaySize > 0 && max(width, height) > maxDisplaySize {
    let scale = Float(maxDisplaySize) / Float(max(width, height))
    let finalW = max(1, Int(Float(width) * scale))
    let finalH = max(1, Int(Float(height) * scale))
    let scaledData = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH)
    var srcBuf = vImage_Buffer(data: outputBuffer.contents(), height: ..., rowBytes: width)
    var dstBuf = vImage_Buffer(data: scaledData, height: ..., rowBytes: finalW)
    vImageScale_Planar8(&srcBuf, &dstBuf, nil, kvImageHighQualityResampling)
    // Create CGImage from scaledData (same CGDataProvider dealloc pattern as CPU path)
} else {
    // existing zero-copy path unchanged
}
```

---

### 4. `ImageStore.swift` — Wire up GPU path + two-phase loading

**This is the biggest change.** Split `loadEntry` into two separate static functions and restructure `processParallel`.

#### New `loadDisplay` (Phase 1 — fast path):
```swift
private nonisolated static func loadDisplay(
    url: URL, maxDisplaySize: Int, maxThumbnailSize: Int
) async -> DisplayLoadResult {
    // 1. readIntoBuffer (GPU path)
    guard let device = ImageStretcher.metalDevice,
          let result = try? FITSReader.readIntoBuffer(from: url, device: device) else {
        // CPU fallback: FITSReader.read() + ImageStretcher.createImage(from:pixels...)
    }
    // 2. Compute histogram from Metal buffer pointer (fast, no allocation)
    let histogram = MetricsCalculator.computeHistogram(
        ptr: result.metalBuffer.contents().assumingMemoryBound(to: Float.self),
        count: result.metadata.width * result.metadata.height
    )
    // 3. GPU stretch + scale
    let display = ImageStretcher.createImage(
        inputBuffer: result.metalBuffer,
        width: result.metadata.width,
        height: result.metadata.height,
        maxDisplaySize: maxDisplaySize
    )
    // 4. Thumbnail from display image
    let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
    return DisplayLoadResult(display: display, thumb: thumb,
                             info: "\(width) × \(height)  |  BITPIX: \(bitpix)",
                             histogram: histogram, headers: result.metadata.headers)
}
```

#### New `loadMetrics` (Phase 2 — background):
```swift
private nonisolated static func loadMetrics(
    url: URL, config: MetricsConfig
) async -> FrameMetrics? {
    guard let fits = try? FITSReader.read(from: url) else { return nil }
    return MetricsCalculator.compute(pixels: fits.pixelValues,
                                     width: fits.width, height: fits.height,
                                     config: config)
}
```

#### Updated `processParallel`:
Run two sequential `withTaskGroup` passes:

```swift
private func processParallel(...) async {
    // Phase 1: Display images — I/O + GPU bound, higher concurrency
    let phase1Concurrency = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))

    await withTaskGroup(of: Void.self) { group in
        var activeCount = 0
        for entry in entries {
            if activeCount >= phase1Concurrency { await group.next(); activeCount -= 1 }
            group.addTask {
                let result = await Self.loadDisplay(url: entry.url, ...)
                await MainActor.run {
                    entry.displayImage = result.display
                    entry.thumbnail    = result.thumb
                    entry.imageInfo    = result.info
                    entry.histogram    = result.histogram
                    entry.headers      = result.headers
                    entry.isProcessing = false   // ← image visible now
                    // selectFirst logic unchanged
                }
            }
            activeCount += 1
        }
    }

    // Phase 2: Metrics — CPU bound, conservative concurrency
    guard metricsConfig.needsStarDetection else { return }
    let phase2Concurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

    await withTaskGroup(of: Void.self) { group in
        var activeCount = 0
        for entry in entries {
            if activeCount >= phase2Concurrency { await group.next(); activeCount -= 1 }
            group.addTask {
                let metrics = await Self.loadMetrics(url: entry.url, config: metricsConfig)
                await MainActor.run { entry.metrics = metrics }
            }
            activeCount += 1
        }
    }
}
```

#### `reprocessAll` stays the same shape but benefits automatically from the new `processParallel`.

---

## Files modified

| File | Changes |
|---|---|
| `FITSReader.swift` | Vectorize BITPIX=32 byte-swap in `read()` and `readIntoBuffer()` |
| `MetricsCalculator.swift` | Add `computeHistogram(ptr:count:)` overload, existing `[Float]` variant calls through |
| `ImageStretcher.swift` | Add `maxDisplaySize` param to `createImage(inputBuffer:)`, add post-GPU `vImageScale_Planar8` |
| `ImageStore.swift` | Replace `loadEntry` with `loadDisplay` + `loadMetrics`; update `processParallel` to two phases; update `EntryLoadResult` → two separate result types |

---

## What does NOT change

- The Metal shader (`FITSStretch.metal`) — already correct and fast
- The CPU fallback path — kept as fallback when Metal device unavailable
- `recomputeMetrics` — already metrics-only, no changes needed
- Thumbnail generation approach
- All navigation, rejection, rating, export logic
- The sidecar / bookmark system
- `AppSettings`, `ContentView`, `InspectorView` — no UI changes

---

## Expected outcome

| Bottleneck | Before | After |
|---|---|---|
| Display path | CPU (Accelerate LUT + flip + scale) | GPU (Metal compute shader) |
| Time to first image visible | ~400–600ms (includes metrics) | ~80–150ms (display only, metrics follow) |
| BITPIX=32 byte swap | Scalar loop | Vectorized vImage permute |
| Concurrency (Phase 1) | CPU_cores/2 | min(CPU_cores, 8), min 4 |
| Memory per image | ~80MB Metal buffer + full-res CGImage | ~80MB buffer (released after scale) + ~1MB scaled CGImage |

---

## Verification

1. Open Xcode, build (`Cmd+B`) — no compile errors
2. Open a folder of >20MP FITS files — confirm images appear quickly with `isProcessing=false` before quality badges appear
3. Confirm quality badges/histogram fill in shortly after the display image
4. Test with BITPIX=8, 16, 32, -32, -64 files if available
5. Toggle metrics off in Settings — Phase 2 should be skipped entirely
6. Test `Reprocess All` in Settings — should still work correctly
7. Test on a Mac without Metal (unlikely, but CPU fallback should remain functional)
