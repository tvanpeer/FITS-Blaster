//
//  MetricsCalculator.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 01/03/2026.
//

import Foundation
import Accelerate
import Metal

/// Computes per-frame quality metrics from raw FITS float pixel data using
/// Accelerate / vDSP heuristics. All methods are nonisolated and safe to call
/// from the cooperative thread pool.
struct MetricsCalculator {

    // MARK: - Metal state (detection kernel)

    /// CPU-side mirror of the Metal DetectParams struct in FITSStretch.metal.
    /// Field order and types must match exactly so setBytes() copies the right bytes.
    private struct DetectParams {
        var width:     UInt32   // image width in pixels
        var height:    UInt32   // image height in pixels
        var threshold: Float    // background + 5σ detection threshold
    }

    /// CPU-side mirror of the Metal DetectCandidate struct.
    /// Two UInt32 values → 8 bytes, naturally aligned, no padding.
    private struct DetectCandidate {
        var x: UInt32
        var y: UInt32
    }

    /// Must match MAX_DETECTION_CANDIDATES in FITSStretch.metal.
    private static let maxDetectionCandidates = 50_000

    // Pipeline state is created once per process and reused for every image.
    // MTLCreateSystemDefaultDevice() is idempotent — it always returns the same
    // device object, so the buffer created by ImageStretcher (also using the
    // default device) is accessible to this pipeline without any copy.
    private static let detectionDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    // A dedicated command queue for detection keeps our GPU work independent
    // from ImageStretcher's stretch queue. Metal queues are thread-safe so this
    // can be called from any thread in the cooperative pool.
    private static let detectionCommandQueue: MTLCommandQueue? =
        detectionDevice?.makeCommandQueue()

    // The compiled pipeline state wraps the detectLocalMaxima kernel defined in
    // FITSStretch.metal. makeDefaultLibrary() finds all kernels from all .metal
    // files compiled into the app bundle — no separate library file needed.
    private static let detectionPipelineState: MTLComputePipelineState? = {
        guard let device   = detectionDevice,
              let library  = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "detectLocalMaxima") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    // MARK: - Public entry points

