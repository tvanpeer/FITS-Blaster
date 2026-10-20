//
//  ClipNormalisationTests.swift
//  FITS Blaster Tests
//
//  Tests for per-folder shared stretch clips: GreyClips.median, BayerClips.median,
//  ImageStretcher.mtfMidtone and computeSTFStatistics.
//

import Testing
@testable import FITS_Blaster

struct ClipNormalisationTests {

    /// Applies the MTF used by the stretch kernels to a value already normalised to [0, 1].
    private func mtf(_ x: Float, midtone m: Float) -> Float {
        (m - 1) * x / ((2 * m - 1) * x - m)
    }

    /// Per-image clips built the same way the app builds them: the midtone follows from
    /// that image's own low, high and background.
    private func greyClips(low: Float, high: Float, background: Float) -> GreyClips {
        GreyClips(low: low, high: high,
                  midtone: ImageStretcher.mtfMidtone(shadowClip: low, highClip: high, background: background),
                  background: background)
    }

    private func bayerClips(green: (low: Float, high: Float, background: Float)) -> BayerClips {
        let neutral = greyClips(low: 0.006, high: 0.15, background: 0.009)
        let g = greyClips(low: green.low, high: green.high, background: green.background)
        return BayerClips(loR: neutral.low, hiR: neutral.high, midR: neutral.midtone,
                          loG: g.low, hiG: g.high, midG: g.midtone,
                          loB: neutral.low, hiB: neutral.high, midB: neutral.midtone,
                          bgR: neutral.background, bgG: g.background, bgB: neutral.background)
    }

    // MARK: - mtfMidtone

    @Test("Midtone maps the background to 25% grey")
    func midtoneMapsBackgroundToQuarterGrey() {
        let midtone = ImageStretcher.mtfMidtone(shadowClip: 0.006, highClip: 0.22, background: 0.009)
        let x = (0.009 - 0.006) / (0.22 - 0.006) as Float
        #expect(abs(mtf(x, midtone: midtone) - 0.25) < 0.001)
    }

    @Test("Empty clip range falls back to a midtone of 0.25")
    func emptyRangeFallsBack() {
        #expect(ImageStretcher.mtfMidtone(shadowClip: 0.5, highClip: 0.5, background: 0.5) == 0.25)
    }

    // MARK: - GreyClips.median

    @Test("Median of one image returns that image's clips")
    func greyMedianOfOneIsIdentity() {
        let clips = greyClips(low: 0.01, high: 0.3, background: 0.02)
        let shared = GreyClips.median(of: [clips])
        #expect(shared.low == clips.low)
        #expect(shared.high == clips.high)
        #expect(shared.background == clips.background)
        #expect(shared.midtone == clips.midtone)
    }

    @Test("Shared grey midtone is recomputed from the shared low, high and background")
    func greyMedianRecomputesMidtone() {
        let clips = [
            greyClips(low: 0.0060, high: 0.2239, background: 0.0090),
            greyClips(low: 0.0060, high: 0.0936, background: 0.0090),
            greyClips(low: 0.0060, high: 0.2372, background: 0.0090)
        ]
        let shared = GreyClips.median(of: clips)
        let expected = ImageStretcher.mtfMidtone(shadowClip: shared.low, highClip: shared.high,
                                                 background: shared.background)
        #expect(shared.midtone == expected)
    }

    // MARK: - BayerClips.median

    @Test("Median of one Bayer image returns that image's clips")
    func bayerMedianOfOneIsIdentity() {
        let clips = bayerClips(green: (0.006, 0.22, 0.0095))
        let shared = BayerClips.median(of: [clips])
        #expect(shared.loG == clips.loG)
        #expect(shared.hiG == clips.hiG)
        #expect(shared.midG == clips.midG)
        #expect(shared.bgG == clips.bgG)
        #expect(shared.midR == clips.midR)
        #expect(shared.midB == clips.midB)
    }

    /// Reproduces the magenta cast on the M31 sample set: the green high clip swings
    /// between frames, and the median high and median midtone came from different frames.
    /// The shared green midtone must still put the shared background at 25% grey.
    /// Green (low, high, background) values are those measured on the eight sample frames.
    @Test("Mismatched green high clips keep the shared background at 25% grey")
    func bayerMedianKeepsBackgroundNeutral() {
        let clips = [
            bayerClips(green: (0.00683, 0.25554, 0.00807)),  // M31_0002
            bayerClips(green: (0.00641, 0.22390, 0.00757)),  // M31_0011
            bayerClips(green: (0.00603, 0.09355, 0.00714)),  // M31_0024
            bayerClips(green: (0.00597, 0.09409, 0.00708)),  // M31_0025
            bayerClips(green: (0.00597, 0.23717, 0.00708)),  // M31_0027
            bayerClips(green: (0.00595, 0.22957, 0.00702)),  // M31_0028
            bayerClips(green: (0.00752, 0.07051, 0.00876)),  // M31_0041
            bayerClips(green: (0.00739, 0.07033, 0.00859))   // M31_0042
        ]
        let shared = BayerClips.median(of: clips)

        let x = (shared.bgG - shared.loG) / (shared.hiG - shared.loG)
        #expect(abs(mtf(x, midtone: shared.midG) - 0.25) < 0.001)

        // The old per-field median of the midtones would have rendered green far darker.
        let naiveMidG = clips.map(\.midG).sorted()[clips.count / 2]
        #expect(mtf(x, midtone: naiveMidG) < 0.2)
    }

    @Test("Empty Bayer clip list gives valid default clips")
    func bayerMedianOfNoneIsValid() {
        #expect(BayerClips.median(of: []).isValid)
        #expect(GreyClips.median(of: []).isValid)
    }

    // MARK: - computeSTFStatistics

    @Test("STF statistics keep the sample median as background and match computeSTFClips")
    func stfStatisticsMatchClips() {
        // Background around 0.1 with a sprinkling of bright "stars".
        let pixels = (0..<20_000).map { i -> Float in
            i % 500 == 0 ? 0.9 : 0.1 + Float(i % 7) * 0.001
        }
        let stats = pixels.withUnsafeBufferPointer {
            ImageStretcher.computeSTFStatistics($0.baseAddress!, count: $0.count)
        }
        let clips = pixels.withUnsafeBufferPointer {
            ImageStretcher.computeSTFClips($0.baseAddress!, count: $0.count)
        }
        #expect(stats.low == clips.shadowClip)
        #expect(stats.high == clips.highClip)
        #expect(stats.midtone == clips.midtone)
        #expect(abs(stats.background - 0.103) < 0.002)
    }
}
