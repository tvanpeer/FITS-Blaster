//
//  StarSizes.swift
//  FITS Blaster
//
//  The pixel sizes the star count and the shape fit use for one star — contrast ring,
//  Moffat fit window, colour crop — scaled with that star's own width (master-plan 13i).
//

import Foundation

extension MetricsCalculator {

    /// The pixel sizes for one star, from its quick FWHM (`measureFWHMOnly`).
    ///
    /// Stars up to about 4 px keep the fixed sizes they always had (`normal`): a 6–10 px
    /// ring, a ±10 px fit and a 25 × 25 colour crop. Larger stars get a ring at 1.5–2.5 × and
    /// a fit window of 1.5 × their FWHM. With the fixed ring, stars of 12–16 px (long focal
    /// length, 0.30″/px) had the ring on their own flank, failed the count (contrast ~5
    /// against the 12 needed) and the frame's FWHM came from galaxy knots (step 13i). Sizing
    /// each star from its own profile follows Siril's star finder; a size for the whole frame
    /// was tried first and dropped, because cloud halos make a frame's stars look large too.
    struct StarSizes: Equatable, Sendable {
        /// Radii (pixels) of the ring that gives the star's local sky and noise.
        let ringInner: Int
        let ringOuter: Int
        /// Steps on each side of the centre along which the Moffat profile is fitted.
        let fitHalfWidth: Int
        /// Half-side of the crop a colour star is debayered and fitted in.
        let cropHalf: Int

        /// The fixed sizes: a 6–10 px ring, a ±10 px fit and a 25 × 25 crop.
        static let normal = StarSizes(ringInner: Constants.contrastRingInner,
                                      ringOuter: Constants.contrastRingOuter,
                                      fitHalfWidth: Shape.moffatHalfWidth,
                                      cropHalf: 12)

        /// Ring radii as multiples of the star's quick FWHM (Tom, 2026-11-05).
        static let ringInnerFactor: Float = 1.5
        static let ringOuterFactor: Float = 2.5
        /// Fit half-width as a multiple of the star's quick FWHM.
        static let fitFactor: Float = 1.5

        /// The sizes for a star of quick FWHM `fwhm`: each at least the normal one.
        static func forStar(fwhm: Float) -> StarSizes {
            guard fwhm.isFinite, fwhm > 0 else { return .normal }
            let fit = max(normal.fitHalfWidth, Int((fitFactor * fwhm).rounded()))
            return StarSizes(ringInner: max(normal.ringInner, Int((ringInnerFactor * fwhm).rounded())),
                             ringOuter: max(normal.ringOuter, Int((ringOuterFactor * fwhm).rounded())),
                             fitHalfWidth: fit,
                             cropHalf: max(normal.cropHalf, fit + 2))
        }

        /// The quick FWHM above which the normal ±10 px window is too short for the star
        /// (1.5 × FWHM > 10): the quick FWHM is then measured again with a wider window.
        static var quickWindowLimit: Float { Float(normal.fitHalfWidth) / fitFactor }

        /// Ring samples `localContrast` can collect for this ring: the pixels of one 2×2
        /// cell position between the radii, with room to spare.
        var ringCapacity: Int {
            let area = Float.pi * Float(ringOuter * ringOuter - ringInner * ringInner)
            return Int(area / 4) + 4 * ringOuter + 16
        }
    }

    /// Candidates whose quick FWHM gives the frame's typical star size.
    static let typicalSampleCount = 50
    /// Candidates looked at, at most, to find them (saturated stars and hot pixels can come
    /// first in the brightness order).
    static let typicalSearchLimit = 2_000
    /// The largest accepted FWHM is at least this multiple of the frame's typical star.
    static let acceptedFWHMTypicalFactor: Float = 2.5

    /// The median quick FWHM of the brightest unsaturated candidates the normal limits
    /// accept (`candidates` brightest first). Only widens the accepted range for frames with
    /// large stars; nil when there are none.
    static func typicalQuickFWHM(_ candidates: [StarCandidate], saturation: Float?,
                                 quickFWHM: (StarCandidate) -> Float) -> Float? {
        var sizes: [Float] = []
        sizes.reserveCapacity(typicalSampleCount)
        for c in candidates.prefix(typicalSearchLimit) {
            if let saturation, c.peak >= saturation { continue }
            let fwhm = quickFWHM(c)
            guard Shape.acceptedFWHM.contains(fwhm) else { continue }
            sizes.append(fwhm)
            if sizes.count == typicalSampleCount { break }
        }
        guard !sizes.isEmpty else { return nil }
        sizes.sort()
        return sizes[sizes.count / 2]
    }

    /// The accepted FWHM range for a frame whose stars typically measure `typical` px: the
    /// normal 0.5–20 px, with the upper limit raised to 2.5 × `typical` where that is more
    /// (frames with stars above 8 px; step 13i).
    static func acceptedFWHMRange(typical: Float?) -> ClosedRange<Float> {
        let normal = Shape.acceptedFWHM
        guard let typical, typical.isFinite else { return normal }
        return normal.lowerBound...max(normal.upperBound, acceptedFWHMTypicalFactor * typical)
    }
}

extension MetricsCalculator {

    /// The counted stars larger than normal, for the duplicate check: a candidate within one
    /// FWHM of a brighter counted large star is another local maximum on that star's top, not
    /// a star of its own (Siril's star finder has the same check, scaled to its box). Stars of
    /// normal size never enter it, so their count is unchanged (non-maximum suppression at
    /// 3 px already separates them).
    struct LargeStarIndex {
        /// Side of a grid cell (pixels); a query looks at the cells around its own.
        private static let cellSide = 32
        private var cells: [Int: [(x: Int, y: Int, fwhm: Float)]] = [:]
        private var largestFWHM: Float = 0

        mutating func insert(x: Int, y: Int, fwhm: Float) {
            cells[Self.key(x / Self.cellSide, y / Self.cellSide), default: []].append((x, y, fwhm))
            largestFWHM = max(largestFWHM, fwhm)
        }

        /// Whether (x, y) lies within one FWHM of a counted large star.
        func isOnCountedStar(x: Int, y: Int) -> Bool {
            guard !cells.isEmpty else { return false }
            let reach = Int(largestFWHM.rounded(.up)) / Self.cellSide + 1
            let cx = x / Self.cellSide, cy = y / Self.cellSide
            for gy in (cy - reach)...(cy + reach) {
                for gx in (cx - reach)...(cx + reach) {
                    guard let stars = cells[Self.key(gx, gy)] else { continue }
                    for s in stars {
                        let dx = Float(x - s.x), dy = Float(y - s.y)
                        if dx * dx + dy * dy < s.fwhm * s.fwhm { return true }
                    }
                }
            }
            return false
        }

        private static func key(_ gx: Int, _ gy: Int) -> Int { gy &* 1_000_003 &+ gx }
    }
}