    /// GPU-accelerated entry point — uses the pixel data already resident in a
    /// Metal shared buffer, so the image is never copied. Star detection runs as
    /// a full-frame compute kernel; shape measurement runs on the CPU using the
    /// same buffer pointer (zero-copy).
    ///
    /// Falls back to the CPU path automatically if the Metal pipeline is
    /// unavailable (e.g. CI, sandboxed test environment).
    static func compute(metalBuffer: MTLBuffer, device: MTLDevice,
                        width: Int, height: Int,
                        config: MetricsConfig) async -> FrameMetrics? {
        guard config.needsStarDetection else { return nil }
        let count = width * height
        guard count > 0 else { return nil }

        let floatPtr = metalBuffer.contents().assumingMemoryBound(to: Float.self)
        let pixels   = UnsafeBufferPointer(start: floatPtr, count: count)

        let (background, sigma) = estimateBackground(pixels, width: width, height: height)
        let threshold = background + 5 * sigma

        // Saturation level: stars with peak > 90 % of the sensor maximum are
        // likely clipped and would bias FWHM high — excluded from shape fitting.
        var satLevel: Float = 0
        vDSP_maxv(floatPtr, 1, &satLevel, vDSP_Length(count))
        let saturationThreshold = satLevel * 0.90

        // Try GPU detection over the full frame; fall back to CPU on failure.
        let allCandidates: [StarCandidate]
        let detectedTotal: Int   // true star count, may exceed the output buffer cap

        if let result = findLocalMaximaGPU(metalBuffer: metalBuffer,
                                            width: width, height: height,
                                            threshold: threshold) {
            allCandidates = result.candidates
            // Use the raw atomic counter value as the star count: it reflects the
            // true number of qualifying pixels found even when the output buffer
            // was capped at maxDetectionCandidates.
            detectedTotal = result.totalFound
        } else {
            // CPU fallback: scan the full frame without a crop limit.
            let cpu = findLocalMaxima(pixels: pixels,
                                      width: width, height: height,
                                      cropX: 0, cropY: 0,
                                      cropW: width, cropH: height,
                                      threshold: threshold)
            allCandidates = cpu
            detectedTotal = cpu.count
        }

        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates, totalCount: detectedTotal,
                                       pixels: pixels, background: background, sigma: sigma,
                                       saturationThreshold: saturationThreshold,
                                       width: width, height: height, config: config)
    }

    /// CPU entry point for plain float arrays (e.g. CPU fallback read path).
    /// Scans a centre crop capped at 4096 × 4096 to keep compute time bounded
    /// on very large images. For full-frame analysis use the Metal entry point.
    static func compute(pixels: [Float], width: Int, height: Int,
                        config: MetricsConfig) async -> FrameMetrics? {
        guard config.needsStarDetection, !pixels.isEmpty else { return nil }
        // `pixels` is a value parameter whose heap storage is kept alive for the entire
        // duration of this async function. We extract the base address here (before the
        // first suspension point) and reconstruct an UnsafeBufferPointer for computeImpl.
        // This is safe because:
        //   - `pixels` is never mutated after this point, so no COW copy can occur.
        //   - Swift heap arrays are not relocated in memory; `base` stays valid.
        //   - The pointer is fully consumed before this function returns.
        let base = pixels.withUnsafeBufferPointer { $0.baseAddress! }
        let buf  = UnsafeBufferPointer(start: base, count: pixels.count)
        return await computeImpl(pixels: buf, width: width, height: height, config: config)
    }

    /// CPU entry point for a raw pointer (retained for callers that already have
    /// a pointer and do not need full-frame GPU detection).
    static func compute(ptr: UnsafePointer<Float>, count: Int, width: Int, height: Int,
                        config: MetricsConfig) async -> FrameMetrics? {
        guard config.needsStarDetection, count > 0 else { return nil }
        let pixels = UnsafeBufferPointer(start: ptr, count: count)
        return await computeImpl(pixels: pixels, width: width, height: height, config: config)
    }

    /// CPU-only implementation. Scans a centre crop capped at 4096² (16× larger
    /// than the old 1024² limit) to cover most of a 16 MP frame while keeping
    /// compute time bounded for the rare cases where Metal is unavailable.
    private static func computeImpl(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                     config: MetricsConfig) async -> FrameMetrics? {
        // 4096² cap: large enough to cover most or all of a typical 16 MP sensor,
        // while bounding worst-case CPU time to ~80 ms for 48 MP+ files.
        let cropW = min(width,  4096)
        let cropH = min(height, 4096)
        let cropX = (width  - cropW) / 2   // centre the crop horizontally
        let cropY = (height - cropH) / 2   // centre the crop vertically

        let (background, sigma) = estimateBackground(pixels, width: width, height: height)
        let threshold = background + 5 * sigma

        var satLevel: Float = 0
        vDSP_maxv(pixels.baseAddress!, 1, &satLevel, vDSP_Length(pixels.count))
        let saturationThreshold = satLevel * 0.90

        let allCandidates = findLocalMaxima(pixels: pixels, width: width, height: height,
                                            cropX: cropX, cropY: cropY,
                                            cropW: cropW, cropH: cropH,
                                            threshold: threshold)
        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates, totalCount: allCandidates.count,
                                       pixels: pixels, background: background, sigma: sigma,
                                       saturationThreshold: saturationThreshold,
                                       width: width, height: height, config: config)
    }

    /// Sendable wrapper for the read-only pixel buffer, allowing concurrent
    /// per-star measurements to share the same memory without copying.
    ///
    /// Using `@unchecked Sendable` is safe here because:
    ///   - All child tasks only read from the pointer — no writes occur.
    ///   - The buffer's lifetime is guaranteed by the caller to outlast all tasks.
    ///   - Multiple concurrent readers on the same memory is safe on all platforms.
    private struct SharedPixels: @unchecked Sendable {
        let buffer: UnsafeBufferPointer<Float>
        let width:  Int
        let height: Int
    }

    /// Measurement result for a single star candidate.
    private struct StarMeasurement: Sendable {
        let fwhm: Float
        let ecc:  Float
        let snr:  Float
    }

    /// Shared measurement stage: filters raw candidates, fits PSF models in parallel,
    /// and assembles the final FrameMetrics. Called by both the GPU and CPU paths
    /// after their respective detection steps.
    ///
    /// `totalCount` is passed explicitly rather than derived from `allCandidates.count`
    /// because the GPU path may have found more candidates than fit in the output buffer.
    /// The atomic counter value (true total) is passed here so the reported star count
    /// is always accurate, even when the candidate list was capped.
    ///
    /// Per-star shape fitting is parallelized with `withTaskGroup`: each candidate gets
    /// its own task on the cooperative thread pool, so all available CPU cores are used
    /// simultaneously. This is most impactful when measuring 100-200 stars per frame.
    private static func measureCandidates(allCandidates: [StarCandidate],
                                          totalCount: Int,
                                          pixels: UnsafeBufferPointer<Float>,
                                          background: Float, sigma: Float,
                                          saturationThreshold: Float,
                                          width: Int, height: Int,
                                          config: MetricsConfig) async -> FrameMetrics? {

        // For shape measurement: exclude saturated stars (peak near sensor max),
        // then use up to 200 of the remaining brightest. The higher limit (up from 50)
        // is viable because per-star measurement now runs in parallel — 200 stars on
        // 8 cores takes roughly the same wall time as 25 stars measured serially.
        let unsaturated = allCandidates.filter { $0.peak < saturationThreshold }
        let candidates  = Array((unsaturated.isEmpty ? allCandidates : unsaturated).prefix(200))

        // SNR now requires FWHM to set the aperture radius, so any metric that
        // needs star measurement triggers the full measureShape call.
        let needMeasure = config.computeFWHM || config.computeEccentricity || config.computeSNR

        var fwhmValues: [Float] = []
        var eccValues:  [Float] = []
        var snrValues:  [Float] = []

        if needMeasure {
            // Wrap the pixel buffer for concurrent read-only sharing across tasks.
            let shared = SharedPixels(buffer: pixels, width: width, height: height)
            let bg = background, sig = sigma

            // Dispatch one task per candidate — the cooperative thread pool schedules
            // them across all available cores automatically.
            let measurements: [StarMeasurement] = await withTaskGroup(
                of: StarMeasurement?.self
            ) { group in
                for candidate in candidates {
                    group.addTask {
                        let (fwhm, ecc, snr) = measureShape(
                            pixels: shared.buffer, width: shared.width, height: shared.height,
                            cx: candidate.x, cy: candidate.y,
                            background: bg, sigma: sig
                        )
                        // Reject hot pixels (FWHM < 0.5 px) and pathological blobs (> 20 px).
                        guard fwhm >= 0.5, fwhm <= 20 else { return nil }
                        return StarMeasurement(fwhm: fwhm, ecc: ecc, snr: snr)
                    }
                }

                var results: [StarMeasurement] = []
                results.reserveCapacity(candidates.count)
                for await measurement in group {
                    if let m = measurement { results.append(m) }
                }
                return results
            }

            for m in measurements {
                if config.computeFWHM         { fwhmValues.append(m.fwhm) }
                if config.computeEccentricity { eccValues.append(m.ecc) }
                if config.computeSNR, m.snr > 0 { snrValues.append(m.snr) }
            }
        }

        let fwhm         = config.computeFWHM         ? median(fwhmValues) : nil
        let eccentricity = config.computeEccentricity ? median(eccValues)  : nil
        let snr          = config.computeSNR          ? median(snrValues)  : nil
        let starCount    = config.computeStarCount    ? totalCount         : nil

        let score = qualityScore(fwhm:         config.computeFWHM         ? fwhm         : nil,
                                 eccentricity: config.computeEccentricity ? eccentricity : nil,
                                 snr:          config.computeSNR          ? snr          : nil,
                                 starCount:    config.computeStarCount    ? starCount    : nil)

        return FrameMetrics(fwhm: fwhm, eccentricity: eccentricity,
                            snr: snr, starCount: starCount, qualityScore: score)
    }

    /// Compute a 256-bin histogram from sampled raw pixel data via a raw pointer.
    /// Uses stride sampling to keep it fast on large images.
    static func computeHistogram(ptr: UnsafePointer<Float>, count: Int) -> [Int] {
        let binCount = 256
        guard count > 0 else { return [Int](repeating: 0, count: binCount) }

        var minVal: Float = 0
        var maxVal: Float = 0
        vDSP_minv(ptr, 1, &minVal, vDSP_Length(count))
        vDSP_maxv(ptr, 1, &maxVal, vDSP_Length(count))
        guard maxVal > minVal else { return [Int](repeating: 0, count: binCount) }

        let scale = Float(binCount - 1) / (maxVal - minVal)
        var histogram = [Int](repeating: 0, count: binCount)

        let stride = max(1, count / 60_000)
        var i = 0
        while i < count {
            let bin = Int((ptr[i] - minVal) * scale)
            histogram[min(bin, binCount - 1)] += 1
            i += stride
        }
        return histogram
    }

    /// Compute a 256-bin histogram from a Float array. Delegates to the pointer overload.
    static func computeHistogram(pixels: [Float], width: Int, height: Int) -> [Int] {
        pixels.withUnsafeBufferPointer { buf in
            computeHistogram(ptr: buf.baseAddress!, count: buf.count)
        }
    }

    // MARK: - Background estimation

    /// Robust background estimate using stratified sampling + median/MAD.
    private static func estimateBackground(_ pixels: UnsafeBufferPointer<Float>, width: Int, height: Int) -> (median: Float, sigma: Float) {
        let n = pixels.count
        let sampleCount = min(n, 5000)
        let stride = max(1, n / sampleCount)

        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount { samples[i] = pixels[i * stride] }
        vDSP.sort(&samples, sortOrder: .ascending)
        let med = samples[sampleCount / 2]

        var deviations = [Float](repeating: 0, count: sampleCount)
        var negMed = -med
        vDSP_vsadd(samples, 1, &negMed, &deviations, 1, vDSP_Length(sampleCount))
        vDSP_vabs(deviations, 1, &deviations, 1, vDSP_Length(sampleCount))
        vDSP.sort(&deviations, sortOrder: .ascending)
        let mad = deviations[sampleCount / 2]
        let sigma = max(mad * 1.4826, 1.0) // consistent estimator; floor avoids zero

        return (med, sigma)
    }

    // MARK: - Star detection

    private struct StarCandidate {
        let x: Int
        let y: Int
        let peak: Float
    }

    /// Find local maxima above threshold within the centre crop.
    /// Returns candidates sorted by peak flux (brightest first).
    ///
    /// Vectorized pre-filter: uses vDSP_maxv on each crop row to skip rows
    /// that contain no above-threshold pixels entirely. For typical sky backgrounds
    /// (95%+ of pixels below threshold) this eliminates the vast majority of rows
    /// before the scalar 8-neighbour check is ever reached — ~50× faster than
    /// the naive full-scan loop.
    private static func findLocalMaxima(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                        cropX: Int, cropY: Int, cropW: Int, cropH: Int,
                                        threshold: Float) -> [StarCandidate] {
        guard let base = pixels.baseAddress else { return [] }
        var candidates: [StarCandidate] = []
        candidates.reserveCapacity(200)

        let innerLen = vDSP_Length(cropW - 2)   // columns excluding the 1-pixel border

        for y in 1..<(cropH - 1) {
            let origY  = cropY + y
            let rowOff = origY * width + cropX

            // Vectorized row-max: skip the entire row if nothing exceeds the threshold.
            var rowMax: Float = 0
            vDSP_maxv(base + rowOff + 1, 1, &rowMax, innerLen)
            guard rowMax >= threshold else { continue }

            // At least one above-threshold pixel exists — check each for local maximum.
            for x in 1..<(cropW - 1) {
                let origX = cropX + x
                let idx   = origY * width + origX
                let val   = pixels[idx]
                guard val >= threshold else { continue }

                if val > pixels[idx - width - 1] &&
                   val > pixels[idx - width    ] &&
                   val > pixels[idx - width + 1] &&
                   val > pixels[idx         - 1] &&
                   val > pixels[idx         + 1] &&
                   val > pixels[idx + width - 1] &&
                   val > pixels[idx + width    ] &&
                   val > pixels[idx + width + 1] {
                    candidates.append(StarCandidate(x: origX, y: origY, peak: val))
                }
            }
        }

        candidates.sort { $0.peak > $1.peak }
        return candidates
    }

    /// GPU-accelerated full-frame local-maximum detection.
    ///
    /// Dispatches the `detectLocalMaxima` Metal kernel across a grid that covers
    /// every pixel of the image simultaneously. Each thread writes 1 or 0 into a
    /// flat UInt8 flag buffer, then the CPU scans that buffer to collect positions.
    ///
    /// Pipeline:
    ///   1. Allocate a `width × height` byte flag buffer in shared memory.
    ///   2. Encode and commit the compute pass (kernel runs fully on the GPU).
    ///   3. Wait for completion (`waitUntilCompleted` — synchronous, ~3–8 ms
    ///      for 16–50 MP on Apple Silicon).
    ///   4. Linear scan of the flag buffer to collect candidate (x, y, peak)
    ///      tuples (~1–2 ms at memory-bandwidth speed).
    ///
    /// Returns nil if Metal is unavailable, letting the caller fall back to CPU.
    /// Return type for GPU detection: the stored candidates (up to the buffer cap)
    /// plus the true total from the atomic counter, which may exceed the cap.
    private struct GPUDetectionResult {
        /// Candidates stored in the output buffer, sorted by peak brightness.
        /// Count is min(totalFound, maxDetectionCandidates).
        let candidates: [StarCandidate]
        /// Actual number of qualifying pixels found across the full frame.
        /// Use this for star-count reporting, not candidates.count.
        let totalFound: Int
    }

    private static func findLocalMaximaGPU(metalBuffer: MTLBuffer,
                                            width: Int, height: Int,
                                            threshold: Float) -> GPUDetectionResult? {
        guard let queue    = detectionCommandQueue,
              let pipeline = detectionPipelineState,
              let device   = detectionDevice else { return nil }

        // Compact candidate list: at most maxDetectionCandidates × 8 bytes = 80 KB.
        // Far smaller than the old width×height flag buffer (up to 200 MB for 50 MP),
        // and the CPU reads only the slots actually written — no full-frame scan.
        let candidateBytes = maxDetectionCandidates * MemoryLayout<DetectCandidate>.stride
        guard let candidatesBuffer = device.makeBuffer(length: candidateBytes,
                                                       options: .storageModeShared) else {
            return nil
        }

        // Single UInt32 atomic counter. Must be zeroed before each dispatch so
        // the kernel starts counting from 0.
        guard let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                                  options: .storageModeShared) else {
            return nil
        }
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var params = DetectParams(width:     UInt32(width),
                                  height:    UInt32(height),
                                  threshold: threshold)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder       = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(metalBuffer,    offset: 0, index: 0)  // input: float pixels
        encoder.setBuffer(candidatesBuffer, offset: 0, index: 1)  // output: compact list
        encoder.setBuffer(countBuffer,    offset: 0, index: 2)  // output: atomic counter
        encoder.setBytes(&params, length: MemoryLayout<DetectParams>.stride, index: 3)

        // 16×16 threadgroup (256 threads) — standard sweet spot for memory-bound
        // 2D kernels on Apple Silicon. Non-uniform dispatch handles any image size.
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let grid   = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()

        // The atomic counter holds the true number of qualifying pixels found,
        // which may exceed the buffer capacity. Preserve both values separately:
        //   totalFound → reported as star count (accurate even when capped)
        //   storedCount → how many candidates we can actually read back
        let totalFound  = Int(countBuffer.contents().load(as: UInt32.self))
        let storedCount = min(totalFound, maxDetectionCandidates)
        guard storedCount > 0 else { return GPUDetectionResult(candidates: [], totalFound: 0) }

        // Convert the compact DetectCandidate list to StarCandidates, looking up
        // peak values from the input buffer. This is O(storedCount) — typically
        // a few hundred to a few thousand reads, not O(width × height).
        let floatPtr   = metalBuffer.contents().assumingMemoryBound(to: Float.self)
        let gpuEntries = candidatesBuffer.contents()
                             .assumingMemoryBound(to: DetectCandidate.self)

        var candidates: [StarCandidate] = []
        candidates.reserveCapacity(storedCount)
        for i in 0..<storedCount {
            let e = gpuEntries[i]
            let x = Int(e.x), y = Int(e.y)
            candidates.append(StarCandidate(x: x, y: y, peak: floatPtr[y * width + x]))
        }

        candidates.sort { $0.peak > $1.peak }
        return GPUDetectionResult(candidates: candidates, totalFound: totalFound)
    }

    // MARK: - Per-star shape measurement

    /// Compute FWHM, eccentricity, and aperture SNR for a single star.
    ///
    /// **FWHM:** 1D Moffat β=4 fits along X and Y axes (PixInsight default model).
    /// Geometric mean of the two axes gives a single representative value.
    ///
    /// **Eccentricity:** 2D intensity-weighted image moments over a ±10px window,
    /// giving eigenvalues λ₁ ≥ λ₂ of the moment matrix. e = √(1 − λ₂/λ₁).
    /// Orientation-invariant: correctly detects elongation at any angle, unlike
    /// the previous approach of comparing two axis-aligned 1D fits.
    ///
    /// **SNR:** Aperture photometry using a circular aperture of radius 2×FWHM.
    /// SNR = I_net / √(I_net + n_ap·σ²_sky) — simplified CCD equation without
    /// requiring camera gain. I_net is the sum of background-subtracted flux
    /// inside the aperture.
    private static func measureShape(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                     cx: Int, cy: Int, background: Float,
                                     sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float) {
        let peakIndex = cy * width + cx
        guard peakIndex >= 0 && peakIndex < pixels.count else { return (0, 0, 0) }
        guard pixels[peakIndex] > background else { return (0, 0, 0) }

        // Sub-pixel centroid via intensity-weighted 5×5 window.
        let centHalf = 2
        var sumI: Float = 0, sumXI: Float = 0, sumYI: Float = 0
        for dy in -centHalf...centHalf {
            for dx in -centHalf...centHalf {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let val = max(0, pixels[py * width + px] - background)
                sumI  += val
                sumXI += Float(dx) * val
                sumYI += Float(dy) * val
            }
        }
        guard sumI > 0 else { return (0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        // True peak via bilinear interpolation at the sub-pixel centroid.
        let peakVal = bilinear(pixels: pixels, width: width, height: height,
                               x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0) }

        // 1D Moffat β=4 fits for FWHM along X and Y.
        guard let fwhmX = fitMoffat1D(pixels: pixels, width: width, height: height,
                                       centX: centX, centY: centY, peakVal: peakVal,
                                       background: background, horizontal: true),
              let fwhmY = fitMoffat1D(pixels: pixels, width: width, height: height,
                                       centX: centX, centY: centY, peakVal: peakVal,
                                       background: background, horizontal: false)
        else { return (0, 0, 0) }

        // Geometric-mean FWHM — matches PixInsight's single-value summary.
        let fwhm = sqrt(fwhmX * fwhmY)

        // --- Eccentricity via 2D intensity-weighted central moments ---
        //
        // We accumulate three second-order moments over the same ±10px window
        // used by the Moffat fits, measuring offsets from the sub-pixel centroid
        // so the result is independent of where the star lands on the pixel grid:
        //
        //   M_20 = Σ(dx²·I) / ΣI   — spread along X
        //   M_02 = Σ(dy²·I) / ΣI   — spread along Y
        //   M_11 = Σ(dx·dy·I) / ΣI — tilt / cross-axis correlation
        //
        // These form a 2×2 symmetric covariance matrix  [[M_20, M_11],
        //                                                [M_11, M_02]]
        // whose eigenvalues λ₁ ≥ λ₂ give the squared semi-axes of the best-fit
        // intensity ellipse. The closed-form eigenvalues are:
        //
        //   λ₁,₂ = (M_20 + M_02)/2  ±  √[ ((M_20−M_02)/2)² + M_11² ]
        //
        // Eccentricity follows the standard conic definition:
        //   e = √(1 − λ_min / λ_max)
        //
        // A perfectly round star → M_11=0 and M_20=M_02 → λ₁=λ₂ → e=0.
        // A star trailed at 45° → large M_11 → λ₁≫λ₂ → e→1.
        // This correctly detects elongation at any orientation, which the old
        // approach (comparing two axis-aligned 1D Moffat fits) could not do.
        let halfW = 10
        var sumI2: Float = 0, sumXXI: Float = 0, sumYYI: Float = 0, sumXYI: Float = 0
        for dy in -halfW...halfW {
            for dx in -halfW...halfW {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let val = max(0, pixels[py * width + px] - background)
                let fdx = Float(px) - centX   // fractional offset from sub-pixel centroid
                let fdy = Float(py) - centY
                sumI2  += val
                sumXXI += fdx * fdx * val     // M_20 numerator
                sumYYI += fdy * fdy * val     // M_02 numerator
                sumXYI += fdx * fdy * val     // M_11 numerator
            }
        }
        let eccentricity: Float
        if sumI2 > 0 {
            let m20  = sumXXI / sumI2
            let m02  = sumYYI / sumI2
            let m11  = sumXYI / sumI2
            let half = (m20 + m02) * 0.5                                          // (λ₁+λ₂)/2
            let disc = (((m20 - m02) * 0.5) * ((m20 - m02) * 0.5) + m11 * m11).squareRoot() // (λ₁−λ₂)/2
            let lambdaMax = half + disc       // major semi-axis² of intensity ellipse
            let lambdaMin = half - disc       // minor semi-axis²
            eccentricity = lambdaMax > 0 ? sqrt(max(0, 1 - lambdaMin / lambdaMax)) : 0
        } else {
            eccentricity = 0
        }

        // --- Aperture SNR (simplified CCD equation) ---
        //
        // We sum the background-subtracted flux inside a circular aperture of
        // radius r = 2×FWHM, then apply:
        //
        //   SNR = I_net / √(I_net + n_ap·σ²_sky)
        //
        // where:
        //   I_net   = Σ max(0, pixel − background)  over n_ap aperture pixels
        //             — total net stellar signal (proxy for photon count)
        //   n_ap    = number of pixels inside the aperture circle
        //   σ_sky   = per-pixel background standard deviation (from MAD estimator)
        //
        // The two noise terms under the root are:
        //   I_net          — Poisson (shot) noise from the star itself
        //   n_ap · σ²_sky  — accumulated background noise across the aperture
        //
        // This is the standard aperture-photometry SNR formula (Merline & Howell
        // 1995; also used by Siril's quick-photometry mode), simplified by
        // omitting the gain-conversion and readout-noise terms that require
        // calibrated detector data. Without known gain the Poisson term is only
        // a proportional proxy, but it still correctly ranks frames relative to
        // each other within a session recorded on the same camera.
        let r    = 2 * fwhm                   // aperture radius in pixels
        let r2   = r * r
        let rInt = Int(r.rounded(.up))
        let icx  = Int(centX.rounded())
        let icy  = Int(centY.rounded())
        var iNet: Float = 0                   // net stellar flux inside aperture
        var nAp = 0                           // pixel count inside aperture
        for dy in -rInt...rInt {
            for dx in -rInt...rInt {
                guard Float(dx * dx + dy * dy) <= r2 else { continue }   // circular mask
                let px = icx + dx, py = icy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                iNet += max(0, pixels[py * width + px] - background)
                nAp  += 1
            }
        }
        // SNR = I_net / √(shot noise² + background noise²)
        let snr: Float = iNet > 0 ? iNet / sqrt(iNet + Float(nAp) * sigma * sigma) : 0

        return (fwhm, eccentricity, snr)
    }

    /// Fit a 1D Moffat (β=4) profile through (centX, centY) along x or y.
    ///
    /// Linearisation: let z = (A/I)^{1/4} − 1, then z = x²/α².
    /// Weighted regression through origin (w = I−B) gives α directly.
    /// Returns FWHM = 2α·√(2^{1/4}−1) in pixels, or nil on failure.
    private static func fitMoffat1D(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                     centX: Float, centY: Float, peakVal: Float,
                                     background: Float, horizontal: Bool) -> Float? {
        let halfW    = 10
        let minFrac: Float = 0.02   // ignore pixels below 2 % of peak (noise dominated)
        var num: Float = 0, den: Float = 0

        for offset in -halfW...halfW where offset != 0 {
            let fx  = horizontal ? centX + Float(offset) : centX
            let fy  = horizontal ? centY                 : centY + Float(offset)
            let val = bilinear(pixels: pixels, width: width, height: height, x: fx, y: fy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let z  = pow(peakVal / val, Float(0.25)) - 1  // linearised Moffat β=4
            let x2 = Float(offset * offset)
            let w  = val                                    // intensity weight
            num += w * z  * x2   // Σ w·z·x²
            den += w * x2 * x2   // Σ w·x⁴
        }

        guard den > 0, num > 0 else { return nil }
        let alpha = sqrt(den / num)
        // FWHM = 2α·√(2^{1/β}−1), β=4 → factor ≈ 0.870
        let fwhmFactor = 2 * sqrt(pow(Float(2), Float(0.25)) - 1)
        return alpha * fwhmFactor
    }

    /// Bilinear interpolation into a float pixel array.
    private static func bilinear(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                  x: Float, y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let x1 = x0 + 1, y1 = y0 + 1
        guard x0 >= 0 && x1 < width && y0 >= 0 && y1 < height else { return 0 }
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = pixels[y0 * width + x0]
        let p10 = pixels[y0 * width + x1]
        let p01 = pixels[y1 * width + x0]
        let p11 = pixels[y1 * width + x1]
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }

    // MARK: - Quality score

    /// Composite quality score 0–100 from whichever metrics are non-nil.
    /// Weights are renormalised so they always sum to 1.0 over the active set.
    static func qualityScore(fwhm: Float?, eccentricity: Float?,
                             snr: Float?, starCount: Int?) -> Int {
        var weightedSum: Float = 0
        var totalWeight: Float = 0

        if let v = fwhm {
            let w: Float = 0.35
            // Ideal ≤ 2 px, bad at 7 px+
            let s = max(0, min(1, 1 - (v - 2.0) / 5.0))
            weightedSum += s * w; totalWeight += w
        }
        if let v = eccentricity {
            let w: Float = 0.35
            // Ideal 0, bad at 0.5+
            let s = max(0, min(1, 1 - v / 0.5))
            weightedSum += s * w; totalWeight += w
        }
        if let v = snr {
            let w: Float = 0.20
            // Aperture SNR: bad below 10, ideal at 200+
            let s = max(0, min(1, (v - 10) / 190))
            weightedSum += s * w; totalWeight += w
        }
        if let v = starCount {
            let w: Float = 0.10
            // Ideal 500+, bad at 0; log scale so small counts aren't completely penalised
            let s = max(0, min(1, log10(Float(v) + 1) / log10(501)))
            weightedSum += s * w; totalWeight += w
        }

        guard totalWeight > 0 else { return 0 }
        return Int((weightedSum / totalWeight) * 100)
    }

    // MARK: - Helpers

    private static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        var sorted = values
        vDSP.sort(&sorted, sortOrder: .ascending)
        return sorted[sorted.count / 2]
    }
}
