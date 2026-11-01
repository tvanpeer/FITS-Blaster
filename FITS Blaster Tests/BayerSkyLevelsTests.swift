//
//  BayerSkyLevelsTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13a: on raw colour (Bayer) frames the sky background and noise are
//  measured per position of the 2×2 cell, so the sky colour no longer counts as noise and
//  no longer hides faint stars; saturated stars are counted once and not measured. Mono
//  frames keep the old single-level arithmetic.
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

struct BayerSkyLevelsTests {

    private static let side = 256
    /// Sky per cell position of an RGGB frame: R, G (red row), G (blue row), B.
    private static let sky = SIMD4<Float>(1000, 1400, 1400, 600)
    /// Peak-to-peak of the uniform noise; its σ is about 40 / √12 ≈ 11.5.
    private static let noiseAmplitude: Float = 40

    /// An RGGB frame with a coloured sky, deterministic noise and grey Moffat stars
    /// (β = 4, FWHM 3 px) of the given amplitudes, clipped at 65,535 like a 16-bit camera.
    private static func colourFrame(stars: [(x: Int, y: Int, amplitude: Float)]) -> [Float] {
        let n = side
        var pixels = [Float](repeating: 0, count: n * n)
        var seed: UInt32 = 2024
        for y in 0..<n {
            for x in 0..<n {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let noise = (Float(seed >> 8) / Float(1 << 24) - 0.5) * noiseAmplitude
                pixels[y * n + x] = sky[SkyLevels.cellIndex(x: x, y: y)] + noise
            }
        }
        let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
        for star in stars {
            for dy in -14...14 {
                for dx in -14...14 {
                    let x = star.x + dx, y = star.y + dy
                    guard x >= 0, x < n, y >= 0, y < n else { continue }
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    pixels[y * n + x] = min(65_535, pixels[y * n + x] + star.amplitude * pow(1 + r2, -4))
                }
            }
        }
        return pixels
    }

    /// Ten stars on a 5 × 2 grid, centred on G pixels (even row, odd column).
    private static let faintStarPositions: [(x: Int, y: Int)] =
        (0..<10).map { (x: 41 + ($0 % 5) * 44, y: 80 + ($0 / 5) * 96) }

    @Test("The background and σ of each Bayer position are those of its channel")
    func channelLevels() {
        let pixels = Self.colourFrame(stars: [])
        let levels = pixels.withUnsafeBufferPointer {
            MetricsCalculator.estimateChannelLevels($0, width: Self.side, height: Self.side)
        }
        #expect(levels.isPerChannel)
        for cell in 0..<4 {
            #expect(abs(levels.background[cell] - Self.sky[cell]) < 3)
            // Uniform noise of ±20: MAD 10, so 1.4826 × MAD ≈ 14.8.
            #expect(levels.sigma[cell] > 13 && levels.sigma[cell] < 17)
        }
        let single = pixels.withUnsafeBufferPointer {
            MetricsCalculator.estimateBackground($0, width: Self.side, height: Self.side)
        }
        // One σ over the whole mosaic counts the sky colour as noise.
        #expect(single.sigma > 3 * levels.sigma.max())
    }

    @Test("Mono frames keep the old detection: no offsets, one threshold of background + 5σ")
    func monoLevelsUnchanged() {
        let levels = SkyLevels.uniform(background: 812.5, sigma: 23.25).detectionLevels()
        #expect(levels == .uniform(threshold: 812.5 + MetricsCalculator.Constants.detectionSigmas * 23.25))
        #expect(levels.lowestCandidateValue == 812.5 + MetricsCalculator.Constants.detectionSigmas * 23.25)
    }

    @Test("Faint stars on a coloured sky are found with per-channel levels, not with one level")
    func faintStarsOnColouredSky() {
        let stars = Self.faintStarPositions.map { (x: $0.x, y: $0.y, amplitude: Float(300)) }
        let pixels = Self.colourFrame(stars: stars)
        let n = Self.side
        let (perChannel, single) = pixels.withUnsafeBufferPointer { buffer in
            let levels = MetricsCalculator.estimateChannelLevels(buffer, width: n, height: n)
            let perChannel = MetricsCalculator.findLocalMaxima(
                pixels: buffer, width: n, height: n, cropX: 0, cropY: 0, cropW: n, cropH: n,
                levels: levels.detectionLevels())
            let old = MetricsCalculator.estimateBackground(buffer, width: n, height: n)
            let single = MetricsCalculator.findLocalMaxima(
                pixels: buffer, width: n, height: n, cropX: 0, cropY: 0, cropW: n, cropH: n,
                threshold: old.median + MetricsCalculator.Constants.detectionSigmas * old.sigma)
            return (MetricsCalculator.nonMaximumSuppression(perChannel, imageWidth: n), single)
        }
        for star in Self.faintStarPositions {
            #expect(perChannel.contains { abs($0.x - star.x) <= 1 && abs($0.y - star.y) <= 1 })
        }
        #expect(perChannel.count == stars.count)   // no sky pixels of the brighter channel
        #expect(single.isEmpty)
    }

