//
//  IntegrationTests.swift
//  FITS Blaster Tests
//
//  Integration tests that exercise the full pipeline from synthetic pixel data
//  through star detection, shape measurement, and scoring. Uses the CPU fallback
//  paths so tests run reliably without GPU.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct IntegrationTests {

    // MARK: - Synthetic image builder

    private struct SyntheticStar {
        let cx: Int
        let cy: Int
        let amplitude: Float
        let sigmaX: Float
        let sigmaY: Float

        init(cx: Int, cy: Int, amplitude: Float = 5000, sigma: Float = 2.5) {
            self.cx = cx; self.cy = cy
            self.amplitude = amplitude
            self.sigmaX = sigma; self.sigmaY = sigma
        }

        init(cx: Int, cy: Int, amplitude: Float = 5000, sigmaX: Float, sigmaY: Float) {
            self.cx = cx; self.cy = cy
            self.amplitude = amplitude
            self.sigmaX = sigmaX; self.sigmaY = sigmaY
        }
    }

    private func makeImage(width: Int, height: Int,
                           background: Float = 1000,
                           stars: [SyntheticStar] = [],
                           noise: Float = 0,
                           gradient: Float = 0) -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            for x in 0..<width {
                let grad = gradient * Float(x) / Float(width)
                pixels[y * width + x] = background + grad
            }
        }

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

        if noise > 0 {
            var seed: UInt64 = 42
            for i in 0..<pixels.count {
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

    private func writeFITS(pixels: [Float], width: Int, height: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).fits")

        var cards: [String] = [
            card("SIMPLE", bool: true), card("BITPIX", int: 16),
            card("NAXIS", int: 2), card("NAXIS1", int: width),
            card("NAXIS2", int: height), card("BZERO", float: 32768), endCard()
        ]
        var headerData = Data(cards.joined().utf8)
        while headerData.count % 2880 != 0 { headerData.append(0x20) }

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
            ? String(format: "%.1f", value) : String(format: "%E", value)
        return fitsCard(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }
    private func fitsCard(_ key: String, value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return (keyword + "= " + value).padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    private func endCard() -> String {
        "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    // MARK: - Single star: FWHM accuracy

    @Test("Single Gaussian star: FWHM matches planted value within 30%")
    func singleStarFWHMAccuracy() async throws {
        let width = 256, height = 256
        let sigma: Float = 2.5
        let expectedFWHM = Double(2.3548 * sigma)

        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: [SyntheticStar(cx: 128, cy: 128, amplitude: 8000, sigma: sigma)])

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                   computeSNR: false, computeStarCount: true)
        let m = try #require(await MetricsCalculator.compute(pixels: pixels,
                                                              width: width, height: height,
                                                              config: config))
        let fwhm = try #require(m.fwhm)
        #expect(abs(Double(fwhm) - expectedFWHM) < expectedFWHM * 0.3,
                "FWHM \(fwhm) should be close to planted \(expectedFWHM)")
        #expect((m.starCount ?? 0) >= 1, "Should detect at least the planted star")
    }

    // MARK: - Multiple stars: count accuracy

    @Test("Five planted stars: count and eccentricity")
    func multipleStarsDetected() async throws {
        let pixels = makeImage(width: 512, height: 512, background: 1000, stars: [
            SyntheticStar(cx: 100, cy: 100, amplitude: 6000, sigma: 2.0),
            SyntheticStar(cx: 250, cy: 100, amplitude: 7000, sigma: 2.5),
            SyntheticStar(cx: 400, cy: 100, amplitude: 5000, sigma: 2.0),
            SyntheticStar(cx: 100, cy: 350, amplitude: 8000, sigma: 3.0),
            SyntheticStar(cx: 300, cy: 300, amplitude: 6000, sigma: 2.5),
        ])

        let m = try #require(await MetricsCalculator.compute(
            pixels: pixels, width: 512, height: 512, config: MetricsConfig()))

        #expect((m.starCount ?? 0) >= 4, "Should detect most planted stars")
        #expect((m.starCount ?? 999) <= 10, "Should not wildly overcount")
        if let ecc = m.eccentricity {
            #expect(ecc < 0.3, "Round stars should have low eccentricity")
        }
    }

    // MARK: - Stars on gradient background

    @Test("Stars detected despite 2000 ADU gradient")
    func starsOnGradientBackground() async throws {
        let pixels = makeImage(width: 512, height: 512, background: 1000,
                               stars: [
                                   SyntheticStar(cx: 80,  cy: 256, amplitude: 6000, sigma: 2.5),
                                   SyntheticStar(cx: 430, cy: 256, amplitude: 6000, sigma: 2.5),
                               ], gradient: 2000)

        let m = try #require(await MetricsCalculator.compute(
            pixels: pixels, width: 512, height: 512,
            config: MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                  computeSNR: false, computeStarCount: true)))

        #expect((m.starCount ?? 0) >= 2, "Background estimator should handle gradient")
    }

    // MARK: - Noisy background: false positive rejection

    @Test("Noise-only image has near-zero star count")
    func noisyBackgroundRejectsNoise() async {
        let pixels = makeImage(width: 256, height: 256, background: 1000, noise: 50)
        let m = await MetricsCalculator.compute(
            pixels: pixels, width: 256, height: 256,
            config: MetricsConfig(computeFWHM: true, computeEccentricity: false,
                                  computeSNR: false, computeStarCount: true))
        // nil is acceptable (no candidates passed threshold)
        if let m { #expect((m.starCount ?? 0) <= 3) }
    }

    // MARK: - Elongated star: eccentricity detection

    @Test("Elongated star has elevated eccentricity")
    func elongatedStarHasHighEccentricity() async throws {
        let pixels = makeImage(width: 256, height: 256, background: 1000,
                               stars: [SyntheticStar(cx: 128, cy: 128, amplitude: 8000,
                                                     sigmaX: 1.5, sigmaY: 5.0)])
        let m = try #require(await MetricsCalculator.compute(
            pixels: pixels, width: 256, height: 256,
            config: MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                  computeSNR: false, computeStarCount: false)))

        if let ecc = m.eccentricity {
            #expect(ecc > 0.3, "Elongated star should have elevated eccentricity")
        }
    }

    // MARK: - Flat image: no stars

    @Test("Flat image with no stars returns nil")
    func flatImageReturnsNil() async {
        let pixels = makeImage(width: 128, height: 128, background: 1000)
        let m = await MetricsCalculator.compute(pixels: pixels, width: 128, height: 128,
                                                 config: MetricsConfig())
        #expect(m == nil, "Flat image with no stars should return nil")
    }

    // MARK: - FITS round-trip

    @Test("FITS file → read → metrics produces valid results")
    func fitsRoundTripProducesMetrics() async throws {
        let pixels = makeImage(width: 256, height: 256, background: 32768,
                               stars: [
                                   SyntheticStar(cx: 128, cy: 128, amplitude: 10000, sigma: 2.5),
                                   SyntheticStar(cx: 60,  cy: 60,  amplitude: 8000,  sigma: 2.0),
                               ])
        let url = try writeFITS(pixels: pixels, width: 256, height: 256)
        defer { try? FileManager.default.removeItem(at: url) }

        let fits = try FITSReader.read(from: url)
        #expect(fits.width == 256)
        #expect(fits.height == 256)
        #expect(fits.pixelValues.count == 256 * 256)

        let m = try #require(await MetricsCalculator.compute(
            pixels: fits.pixelValues, width: fits.width, height: fits.height,
            config: MetricsConfig()))

        #expect((m.starCount ?? 0) >= 1)
        #expect(m.fwhm != nil)
        #expect(m.eccentricity != nil)
        #expect(m.snr != nil)
        #expect(m.qualityScore > 0)
    }

    // MARK: - CPU image stretcher

    @Test("CPU stretch produces a valid NSImage")
    func cpuStretchProducesImage() throws {
        var pixels = makeImage(width: 128, height: 128, background: 1000,
                               stars: [SyntheticStar(cx: 64, cy: 64, amplitude: 5000, sigma: 2.0)])
        let image = try #require(ImageStretcher.createImage(from: &pixels, width: 128, height: 128,
                                                             maxDisplaySize: 128))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - Histogram from synthetic data

    @Test("Histogram from synthetic image is background-dominated")
    func histogramFromSyntheticImage() {
        let pixels = makeImage(width: 128, height: 128, background: 1000,
                               stars: [SyntheticStar(cx: 64, cy: 64, amplitude: 5000, sigma: 2.0)])
        let hist = MetricsCalculator.computeHistogram(pixels: pixels,
                                                       minVal: pixels.min()!, maxVal: pixels.max()!)
        #expect(hist.count == 256)
        let totalSampled = hist.reduce(0, +)
        #expect(totalSampled > 0)
        let lowerHalf = hist[0..<128].reduce(0, +)
        #expect(lowerHalf > totalSampled / 2, "Background-dominated image should peak in lower bins")
    }
}
