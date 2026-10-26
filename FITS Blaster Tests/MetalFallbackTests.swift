//
//  MetalFallbackTests.swift
//  FITS Blaster Tests
//
//  MetalContext: a failed GPU pass is detected and the CPU path takes over (CODE_AUDIT
//  §5.17), the threadgroup is clamped, and the CPU stretch is compared with the GPU
//  stretch (METAL_REVIEW M1). Failures are forced with the task-local
//  `MetalContext.failsCommandBuffersForTesting`, which only affects the test that sets it.
//

import AppKit
import Metal
import Testing
@testable import FITS_Blaster

@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"))
struct MetalFallbackTests {

    private static let width = 600, height = 400

    /// A synthetic frame: sky with a gradient and deterministic noise, plus 40 Gaussian stars.
    private static func starField() -> [Float] {
        var pixels = [Float](repeating: 0, count: width * height)
        var seed: UInt32 = 12345
        func noise() -> Float {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) - 0.5
        }
        for y in 0..<height {
            for x in 0..<width {
                pixels[y * width + x] = 1000 + Float(x + y) * 0.5 + noise() * 40
            }
        }
        for s in 0..<40 {
            let cx = 20 + (s * 137) % (width - 40), cy = 20 + (s * 89) % (height - 40)
            let amplitude = Float(2000 + (s * 997) % 20000)
            for dy in -8...8 {
                for dx in -8...8 {
                    let r2 = Float(dx * dx + dy * dy)
                    pixels[(cy + dy) * width + (cx + dx)] += amplitude * exp(-r2 / (2 * 1.8 * 1.8))
                }
            }
        }
        return pixels
    }

    private static func buffer(_ pixels: [Float]) throws -> MTLBuffer {
        let device = try #require(MetalContext.device)
        return try #require(device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<Float>.stride,
                                              options: .storageModeShared))
    }

    /// The 8-bit grey pixels of a rendered image.
    private static func greyBytes(_ image: NSImage) throws -> (width: Int, height: Int, bytes: [UInt8]) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let data = try #require(cg.dataProvider?.data as Data?)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(cg.width * cg.height)
        for row in 0..<cg.height {
            let start = row * cg.bytesPerRow
            bytes.append(contentsOf: data[start..<(start + cg.width)])
        }
        return (cg.width, cg.height, bytes)
    }

    // MARK: - Failed passes fall back to the CPU (§5.17)

    @Test("A failed stretch pass renders on the CPU, the same as the CPU path")
    func failedStretchUsesCPU() async throws {
        var pixels = Self.starField()
        let frame = pixels
        let rendered = try await MetalContext.$failsCommandBuffersForTesting.withValue(true) {
            // The buffer is made where it is used: Swift 6 doesn't let a Metal buffer
            // cross from one closure or task into another.
            let input = try Self.buffer(frame)
            return await ImageStretcher.createImage(inputBuffer: input, width: Self.width,
                                                    height: Self.height, maxDisplaySize: 256)
        }
        let fallback = try #require(rendered)
        let cpu = try #require(ImageStretcher.createImage(from: &pixels, width: Self.width,
                                                          height: Self.height, maxDisplaySize: 256))
        let a = try Self.greyBytes(fallback), b = try Self.greyBytes(cpu)
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.bytes == b.bytes)
    }

    @Test("A failed colour pass gives no colour image (the frame keeps its grey render)")
    func failedBayerStretchGivesNil() async throws {
        // A fresh buffer for each call: a Metal buffer can't be shared between concurrent calls.
        let pixels = Self.starField()
        let clips = ImageStretcher.computeBayerClips(try Self.buffer(pixels), width: Self.width,
                                                     height: Self.height, rOffset: 0)
        try #require(clips.isValid)
        let image = try await MetalContext.$failsCommandBuffersForTesting.withValue(true) {
            let failing = try Self.buffer(pixels)
            return await ImageStretcher.createBayerImage(inputBuffer: failing, width: Self.width,
                                                         height: Self.height, rOffset: 0, clips: clips)
        }
        #expect(image == nil)
        // Without the forced failure the same call renders.
        let working = try Self.buffer(pixels)
        #expect(await ImageStretcher.createBayerImage(inputBuffer: working, width: Self.width,
                                                      height: Self.height, rOffset: 0, clips: clips) != nil)
    }

    @Test("A failed detection pass detects on the CPU and still measures the stars")
    func failedDetectionUsesCPU() async throws {
        // A fresh buffer for each call: a Metal buffer can't be shared between concurrent calls.
        let pixels = Self.starField()
        let working = try Self.buffer(pixels)
        let gpuDetection = await MetricsCalculator.findLocalMaximaGPU(metalBuffer: working, width: Self.width,
                                                                      height: Self.height, threshold: 1500)
        #expect(gpuDetection != nil)

        let (failedDetection, fallbackMetrics) = try await MetalContext.$failsCommandBuffersForTesting.withValue(true) {
            let failingDetect = try Self.buffer(pixels)
            let detection = await MetricsCalculator.findLocalMaximaGPU(metalBuffer: failingDetect, width: Self.width,
                                                                       height: Self.height, threshold: 1500)
            let failingMeasure = try Self.buffer(pixels)
            let metrics = await MetricsCalculator.compute(metalBuffer: failingMeasure, width: Self.width,
                                                          height: Self.height, config: MetricsConfig())
            return (detection == nil, metrics)
        }
        #expect(failedDetection)
        let metrics = try #require(fallbackMetrics)
        // The CPU path over the same pixels gives the same measurement.
        let cpu = try #require(await MetricsCalculator.compute(pixels: pixels, width: Self.width,
                                                               height: Self.height, config: MetricsConfig()))
        #expect(metrics.starCount == cpu.starCount)
        #expect(metrics.fwhm == cpu.fwhm)
        #expect((metrics.starCount ?? 0) > 0)
    }

    @Test("The threadgroup is 16 × 16, clamped to the pipeline's limit")
    func threadgroupClamped() throws {
        for pipeline in [MetalContext.stretchPipeline, MetalContext.bayerStretchPipeline,
                         MetalContext.detectionPipeline] {
            let p = try #require(pipeline)
            let size = MetalContext.threadgroupSize(for: p)
            #expect(size.width * size.height <= p.maxTotalThreadsPerThreadgroup)
            #expect(size.width <= 16 && size.height <= 16 && size.depth == 1)
        }
    }

    // MARK: - CPU vs GPU stretch (METAL_REVIEW M1)

    /// Today's difference between the CPU and GPU stretch on the synthetic frame, measured
    /// 2026-10-26 (METAL_REVIEW M1): at full size only the rounding differs (GPU truncates,
    /// CPU rounds); scaled down, the order of downscale and stretch differs too, mostly in
    /// the stars. Whether the CPU path should follow the GPU is decided in master-plan step 13;
    /// until then the difference must not grow.
    private static let parityLimits: [Int: (max: Int, mean: Double)] = [
        0:   (max: 1,  mean: 0.50),
        256: (max: 78, mean: 1.22),
    ]

    @Test("CPU and GPU stretch differ by no more than today (M1)", arguments: [0, 256])
    func cpuGPUParity(maxDisplaySize: Int) async throws {
        var pixels = Self.starField()
        let input = try Self.buffer(pixels)
        let gpuImage = await ImageStretcher.createImage(inputBuffer: input, width: Self.width,
                                                        height: Self.height, maxDisplaySize: maxDisplaySize)
        let gpu = try #require(gpuImage)
        let cpu = try #require(ImageStretcher.createImage(from: &pixels, width: Self.width, height: Self.height,
                                                          maxDisplaySize: maxDisplaySize))
        let g = try Self.greyBytes(gpu), c = try Self.greyBytes(cpu)
        try #require(g.width == c.width && g.height == c.height)
        let diffs = zip(g.bytes, c.bytes).map { abs(Int($0) - Int($1)) }
        let maxDiff = diffs.max() ?? 0
        let meanDiff = Double(diffs.reduce(0, +)) / Double(diffs.count)
        let limits = try #require(Self.parityLimits[maxDisplaySize])
        #expect(maxDiff <= limits.max, "largest difference \(maxDiff) levels at \(g.width)×\(g.height)")
        #expect(meanDiff <= limits.mean, "mean difference \(meanDiff) levels at \(g.width)×\(g.height)")
    }
}
