//
//  MetricsCalculator.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//
//  Public API, orchestration, and shared internal types.
//  Implementation is split across focused extension files:
//    MetricsCalculator+StarDetection.swift   — background estimation, GPU/CPU detection, NMS
//    MetricsCalculator+ShapeMeasurement.swift — FWHM, eccentricity, SNR, crop extraction
//    MetricsCalculator+Scoring.swift          — quality score, histogram, median
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
    struct DetectParams {
        var width:     UInt32   // image width in pixels
        var height:    UInt32   // image height in pixels
        var threshold: Float    // background + 5σ detection threshold
    }

    /// CPU-side mirror of the Metal DetectCandidate struct.
    /// Two UInt32 values → 8 bytes, naturally aligned, no padding.
    struct DetectCandidate {
        var x: UInt32
        var y: UInt32
    }

    // MARK: - Tuning constants

    /// Controls star detection and measurement limits.
    enum Constants {
        /// Must match MAX_DETECTION_CANDIDATES in FITSStretch.metal.
        static let maxDetectionCandidates  = 50_000
        /// Number of stratified samples for background estimation.
        static let backgroundSampleCount   = 5_000
        /// Top N candidates used for full shape measurement (FWHM, ecc, SNR).
        static let topCandidatesForShape   = 200
        /// Additional candidates checked in the fast star-count pass (Phase 2).
        static let fallbackCandidateCount  = 6_000
    }

    /// Must match MAX_DETECTION_CANDIDATES in FITSStretch.metal.
    static let maxDetectionCandidates = Constants.maxDetectionCandidates

    /// Half-width of the pixel crop extracted around each star candidate.
    /// 12 → 25×25 crop; covers the ±10-px Moffat fit window plus the ±2-px
    /// centroid window, with one pixel to spare for bilinear interpolation.
    private static let cropHalf = 12

    // Pipeline state is created once per process and reused for every image.
    // MTLCreateSystemDefaultDevice() is idempotent — it always returns the same
    // device object, so the buffer created by ImageStretcher (also using the
    // default device) is accessible to this pipeline without any copy.
    static let detectionDevice: MTLDevice? = MTLCreateSystemDefaultDevice()

    // A dedicated command queue for detection keeps our GPU work independent
    // from ImageStretcher's stretch queue. Metal queues are thread-safe so this
    // can be called from any thread in the cooperative pool.
    static let detectionCommandQueue: MTLCommandQueue? =
        detectionDevice?.makeCommandQueue()

    // The compiled pipeline state wraps the detectLocalMaxima kernel defined in
    // FITSStretch.metal. makeDefaultLibrary() finds all kernels from all .metal
    // files compiled into the app bundle — no separate library file needed.
    static let detectionPipelineState: MTLComputePipelineState? = {
        guard let device   = detectionDevice,
              let library  = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "detectLocalMaxima") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    // MARK: - Internal types shared with extension files

    /// Intermediate star candidate used internally during detection and NMS.
    struct StarCandidate {
        let x: Int
        let y: Int
        let peak: Float

        /// Sort order for candidates: brightest peak first; equal peaks by row, then column.
        ///
        /// The tie-break makes the order deterministic. 16-bit data has many equal peaks
        /// (saturated stars above all), and the GPU returns candidates in a random order,
        /// so sorting on the peak alone let that order decide which stars were kept and
        /// measured — and the metrics varied between runs on the same file.
        static func brighterFirst(_ a: StarCandidate, _ b: StarCandidate) -> Bool {
            if a.peak != b.peak { return a.peak > b.peak }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
    }

    /// One shape measurement from a parallel task: the candidate's position in the
    /// sorted list, and (fwhm, eccentricity, snr, peak) — nil when the fit was rejected.
    typealias IndexedShape = (index: Int, shape: (Float, Float, Float, Float)?)

    /// Return type for GPU detection.
    struct GPUDetectionResult {
        /// Candidates stored in the output buffer, sorted by peak brightness.
        let candidates: [StarCandidate]
    }

    // MARK: - Public entry points

    /// GPU-accelerated entry point — uses the pixel data already resident in a
    /// Metal shared buffer, so the image is never copied. Star detection runs as
    /// a full-frame compute kernel; shape measurement runs on the CPU using the
    /// same buffer pointer (zero-copy).
    ///
    /// Falls back to the CPU path automatically if the Metal pipeline is
    /// unavailable (e.g. CI, sandboxed test environment).
    @concurrent static func compute(metalBuffer: MTLBuffer,
                                    width: Int, height: Int,
                                    config: MetricsConfig,
                                    bayerPattern: BayerPattern? = nil) async -> FrameMetrics? {
        guard config.needsStarDetection else { return nil }
        let count = width * height
        guard count > 0 else { return nil }

        let floatPtr = metalBuffer.contents().assumingMemoryBound(to: Float.self)
        let pixels   = UnsafeBufferPointer(start: floatPtr, count: count)

        let (background, sigma) = estimateBackground(pixels, width: width, height: height)
        let threshold = background + 5 * sigma

        // Try GPU detection over the full frame; fall back to CPU on failure.
        let allCandidates: [StarCandidate]

        if let result = await findLocalMaximaGPU(metalBuffer: metalBuffer,
                                                  width: width, height: height,
                                                  threshold: threshold) {
            allCandidates = nonMaximumSuppression(result.candidates, imageWidth: width)
        } else {
            let cpu = findLocalMaxima(pixels: pixels,
                                      width: width, height: height,
                                      cropX: 0, cropY: 0,
                                      cropW: width, cropH: height,
                                      threshold: threshold)
            allCandidates = nonMaximumSuppression(cpu, imageWidth: width)
        }

        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sigma: sigma,
                                       width: width, height: height, config: config,
                                       bayerPattern: bayerPattern)
    }

    /// CPU entry point for plain float arrays (e.g. CPU fallback read path).
    /// Scans a centre crop capped at 4096 × 4096 to keep compute time bounded
    /// on very large images. For full-frame analysis use the Metal entry point.
    @concurrent static func compute(pixels: [Float], width: Int, height: Int,
                                    config: MetricsConfig,
                                    bayerPattern: BayerPattern? = nil) async -> FrameMetrics? {
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
        return await computeImpl(pixels: buf, width: width, height: height, config: config,
                                 bayerPattern: bayerPattern)
    }

    // MARK: - Private orchestration

    /// CPU-only implementation. Scans a centre crop capped at 4096² (16× larger
    /// than the old 1024² limit) to cover most of a 16 MP frame while keeping
    /// compute time bounded for the rare cases where Metal is unavailable.
    @concurrent private static func computeImpl(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                                config: MetricsConfig,
                                                bayerPattern: BayerPattern? = nil) async -> FrameMetrics? {
        // 4096² cap: large enough to cover most or all of a typical 16 MP sensor,
        // while bounding worst-case CPU time to ~80 ms for 48 MP+ files.
        let cropW = min(width,  4096)
        let cropH = min(height, 4096)
        let cropX = (width  - cropW) / 2   // centre the crop horizontally
        let cropY = (height - cropH) / 2   // centre the crop vertically

        let (background, sigma) = estimateBackground(pixels, width: width, height: height)
        let threshold = background + 5 * sigma

        let raw = findLocalMaxima(pixels: pixels, width: width, height: height,
                                  cropX: cropX, cropY: cropY,
                                  cropW: cropW, cropH: cropH,
                                  threshold: threshold)
        let allCandidates = nonMaximumSuppression(raw, imageWidth: width)
        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sigma: sigma,
                                       width: width, height: height, config: config,
                                       bayerPattern: bayerPattern)
    }

    /// Shared measurement stage: filters raw candidates, fits PSF models sequentially,
    /// and assembles the final FrameMetrics. Called by both the GPU and CPU paths
    /// after their respective detection steps.
    @concurrent private static func measureCandidates(allCandidates: [StarCandidate],
                                                     pixels: UnsafeBufferPointer<Float>,
                                                     background: Float, sigma: Float,
                                                     width: Int, height: Int,
                                                     config: MetricsConfig,
                                                     bayerPattern: BayerPattern? = nil) async -> FrameMetrics? {

        let needMeasure = config.computeFWHM || config.computeEccentricity || config.computeSNR

        // ── Phase 1: shape statistics (parallel, top 200 candidates) ────────────
        //
        // Candidates are sorted brightest-first, so the top 200 reliably contain
        // enough unsaturated stars for stable median FWHM/eccentricity/SNR estimates.
        // measureShape is pure (no shared mutable state), so fits can run 4-wide
        // across the cooperative thread pool without any synchronisation overhead.

        var fwhmValues:  [Float] = []
        var eccValues:   [Float] = []
        var snrValues:   [Float] = []
        var topVerified  = 0    // PSF-verified count within the top-200 pass
        // PSF Signal Weight accumulator: Σ(peakVal) across verified stars.
        var psfFluxSum:  Float = 0

        // Results arrive in task-completion order; they are aggregated afterwards in
        // candidate order so the float sum (and everything else) is the same on every run.
        var measured: [IndexedShape] = []
        await withTaskGroup(of: IndexedShape.self) { group in
            let innerConcurrency = 4
            var active = 0
            for (index, candidate) in allCandidates.prefix(Constants.topCandidatesForShape).enumerated() {
                if active >= innerConcurrency {
                    if let r = await group.next() { measured.append(r) }
                    active -= 1
                }
                let c = candidate
                group.addTask {
                    let shape: (Float, Float, Float, Float)? = {
                        if let pattern = bayerPattern {
                            let rawCrop = Self.extractCrop(from: pixels, width: width, height: height,
                                                           cx: c.x, cy: c.y, cropHalf: Self.cropHalf)
                            let rec709Lum = Self.debayerCropToLuminance(
                                crop: rawCrop, cropHalf: Self.cropHalf,
                                originX: c.x - Self.cropHalf, originY: c.y - Self.cropHalf,
                                pattern: pattern, weights: .rec709)
                            let (fwhm, eccRec709, snr, peakVal) = Self.measureShapeFromCrop(
                                crop: rec709Lum, cropHalf: Self.cropHalf,
                                background: background, sigma: sigma)
                            guard fwhm >= 0.5, fwhm <= 20 else { return nil }
                            let adaptiveLum = Self.debayerCropToLuminance(
                                crop: rawCrop, cropHalf: Self.cropHalf,
                                originX: c.x - Self.cropHalf, originY: c.y - Self.cropHalf,
                                pattern: pattern, weights: .adaptive)
                            let (_, eccAdaptive, _, _) = Self.measureShapeFromCrop(
                                crop: adaptiveLum, cropHalf: Self.cropHalf,
                                background: background, sigma: sigma)
                            let ecc = eccAdaptive > 0 ? eccAdaptive : eccRec709
                            return (fwhm, ecc, snr, peakVal)
                        } else {
                            let (fwhm, ecc, snr, peakVal) = Self.measureShape(
                                pixels: pixels, width: width, height: height,
                                cx: c.x, cy: c.y, background: background, sigma: sigma)
                            guard fwhm >= 0.5, fwhm <= 20 else { return nil }
                            return (fwhm, ecc, snr, peakVal)
                        }
                    }()
                    return (index, shape)
                }
                active += 1
            }
            for await r in group { measured.append(r) }
        }
        for (_, shape) in measured.sorted(by: { $0.index < $1.index }) {
            guard let (fwhm, ecc, snr, peakVal) = shape else { continue }
            topVerified += 1
            if needMeasure {
                if config.computeFWHM         { fwhmValues.append(fwhm) }
                if config.computeEccentricity { eccValues.append(ecc) }
                if config.computeSNR          { snrValues.append(snr) }
            }
            psfFluxSum += peakVal
        }

        // ── Phase 2: star count via direct measurement of top candidates ─────────
        //
        // Candidates are sorted brightest-first. Real stars are substantially
        // brighter than noise peaks (which cluster just above background + 5σ),
        // so real stars dominate the top of the list. Directly counting up to
        // 6 000 candidates with measureFWHMOnly avoids the extrapolation trap:
        // with a sample+extrapolate approach, even a 1% noise false-positive rate
        // multiplied by ~49 700 remaining candidates adds ~497 phantom stars.
        // Direct counting limits noise contamination to at most a few dozen stars
        // regardless of how large the candidate list is.

        var verifiedCount = topVerified

        if config.computeStarCount, allCandidates.count > Constants.topCandidatesForShape {
            let remaining = allCandidates.dropFirst(Constants.topCandidatesForShape)
                                         .prefix(Constants.fallbackCandidateCount)
            await withTaskGroup(of: Int.self) { group in
                let innerConcurrency = 4
                var active = 0
                for c in remaining {
                    if active >= innerConcurrency {
                        verifiedCount += await group.next() ?? 0
                        active -= 1
                    }
                    group.addTask {
                        let fwhm = Self.measureFWHMOnly(
                            pixels: pixels, width: width, height: height,
                            cx: c.x, cy: c.y, background: background)
                        return (fwhm >= 0.5 && fwhm <= 20) ? 1 : 0
                    }
                    active += 1
                }
                for await count in group { verifiedCount += count }
            }
        }

        let fwhm         = config.computeFWHM         ? median(fwhmValues) : nil
        let eccentricity = config.computeEccentricity ? median(eccValues)  : nil
        let snr          = config.computeSNR          ? median(snrValues)  : nil
        let starCount    = config.computeStarCount    ? verifiedCount      : nil

        // PSF Signal Weight: mean integrated flux per star normalised by sky noise.
        // Nil when no stars were successfully fitted.
        let psfSignalWeight: Float? = topVerified > 0 && sigma > 0
            ? (psfFluxSum / Float(topVerified)) / sigma
            : nil

        let score = qualityScore(fwhm:         config.computeFWHM         ? fwhm         : nil,
                                 eccentricity: config.computeEccentricity ? eccentricity : nil,
                                 snr:          config.computeSNR          ? snr          : nil,
                                 starCount:    config.computeStarCount    ? starCount    : nil)

        return FrameMetrics(fwhm: fwhm, eccentricity: eccentricity,
                            snr: snr, starCount: starCount, qualityScore: score,
                            skyBackground: background, psfSignalWeight: psfSignalWeight)
    }
}
