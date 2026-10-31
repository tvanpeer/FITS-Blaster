//
//  DetectionCapacityTests.swift
//  FITS Blaster Tests
//
//  A frame with more local maxima than the GPU detection's first candidate list holds gets
//  every one of them, the same on every run. Before, the GPU's thread order decided which
//  ones fitted, and the metrics varied between runs on the same file (m31-night #0026:
//  50,455 maxima against room for 50,000).
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

@Suite(.enabled(if: MetalContext.detectionPipeline != nil, "Requires the Metal detection kernel"))
struct DetectionCapacityTests {

    private static let side = 300

    /// A dark frame with a bright isolated pixel at every (x, y) with x % 3 == 1 and
    /// y % 3 == 1: 100 × 100 strict local maxima, all with different values.
    private func peaksFrame() throws -> MTLBuffer {
        let n = Self.side
        var pixels = [Float](repeating: 0, count: n * n)
        var level: Float = 1000
        for y in stride(from: 1, to: n - 1, by: 3) {
            for x in stride(from: 1, to: n - 1, by: 3) {
                pixels[y * n + x] = level
                level += 1
            }
        }
        let device = try #require(MetalContext.device)
        return try #require(device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<Float>.stride,
                                              options: .storageModeShared))
    }

    private func positions(_ result: MetricsCalculator.GPUDetectionResult) -> [Int] {
        result.candidates.map { $0.y * Self.side + $0.x }
    }

    @Test("More maxima than the first list holds: all of them, the same on every run")
    func overflowIsComplete() async throws {
        let frame = try peaksFrame()
        let n = Self.side
        let pixels = UnsafeBufferPointer(start: frame.contents().assumingMemoryBound(to: Float.self), count: n * n)
        let cpu = MetricsCalculator.findLocalMaxima(pixels: pixels, width: n, height: n,
                                                    cropX: 0, cropY: 0, cropW: n, cropH: n, threshold: 500)
        #expect(cpu.count == 10_000)

        var first: [Int]?
        for _ in 0..<5 {
            let result = try #require(await MetricsCalculator.findLocalMaximaGPU(
                metalBuffer: frame, width: n, height: n, threshold: 500, capacity: 1_000))
            let found = positions(result)
            #expect(found.count == 10_000)
            if let first { #expect(found == first) } else { first = found }
        }
        #expect(Set(first ?? []) == Set(cpu.map { $0.y * n + $0.x }))
    }

    @Test("Exactly enough room: one pass, the same candidates as with more room")
    func underCapacity() async throws {
        let frame = try peaksFrame()
        let n = Self.side
        let small = try #require(await MetricsCalculator.findLocalMaximaGPU(
            metalBuffer: frame, width: n, height: n, threshold: 500, capacity: 10_000))
        let large = try #require(await MetricsCalculator.findLocalMaximaGPU(
            metalBuffer: frame, width: n, height: n, threshold: 500))
        #expect(positions(small) == positions(large))
    }
}
