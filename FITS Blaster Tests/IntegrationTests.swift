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

    /// Ten copies of `star` on a 5 × 2 grid: a frame needs at least
    /// `MetricsCalculator.Constants.minimumStars` stars to be measured (step 13g). Their
    /// peaks differ by 1 % each: identical peaks would share the frame's highest value and
    /// count as saturated (step 13d).
    private func tenCopies(of star: SyntheticStar, width: Int, height: Int) -> [SyntheticStar] {
        (0..<10).map { i in
            SyntheticStar(cx: width * (1 + 2 * (i % 5)) / 10, cy: height * (1 + 2 * (i / 5)) / 4,
                          amplitude: star.amplitude * (1 + 0.01 * Float(i)),
                          sigmaX: star.sigmaX, sigmaY: star.sigmaY)
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
        let stored = pixels.map { Int16(bitPattern: UInt16(max(0, min(65535, $0))) &- 32768) }
        var pixelData = TestFITS.bigEndian(stored)
        pixelData.append(Data(count: width * height * 2 - pixelData.count))
        let cards = TestFITS.imageCards(bitpix: 16, width: width, height: height, bzero: 32768)
        return try TestFITS.write(TestFITS.fileData(cards: cards, pixels: pixelData))
    }

    // MARK: - Single star: FWHM accuracy

    @Test("Ten identical Gaussian stars: FWHM matches planted value within 30%")
    func singleStarFWHMAccuracy() async throws {
        let width = 256, height = 256
        let sigma: Float = 2.5
        let expectedFWHM = Double(2.3548 * sigma)

        let pixels = makeImage(width: width, height: height, background: 1000,
                               stars: tenCopies(of: SyntheticStar(cx: 0, cy: 0, amplitude: 8000, sigma: sigma),
                                                width: width, height: height))

        let config = MetricsConfig()
        let m = try #require(await MetricsCalculator.compute(pixels: pixels,
                                                              width: width, height: height,
                                                              config: config))
        let fwhm = try #require(m.fwhm)
        #expect(abs(Double(fwhm) - expectedFWHM) < expectedFWHM * 0.3,
                "FWHM \(fwhm) should be close to planted \(expectedFWHM)")
        #expect(m.starCount == 10, "Should detect the planted stars")
    }

    // MARK: - Multiple stars: count accuracy

    @Test("Twelve planted stars: count and eccentricity")
    func multipleStarsDetected() async throws {
        let pixels = makeImage(width: 512, height: 512, background: 1000, stars: [
            SyntheticStar(cx: 100, cy: 100, amplitude: 6000, sigma: 2.0),
            SyntheticStar(cx: 250, cy: 100, amplitude: 7000, sigma: 2.5),
            SyntheticStar(cx: 400, cy: 100, amplitude: 5000, sigma: 2.0),
            SyntheticStar(cx: 100, cy: 350, amplitude: 8000, sigma: 3.0),
            SyntheticStar(cx: 300, cy: 300, amplitude: 6000, sigma: 2.5),
            SyntheticStar(cx: 450, cy: 220, amplitude: 6500, sigma: 2.2),
            SyntheticStar(cx: 60,  cy: 220, amplitude: 7500, sigma: 2.4),
            SyntheticStar(cx: 200, cy: 450, amplitude: 5500, sigma: 2.6),
            SyntheticStar(cx: 350, cy: 450, amplitude: 6200, sigma: 2.0),
            SyntheticStar(cx: 450, cy: 400, amplitude: 7200, sigma: 2.8),
            SyntheticStar(cx: 180, cy: 230, amplitude: 5800, sigma: 2.3),
            SyntheticStar(cx: 330, cy: 180, amplitude: 6800, sigma: 2.1),
        ])

        let m = try #require(await MetricsCalculator.compute(
            pixels: pixels, width: 512, height: 512, config: MetricsConfig()))

        #expect((m.starCount ?? 0) >= 11, "Should detect most planted stars")
        #expect((m.starCount ?? 999) <= 16, "Should not wildly overcount")
        let ecc = try #require(m.eccentricity)
        #expect(ecc < 0.3, "Round stars should have low eccentricity")
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
            config: MetricsConfig()))

        #expect((m.starCount ?? 0) >= 2, "Background estimator should handle gradient")
    }

    // MARK: - Noisy background: false positive rejection

    @Test("Noise-only image has near-zero star count")
    func noisyBackgroundRejectsNoise() async {
        let pixels = makeImage(width: 256, height: 256, background: 1000, noise: 50)
        let m = await MetricsCalculator.compute(
            pixels: pixels, width: 256, height: 256,
            config: MetricsConfig())
        // nil is acceptable (no candidates passed threshold)
        if let m { #expect((m.starCount ?? 0) <= 3) }
    }

    // MARK: - Elongated star: eccentricity detection

    @Test("Elongated star has elevated eccentricity")
    func elongatedStarHasHighEccentricity() async throws {
        let pixels = makeImage(width: 256, height: 256, background: 1000,
                               stars: tenCopies(of: SyntheticStar(cx: 0, cy: 0, amplitude: 8000,
                                                                  sigmaX: 1.5, sigmaY: 5.0),
                                                width: 256, height: 256))
        let m = try #require(await MetricsCalculator.compute(
            pixels: pixels, width: 256, height: 256,
            config: MetricsConfig()))

        let ecc = try #require(m.eccentricity)
        #expect(ecc > 0.3, "Elongated stars should have elevated eccentricity")
    }

    // MARK: - Flat image: no stars

    @Test("Flat image with no stars: star count 0 and score 0 (step 13g)")
    func flatImageReturnsNil() async throws {
        let pixels = makeImage(width: 128, height: 128, background: 1000)
        let m = try #require(await MetricsCalculator.compute(pixels: pixels, width: 128, height: 128,
                                                             config: MetricsConfig()))
        #expect(m.starCount == 0)
        #expect(m.qualityScore == 0)
        #expect(m.fwhm == nil)
    }

    // MARK: - FITS round-trip

    @Test("FITS file → read → metrics produces valid results")
    func fitsRoundTripProducesMetrics() async throws {
        let pixels = makeImage(width: 256, height: 256, background: 32768,
                               stars: tenCopies(of: SyntheticStar(cx: 0, cy: 0, amplitude: 10000, sigma: 2.5),
                                                width: 256, height: 256))
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
                                                             flipRows: false, maxDisplaySize: 128))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    // MARK: - Histogram from synthetic data

    @Test("Histogram from synthetic image is background-dominated")
    func histogramFromSyntheticImage() throws {
        let pixels = makeImage(width: 128, height: 128, background: 1000,
                               stars: [SyntheticStar(cx: 64, cy: 64, amplitude: 5000, sigma: 2.0)])
        let minVal = try #require(pixels.min())
        let maxVal = try #require(pixels.max())
        let hist = MetricsCalculator.computeHistogram(pixels: pixels,
                                                       minVal: minVal, maxVal: maxVal)
        #expect(hist.count == 256)
        let totalSampled = hist.reduce(0, +)
        #expect(totalSampled > 0)
        let lowerHalf = hist[0..<128].reduce(0, +)
        #expect(lowerHalf > totalSampled / 2, "Background-dominated image should peak in lower bins")
    }
}
