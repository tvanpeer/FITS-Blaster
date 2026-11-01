//
//  SaturatedStars.swift
//  FITS Blaster
//
//  Recognises saturated star candidates on raw colour frames and counts each saturated
//  star once (master-plan step 13a).
//

import Foundation

/// Saturated star candidates of one raw colour frame.
///
/// With the channel backgrounds subtracted, a saturated R or B pixel beats its saturated G
/// neighbours, so a saturated star is detected, and a large one more than once: its flat top
/// holds several R and B pixels a few pixels apart. Each saturated star is therefore
/// identified by its saturated area (saturated pixels at most `bridge` pixels apart, which
/// joins the channels of one star even where one of them stays just below the level), and
/// only its first candidate counts.
struct SaturatedStars {
    private let pixels: UnsafeBufferPointer<Float>
    private let width: Int
    private let height: Int
    private let level: Float
    /// Saturated pixels already assigned to a star.
    private var claimed = Set<Int>()
    /// Saturated pixels at most this far apart (in x and in y) belong to the same star.
    private static let bridge = 2

    init(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int, level: Float) {
        self.pixels = pixels
        self.width = width
        self.height = height
        self.level = level
    }

    enum Kind: Equatable {
        /// No pixel of the candidate's 3×3 neighbourhood reaches the level.
        case unsaturated
        /// The first candidate on a saturated star.
        case newStar
        /// Another candidate on a saturated star counted before.
        case sameStar
    }

    /// Classifies a candidate (candidates come brightest first, so the first one on a star
    /// claims its whole saturated area).
    mutating func classify(x: Int, y: Int) -> Kind {
        guard let seed = saturatedPixel(nearX: x, y: y) else { return .unsaturated }
        if claimed.contains(seed) { return .sameStar }
        claimArea(from: seed)
        return .newStar
    }

    /// The first pixel of the 3×3 neighbourhood of (x, y) that reaches the level.
    private func saturatedPixel(nearX x: Int, y: Int) -> Int? {
        for py in max(0, y - 1)...min(height - 1, y + 1) {
            for px in max(0, x - 1)...min(width - 1, x + 1) where pixels[py * width + px] >= level {
                return py * width + px
            }
        }
        return nil
    }

    /// Claims every saturated pixel connected to `seed` (steps of up to `bridge` pixels).
    private mutating func claimArea(from seed: Int) {
        var pending = [seed]
        claimed.insert(seed)
        let bridge = Self.bridge
        while let index = pending.popLast() {
            let x = index % width, y = index / width
            for py in max(0, y - bridge)...min(height - 1, y + bridge) {
                for px in max(0, x - bridge)...min(width - 1, x + bridge) {
                    let neighbour = py * width + px
                    if pixels[neighbour] >= level, claimed.insert(neighbour).inserted {
                        pending.append(neighbour)
                    }
                }
            }
        }
    }
}
