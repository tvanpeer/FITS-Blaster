//
//  MetricsDeterminismTests.swift
//  FITS Blaster Tests
//
//  The same image must always give the same metrics. The GPU returns star candidates
//  in a random order and 16-bit data has many equal peaks, so the candidate sort has
//  to break ties deterministically, and parallel measurements have to be combined in
//  a fixed order.
//

import Testing
import Metal
@testable import FITS_Blaster

struct MetricsDeterminismTests {

    private typealias StarCandidate = MetricsCalculator.StarCandidate

    // MARK: - Candidate order

    /// Candidates with many equal peaks, some of them close enough together for
    /// non-maximum suppression to keep only one.
    private func tiedCandidates() -> [StarCandidate] {
        var candidates: [StarCandidate] = []
        for i in 0..<300 {
            let x = 10 + (i % 20) * 12, y = 10 + (i / 20) * 12
            let peak: Float = i % 3 == 0 ? 65535 : Float(40000 + (i % 5) * 1000)
            candidates.append(StarCandidate(x: x, y: y, peak: peak))
            // A neighbour 2 px away with the same peak: suppression keeps one of the two.
            candidates.append(StarCandidate(x: x + 2, y: y, peak: peak))
        }
        return candidates
    }

    @Test("Shuffled candidates sort into the same order")
    func sortIsDeterministic() {
        let reference = tiedCandidates().sorted(by: StarCandidate.brighterFirst)
        for _ in 0..<20 {
            let sorted = tiedCandidates().shuffled().sorted(by: StarCandidate.brighterFirst)
            #expect(sorted.map { [$0.x, $0.y] } == reference.map { [$0.x, $0.y] })
        }
    }

    @Test("Equal peaks are ordered by row, then column")
    func tieBreakOrder() {
        let a = StarCandidate(x: 5, y: 1, peak: 100)
        let b = StarCandidate(x: 1, y: 2, peak: 100)
        let c = StarCandidate(x: 2, y: 2, peak: 100)
        let brighter = StarCandidate(x: 9, y: 9, peak: 200)
        let sorted = [c, b, a, brighter].sorted(by: StarCandidate.brighterFirst)
        #expect(sorted.map { [$0.x, $0.y] } == [[9, 9], [5, 1], [1, 2], [2, 2]])
    }

    @Test("Suppression keeps the same stars whatever order the candidates arrived in")
    func suppressionIsDeterministic() {
        let reference = MetricsCalculator.nonMaximumSuppression(
            tiedCandidates().sorted(by: StarCandidate.brighterFirst), imageWidth: 300)
        for _ in 0..<20 {
            let kept = MetricsCalculator.nonMaximumSuppression(
                tiedCandidates().shuffled().sorted(by: StarCandidate.brighterFirst), imageWidth: 300)
            #expect(kept.map { [$0.x, $0.y] } == reference.map { [$0.x, $0.y] })
        }
    }

    // MARK: - Full measurement on the GPU

    /// 625 stars with exactly the same peak value but different widths: which 200 are
    /// measured decides FWHM, eccentricity and SNR, so a random choice shows up at once.
    @Test("Measuring the same image repeatedly on the GPU gives identical metrics",
          .enabled(if: ImageStretcher.metalDevice != nil, "Requires Metal GPU"))
    func gpuMetricsAreDeterministic() async throws {
        let device = try #require(ImageStretcher.metalDevice)
        let width = 520, height = 520
        let buffer = try #require(device.makeBuffer(length: width * height * MemoryLayout<Float>.stride,
                                                    options: .storageModeShared))
        let pixels = buffer.contents().assumingMemoryBound(to: Float.self)
        for i in 0..<(width * height) { pixels[i] = 1000 }

        for row in 0..<25 {
            for column in 0..<25 {
                let cx = 20 + column * 20, cy = 20 + row * 20
                let sigma = 1.2 + Float((row * 25 + column) % 7) * 0.25
                for y in (cy - 8)...(cy + 8) {
                    for x in (cx - 8)...(cx + 8) {
                        let dx = Float(x - cx), dy = Float(y - cy)
                        pixels[y * width + x] += 9000 * exp(-0.5 * (dx * dx + dy * dy) / (sigma * sigma))
                    }
                }
            }
        }
        // Whole numbers, like 16-bit FITS data: every star centre is exactly 10 000.
        for i in 0..<(width * height) { pixels[i] = pixels[i].rounded() }

        let config = MetricsConfig(computeFWHM: true, computeEccentricity: true,
                                   computeSNR: true, computeStarCount: true)
        let reference = try #require(
            await MetricsCalculator.compute(metalBuffer: buffer,
                                            width: width, height: height, config: config))
        for _ in 0..<10 {
            let metrics = try #require(
                await MetricsCalculator.compute(metalBuffer: buffer,
                                                width: width, height: height, config: config))
            #expect(metrics.fwhm == reference.fwhm)
            #expect(metrics.eccentricity == reference.eccentricity)
            #expect(metrics.snr == reference.snr)
            #expect(metrics.starCount == reference.starCount)
            #expect(metrics.psfSignalWeight == reference.psfSignalWeight)
            #expect(metrics.qualityScore == reference.qualityScore)
        }
    }
}
