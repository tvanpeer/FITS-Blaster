//
//  LargeStarTests.swift
//  FITS Blaster Tests
//
//  Stars larger than the fixed contrast ring and fit window (long focal length, 0.30″/px;
//  master-plan 13i): each star's ring, fit window and colour crop scale with its own quick
//  FWHM (StarSizes), and a second local maximum on a large star's top is not counted.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct LargeStarTests {

    // MARK: - Sizes

    @Test("Stars up to about 4 px keep the fixed sizes; larger stars scale with their FWHM")
    func sizesForStar() {
        typealias Sizes = MetricsCalculator.StarSizes
        #expect(Sizes.forStar(fwhm: 3) == .normal)
        #expect(Sizes.forStar(fwhm: 4) == .normal)
        #expect(Sizes.forStar(fwhm: .nan) == .normal)
        #expect(Sizes.forStar(fwhm: 0) == .normal)

        let ten = Sizes.forStar(fwhm: 10)
        #expect(ten.ringInner == 15)
        #expect(ten.ringOuter == 25)
        #expect(ten.fitHalfWidth == 15)
        #expect(ten.cropHalf == 17)

        // Each size is at least the normal one: at 5 px the ring grows, the fit window not.
        let five = Sizes.forStar(fwhm: 5)
        #expect(five.ringInner == 8)
        #expect(five.ringOuter == 13)
        #expect(five.fitHalfWidth == Sizes.normal.fitHalfWidth)
        #expect(five.cropHalf == Sizes.normal.cropHalf)
    }

    @Test("The accepted FWHM range only widens for frames with large stars")
    func acceptedRange() {
        let normal = MetricsCalculator.Shape.acceptedFWHM
        #expect(MetricsCalculator.acceptedFWHMRange(typical: nil) == normal)
        #expect(MetricsCalculator.acceptedFWHMRange(typical: 3) == normal)
        #expect(MetricsCalculator.acceptedFWHMRange(typical: 8) == normal)
        #expect(MetricsCalculator.acceptedFWHMRange(typical: 12) == normal.lowerBound...30)
        #expect(MetricsCalculator.acceptedFWHMRange(typical: .infinity) == normal)
    }

    @Test("A point within one FWHM of a counted large star is on that star")
    func largeStarIndex() {
        var index = MetricsCalculator.LargeStarIndex()
        #expect(!index.isOnCountedStar(x: 100, y: 100))
        index.insert(x: 100, y: 100, fwhm: 12)
        #expect(index.isOnCountedStar(x: 108, y: 100))
        #expect(index.isOnCountedStar(x: 93, y: 107))
        #expect(!index.isOnCountedStar(x: 112, y: 100))
        #expect(!index.isOnCountedStar(x: 300, y: 300))
        // Across a grid cell border (cells of 32 px).
        index.insert(x: 63, y: 63, fwhm: 40)
        #expect(index.isOnCountedStar(x: 95, y: 63))
    }

    // MARK: - Contrast ring

    /// The ring statistic as it was computed before the faster scan: every pixel of the
    /// square tested, two full sorts.
    private static func referenceContrast(_ p: [Float], width: Int, height: Int, x: Int, y: Int,
                                          sizes: MetricsCalculator.StarSizes) -> Float {
        let inner = sizes.ringInner, outer = sizes.ringOuter
        var ring: [Float] = []
        for py in max(0, y - outer)...min(height - 1, y + outer) {
            for px in max(0, x - outer)...min(width - 1, x + outer)
            where SkyLevels.cellIndex(x: px, y: py) == SkyLevels.cellIndex(x: x, y: y) {
                let r2 = (px - x) * (px - x) + (py - y) * (py - y)
                if r2 >= inner * inner && r2 <= outer * outer { ring.append(p[py * width + px]) }
            }
        }
        guard !ring.isEmpty else { return 0 }
        ring.sort()
        let median = ring[ring.count / 2]
        let deviations = ring.map { abs($0 - median) }.sorted()
        let noise = deviations[deviations.count / 2] * 1.4826
        let excess = p[y * width + x] - median
        guard noise > 0 else { return excess > 0 ? .infinity : 0 }
        return excess / noise
    }

    @Test("The contrast ring gives the same value as testing every pixel, also at the edges")
    func contrastMatchesReference() {
        let width = 97, height = 83
        var seed: UInt32 = 11
        func next() -> UInt32 { seed = seed &* 1_664_525 &+ 1_013_904_223; return seed >> 8 }
        // Integer-valued noise, so the ring has repeated values (as real 16-bit data).
        let pixels = (0..<(width * height)).map { _ in Float(1000 + next() % 40) }
        var ring: [Float] = []
        for fwhm in [Float(2), 5, 9, 16, 30] {
            let sizes = MetricsCalculator.StarSizes.forStar(fwhm: fwhm)
            for _ in 0..<200 {
                let x = Int(next() % UInt32(width)), y = Int(next() % UInt32(height))
                let fast = pixels.withUnsafeBufferPointer { buf in
                    MetricsCalculator.localContrast(pixels: buf, width: width, height: height,
                                                    x: x, y: y, ring: &ring, sizes: sizes)
                }
                let reference = Self.referenceContrast(pixels, width: width, height: height,
                                                       x: x, y: y, sizes: sizes)
                #expect(fast == reference || (fast.isNaN && reference.isNaN),
                        "FWHM \(fwhm) at (\(x), \(y)): \(fast) vs \(reference)")
            }
        }
    }

    @Test("Order statistic equals the sorted value; integer square root")
    func selectionHelpers() {
        var seed: UInt32 = 3
        for count in [1, 2, 3, 10, 51, 200] {
            for _ in 0..<20 {
                var values = (0..<count).map { _ -> Float in
                    seed = seed &* 1_664_525 &+ 1_013_904_223
                    return Float(seed >> 8 % 17)
                }
                let sorted = values.sorted()
                let k = Int(seed % UInt32(count))
                #expect(MetricsCalculator.orderStatistic(&values, k) == sorted[k])
            }
        }
        #expect([0, 1, 3, 4, 8, 9, 99, 100, -5].map(MetricsCalculator.integerSquareRoot) == [0, 1, 1, 2, 2, 3, 9, 10, 0])
    }

    // MARK: - Synthetic frames

    /// Mono frame: sky 1000, uniform noise ±20 (σ ≈ 11.5), 81 Moffat β = 4 stars on a 100 px
    /// grid with peaks spread log-uniformly from 150 to 30,000 (none saturated).
    /// `axisRatio` < 1 stretches every star along x (eccentricity √(1 − ratio²)).
    private static func frame(fwhm: Float, axisRatio: Float) -> [Float] {
        let side = Self.side
        var pixels = [Float](repeating: 0, count: side * side)
        var seed: UInt32 = 7
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
        }
        // Geometric-mean FWHM = fwhm: major axis fwhm/√ratio, minor fwhm·√ratio.
        let alpha = fwhm / MetricsCalculator.Shape.moffatFWHMFactor
        let ax = alpha / axisRatio.squareRoot(), ay = alpha * axisRatio.squareRoot()
        let reach = Int(fwhm * 4) + 4
        for i in 0..<starCount {
            let cx = 112 + (i % 9) * 100, cy = 112 + (i / 9) * 100
            let amplitude = 150 * pow(200, Float(i) / Float(starCount - 1))
            for dy in -reach...reach {
                for dx in -reach...reach {
                    let x = cx + dx, y = cy + dy
                    guard x >= 0, x < side, y >= 0, y < side else { continue }
                    let r2 = Float(dx * dx) / (ax * ax) + Float(dy * dy) / (ay * ay)
                    pixels[y * side + x] += amplitude * pow(1 + r2, -4)
                }
            }
        }
        return pixels
    }

    private static let side = 1024
    private static let starCount = 81

    @Test("Round stars of 3–20 px: nearly all counted once, FWHM measured",
          arguments: [Float(3), 6, 8, 12, 16, 20])
    func roundStars(fwhm: Float) async throws {
        let pixels = Self.frame(fwhm: fwhm, axisRatio: 1)
        let m = try #require(await MetricsCalculator.compute(pixels: pixels, width: Self.side, height: Self.side,
                                                             config: MetricsConfig()))
        // Before 13i, stars from 12 px failed the count (ring on their own flank) and stars
        // from 16 px were counted more than once.
        let counted = try #require(m.starCount)
        #expect((75...Self.starCount).contains(counted), "counted \(counted) of \(Self.starCount)")
        let measured = try #require(m.fwhm)
        #expect(abs(measured - fwhm) <= 0.05 * fwhm, "FWHM \(measured), truth \(fwhm)")
        #expect(try #require(m.eccentricity) < 0.2)
    }

    @Test("Elongated stars of 6–20 px: eccentricity measured",
          arguments: [Float(6), 12, 20])
    func elongatedStars(fwhm: Float) async throws {
        let ratio: Float = 0.8
        let truth = (1 - ratio * ratio).squareRoot()
        let pixels = Self.frame(fwhm: fwhm, axisRatio: ratio)
        let m = try #require(await MetricsCalculator.compute(pixels: pixels, width: Self.side, height: Self.side,
                                                             config: MetricsConfig()))
        let counted = try #require(m.starCount)
        #expect((75...Self.starCount).contains(counted), "counted \(counted) of \(Self.starCount)")
        let eccentricity = try #require(m.eccentricity)
        #expect(abs(eccentricity - truth) <= 0.05, "eccentricity \(eccentricity), truth \(truth)")
    }
}
