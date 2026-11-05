//
//  MetricsCalculator.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//
//  Public API and orchestration.
//  Implementation is split across focused extension files:
//    MetricsCalculator+Types.swift            — shared types and tuning constants
//    MetricsCalculator+StarDetection.swift    — background estimation, GPU/CPU detection, NMS
//    MetricsCalculator+ShapeMeasurement.swift — FWHM, eccentricity, SNR
//    MetricsCalculator+Bayer.swift            — star crops and their Bayer demosaic
//    MetricsCalculator+Scoring.swift          — quality score, histogram, median
//

import Foundation
import Accelerate
import Metal

/// Computes per-frame quality metrics from raw FITS float pixel data using
/// Accelerate / vDSP heuristics. All methods are nonisolated and safe to call
/// from the cooperative thread pool.
struct MetricsCalculator {

    /// Room for this many candidates in the first GPU detection pass.
    static let maxDetectionCandidates = Constants.maxDetectionCandidates

    /// Half-width of the pixel crop extracted around each star candidate.

    // The detection pipeline, device and queue are MetalContext's, shared with the
    // stretch: the frame's buffer from Phase A is used without a copy.

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

        let (background, sky) = skyLevels(pixels, width: width, height: height, bayerPattern: bayerPattern)
        let saturation = saturationLevel(pixels)
        let levels = sky.detectionLevels(saturation: saturation ?? .infinity)

        // Try GPU detection over the full frame; fall back to CPU on failure.
        let allCandidates: [StarCandidate]

        if let result = await findLocalMaximaGPU(metalBuffer: metalBuffer,
                                                  width: width, height: height,
                                                  levels: levels) {
            allCandidates = nonMaximumSuppression(result.candidates, imageWidth: width)
        } else {
            let cpu = findLocalMaxima(pixels: pixels,
                                      width: width, height: height,
                                      cropX: 0, cropY: 0,
                                      cropW: width, cropH: height,
                                      levels: levels)
            allCandidates = nonMaximumSuppression(cpu, imageWidth: width)
        }

        guard !allCandidates.isEmpty else { return noStars(starCount: 0, background: background) }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sky: sky,
                                       saturation: saturation,
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
        // computeImpl suspends, and a pointer from `withUnsafeBufferPointer` is only valid
        // inside its closure (CODE_AUDIT §3.10). So the pixels are copied into a buffer
        // this function owns and frees when computeImpl has returned. Only the CPU
        // fallback (no Metal) comes here, so the copy costs nothing in normal use.
        let buffer = UnsafeMutableBufferPointer<Float>.allocate(capacity: pixels.count)
        defer { buffer.deallocate() }
        _ = buffer.initialize(from: pixels)
        return await computeImpl(pixels: UnsafeBufferPointer(buffer), width: width, height: height,
                                 config: config, bayerPattern: bayerPattern)
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
        let cropW = min(width,  Constants.cpuDetectionCropSide)
        let cropH = min(height, Constants.cpuDetectionCropSide)
        let cropX = (width  - cropW) / 2   // centre the crop horizontally
        let cropY = (height - cropH) / 2   // centre the crop vertically

        let (background, sky) = skyLevels(pixels, width: width, height: height, bayerPattern: bayerPattern)
        let saturation = saturationLevel(pixels)

