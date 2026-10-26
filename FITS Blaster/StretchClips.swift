//
//  StretchClips.swift
//  FITS Blaster
//
//  The stretch clip bounds of a grey and of a Bayer image, and their per-group medians.
//

import Foundation

// MARK: - GreyClips

/// Percentile clip bounds for a greyscale (mono) image.
/// Stored on `ImageEntry` during Phase A so the post-batch normalisation step
/// can compute per-(folder, filter) medians and re-render with shared bounds.
struct GreyClips: Sendable, Equatable {
    let low: Float
    let high: Float
    let midtone: Float     // MTF midtone parameter derived from STF statistics
    let background: Float  // Sky background (sample median) the midtone was derived from

    var isValid: Bool { high > low }

    /// Per-group shared clips. Low, high and background are medians across the group;
    /// the midtone is recomputed from them rather than taken as a median of its own,
    /// because each image's midtone only fits that image's own low/high pair.
    static func median(of clips: [GreyClips]) -> GreyClips {
        guard !clips.isEmpty else { return ImageStretcher.stfFallback }
        let mid         = clips.count / 2
        let low         = clips.map(\.low).sorted()[mid]
        let high        = clips.map(\.high).sorted()[mid]
        let background  = clips.map(\.background).sorted()[mid]
        let midtone     = ImageStretcher.mtfMidtone(shadowClip: low, highClip: high, background: background)
        return GreyClips(low: low, high: high, midtone: midtone, background: background)
    }
}

// MARK: - BayerClips

/// Per-channel percentile clip bounds for a Bayer image.
/// Stored on `ImageEntry` during the grey-pass so the post-batch normalisation
/// step can compute per-folder medians and re-render in colour with shared bounds.
struct BayerClips: Sendable {
    let loR, hiR: Float
    let midR: Float  // MTF midtone for R channel
    let loG, hiG: Float
    let midG: Float  // MTF midtone for G channel
    let loB, hiB: Float
    let midB: Float  // MTF midtone for B channel
    /// Per-channel sky background (sample median) each midtone was derived from.
    let bgR, bgG, bgB: Float

    var isValid: Bool { hiR > loR && hiG > loG && hiB > loB }

    /// Per-folder shared clips. Low, high and background are per-channel medians;
    /// each midtone is recomputed from them rather than taken as a median of its own,
    /// because an image's midtone only fits that image's own low/high pair. Mixing
    /// them (e.g. one frame's high with another frame's midtone) causes colour casts.
    static func median(of clips: [BayerClips]) -> BayerClips {
        guard !clips.isEmpty else {
            // The grey fallback for every channel.
            let f = ImageStretcher.stfFallback
            return BayerClips(loR: f.low, hiR: f.high, midR: f.midtone,
                              loG: f.low, hiG: f.high, midG: f.midtone,
                              loB: f.low, hiB: f.high, midB: f.midtone,
                              bgR: f.background, bgG: f.background, bgB: f.background)
        }
        let mid = clips.count / 2
        func med(_ kp: KeyPath<BayerClips, Float>) -> Float {
            clips.map { $0[keyPath: kp] }.sorted()[mid]
        }
        let loR = med(\.loR), hiR = med(\.hiR), bgR = med(\.bgR)
        let loG = med(\.loG), hiG = med(\.hiG), bgG = med(\.bgG)
        let loB = med(\.loB), hiB = med(\.hiB), bgB = med(\.bgB)
        return BayerClips(
            loR: loR, hiR: hiR, midR: ImageStretcher.mtfMidtone(shadowClip: loR, highClip: hiR, background: bgR),
            loG: loG, hiG: hiG, midG: ImageStretcher.mtfMidtone(shadowClip: loG, highClip: hiG, background: bgG),
            loB: loB, hiB: hiB, midB: ImageStretcher.mtfMidtone(shadowClip: loB, highClip: hiB, background: bgB),
            bgR: bgR, bgG: bgG, bgB: bgB
        )
    }
}
