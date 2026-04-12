//
//  IntegrationTests.swift
//  FITS Blaster Tests
//
//  Integration tests that exercise the full pipeline from synthetic pixel data
//  through star detection, shape measurement, and scoring. Uses the CPU fallback
//  paths so tests run reliably without GPU.
//

import XCTest
@testable import FITS_Blaster

final class IntegrationTests: XCTestCase {

    // MARK: - Synthetic image builder

    /// Build a flat-background Float array with optional Gaussian stars planted on it.
    /// Stars are defined by position, amplitude, and sigma (σ_x, σ_y).
    private struct SyntheticStar {
        let cx: Int
        let cy: Int
        let amplitude: Float
        let sigmaX: Float
        let sigmaY: Float

        /// Round star with equal sigma in both axes.
        init(cx: Int, cy: Int, amplitude: Float = 5000, sigma: Float = 2.5) {
            self.cx = cx; self.cy = cy
            self.amplitude = amplitude
            self.sigmaX = sigma; self.sigmaY = sigma
        }

        /// Elongated star with different sigma per axis (simulates trailing).
        init(cx: Int, cy: Int, amplitude: Float = 5000, sigmaX: Float, sigmaY: Float) {
            self.cx = cx; self.cy = cy
            self.amplitude = amplitude
            self.sigmaX = sigmaX; self.sigmaY = sigmaY
        }
    }