        let raw = findLocalMaxima(pixels: pixels, width: width, height: height,
                                  cropX: cropX, cropY: cropY,
                                  cropW: cropW, cropH: cropH,
                                  levels: sky.detectionLevels(saturation: saturation ?? .infinity))
        let allCandidates = nonMaximumSuppression(raw, imageWidth: width)
        guard !allCandidates.isEmpty else { return noStars(starCount: 0, background: background) }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sky: sky,
                                       saturation: saturation,
                                       width: width, height: height, config: config,
                                       bayerPattern: bayerPattern)
    }

    /// Room for the ring samples of `localContrast` (pixels of one cell position at 6–10 px).
    private static let contrastRingCapacity = 128

    /// How far the pixel at (x, y) stands above its local sky, in units of the local noise:
    /// (pixel − median) ÷ (1.4826 × MAD) of the pixels in the star's ring (`sizes`: 6–10 px
    /// for stars up to about 4 px, 1.5–2.5 × FWHM for larger ones, step 13i) at the same
    /// position of the 2×2 cell (the same colour channel on a raw colour frame). Infinite when
    /// the ring has no spread and the pixel is above it. `ring` is a reused buffer.
    static func localContrast(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                              x: Int, y: Int, ring: inout [Float],
                              sizes: StarSizes = .normal) -> Float {
        let inner2 = sizes.ringInner * sizes.ringInner, outer = sizes.ringOuter, outer2 = outer * outer
        ring.removeAll(keepingCapacity: true)
        // Only the pixels at the same position of the 2×2 cell (same parity as x and y), and
        // per row only the x range the ring covers: the same samples as testing every pixel
        // of the square, about 9 × fewer visited (the rings of large stars, step 13i).
        let firstY = Self.sameParity(max(0, y - outer), as: y)
        for py in stride(from: firstY, through: min(height - 1, y + outer), by: 2) {
            let dy2 = (py - y) * (py - y)
            let reach = Self.integerSquareRoot(outer2 - dy2)
            let row = py * width
            for px in stride(from: Self.sameParity(max(0, x - reach), as: x),
                             through: min(width - 1, x + reach), by: 2) {
                let dx = px - x
                if dx * dx + dy2 >= inner2 { ring.append(pixels[row + px]) }
            }
        }
        guard !ring.isEmpty else { return 0 }
        let middle = ring.count / 2
        let median = Self.orderStatistic(&ring, middle)
        for i in ring.indices { ring[i] = abs(ring[i] - median) }
        let noise = Self.orderStatistic(&ring, middle) * 1.4826
        let excess = pixels[y * width + x] - median
        guard noise > 0 else { return excess > 0 ? .infinity : 0 }
        return excess / noise
    }

    /// `value`, or the next number up when its parity differs from `reference`'s.
    private static func sameParity(_ value: Int, as reference: Int) -> Int {
        value + ((value ^ reference) & 1)
    }

    /// The largest integer whose square is at most `n` (0 for negative `n`).
    static func integerSquareRoot(_ n: Int) -> Int {
        guard n > 0 else { return 0 }
        var root = Int(Double(n).squareRoot())
        while root * root > n { root -= 1 }
        while (root + 1) * (root + 1) <= n { root += 1 }
        return root
    }

    /// The `k`-th smallest value of `values` (0-based), the value `values.sorted()[k]` gives,
    /// found by selection instead of a full sort; reorders `values`.
    static func orderStatistic(_ values: inout [Float], _ k: Int) -> Float {
        values.withUnsafeMutableBufferPointer { v in
            var low = 0, high = v.count - 1
            while low < high {
                // Median of three as pivot; Hoare partition.
                let mid = low + (high - low) / 2
                if v[mid] < v[low] { v.swapAt(mid, low) }
                if v[high] < v[low] { v.swapAt(high, low) }
                if v[high] < v[mid] { v.swapAt(high, mid) }
                let pivot = v[mid]
                var i = low, j = high
                while i <= j {
                    while v[i] < pivot { i += 1 }
                    while pivot < v[j] { j -= 1 }
                    if i <= j { v.swapAt(i, j); i += 1; j -= 1 }
                }
                if k <= j { high = j } else if k >= i { low = i } else { break }
            }
            return v[k]
        }
    }

    /// The metrics of a frame without stars (fewer than `minimumStars`, none at all when
    /// detection found no candidates): the star count as counted, the sky background, no
    /// FWHM, eccentricity, SNR or PSF·S, and score 0 (step 13g, CODE_AUDIT §5.4). Before,
    /// a frame without candidates got no metrics at all, so no check could reject it, and
    /// one or two spurious "stars" on a flat could give it a score of 40.
    static func noStars(starCount: Int, background: Float) -> FrameMetrics {
        FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: starCount, qualityScore: 0,
                     skyBackground: background, psfSignalWeight: nil)
    }

    /// The fitted stars FWHM and eccentricity are taken from (step 13f): those with local
    /// contrast ≥ `shapeContrast`, or, when fewer than `shapeMinimumStars` reach it, the
    /// `shapeMinimumStars` with the highest contrast (ties: brightest first, i.e. the earlier
    /// one). Falling back to all stars would bring back the noisy faint ones.
    static func brightStarsForShape(_ stars: [(contrast: Float, fwhm: Float, ecc: Float)])
        -> [(contrast: Float, fwhm: Float, ecc: Float)] {
        let bright = stars.filter { $0.contrast >= Constants.shapeContrast }
        guard bright.count < Constants.shapeMinimumStars else { return bright }
        let order = stars.indices.sorted { a, b in
            stars[a].contrast != stars[b].contrast ? stars[a].contrast > stars[b].contrast : a < b
        }
        return order.prefix(Constants.shapeMinimumStars).map { stars[$0] }
    }

    /// The level from which a pixel counts as saturated: `saturationFraction` of the frame's
    /// highest value (PixInsight's ImageAnalysis uses ¾ of the maximum for the same purpose).
    /// Nil when the frame isn't clipped: fewer than `saturatedPixelsAtMaximum` pixels share
    /// exactly the highest value, so it is one bright star, not saturation (step 13d).
    static func saturationLevel(_ pixels: UnsafeBufferPointer<Float>) -> Float? {
        guard let base = pixels.baseAddress, !pixels.isEmpty else { return nil }
        var maximum: Float = 0
        vDSP_maxv(base, 1, &maximum, vDSP_Length(pixels.count))
        guard maximum > 0 else { return nil }
        var atMaximum = 0
        for value in pixels where value == maximum {
            atMaximum += 1
            if atMaximum >= Constants.saturatedPixelsAtMaximum { return maximum * Constants.saturationFraction }
        }
        return nil
    }

    /// The frame's sky: the background over all pixels (the Sky BG value, unchanged by step
    /// 13a) and the levels the detection and measurement use. Mono frames: that one
    /// background and σ everywhere. Raw colour frames: background and σ per position of the
    /// 2×2 Bayer cell, so the sky colour no longer counts as noise (master-plan step 13a).
    private static func skyLevels(_ pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                  bayerPattern: BayerPattern?) -> (background: Float, sky: SkyLevels) {
        let (background, sigma) = estimateBackground(pixels, width: width, height: height)
        guard bayerPattern != nil else { return (background, .uniform(background: background, sigma: sigma)) }
        return (background, estimateChannelLevels(pixels, width: width, height: height))
    }

    /// Shared measurement stage: filters raw candidates, fits PSF models sequentially,
    /// and assembles the final FrameMetrics. Called by both the GPU and CPU paths
    /// after their respective detection steps.
    @concurrent private static func measureCandidates(allCandidates: [StarCandidate],
                                                     pixels: UnsafeBufferPointer<Float>,
                                                     background: Float, sky: SkyLevels,
                                                     saturation: Float?,
                                                     width: Int, height: Int,
                                                     config: MetricsConfig,
                                                     bayerPattern: BayerPattern? = nil) async -> FrameMetrics? {
        // σ for SNR and PSF·S. Mono: the frame's σ, as before. Colour: the noise of the
        // luminance the star crops are measured on, from the channel σ's (step 13a).
        // The star fits keep the single background of the whole frame on both: subtracting
        // the channel backgrounds under the fits made FWHM and eccentricity agree less with
        // PixInsight (California eccentricity order −0.47 against +0.82; architecture-plan
        // 13a), so that part of 13a was dropped.
        let sigma = bayerPattern.map { sky.luminanceSigma(pattern: $0) } ?? sky.sigma[0]

        // ── Phase 1: star count, and the stars to measure ────────────────────────
        //
        // Every candidate is checked (master-plan step 13c; before, only the first 6,200,
        // and on uncalibrated frames thousands of hot pixels came first in the brightness
        // order, so faint real stars were never looked at). A candidate counts as a star when
        //   • the quick profile check accepts it (`measureFWHMOnly`: all four neighbours
        //     carry part of the peak, which keeps hot pixels out, and a plausible FWHM), and
        //   • its peak stands at least `countContrast` × the local noise above the local sky
        //     (`localContrast`), which keeps noise peaks on nebula and peaks below
        //     PixInsight's detection out.
        // Saturated stars count once each, when their neighbours are bright too (a saturated
        // hot pixel doesn't count), and are not measured: their tops are clipped (colour:
        // step 13a, mono: step 13d). With k = 12 the counts of six test frames lie within
        // ±18 % of PixInsight's real stars (architecture-plan 13c).
        //
        // The first `topCandidatesForShape` unsaturated stars, brightest first, are the ones
        // measured in phase 2 (step 13e). Before, the brightest 200 candidates were measured
        // whether they were stars or not; on uncalibrated frames many were hot pixels, which
        // the shape fit accepts, and they pulled FWHM, eccentricity, SNR and PSF·S around.
        // Each check takes microseconds, so they run in one loop (§3.8).

        // Each star's ring, fit window and crop follow its own quick FWHM (step 13i): the
        // fixed 6–10 px ring lies on the flank of stars of 12 px and more. A star whose quick
        // FWHM fills the normal ±10 px window is measured again with a wider one.
        func quickFWHM(_ c: StarCandidate) -> Float {
            let fwhm = Self.measureFWHMOnly(pixels: pixels, width: width, height: height,
                                            cx: c.x, cy: c.y, sky: sky)
            guard fwhm > StarSizes.quickWindowLimit else { return fwhm }
            let wide = Self.measureFWHMOnly(pixels: pixels, width: width, height: height,
                                            cx: c.x, cy: c.y, sky: sky,
                                            halfWidth: StarSizes.forStar(fwhm: fwhm).fitHalfWidth)
            return wide > 0 ? wide : fwhm
        }
        // Largest accepted FWHM: 20 px, or 2.5 × the frame's typical star where that is more,
        // so the long axis of elongated large stars isn't taken for a galaxy (step 13i).
        let acceptedFWHM = Self.acceptedFWHMRange(
            typical: Self.typicalQuickFWHM(allCandidates, saturation: saturation, quickFWHM: quickFWHM))

        var verifiedCount = 0
        // The stars to fit, each with its local contrast and sizes (used again in phase 2).
        var shapeCandidates: [(candidate: StarCandidate, contrast: Float, sizes: StarSizes)] = []
        shapeCandidates.reserveCapacity(Constants.topCandidatesForShape)
        var saturated = saturation.map {
            SaturatedStars(pixels: pixels, width: width, height: height, level: $0)
        }
        var ring: [Float] = []
        ring.reserveCapacity(Self.contrastRingCapacity)
        // Counted stars larger than normal: a wide, noisy star top has several local maxima,
        // and with a ring sized to the star the second one passes the contrast check too.
        var largeStars = LargeStarIndex()
        for c in allCandidates {
            switch saturated?.classify(x: c.x, y: c.y) {
            case .newStar:
                // A saturated hot pixel is one bright pixel with its neighbours at sky level;
                // a saturated star's neighbours are bright too (step 13d).
                if Self.hasStarNeighbours(pixels: pixels, width: width, height: height,
                                          cx: c.x, cy: c.y, sky: sky) { verifiedCount += 1 }
                continue
            case .sameStar: continue
            default:        break
            }
            let fwhm = quickFWHM(c)
            guard acceptedFWHM.contains(fwhm) else { continue }
            let sizes = StarSizes.forStar(fwhm: fwhm)
            let isLarge = sizes != .normal
            if isLarge, largeStars.isOnCountedStar(x: c.x, y: c.y) { continue }
            let contrast = Self.localContrast(pixels: pixels, width: width, height: height,
                                              x: c.x, y: c.y, ring: &ring, sizes: sizes)
            guard contrast >= Constants.countContrast else { continue }
            if isLarge { largeStars.insert(x: c.x, y: c.y, fwhm: fwhm) }
            verifiedCount += 1
            if shapeCandidates.count < Constants.topCandidatesForShape {
                shapeCandidates.append((candidate: c, contrast: contrast, sizes: sizes))
            }
        }

        // Too few stars to measure: a frame without stars (step 13g).
        guard verifiedCount >= Constants.minimumStars else {
            return noStars(starCount: verifiedCount, background: background)
        }

        // ── Phase 2: shape statistics (up to 200 stars) ──────────────────────────
        //
        // The fits run one after another, in candidate order: several frames are
        // measured at the same time during a load, which keeps the cores busy, and the
        // pixel pointer then never crosses into another task (CODE_AUDIT §3.3, §3.8).
        // Aggregating in candidate order keeps the float sums the same on every run.
        //
        // SNR and PSF·S use every fitted star: they follow the transparency through the
        // faint stars as well. FWHM and eccentricity use only the bright ones (step 13f):
        // noise makes a faint star's fit wider and more elongated (a round star at peak
        // SNR 40 measures eccentricity 0.4–0.75), and on frames with few bright stars the
        // faint ones would dominate the median.

        var fitted: [(contrast: Float, fwhm: Float, ecc: Float)] = []
        var snrValues:   [Float] = []
        var topVerified  = 0    // PSF-verified count within the measured stars
        // PSF Signal Weight accumulator: Σ(peakVal) across verified stars.
        var psfFluxSum:  Float = 0

        for (c, contrast, sizes) in shapeCandidates {
            let shape: (Float, Float, Float, Float)? = {
                if let pattern = bayerPattern {
                    let rawCrop = Self.extractCrop(from: pixels, width: width, height: height,
                                                   cx: c.x, cy: c.y, cropHalf: sizes.cropHalf)
                    let rec709Lum = Self.debayerCropToLuminance(
                        crop: rawCrop, cropHalf: sizes.cropHalf,
                        originX: c.x - sizes.cropHalf, originY: c.y - sizes.cropHalf,
                        pattern: pattern, weights: .rec709)
                    let (fwhm, eccRec709, snr, peakVal) = Self.measureShapeFromCrop(
                        crop: rec709Lum, cropHalf: sizes.cropHalf,
                        background: background, sigma: sigma, halfWidth: sizes.fitHalfWidth)
                    guard acceptedFWHM.contains(fwhm) else { return nil }
                    let adaptiveLum = Self.debayerCropToLuminance(
                        crop: rawCrop, cropHalf: sizes.cropHalf,
                        originX: c.x - sizes.cropHalf, originY: c.y - sizes.cropHalf,
                        pattern: pattern, weights: .adaptive)
                    let (_, eccAdaptive, _, _) = Self.measureShapeFromCrop(
                        crop: adaptiveLum, cropHalf: sizes.cropHalf,
                        background: background, sigma: sigma, halfWidth: sizes.fitHalfWidth)
                    let ecc = eccAdaptive > 0 ? eccAdaptive : eccRec709
                    return (fwhm, ecc, snr, peakVal)
                } else {
                    let (fwhm, ecc, snr, peakVal) = Self.measureShape(
                        pixels: pixels, width: width, height: height,
                        cx: c.x, cy: c.y, background: background, sigma: sigma,
                        halfWidth: sizes.fitHalfWidth)
                    guard acceptedFWHM.contains(fwhm) else { return nil }
                    return (fwhm, ecc, snr, peakVal)
                }
            }()
            guard let (fwhm, ecc, snr, peakVal) = shape else { continue }
            topVerified += 1
            fitted.append((contrast: contrast, fwhm: fwhm, ecc: ecc))
            snrValues.append(snr)
            psfFluxSum += peakVal
        }

        let forShape = Self.brightStarsForShape(fitted)
        let fwhm         = median(forShape.map(\.fwhm))
        let eccentricity = median(forShape.map(\.ecc))
        let snr          = median(snrValues)
        let starCount    = verifiedCount

        // PSF Signal Weight: mean background-subtracted star peak divided by the sky sigma.
        // Nil when no stars were successfully fitted.
        let psfSignalWeight: Float? = topVerified > 0 && sigma > 0
            ? (psfFluxSum / Float(topVerified)) / sigma
            : nil

        let score = qualityScore(fwhm: fwhm, eccentricity: eccentricity, snr: snr, starCount: starCount)

        return FrameMetrics(fwhm: fwhm, eccentricity: eccentricity,
                            snr: snr, starCount: starCount, qualityScore: score,
                            skyBackground: background, psfSignalWeight: psfSignalWeight)
    }
}
