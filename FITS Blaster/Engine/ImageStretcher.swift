//
//  ImageStretcher.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//
//  Stretch statistics: STF clips and midtone. The stretches themselves are in
//  ImageStretcher+CPU.swift and ImageStretcher+Metal.swift.
//

import Foundation
import Accelerate

/// Converts raw FITS pixel data into a displayable image. The stretch is the PixInsight
/// STF: shadow clip, highlight clip and an MTF midtone from the image's own statistics.
///
/// Split by what each part needs (CODE_AUDIT §9.12):
///   - this file: the statistics (clips and midtone), shared by every path;
///   - `ImageStretcher+CPU.swift`: the CPU stretch, thumbnails and RGB images — also used
///     by the Quick Look extensions, which have no Metal;
///   - `ImageStretcher+Metal.swift` (app only): the GPU stretch, a single pass of
///     box-filter downsample → vertical flip → STF clip → MTF stretch → float-to-byte,
///     with the input and output in Metal shared buffers (no copies).
struct ImageStretcher {

    /// Number of random samples used to estimate percentile clip bounds
    private static let percentileSampleCount = 10_000

    // MARK: - Percentile Estimation

    /// Estimate percentile clip bounds separately for each Bayer channel (R, G, B).
    /// Each channel is sampled independently so per-channel stretch eliminates colour casts.
    /// R and B each occupy ~1/4 of pixels; G occupies ~1/2.
    static func estimateBayerPerChannelPercentiles(
        _ ptr: UnsafePointer<Float>, width: Int, height: Int, rOffset: UInt32
    ) -> BayerClips {
        let rx = Int(rOffset & 1)
        let ry = Int((rOffset >> 1) & 1)
        let bx = 1 - rx
        let by = 1 - ry

        // Channel pixel counts
        let rCount = (width / 2) * (height / 2)
        let gCount = width * height / 2
        let rSubstride = max(1, rCount / percentileSampleCount)
        let gSubstride = max(1, gCount / percentileSampleCount)

        var rSamples = [Float](); rSamples.reserveCapacity(percentileSampleCount)
        var gSamples = [Float](); gSamples.reserveCapacity(percentileSampleCount)
        var bSamples = [Float](); bSamples.reserveCapacity(percentileSampleCount)

        // R pixels: every (rx, ry) position in 2×2 cell
        var i = 0
        for row in stride(from: ry, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: rx, to: width, by: 2) {
                if i % rSubstride == 0 { rSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        // B pixels: every (bx, by) position in 2×2 cell
        i = 0
        for row in stride(from: by, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: bx, to: width, by: 2) {
                if i % rSubstride == 0 { bSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        // G pixels: the two remaining positions per 2×2 cell
        i = 0
        for row in stride(from: ry, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: bx, to: width, by: 2) { // (bx, ry) — G in R-row
                if i % gSubstride == 0 { gSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        for row in stride(from: by, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: rx, to: width, by: 2) { // (rx, by) — G in B-row
                if i % gSubstride == 0 { gSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }

        // Each channel's statistics as for grey, but from 2 samples on (§9.6).
        let r = stfStatistics(of: &rSamples, minimumCount: Self.bayerMinimumSamples)
        let g = stfStatistics(of: &gSamples, minimumCount: Self.bayerMinimumSamples)
        let b = stfStatistics(of: &bSamples, minimumCount: Self.bayerMinimumSamples)
        return BayerClips(loR: r.low, hiR: r.high, midR: r.midtone,
                          loG: g.low, hiG: g.high, midG: g.midtone,
                          loB: b.low, hiB: b.high, midB: b.midtone,
                          bgR: r.background, bgG: g.background, bgB: b.background)
    }

    /// MTF midtone that maps `background` to 25% grey after clipping to
    /// [`shadowClip`, `highClip`]: m = 3x / (2x + 1), where x is the normalised background.
    /// Returns 0.25 when the clip range is empty.
    static func mtfMidtone(shadowClip: Float, highClip: Float, background: Float) -> Float {
        let range = highClip - shadowClip
        guard range > 0 else { return 0.25 }
        let x = max(1e-4, min(0.9999, (background - shadowClip) / range))
        return max(0.01, min(0.99, 3 * x / (2 * x + 1)))
    }

    /// Compute STF (Screen Transfer Function) shadow clip, highlight clip, and MTF midtone.
    /// Samples up to `percentileSampleCount` non-zero pixels, computes the median and MAD,
    /// then derives the shadow clip (median − 2.8 × MAD) and the MTF midtone parameter that
    /// places the normalized background at 25% grey: m = 3x / (2x + 1) where x is the
    /// normalized median after shadow clipping.
    static func computeSTFClips(_ ptr: UnsafePointer<Float>, count: Int)
        -> (shadowClip: Float, highClip: Float, midtone: Float) {
        let clips = computeSTFStatistics(ptr, count: count)
        return (clips.low, clips.high, clips.midtone)
    }

    /// Same as `computeSTFClips`, but also keeps the sky background (sample median) so
    /// per-group medians can recompute a midtone that matches the shared clip range.
    static func computeSTFStatistics(_ ptr: UnsafePointer<Float>, count: Int) -> GreyClips {
        guard count > 0 else { return stfFallback }
        let sampleStride = max(1, count / percentileSampleCount)
        var sample = [Float]()
        sample.reserveCapacity(min(count, percentileSampleCount))
        var i = 0
        while i < count {
            let v = ptr[i]
            // Grey sampling skips empty (≤ 0) pixels, e.g. a registered frame's border.
            if v > 0 { sample.append(v) }
            i += sampleStride
        }
        return stfStatistics(of: &sample, minimumCount: greyMinimumSamples)
    }

    /// The highlight clip: this fraction of the sorted samples lies below it (99.99 %).
    static let highClipPercentile: Float = 0.9999
    /// The shadow clip lies this many MADs (median absolute deviations) below the median.
    static let shadowClipMADs: Float = 2.8

    /// Clips used when there are too few samples: the whole range, a 25 % midtone.
    static let stfFallback = GreyClips(low: 0, high: 1, midtone: 0.25, background: 0.1)
    /// Fewest samples for grey statistics; fewer give `stfFallback`.
    static let greyMinimumSamples = 11
    /// Fewest samples per Bayer channel for colour statistics; fewer give `stfFallback`.
    /// Lower than for grey, as it has always been (CODE_AUDIT §9.6; making them the same
    /// would change renders, decision 10: not planned).
    static let bayerMinimumSamples = 2

    /// The STF statistics of a set of samples, the same for grey and every Bayer channel
    /// (CODE_AUDIT §9.6): high clip at the 99.99th percentile, background = median, shadow
    /// clip = median − 2.8 × MAD (not below 0), and the MTF midtone that puts the background
    /// at 25 % grey. Sorts `samples` in place. Fewer than `minimumCount` samples give
    /// `stfFallback`.
    static func stfStatistics(of samples: inout [Float], minimumCount: Int) -> GreyClips {
        guard samples.count >= minimumCount else { return stfFallback }
        vDSP.sort(&samples, sortOrder: .ascending)
        let n        = samples.count
        let highClip = samples[min(n - 1, Int(Float(n - 1) * highClipPercentile))]
        let median   = samples[n / 2]
        var madArr   = samples.map { abs($0 - median) }
        vDSP.sort(&madArr, sortOrder: .ascending)
        let mad        = madArr[madArr.count / 2]
        let shadowClip = max(0, median - shadowClipMADs * mad)
        // mtfMidtone gives 0.25 when the clip range is empty (highClip ≤ shadowClip).
        let midtone    = mtfMidtone(shadowClip: shadowClip, highClip: highClip, background: median)
        return GreyClips(low: shadowClip, high: highClip, midtone: midtone, background: median)
    }
}