    /// Returns a Float pixel array of `width × height` with a flat background
    /// plus planted Gaussian stars.
    private func makeImage(width: Int, height: Int,
                           background: Float = 1000,
                           stars: [SyntheticStar] = [],
                           noise: Float = 0,
                           gradient: Float = 0) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height)

        // Background + optional linear gradient (left-to-right)
        for y in 0..<height {
            for x in 0..<width {
                let grad = gradient * Float(x) / Float(width)
                pixels[y * width + x] = background + grad
            }
        }

        // Plant stars as 2D Gaussians
        for star in stars {
            let radius = Int(max(star.sigmaX, star.sigmaY) * 5)
            let yMin = max(0, star.cy - radius)
            let yMax = min(height - 1, star.cy + radius)
            let xMin = max(0, star.cx - radius)
            let xMax = min(width - 1, star.cx + radius)

            for y in yMin...yMax {
                for x in xMin...xMax {
                    let dx = Float(x - star.cx)
                    let dy = Float(y - star.cy)
                    let exponent = -0.5 * ((dx * dx) / (star.sigmaX * star.sigmaX)
                                         + (dy * dy) / (star.sigmaY * star.sigmaY))
                    pixels[y * width + x] += star.amplitude * exp(exponent)
                }
            }
        }

        // Optional Gaussian noise
        if noise > 0 {
            // Simple Box-Muller pairs for reproducible pseudo-Gaussian noise.
            // Not cryptographic quality, but fine for testing star detection thresholds.
            var seed: UInt64 = 42
            for i in 0..<pixels.count {
                // xorshift64
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let u1 = max(Float.leastNormalMagnitude, Float(seed & 0xFFFF) / 65535.0)
                seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
                let u2 = Float(seed & 0xFFFF) / 65535.0
                let z = sqrt(-2.0 * log(u1)) * cos(2.0 * .pi * u2)
                pixels[i] += noise * z
            }
        }

        return pixels
    }

    /// Writes a Float pixel array as a valid BITPIX-16 FITS file.
    /// Values are clamped to Int16 range then stored big-endian with BZERO=32768.
    private func writeFITS(pixels: [Float], width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).fits")

        // Header
        var cards: [String] = [
            card("SIMPLE", bool: true),
            card("BITPIX", int: 16),
            card("NAXIS",  int: 2),
            card("NAXIS1", int: width),
            card("NAXIS2", int: height),
            card("BZERO",  float: 32768),
            endCard()
        ]
        var headerData = Data(cards.joined().utf8)
        while headerData.count % 2880 != 0 { headerData.append(0x20) }

        // Pixel data: convert float → unsigned 16-bit → stored as signed with BZERO offset
        var pixelData = Data(count: width * height * 2)
        for i in 0..<pixels.count {
            let clamped = max(0, min(65535, pixels[i]))
            let stored = Int16(bitPattern: UInt16(clamped) &- 32768)
            pixelData[i * 2]     = UInt8(bitPattern: Int8(truncatingIfNeeded: stored >> 8))
            pixelData[i * 2 + 1] = UInt8(truncatingIfNeeded: stored)
        }
        while pixelData.count % 2880 != 0 { pixelData.append(0x00) }

        var fileData = headerData
        fileData.append(pixelData)
        try fileData.write(to: url)
        return url
    }

    // MARK: - Card builders (shared with FITSReaderTests)

    private func card(_ key: String, bool value: Bool) -> String {
        let v = String(repeating: " ", count: 19) + (value ? "T" : "F")
        return fitsCard(key, value: v)
    }

    private func card(_ key: String, int value: Int) -> String {
        let s = String(value)
        return fitsCard(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }

    private func card(_ key: String, float value: Double) -> String {
        let s = value == value.rounded() && abs(value) < 1e15
            ? String(format: "%.1f", value)
            : String(format: "%E", value)
        return fitsCard(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }

    private func fitsCard(_ key: String, value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let card = keyword + "= " + value
        return card.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    private func endCard() -> String {
        "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    // MARK: - Single star: FWHM accuracy

    func testSingleStarFWHMAccuracy() async throws {
        // Plant a single Gaussian star with known sigma = 2.5 px.
        // FWHM = 2.355 × sigma ≈ 5.9 px
        let width = 256, height = 256
        let sigma: Float = 2.5
        let expectedFWHM = 2.3548 * sigma  // ≈ 5.89

        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: [SyntheticStar(cx: 128, cy: 128, amplitude: 8000, sigma: sigma)])

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: true)
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        XCTAssertNotNil(metrics, "Should detect at least one star")
        guard let m = metrics else { return }

        XCTAssertNotNil(m.fwhm)
        if let fwhm = m.fwhm {
            // Allow 30% tolerance — the Moffat fitter on a Gaussian isn't exact
            XCTAssertEqual(Double(fwhm), Double(expectedFWHM), accuracy: Double(expectedFWHM) * 0.3,
                           "FWHM should be close to planted value")
        }

        XCTAssertNotNil(m.starCount)
        if let count = m.starCount {
            XCTAssertGreaterThanOrEqual(count, 1, "Should detect at least the planted star")
        }
    }

    // MARK: - Multiple stars: count accuracy

    func testMultipleStarsDetected() async throws {
        let width = 512, height = 512
        let stars = [
            SyntheticStar(cx: 100, cy: 100, amplitude: 6000, sigma: 2.0),
            SyntheticStar(cx: 250, cy: 100, amplitude: 7000, sigma: 2.5),
            SyntheticStar(cx: 400, cy: 100, amplitude: 5000, sigma: 2.0),
            SyntheticStar(cx: 100, cy: 350, amplitude: 8000, sigma: 3.0),
            SyntheticStar(cx: 300, cy: 300, amplitude: 6000, sigma: 2.5),
        ]

        let pixels = makeImage(width: width, height: height, background: 1000, stars: stars)

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                   computeSNR: true, computeStarCount: true)
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        XCTAssertNotNil(metrics)
        guard let m = metrics else { return }

        // All 5 should be detected; allow a few extra from ringing
        XCTAssertGreaterThanOrEqual(m.starCount ?? 0, 4, "Should detect most planted stars")
        XCTAssertLessThanOrEqual(m.starCount ?? 999, 10, "Should not wildly overcount")

        // Eccentricity should be low — all stars are round
        if let ecc = m.eccentricity {
            XCTAssertLessThan(ecc, 0.3, "Round stars should have low eccentricity")
        }
    }

    // MARK: - Stars on gradient background

    func testStarsOnGradientBackground() async throws {
        let width = 512, height = 512
        let stars = [
            SyntheticStar(cx: 80,  cy: 256, amplitude: 6000, sigma: 2.5),  // dim side
            SyntheticStar(cx: 430, cy: 256, amplitude: 6000, sigma: 2.5),  // bright side
        ]

        // Gradient adds 0..2000 ADU left-to-right (simulates light pollution)
        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: stars, gradient: 2000)

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: true)
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        XCTAssertNotNil(metrics)
        guard let m = metrics else { return }

        // Both stars should be detected despite the gradient
        XCTAssertGreaterThanOrEqual(m.starCount ?? 0, 2,
                                    "Background estimator should handle gradient")
    }

    // MARK: - Noisy background: false positive rejection

    func testNoisyBackgroundRejectsNoise() async throws {
        let width = 256, height = 256
        // No stars — just background + noise. Sigma of noise = 50 ADU.
        // Detection threshold is background + 5σ(estimated), so noise peaks
        // should not survive.
        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: [], noise: 50)

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: true)
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        // Should return nil (no valid stars) or a very low count
        if let m = metrics {
            XCTAssertLessThanOrEqual(m.starCount ?? 0, 3,
                                     "Noise-only image should have near-zero star count")
        }
        // nil is also acceptable — means no candidates passed the threshold
    }

    // MARK: - Elongated star: eccentricity detection

    func testElongatedStarHasHighEccentricity() async throws {
        let width = 256, height = 256
        // Elongated: sigmaX = 1.5, sigmaY = 5.0 → axis ratio ~3.3
        let stars = [
            SyntheticStar(cx: 128, cy: 128, amplitude: 8000, sigmaX: 1.5, sigmaY: 5.0)
        ]

        let pixels = makeImage(width: width, height: height, background: 1000, stars: stars)

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                   computeSNR: false, computeStarCount: false)
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        XCTAssertNotNil(metrics)
        if let ecc = metrics?.eccentricity {
            XCTAssertGreaterThan(ecc, 0.3, "Elongated star should have elevated eccentricity")
        }
    }

    // MARK: - Flat image: no stars

    func testFlatImageReturnsNil() async throws {
        let width = 128, height = 128
        let pixels = makeImage(width: width, height: height, background: 1000, stars: [])

        let config = MetricsConfig()
        let metrics = await MetricsCalculator.compute(pixels: pixels,
                                                       width: width, height: height,
                                                       config: config)

        XCTAssertNil(metrics, "Flat image with no stars should return nil")
    }

    // MARK: - FITS round-trip: file → read → metrics

    func testFITSRoundTripProducesMetrics() async throws {
        let width = 256, height = 256
        let pixels = makeImage(width: width, height: height, background: 32768,
                               stars: [
                                   SyntheticStar(cx: 128, cy: 128, amplitude: 10000, sigma: 2.5),
                                   SyntheticStar(cx: 60,  cy: 60,  amplitude: 8000,  sigma: 2.0),
                               ])

        let url = try writeFITS(pixels: pixels, width: width, height: height)
        defer { try? FileManager.default.removeItem(at: url) }

        // Read back through FITSReader
        let fits = try FITSReader.read(from: url)
        XCTAssertEqual(fits.width, width)
        XCTAssertEqual(fits.height, height)
        XCTAssertEqual(fits.pixelValues.count, width * height)

        // Run metrics on the read-back data
        let config = MetricsConfig()
        let metrics = await MetricsCalculator.compute(pixels: fits.pixelValues,
                                                       width: fits.width, height: fits.height,
                                                       config: config)

        XCTAssertNotNil(metrics, "Should detect stars in round-tripped FITS")
        if let m = metrics {
            XCTAssertGreaterThanOrEqual(m.starCount ?? 0, 1)
            XCTAssertNotNil(m.fwhm)
            XCTAssertNotNil(m.eccentricity)
            XCTAssertNotNil(m.snr)
            XCTAssertGreaterThan(m.qualityScore, 0)
        }
    }

    // MARK: - CPU image stretcher

    func testCPUStretchProducesImage() throws {
        let width = 128, height = 128
        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: [SyntheticStar(cx: 64, cy: 64, amplitude: 5000, sigma: 2.0)])

        var mutablePixels = pixels
        let image = ImageStretcher.createImage(from: &mutablePixels,
                                                width: width, height: height,
                                                maxDisplaySize: 128)

        XCTAssertNotNil(image, "CPU stretch should produce a non-nil NSImage")
        if let img = image {
            XCTAssertGreaterThan(img.size.width, 0)
            XCTAssertGreaterThan(img.size.height, 0)
        }
    }

    // MARK: - Histogram from synthetic data

    func testHistogramFromSyntheticImage() {
        let width = 128, height = 128
        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: [SyntheticStar(cx: 64, cy: 64, amplitude: 5000, sigma: 2.0)])

        let minVal = pixels.min()!
        let maxVal = pixels.max()!
        let hist = MetricsCalculator.computeHistogram(pixels: pixels,
                                                       minVal: minVal, maxVal: maxVal)

        XCTAssertEqual(hist.count, 256)
        let totalSampled = hist.reduce(0, +)
        XCTAssertGreaterThan(totalSampled, 0)

        // Most pixels are near the background — the histogram should be heavily
        // weighted toward the low end (background bin).
        let lowerHalf = hist[0..<128].reduce(0, +)
        XCTAssertGreaterThan(lowerHalf, totalSampled / 2,
                             "Background-dominated image should have most counts in lower bins")
    }
}
