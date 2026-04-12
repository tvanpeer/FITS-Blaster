//
//  GPUTests.swift
//  FITS Blaster Tests
//
//  Tests for the Metal GPU paths: stretch, star detection, and consistency
//  with the CPU fallback. Skipped automatically when Metal is unavailable.
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

/// Tests that exercise the Metal compute pipeline.
/// All tests are gated on GPU availability — they skip cleanly in headless CI.
@Suite(.enabled(if: ImageStretcher.metalDevice != nil, "Requires Metal GPU"))
struct GPUTests {

    // MARK: - Helpers

    private struct SyntheticStar {
        let cx: Int, cy: Int, amplitude: Float, sigma: Float
    }

    /// Creates an MTLBuffer filled with synthetic pixel data (flat background + Gaussian stars).
    private func makeMetalBuffer(width: Int, height: Int,
                                 background: Float = 1000,
                                 stars: [SyntheticStar] = []) throws -> MTLBuffer {
        let device = try #require(ImageStretcher.metalDevice)
        let count = width * height
        let buffer = try #require(device.makeBuffer(length: count * MemoryLayout<Float>.stride,
                                                     options: .storageModeShared))
        let ptr = buffer.contents().assumingMemoryBound(to: Float.self)

        // Fill background
        for i in 0..<count { ptr[i] = background }

        // Plant stars
        for star in stars {
            let radius = Int(star.sigma * 5)
            let yMin = max(0, star.cy - radius)
            let yMax = min(height - 1, star.cy + radius)
            let xMin = max(0, star.cx - radius)
            let xMax = min(width - 1, star.cx + radius)
            for y in yMin...yMax {
                for x in xMin...xMax {
                    let dx = Float(x - star.cx)
                    let dy = Float(y - star.cy)
                    let exponent = -0.5 * (dx * dx + dy * dy) / (star.sigma * star.sigma)
                    ptr[y * width + x] += star.amplitude * exp(exponent)
                }
            }
        }
        return buffer
    }

    // MARK: - GPU stretch

    @Test("GPU stretch produces a non-nil image with correct dimensions")
    func gpuStretchProducesImage() async throws {
        let width = 256, height = 256
        let buffer = try makeMetalBuffer(width: width, height: height, background: 1000,
                                         stars: [SyntheticStar(cx: 128, cy: 128, amplitude: 5000, sigma: 2.5)])

        let image = try #require(
            await ImageStretcher.createImage(inputBuffer: buffer, width: width, height: height,
                                             maxDisplaySize: 256),
            "GPU stretch should produce a non-nil image")

        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }

    @Test("GPU stretch with downscaling produces smaller image")
    func gpuStretchDownscales() async throws {
        let width = 512, height = 512
        let buffer = try makeMetalBuffer(width: width, height: height, background: 1000,
                                         stars: [SyntheticStar(cx: 256, cy: 256, amplitude: 5000, sigma: 2.5)])

        let image = try #require(
            await ImageStretcher.createImage(inputBuffer: buffer, width: width, height: height,
                                             maxDisplaySize: 128))

        #expect(Int(image.size.width) <= 128)
        #expect(Int(image.size.height) <= 128)
    }

    @Test("GPU stretch handles flat image without crashing")
    func gpuStretchFlatImage() async throws {
        // All pixels identical — the stretch should complete without crashing.
        // Whether it returns nil or a uniform image depends on the percentile estimator.
        let buffer = try makeMetalBuffer(width: 64, height: 64, background: 1000)
        _ = await ImageStretcher.createImage(inputBuffer: buffer, width: 64, height: 64)
        // No crash = pass
    }

    // MARK: - GPU star detection

    @Test("GPU detection finds planted stars")
    func gpuDetectionFindsStars() async throws {
        let width = 256, height = 256
        let buffer = try makeMetalBuffer(width: width, height: height, background: 1000,
                                         stars: [
                                             SyntheticStar(cx: 80,  cy: 80,  amplitude: 6000, sigma: 2.5),
                                             SyntheticStar(cx: 180, cy: 180, amplitude: 7000, sigma: 2.0),
                                         ])
        let device = try #require(ImageStretcher.metalDevice)
        let config = MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                   computeSNR: true, computeStarCount: true)

        let m = try #require(
            await MetricsCalculator.compute(metalBuffer: buffer, device: device,
                                            width: width, height: height, config: config))

        #expect((m.starCount ?? 0) >= 2, "Should detect both planted stars")
        #expect(m.fwhm != nil, "Should compute FWHM")
        #expect(m.eccentricity != nil, "Should compute eccentricity")
        #expect(m.snr != nil, "Should compute SNR")
    }

    @Test("GPU detection returns nil for flat image")
    func gpuDetectionFlatImage() async throws {
        let buffer = try makeMetalBuffer(width: 128, height: 128, background: 1000)
        let device = try #require(ImageStretcher.metalDevice)
        let m = await MetricsCalculator.compute(metalBuffer: buffer, device: device,
                                                 width: 128, height: 128, config: MetricsConfig())
        #expect(m == nil, "Flat image should return nil from GPU detection")
    }

    // MARK: - GPU vs CPU consistency

    @Test("GPU and CPU paths produce consistent star counts")
    func gpuCpuConsistency() async throws {
        let width = 256, height = 256
        let stars = [
            SyntheticStar(cx: 64,  cy: 64,  amplitude: 6000, sigma: 2.0),
            SyntheticStar(cx: 192, cy: 64,  amplitude: 7000, sigma: 2.5),
            SyntheticStar(cx: 128, cy: 192, amplitude: 8000, sigma: 2.0),
        ]
        let buffer = try makeMetalBuffer(width: width, height: height, background: 1000, stars: stars)
        let device = try #require(ImageStretcher.metalDevice)

        // Build a matching Float array for the CPU path
        let ptr = buffer.contents().assumingMemoryBound(to: Float.self)
        var cpuPixels = [Float](repeating: 0, count: width * height)
        for i in 0..<cpuPixels.count { cpuPixels[i] = ptr[i] }

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                   computeSNR: true, computeStarCount: true)

        let gpuMetrics = try #require(
            await MetricsCalculator.compute(metalBuffer: buffer, device: device,
                                            width: width, height: height, config: config))
        let cpuMetrics = try #require(
            await MetricsCalculator.compute(pixels: cpuPixels, width: width, height: height,
                                            config: config))

        // Star counts should be equal or very close — the GPU scans the full frame
        // while the CPU path crops to 4096², but our image is only 256² so both
        // see the same data.
        let gpuStars = try #require(gpuMetrics.starCount)
        let cpuStars = try #require(cpuMetrics.starCount)
        #expect(abs(gpuStars - cpuStars) <= 1,
                "GPU (\(gpuStars)) and CPU (\(cpuStars)) star counts should match")

        // FWHM should agree within 20%
        let gpuFWHM = try #require(gpuMetrics.fwhm)
        let cpuFWHM = try #require(cpuMetrics.fwhm)
        let fwhmDiff = abs(gpuFWHM - cpuFWHM) / max(gpuFWHM, cpuFWHM)
        #expect(fwhmDiff < 0.2,
                "GPU FWHM (\(gpuFWHM)) and CPU FWHM (\(cpuFWHM)) should be within 20%")
    }

    // MARK: - FITS round-trip via Metal buffer

    @Test("FITSReader.readIntoBuffer produces valid Metal buffer")
    func fitsReadIntoBuffer() async throws {
        // Write a synthetic FITS file, read it back via the Metal path
        let width = 64, height = 64
        let device = try #require(ImageStretcher.metalDevice)

        // Build a minimal FITS file with known pixel data
        let url = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).fits")
        defer { try? FileManager.default.removeItem(at: url) }

        var cards: [String] = [
            fitsCard("SIMPLE", bool: true), fitsCard("BITPIX", int: 16),
            fitsCard("NAXIS", int: 2), fitsCard("NAXIS1", int: width),
            fitsCard("NAXIS2", int: height), endCard()
        ]
        var headerData = Data(cards.joined().utf8)
        while headerData.count % 2880 != 0 { headerData.append(0x20) }

        // All pixels = 1000 (big-endian Int16)
        var pixelData = Data(count: width * height * 2)
        let stored: Int16 = 1000
        for i in 0..<(width * height) {
            pixelData[i * 2]     = UInt8((stored >> 8) & 0xFF)
            pixelData[i * 2 + 1] = UInt8(stored & 0xFF)
        }
        while pixelData.count % 2880 != 0 { pixelData.append(0x00) }

        var fileData = headerData
        fileData.append(pixelData)
        try fileData.write(to: url)

        let result = try FITSReader.readIntoBuffer(from: url, device: device)
        #expect(result.metadata.width == width)
        #expect(result.metadata.height == height)
        #expect(result.metadata.bitpix == 16)

        // Verify pixel values in the Metal buffer
        let floatPtr = result.metalBuffer.contents().assumingMemoryBound(to: Float.self)
        #expect(abs(floatPtr[0] - 1000) < 0.5, "First pixel should be ~1000")
        #expect(abs(floatPtr[width * height - 1] - 1000) < 0.5, "Last pixel should be ~1000")
    }

    // MARK: - FITS card helpers

    private func fitsCard(_ key: String, bool value: Bool) -> String {
        let v = String(repeating: " ", count: 19) + (value ? "T" : "F")
        return fitsCardRaw(key, value: v)
    }
    private func fitsCard(_ key: String, int value: Int) -> String {
        let s = String(value)
        return fitsCardRaw(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }
    private func fitsCardRaw(_ key: String, value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return (keyword + "= " + value).padding(toLength: 80, withPad: " ", startingAt: 0)
    }
    private func endCard() -> String {
        "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
