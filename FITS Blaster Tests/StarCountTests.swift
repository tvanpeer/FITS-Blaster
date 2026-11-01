//
//  StarCountTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13c: the star count checks every candidate (no 6,200 limit) and counts
//  only peaks that stand at least 12 × the local noise above the local sky, so noise peaks
//  on nebula and very faint peaks don't count.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct StarCountTests {

    /// A mono frame: sky 1000 with deterministic uniform noise (±20, so 1.4826 × MAD ≈ 15),
    /// an optional smooth "nebula" (Gaussian blob), and round Moffat β = 4 stars of FWHM 3 px.
    private static func frame(width: Int, height: Int, stars: [(x: Int, y: Int, amplitude: Float)],
                              nebula: (x: Float, y: Float, sigma: Float, amplitude: Float)? = nil) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height)
        var seed: UInt32 = 4242
        for y in 0..<height {
            for x in 0..<width {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                var v = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
                if let n = nebula {
                    let d2 = (Float(x) - n.x) * (Float(x) - n.x) + (Float(y) - n.y) * (Float(y) - n.y)
                    v += n.amplitude * exp(-d2 / (2 * n.sigma * n.sigma))
                }
                pixels[y * width + x] = v
            }
        }
        let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
        for star in stars {
            for dy in -6...6 {
                for dx in -6...6 {
                    let x = star.x + dx, y = star.y + dy
                    guard x >= 0, x < width, y >= 0, y < height else { continue }
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    pixels[y * width + x] += star.amplitude * pow(1 + r2, -4)
                }
            }
        }
        return pixels
    }

    @Test("More than 6,200 stars are all counted")
    func noLimit() async throws {
        let side = 1200, spacing = 14
        var stars: [(x: Int, y: Int, amplitude: Float)] = []
        for y in stride(from: 12, to: side - 10, by: spacing) {
            for x in stride(from: 12, to: side - 10, by: spacing) {
                stars.append((x: x, y: y, amplitude: 2000 + Float((x * 7 + y * 13) % 997)))
            }
        }
        #expect(stars.count > 6_200)
        let metrics = try #require(await MetricsCalculator.compute(
            pixels: Self.frame(width: side, height: side, stars: stars),
            width: side, height: side, config: MetricsConfig()))
        #expect(metrics.starCount == stars.count)
    }

    @Test("Noise peaks on a nebula don't count; the stars on it do")
    func nebulaNoise() async throws {
        let side = 400
        let stars: [(x: Int, y: Int, amplitude: Float)] = (0..<10).map { i in
            (x: 40 + (i % 5) * 80, y: 60 + (i / 5) * 280, amplitude: Float(3000))
        }
        let pixels = Self.frame(width: side, height: side, stars: stars,
                                nebula: (x: 200, y: 200, sigma: 70, amplitude: 400))
        let metrics = try #require(await MetricsCalculator.compute(pixels: pixels, width: side, height: side,
                                                                  config: MetricsConfig()))
        // The nebula lifts thousands of noise peaks above the frame-wide 5σ threshold.
        let candidates = pixels.withUnsafeBufferPointer { buffer in
            let sky = MetricsCalculator.estimateBackground(buffer, width: side, height: side)
            return MetricsCalculator.findLocalMaxima(
                pixels: buffer, width: side, height: side, cropX: 0, cropY: 0, cropW: side, cropH: side,
                threshold: sky.median + MetricsCalculator.Constants.detectionSigmas * sky.sigma).count
        }
        #expect(candidates > 100)
        #expect(metrics.starCount == stars.count)
    }

    @Test("A star counts from 12 × the local noise above its local sky")
    func contrastThreshold() async throws {
        let side = 400
        // Local noise ≈ 15: amplitude 90 is about 6 ×, 450 about 30 ×.
        let faint: [(x: Int, y: Int, amplitude: Float)] = (0..<8).map { i in (x: 40 + i * 45, y: 100, amplitude: 90) }
        let bright: [(x: Int, y: Int, amplitude: Float)] = (0..<8).map { i in (x: 40 + i * 45, y: 300, amplitude: 450) }
        let metrics = try #require(await MetricsCalculator.compute(
            pixels: Self.frame(width: side, height: side, stars: faint + bright),
            width: side, height: side, config: MetricsConfig()))
        #expect(metrics.starCount == bright.count)
    }

    @Test("Local contrast: a peak against the median and MAD of its ring at 6–10 px, same cell position")
    func localContrastValue() {
        let side = 41, cx = 20, cy = 21
        var pixels = [Float](repeating: 0, count: side * side)
        var seed: UInt32 = 99
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = 1000 + Float(seed >> 8) / Float(1 << 24) * 50
        }
        pixels[cy * side + cx] = 1300
        // The expected value, straight from the definition.
        var values: [Float] = []
        for y in 0..<side {
            for x in 0..<side where (x & 1) == (cx & 1) && (y & 1) == (cy & 1) {
                let r2 = (x - cx) * (x - cx) + (y - cy) * (y - cy)
                if r2 >= 36 && r2 <= 100 { values.append(pixels[y * side + x]) }
            }
        }
        values.sort()
        let median = values[values.count / 2]
        let deviations = values.map { abs($0 - median) }.sorted()
        let expected = (1300 - median) / (deviations[deviations.count / 2] * 1.4826)

        var ring: [Float] = []
        let contrast = pixels.withUnsafeBufferPointer {
            MetricsCalculator.localContrast(pixels: $0, width: side, height: side, x: cx, y: cy, ring: &ring)
        }
        #expect(abs(contrast - expected) < 1e-4 * expected)
        #expect(contrast > 12)
    }
}
