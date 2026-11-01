//
//  ShapeSetTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13e: FWHM, eccentricity, SNR and PSF·S are measured only on candidates
//  that count as stars. Hot pixels brighter than every star (as on uncalibrated frames)
//  must not change the measurements, and the star count stays the same.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct ShapeSetTests {

    private static let side = 256

    /// Twenty round Moffat β = 4 stars of FWHM 3 px on a 5 × 4 grid.
    private static let stars: [(x: Int, y: Int, amplitude: Float)] = (0..<20).map { (i: Int) -> (x: Int, y: Int, amplitude: Float) in
        let x: Int = 24 + (i % 5) * 50
        let y: Int = 30 + (i / 5) * 60
        return (x: x, y: y, amplitude: Float(3000 + i * 300))
    }

    /// Sky 1000 with deterministic uniform noise (±20) plus the stars. `channelGain` scales
    /// each position of the 2×2 cell (a colour camera's R, G, G, B response); 1 for mono.
    private static func frame(channelGain: SIMD4<Float> = SIMD4(repeating: 1)) -> [Float] {
        let n = side
        var pixels = [Float](repeating: 0, count: n * n)
        var seed: UInt32 = 2024
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
        }
        let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
        for star in stars {
            for dy in -12...12 {
                for dx in -12...12 {
                    let x = star.x + dx, y = star.y + dy
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    let gain = channelGain[SkyLevels.cellIndex(x: x, y: y)]
                    pixels[y * n + x] += gain * star.amplitude * pow(1 + r2, -4)
                }
            }
        }
        return pixels
    }

    /// The same frame with 300 single-pixel hot pixels, each brighter than every star, at
    /// least 14 px from any star, all with different values (so the frame isn't "saturated").
    private static func withHotPixels(_ clean: [Float]) -> [Float] {
        var pixels = clean
        var seed: UInt32 = 7
        var placed = 0
        while placed < 300 {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let x = 2 + Int(seed >> 8) % (side - 4)
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let y = 2 + Int(seed >> 8) % (side - 4)
            guard stars.allSatisfy({ abs($0.x - x) > 14 || abs($0.y - y) > 14 }) else { continue }
            pixels[y * side + x] = 20_000 + Float(placed) * 61.7
            placed += 1
        }
        return pixels
    }

    private static func expectSameMeasurements(_ hot: FrameMetrics, _ clean: FrameMetrics) throws {
        #expect(hot.starCount == clean.starCount)
        #expect(clean.starCount == stars.count)
        let fwhm = try #require(hot.fwhm), cleanFWHM = try #require(clean.fwhm)
        let ecc = try #require(hot.eccentricity), cleanEcc = try #require(clean.eccentricity)
        let snr = try #require(hot.snr), cleanSNR = try #require(clean.snr)
        let psf = try #require(hot.psfSignalWeight), cleanPSF = try #require(clean.psfSignalWeight)
        // The hot pixels shift the frame's background and σ very slightly, nothing more.
        #expect(abs(fwhm - cleanFWHM) < 0.01)
        #expect(abs(ecc - cleanEcc) < 0.01)
        #expect(abs(snr / cleanSNR - 1) < 0.02)
        #expect(abs(psf / cleanPSF - 1) < 0.02)
    }

    @Test("FWHM and eccentricity use the stars with contrast ≥ 40, or the 20 with the highest contrast")
    func brightStarSelection() {
        typealias Star = (contrast: Float, fwhm: Float, ecc: Float)
        // 25 bright stars among faint ones: only the bright ones.
        let mixed: [Star] = (0..<100).map { i in (contrast: i % 4 == 0 ? 50 : 20, fwhm: Float(i), ecc: 0) }
        let bright = MetricsCalculator.brightStarsForShape(mixed)
        #expect(bright.count == 25)
        #expect(bright.allSatisfy { $0.contrast >= 40 })
        // Only 5 bright stars: the 20 with the highest contrast; ties go to the earlier star.
        let few: [Star] = (0..<50).map { i in (contrast: i < 5 ? 100 : Float(30 - i % 3), fwhm: Float(i), ecc: 0) }
        let fallback = MetricsCalculator.brightStarsForShape(few)
        #expect(fallback.count == 20)
        // Contrast 100 for 0–4, then 30 (i % 3 == 0), 29, 28 in turn: the 15 stars at 30 in order.
        #expect(fallback.map(\.fwhm) == [0, 1, 2, 3, 4, 6, 9, 12, 15, 18, 21, 24, 27, 30, 33, 36, 39, 42, 45, 48])
        // Fewer than 20 stars in all: all of them.
        #expect(MetricsCalculator.brightStarsForShape(Array(few.prefix(7))).count == 7)
        #expect(MetricsCalculator.brightStarsForShape([]).isEmpty)
    }

    @Test("Faint stars don't widen FWHM and eccentricity; they still count")
    func faintStarsLeftOutOfShape() async throws {
        let n = 512, spacing = 38
        var positions: [(x: Int, y: Int)] = []
        for gy in 0..<13 { for gx in 0..<13 { positions.append((x: 20 + gx * spacing, y: 20 + gy * spacing)) } }
        let bright = Array(positions.prefix(30)).enumerated().map { i, p in
            (x: p.x, y: p.y, amplitude: Float(5000 + i * 100))
        }
        let faint = Array(positions.dropFirst(30).prefix(120)).map { p in (x: p.x, y: p.y, amplitude: Float(300)) }
        func render(_ stars: [(x: Int, y: Int, amplitude: Float)]) -> [Float] {
            var pixels = [Float](repeating: 0, count: n * n)
            var seed: UInt32 = 99
            for i in pixels.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i] = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
            }
            let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
            for star in stars {
                for dy in -12...12 {
                    for dx in -12...12 {
                        let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                        pixels[(star.y + dy) * n + star.x + dx] += star.amplitude * pow(1 + r2, -4)
                    }
                }
            }
            return pixels
        }
        let both = try #require(await MetricsCalculator.compute(pixels: render(bright + faint), width: n, height: n,
                                                               config: MetricsConfig()))
        let brightOnly = try #require(await MetricsCalculator.compute(pixels: render(bright), width: n, height: n,
                                                                     config: MetricsConfig()))
        #expect(both.starCount == bright.count + faint.count)
        let fwhm = try #require(both.fwhm), brightFWHM = try #require(brightOnly.fwhm)
        let ecc = try #require(both.eccentricity), brightEcc = try #require(brightOnly.eccentricity)
        #expect(abs(fwhm - brightFWHM) < 0.02)
        #expect(abs(ecc - brightEcc) < 0.02)
    }

    @Test("Mono: hot pixels brighter than the stars don't change the measurements")
    func monoHotPixels() async throws {
        let n = Self.side
        let clean = Self.frame()
        let cleanMetrics = try #require(await MetricsCalculator.compute(pixels: clean, width: n, height: n,
                                                                       config: MetricsConfig()))
        let hotMetrics = try #require(await MetricsCalculator.compute(pixels: Self.withHotPixels(clean),
                                                                     width: n, height: n, config: MetricsConfig()))
        try Self.expectSameMeasurements(hotMetrics, cleanMetrics)
    }

    @Test("Colour (RGGB): hot pixels brighter than the stars don't change the measurements")
    func colourHotPixels() async throws {
        let n = Self.side
        let clean = Self.frame(channelGain: SIMD4(0.8, 1, 1, 0.6))
        let cleanMetrics = try #require(await MetricsCalculator.compute(pixels: clean, width: n, height: n,
                                                                       config: MetricsConfig(), bayerPattern: .rggb))
        let hotMetrics = try #require(await MetricsCalculator.compute(pixels: Self.withHotPixels(clean),
                                                                     width: n, height: n, config: MetricsConfig(),
                                                                     bayerPattern: .rggb))
        try Self.expectSameMeasurements(hotMetrics, cleanMetrics)
    }
}
