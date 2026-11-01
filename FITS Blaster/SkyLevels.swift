//
//  SkyLevels.swift
//  FITS Blaster
//
//  The sky background and noise of a frame at the four positions of the 2×2 Bayer cell.
//

import Foundation

/// The sky background and noise (σ) of a frame, per position of the 2×2 Bayer cell.
///
/// A raw colour (Bayer) frame has a different sky level in R, G and B, so one median and one
/// σ over all pixels count that colour spread as noise and put a faint star's R and B
/// neighbours below "the" background (master-plan step 13a). Colour frames therefore get
/// their levels per cell position. Mono frames get one level in all four positions, which
/// keeps their arithmetic exactly as it was.
struct SkyLevels: Sendable, Equatable {

    /// Background (median) at each cell position, indexed by `cellIndex(x:y:)`.
    let background: SIMD4<Float>
    /// Noise σ (1.4826 × MAD) at each cell position.
    let sigma: SIMD4<Float>
    /// True when the levels were measured per position (a Bayer frame).
    let isPerChannel: Bool

    /// Position of pixel (x, y) in the 2×2 cell: row parity × 2 + column parity.
    static func cellIndex(x: Int, y: Int) -> Int { (y & 1) << 1 | (x & 1) }

    /// One background and σ for every pixel (a mono frame).
    static func uniform(background: Float, sigma: Float) -> SkyLevels {
        SkyLevels(background: SIMD4(repeating: background), sigma: SIMD4(repeating: sigma), isPerChannel: false)
    }

    /// The background at pixel (x, y).
    func background(x: Int, y: Int) -> Float { background[Self.cellIndex(x: x, y: y)] }

    /// What the detection compares: pixel − offset against the threshold of its position.
    /// Mono: offset 0 and background + 5σ, the same arithmetic as before step 13a. Colour:
    /// the channel's background and 5 × the channel's σ.
    var detectionLevels: DetectionLevels {
        let sigmas = MetricsCalculator.Constants.detectionSigmas
        guard isPerChannel else {
            let threshold = background[0] + sigmas * sigma[0]
            return DetectionLevels(offsets: .zero, thresholds: SIMD4(repeating: threshold))
        }
        return DetectionLevels(offsets: background, thresholds: sigmas * sigma)
    }

    /// The noise of the luminance the star crops of a colour frame are measured on: the
    /// channel σ's with the Rec. 709 weights of the FWHM and SNR crop (G averaged over its
    /// two positions). The weighted sum treats the channels as fully correlated, so it is an
    /// upper bound for the noise of the interpolated luminance.
    func luminanceSigma(pattern: BayerPattern) -> Float {
        let r = Int(pattern.rOffset)
        let red = sigma[r], blue = sigma[r ^ 3]
        let green = (sigma[r ^ 1] + sigma[r ^ 2]) / 2
        let w = BayerLuminanceWeights.rec709Weights
        return w.r * red + w.g * green + w.b * blue
    }
}