    @Test("The star-count check accepts a faint star whose neighbours are another colour")
    func countCheckPerChannel() {
        let star = Self.faintStarPositions[0]
        let pixels = Self.colourFrame(stars: [(x: star.x, y: star.y, amplitude: 300)])
        let n = Self.side
        let (perChannel, single) = pixels.withUnsafeBufferPointer { buffer in
            let levels = MetricsCalculator.estimateChannelLevels(buffer, width: n, height: n)
            let old = MetricsCalculator.estimateBackground(buffer, width: n, height: n)
            return (MetricsCalculator.measureFWHMOnly(pixels: buffer, width: n, height: n,
                                                      cx: star.x, cy: star.y, sky: levels),
                    MetricsCalculator.measureFWHMOnly(pixels: buffer, width: n, height: n,
                                                      cx: star.x, cy: star.y,
                                                      sky: .uniform(background: old.median, sigma: old.sigma)))
        }
        #expect(MetricsCalculator.Shape.acceptedFWHM.contains(perChannel))
        #expect(single == 0)
    }

    @Test("Saturated stars are counted once each and left out of FWHM")
    func saturatedStars() async throws {
        let n = Self.side
        let normal: [(x: Int, y: Int, amplitude: Float)] = (0..<20).map { i in
            let x = 22 + (i % 5) * 50
            let y = 22 + (i / 5) * 60
            return (x: x, y: y, amplitude: Float(3000 + i * 400))
        }
        let saturatedStars: [(x: Int, y: Int, amplitude: Float)] = (0..<3).map { i in
            (x: 48 + i * 80, y: 236, amplitude: Float(400_000))
        }
        var withSaturated = Self.colourFrame(stars: normal + saturatedStars)
        var without = Self.colourFrame(stars: normal)
        // One saturated hot pixel in both frames gives them the same saturation level (98 % of
        // the frame maximum); without it the brightest normal star would be the reference's
        // "saturated" one. It is a saturated candidate in both, counted in both.
        withSaturated[10 * n + 250] = 65_535
        without[10 * n + 250] = 65_535
        let metrics = try #require(await MetricsCalculator.compute(pixels: withSaturated, width: n, height: n,
                                                                  config: MetricsConfig(), bayerPattern: .rggb))
        let reference = try #require(await MetricsCalculator.compute(pixels: without, width: n, height: n,
                                                                    config: MetricsConfig(), bayerPattern: .rggb))
        // Each saturated top holds several R and B pixels that are candidates; one count each.
        #expect(metrics.starCount == (reference.starCount ?? 0) + saturatedStars.count)
        // The fits use the frame's single background, which the saturated stars raise a
        // little; so equal within a hundredth, not bit for bit.
        let fwhm = try #require(metrics.fwhm), referenceFWHM = try #require(reference.fwhm)
        let eccentricity = try #require(metrics.eccentricity), referenceEccentricity = try #require(reference.eccentricity)
        #expect(abs(fwhm - referenceFWHM) < 0.01)
        #expect(abs(eccentricity - referenceEccentricity) < 0.01)
    }

    @Test("The GPU finds the same per-channel candidates as the CPU",
          .enabled(if: MetalContext.detectionPipeline != nil, "Requires the Metal detection kernel"))
    func gpuMatchesCPU() async throws {
        let stars = Self.faintStarPositions.map { (x: $0.x, y: $0.y, amplitude: Float(300)) }
        let pixels = Self.colourFrame(stars: stars)
        let n = Self.side
        let device = try #require(MetalContext.device)
        let buffer = try #require(device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<Float>.stride,
                                                    options: .storageModeShared))
        let frame = UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: Float.self), count: n * n)
        let levels = MetricsCalculator.estimateChannelLevels(frame, width: n, height: n).detectionLevels()
        let cpu = MetricsCalculator.findLocalMaxima(pixels: frame, width: n, height: n,
                                                    cropX: 0, cropY: 0, cropW: n, cropH: n, levels: levels)
        let gpu = try #require(await MetricsCalculator.findLocalMaximaGPU(metalBuffer: buffer, width: n, height: n,
                                                                         levels: levels))
        #expect(gpu.candidates.map { [$0.x, $0.y] } == cpu.map { [$0.x, $0.y] })
        #expect(gpu.candidates.map(\.peak) == cpu.map(\.peak))
    }
}
