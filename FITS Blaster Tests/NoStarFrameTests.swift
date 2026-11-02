//
//  NoStarFrameTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13g (CODE_AUDIT §5.4): a frame without stars (no candidates at all, or
//  fewer than 10 stars, like a flat) gets metrics with its star count and score 0, every
//  Auto-Flag / CLI check rejects it, it stays out of the group medians, and its badge is
//  "low stars".
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct NoStarFrameTests {

    // MARK: - Measurement

    /// Sky 1000 with deterministic uniform noise (±20), plus `count` round Moffat β = 4 stars
    /// of FWHM 3 px on a grid.
    private static func frame(side: Int = 256, stars count: Int, noise: Bool = true) -> [Float] {
        var pixels = [Float](repeating: 1000, count: side * side)
        if noise {
            var seed: UInt32 = 11
            for i in pixels.indices {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[i] += (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
            }
        }
        let alpha: Float = 3 / MetricsCalculator.Shape.moffatFWHMFactor
        for i in 0..<count {
            let cx = 20 + (i % 5) * 50, cy = 20 + (i / 5) * 50
            let amplitude = Float(4000 + i * 200)
            for dy in -12...12 {
                for dx in -12...12 {
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    pixels[(cy + dy) * side + cx + dx] += amplitude * pow(1 + r2, -4)
                }
            }
        }
        return pixels
    }

    @Test("A frame without any candidate gets star count 0 and score 0, not nil")
    func noCandidates() async throws {
        let n = 256
        let flat = [Float](repeating: 1000, count: n * n)   // no pixel above its neighbours
        let metrics = try #require(await MetricsCalculator.compute(pixels: flat, width: n, height: n,
                                                                  config: MetricsConfig()))
        #expect(metrics.starCount == 0)
        #expect(metrics.qualityScore == 0)
        #expect(metrics.fwhm == nil && metrics.eccentricity == nil && metrics.snr == nil)
        #expect(metrics.psfSignalWeight == nil)
        #expect(metrics.skyBackground == 1000)
        #expect(metrics.hasNoStars)
    }

    @Test("Fewer than 10 stars: no FWHM, eccentricity, SNR or PSF·S, score 0")
    func tooFewStars() async throws {
        let n = 256
        let metrics = try #require(await MetricsCalculator.compute(pixels: Self.frame(stars: 3), width: n, height: n,
                                                                  config: MetricsConfig()))
        #expect(metrics.starCount == 3)
        #expect(metrics.qualityScore == 0)
        #expect(metrics.fwhm == nil && metrics.eccentricity == nil && metrics.snr == nil)
        #expect(metrics.psfSignalWeight == nil)
        #expect(metrics.hasNoStars)
    }

    @Test("10 stars are measured as usual")
    func tenStars() async throws {
        let n = 256
        let metrics = try #require(await MetricsCalculator.compute(pixels: Self.frame(stars: 10), width: n, height: n,
                                                                  config: MetricsConfig()))
        #expect(metrics.starCount == 10)
        #expect(!metrics.hasNoStars)
        let fwhm = try #require(metrics.fwhm)
        #expect(abs(fwhm - 3) < 0.5)
        #expect(metrics.snr != nil && metrics.psfSignalWeight != nil)
        #expect(metrics.qualityScore > 0)
    }

    @Test("Metrics off: no star count, so not a frame without stars")
    func metricsOff() {
        let off = MetricsCalculator.noStars(starCount: 0, background: 1000).filtered(by: .off)
        #expect(off.starCount == nil)
        #expect(!off.hasNoStars)
    }

    // MARK: - Auto-Flag, group statistics, badge

    /// Four measured frames plus one frame without stars (2 spurious "stars", as on a flat).
    private func makeStore() -> (ImageStore, noStar: ImageEntry) {
        let store = ImageStore()
        func add(_ metrics: FrameMetrics) -> ImageEntry {
            let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
            entry.isProcessing = false
            entry.metrics = metrics
            store.entries.append(entry)
            return entry
        }
        for stars in [400, 420, 440, 460] {
            _ = add(FrameMetrics(fwhm: 3, eccentricity: 0.3, snr: 2000, starCount: stars,
                                 qualityScore: MetricsCalculator.qualityScore(fwhm: 3, eccentricity: 0.3,
                                                                              snr: 2000, starCount: stars),
                                 skyBackground: 1000, psfSignalWeight: 100))
        }
        let noStar = add(MetricsCalculator.noStars(starCount: 2, background: 1000))
        store.updateGroupStatistics()
        return (store, noStar)
    }

    /// A config with every check off.
    private func allOff(_ mode: AutoRejectConfig.Mode) -> AutoRejectConfig {
        var config = AutoRejectConfig()
        config.mode = mode
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.useSkyBackground = false
        config.usePSF = false
        config.useScore = false
        return config
    }

    @Test("Any single check rejects a frame without stars, in both modes", arguments: AutoRejectConfig.Mode.allCases)
    func everyCheckRejects(mode: AutoRejectConfig.Mode) {
        let (store, noStar) = makeStore()
        let switches: [WritableKeyPath<AutoRejectConfig, Bool>] = [
            \.useFWHM, \.useEccentricity, \.useStarCount, \.useSNR, \.useSkyBackground, \.usePSF,
        ]
        for keyPath in switches {
            var config = allOff(mode)
            config[keyPath: keyPath] = true
            #expect(store.previewAutoReject(config: config).map(\.id) == [noStar.id])
        }
        #expect(store.previewAutoReject(config: allOff(mode)).isEmpty)
    }

    @Test("The score check rejects a frame without stars in absolute mode only (as for any frame)")
    func scoreCheck() {
        let (store, noStar) = makeStore()
        var absolute = allOff(.absolute)
        absolute.useScore = true
        absolute.scoreFloor = 0
        #expect(store.previewAutoReject(config: absolute).map(\.id) == [noStar.id])
        var relative = allOff(.relative)
        relative.useScore = true
        #expect(store.previewAutoReject(config: relative).isEmpty)
    }

    @Test("Group medians leave frames without stars out")
    func groupMedians() throws {
        let (store, _) = makeStore()
        let stats = try #require(store.groupStatistics.values.first)
        #expect(stats.medianStarCount == 440)   // upper median of 400…460; with the 2 it would be 420
    }

    @Test("A frame without stars gets the low-stars badge, even without group statistics")
    func badge() {
        let metrics = MetricsCalculator.noStars(starCount: 0, background: 1000)
        #expect(metrics.badgeProblem(stats: nil) == .lowStars)
    }
}
