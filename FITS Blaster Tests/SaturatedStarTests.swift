//
//  SaturatedStarTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13d (METAL_REVIEW M3): a flat saturated star top gives one candidate (the
//  tie rule at saturation), saturated stars on mono frames count once and are not measured,
//  a saturated hot pixel doesn't count, and a frame only counts as saturated when several
//  pixels share exactly its highest value.
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

struct SaturatedStarTests {

    /// A mono frame: sky 1000 with deterministic uniform noise (±20) and round Moffat β = 4
    /// stars of FWHM 3 px, clipped at 65,535 like a 16-bit camera.
    private static func frame(side: Int, stars: [(x: Int, y: Int, amplitude: Float)]) -> [Float] {
        var pixels = [Float](repeating: 0, count: side * side)
        var seed: UInt32 = 31
        for i in pixels.indices {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
        }
        let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
        for star in stars {
            for dy in -14...14 {
                for dx in -14...14 {
                    let x = star.x + dx, y = star.y + dy
                    guard x >= 0, x < side, y >= 0, y < side else { continue }
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    pixels[y * side + x] = min(65_535, pixels[y * side + x] + star.amplitude * pow(1 + r2, -4))
                }
            }
        }
        return pixels
    }

    /// A small frame with a 3 × 3 flat top at 65,535 centred on (10, 10), sloping down around it.
    private static func plateau() -> [Float] {
        let side = 21
        var pixels = [Float](repeating: 1000, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let d = max(abs(x - 10), abs(y - 10))
                pixels[y * side + x] = d <= 1 ? 65_535 : max(1000, 65_535 - Float(d - 1) * 15_000)
            }
        }
        return pixels
    }

    @Test("A flat saturated top gives one candidate, its top-left pixel; without saturation none")
    func flatTopCPU() {
        let pixels = Self.plateau(), side = 21
        let (withRule, strict) = pixels.withUnsafeBufferPointer { buffer in
            (MetricsCalculator.findLocalMaxima(pixels: buffer, width: side, height: side, cropX: 0, cropY: 0,
                                               cropW: side, cropH: side,
                                               levels: DetectionLevels(offsets: .zero,
                                                                       thresholds: SIMD4(repeating: 2000),
                                                                       saturation: 64_000)),
             MetricsCalculator.findLocalMaxima(pixels: buffer, width: side, height: side, cropX: 0, cropY: 0,
                                               cropW: side, cropH: side, threshold: 2000))
        }
        #expect(withRule.map { [$0.x, $0.y] } == [[9, 9]])
        #expect(strict.isEmpty)
    }

    @Test("The GPU applies the same tie rule as the CPU",
          .enabled(if: MetalContext.detectionPipeline != nil, "Requires the Metal detection kernel"))
    func flatTopGPU() async throws {
        let pixels = Self.plateau(), side = 21
        let device = try #require(MetalContext.device)
        let buffer = try #require(device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<Float>.stride,
                                                    options: .storageModeShared))
        let levels = DetectionLevels(offsets: .zero, thresholds: SIMD4(repeating: 2000), saturation: 64_000)
        let gpu = try #require(await MetricsCalculator.findLocalMaximaGPU(metalBuffer: buffer, width: side,
                                                                         height: side, levels: levels))
        #expect(gpu.candidates.map { [$0.x, $0.y] } == [[9, 9]])
    }

    @Test("A frame is saturated only when at least 3 pixels share exactly the highest value")
    func saturationRule() {
        var pixels = [Float](repeating: 1000, count: 100)
        pixels[10] = 50_000
        pixels[20] = 50_000
        #expect(pixels.withUnsafeBufferPointer { MetricsCalculator.saturationLevel($0) } == nil)
        pixels[30] = 50_000
        let level = pixels.withUnsafeBufferPointer { MetricsCalculator.saturationLevel($0) }
        #expect(level == 50_000 * MetricsCalculator.Constants.saturationFraction)
    }

    @Test("Mono: saturated stars count once each and are left out of FWHM; a saturated hot pixel doesn't count")
    func monoSaturatedStars() async throws {
        let side = 256
        let normal: [(x: Int, y: Int, amplitude: Float)] = (0..<20).map { i in
            let x = 22 + (i % 5) * 50
            let y = 22 + (i / 5) * 50
            return (x: x, y: y, amplitude: Float(3000 + i * 400))
        }
        let saturatedStars: [(x: Int, y: Int, amplitude: Float)] = (0..<3).map { i in
            (x: 48 + i * 80, y: 236, amplitude: Float(400_000))
        }
        var withSaturated = Self.frame(side: side, stars: normal + saturatedStars)
        var reference = Self.frame(side: side, stars: normal)
        // A saturated hot pixel in both: the same saturation level (98 % of 65,535), and it must
        // not count. Three clipped pixels make the reference count as saturated too.
        for frame in [0, 1] {
            for (x, y) in [(250, 10), (5, 120), (130, 5)] {
                if frame == 0 { withSaturated[y * side + x] = 65_535 } else { reference[y * side + x] = 65_535 }
            }
        }
        let metrics = try #require(await MetricsCalculator.compute(pixels: withSaturated, width: side, height: side,
                                                                  config: MetricsConfig()))
        let expected = try #require(await MetricsCalculator.compute(pixels: reference, width: side, height: side,
                                                                   config: MetricsConfig()))
        #expect(expected.starCount == normal.count)
        #expect(metrics.starCount == normal.count + saturatedStars.count)
        let fwhm = try #require(metrics.fwhm), referenceFWHM = try #require(expected.fwhm)
        #expect(abs(fwhm - referenceFWHM) < 0.01)
    }
}
