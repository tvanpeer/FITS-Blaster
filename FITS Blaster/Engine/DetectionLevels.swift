//
//  DetectionLevels.swift
//  FITS Blaster
//
//  Per-position levels for the local-maximum star detection.
//

import Foundation

/// The levels the star detection works with, per position of the 2×2 Bayer cell (indexed
/// like `SkyLevels.cellIndex(x:y:)`): a pixel's value minus its position's offset must reach
/// its position's threshold and be higher than each neighbour minus that neighbour's offset.
///
/// Mono frames use offset 0 and one threshold, so `value − 0` is the value itself and the
/// detection is exactly the old single-threshold test.
struct DetectionLevels: Sendable, Equatable {
    /// Subtracted from every pixel before comparing (the channel's sky background; 0 for mono).
    let offsets: SIMD4<Float>
    /// The level `pixel − offset` must reach.
    let thresholds: SIMD4<Float>
    /// Raw pixel value from which a pixel counts as saturated (∞: the frame isn't). At or
    /// above it a pixel is a maximum when it is at least as high as all 8 neighbours and
    /// strictly higher than the 4 before it in reading order, so a flat saturated top gives
    /// one candidate, its top-left pixel (master-plan step 13d). Below it the test stays strict.
    var saturation: Float = .infinity

    /// One threshold for every pixel, no offsets, no saturation: the detection as before step 13a.
    static func uniform(threshold: Float) -> DetectionLevels {
        DetectionLevels(offsets: .zero, thresholds: SIMD4(repeating: threshold))
    }

    /// The lowest raw pixel value that can be a candidate anywhere: rows whose maximum stays
    /// below it can be skipped. For mono frames this is the threshold itself.
    var lowestCandidateValue: Float { (offsets + thresholds).min() }
}
