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
    /// 12 → 25×25 crop; covers the ±10-px Moffat fit window plus the ±2-px
    /// centroid window, with one pixel to spare for bilinear interpolation.
    private static let cropHalf = 12

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
        let levels = sky.detectionLevels

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

        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sky: sky,
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

        let raw = findLocalMaxima(pixels: pixels, width: width, height: height,
                                  cropX: cropX, cropY: cropY,
                                  cropW: cropW, cropH: cropH,
                                  levels: sky.detectionLevels)
        let allCandidates = nonMaximumSuppression(raw, imageWidth: width)
        guard !allCandidates.isEmpty else { return nil }
        return await measureCandidates(allCandidates: allCandidates,
                                       pixels: pixels, background: background, sky: sky,
                                       width: width, height: height, config: config,
                                       bayerPattern: bayerPattern)
    }

    /// The level from which a pixel counts as saturated: `saturationFraction` of the frame's
    /// highest value (PixInsight's ImageAnalysis uses ¾ of the maximum for the same purpose).
    private static func saturationLevel(_ pixels: UnsafeBufferPointer<Float>) -> Float {
        guard let base = pixels.baseAddress, !pixels.isEmpty else { return .infinity }
        var maximum: Float = 0
        vDSP_maxv(base, 1, &maximum, vDSP_Length(pixels.count))
        return maximum * Constants.saturationFraction
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

        // ── Phase 1: shape statistics (top 200 candidates) ───────────────────────
        //
        // Candidates are sorted brightest-first, so the top 200 reliably contain
        // enough unsaturated stars for stable median FWHM/eccentricity/SNR estimates.
        // The fits run one after another, in candidate order: several frames are
        // measured at the same time during a load, which keeps the cores busy, and the
        // pixel pointer then never crosses into another task (CODE_AUDIT §3.3, §3.8).
        // Aggregating in candidate order keeps the float sums the same on every run.

        var fwhmValues:  [Float] = []
        var eccValues:   [Float] = []
        var snrValues:   [Float] = []
        var topVerified  = 0    // PSF-verified count within the top-200 pass
        // PSF Signal Weight accumulator: Σ(peakVal) across verified stars.
        var psfFluxSum:  Float = 0

        // Colour frames: saturated stars are left out of the shape measurements and counted
        // once each (master-plan step 13a). With the channel backgrounds subtracted a
        // saturated R or B pixel beats its saturated G neighbours, so saturated stars are
        // detected and would otherwise fill the brightest 200. Mono frames take the first 200
        // candidates as before.
        var saturated: SaturatedStars? = bayerPattern.map { _ in
            SaturatedStars(pixels: pixels, width: width, height: height, level: Self.saturationLevel(pixels))
        }
        var shapeCandidates: [StarCandidate] = []
        var saturatedStars = 0
        var nextCandidate = 0   // the first candidate Phase 2 looks at
        if saturated != nil {
            while nextCandidate < allCandidates.count, shapeCandidates.count < Constants.topCandidatesForShape {
                let c = allCandidates[nextCandidate]
                nextCandidate += 1
                switch saturated?.classify(x: c.x, y: c.y) {
                case .newStar:  saturatedStars += 1
                case .sameStar: break
                default:        shapeCandidates.append(c)
                }
            }
        } else {
            shapeCandidates = Array(allCandidates.prefix(Constants.topCandidatesForShape))
            nextCandidate = shapeCandidates.count
        }

        for c in shapeCandidates {
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
                    guard Shape.acceptedFWHM.contains(fwhm) else { return nil }
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
                    guard Shape.acceptedFWHM.contains(fwhm) else { return nil }
                    return (fwhm, ecc, snr, peakVal)
                }
            }()
            guard let (fwhm, ecc, snr, peakVal) = shape else { continue }
            topVerified += 1
            fwhmValues.append(fwhm)
            eccValues.append(ecc)
            snrValues.append(snr)
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
        // regardless of how large the candidate list is. Each check takes about a
        // microsecond, less than a child task would cost, so they run in one loop (§3.8).

        var verifiedCount = topVerified + saturatedStars

        if allCandidates.count > nextCandidate {
            let remaining = allCandidates[nextCandidate...].prefix(Constants.fallbackCandidateCount)
            for c in remaining {
                switch saturated?.classify(x: c.x, y: c.y) {
                case .newStar:  verifiedCount += 1; continue
                case .sameStar: continue
                default:        break
                }
                let fwhm = Self.measureFWHMOnly(
                    pixels: pixels, width: width, height: height,
                    cx: c.x, cy: c.y, sky: sky)
                if Shape.acceptedFWHM.contains(fwhm) { verifiedCount += 1 }
            }
        }

        let fwhm         = median(fwhmValues)
        let eccentricity = median(eccValues)
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
