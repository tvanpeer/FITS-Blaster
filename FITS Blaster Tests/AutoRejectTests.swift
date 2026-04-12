//
//  AutoRejectTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore.previewAutoReject: relative and absolute mode
//  thresholds, per-metric toggles, and interaction with group statistics.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct AutoRejectTests {

    // MARK: - Helpers

    /// Creates an ImageStore with entries that have known metrics.
    /// Returns (store, entries) so tests can reference individual entries.
    private func makeStore(metricsPerEntry: [(fwhm: Float, ecc: Float, snr: Float, stars: Int, filter: String?)]) -> (ImageStore, [ImageEntry]) {
        let store = ImageStore()
        var entries: [ImageEntry] = []
        for m in metricsPerEntry {
            let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits")
            let entry = ImageEntry(url: url)
            entry.isProcessing = false
            entry.metrics = FrameMetrics(
                fwhm: m.fwhm, eccentricity: m.ecc, snr: m.snr, starCount: m.stars,
                qualityScore: MetricsCalculator.qualityScore(
                    fwhm: m.fwhm, eccentricity: m.ecc, snr: m.snr, starCount: m.stars))
            if let filter = m.filter {
                entry.headers = ["FILTER": filter]
            }
            store.entries.append(entry)
            entries.append(entry)
        }
        store.updateGroupStatistics()
        return (store, entries)
    }

    // MARK: - Relative mode: FWHM

    @Test("Relative mode rejects entries with FWHM > multiplier × median")
    func relativeFWHM() {
        // Three entries: FWHM 3.0, 3.0, 6.0. Median = 3.0. Multiplier 1.5 → threshold 4.5.
        let (store, entries) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 6.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .relative
        config.useFWHM = true
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.fwhmMultiplier = 1.5

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Only the FWHM=6.0 entry should be rejected")
        #expect(rejected.first === entries[2])
    }

    // MARK: - Relative mode: star count

    @Test("Relative mode rejects entries with stars < multiplier × median")
    func relativeStarCount() {
        // Median star count = 200. Multiplier 0.4 → threshold 80.
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 50,  filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .relative
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = true
        config.useSNR = false
        config.starCountMultiplier = 0.4

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Only the 50-star entry should be rejected")
    }

    // MARK: - Relative mode: SNR

    @Test("Relative mode rejects entries with SNR < multiplier × median")
    func relativeSNR() {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 30,  stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .relative
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = true
        config.snrMultiplier = 0.5

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1)
    }

    // MARK: - Eccentricity (same in both modes)

    @Test("Eccentricity threshold rejects high-ecc entries in both modes", arguments: [
        AutoRejectConfig.Mode.relative,
        AutoRejectConfig.Mode.absolute,
    ])
    func eccentricityThreshold(mode: AutoRejectConfig.Mode) {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.2, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.6, snr: 100, stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = mode
        config.useFWHM = false
        config.useEccentricity = true
        config.useStarCount = false
        config.useSNR = false
        config.eccentricityThreshold = 0.5

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Only the ecc=0.6 entry should be rejected")
    }

    // MARK: - Absolute mode

    @Test("Absolute mode rejects entries exceeding FWHM threshold")
    func absoluteFWHM() {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 4.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = true
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.absoluteFWHM = 3.5

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1)
    }

    @Test("Absolute mode rejects entries below star count floor")
    func absoluteStarCount() {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 10,  filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = true
        config.useSNR = false
        config.absoluteStarCountFloor = 20

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1)
    }

    @Test("Absolute mode rejects entries below SNR floor")
    func absoluteSNR() {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 3.0, ecc: 0.1, snr: 15,  stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = true
        config.absoluteSNRFloor = 20.0

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1)
    }

    @Test("Absolute mode rejects entries below score floor")
    func absoluteScore() {
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 2.0, ecc: 0.1, snr: 150, stars: 300, filter: nil),  // high score
            (fwhm: 6.0, ecc: 0.4, snr: 20,  stars: 30,  filter: nil),  // low score
        ])
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.useScore = true
        config.scoreFloor = 40

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Only the low-score entry should be rejected")
    }

    // MARK: - Edge cases

    @Test("Already-rejected entries are excluded from preview")
    func alreadyRejectedExcluded() {
        let (store, entries) = makeStore(metricsPerEntry: [
            (fwhm: 6.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
            (fwhm: 6.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
        ])
        entries[0].isRejected = true
        store.rejectedEntryIDs.insert(entries[0].id)

        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = true
        config.absoluteFWHM = 3.5
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Already-rejected entry should be excluded")
        #expect(rejected.first === entries[1])
    }

    @Test("Entries without metrics are excluded from preview")
    func noMetricsExcluded() {
        let (store, entries) = makeStore(metricsPerEntry: [
            (fwhm: 6.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
        ])
        entries[0].metrics = nil

        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = true
        config.absoluteFWHM = 3.5

        #expect(store.previewAutoReject(config: config).isEmpty)
    }

    @Test("Disabled metrics are not evaluated")
    func disabledMetricsIgnored() {
        // Entry has bad FWHM but FWHM check is disabled
        let (store, _) = makeStore(metricsPerEntry: [
            (fwhm: 10.0, ecc: 0.1, snr: 100, stars: 200, filter: nil),
        ])
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.useScore = false

        #expect(store.previewAutoReject(config: config).isEmpty,
                "No metrics enabled → nothing rejected")
    }

    // MARK: - Per-group statistics

    @Test("Relative mode evaluates per filter group")
    func perGroupStatistics() {
        // Ha group: median FWHM ~3.0, entry with 5.0 → rejected (5.0 > 3.0 × 1.5)
        // OIII group: median FWHM ~5.0, entry with 5.0 → NOT rejected (5.0 ≤ 5.0 × 1.5)
        let (store, entries) = makeStore(metricsPerEntry: [
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: "Ha"),
            (fwhm: 3.0, ecc: 0.1, snr: 100, stars: 200, filter: "Ha"),
            (fwhm: 5.0, ecc: 0.1, snr: 100, stars: 200, filter: "Ha"),   // above Ha median
            (fwhm: 5.0, ecc: 0.1, snr: 100, stars: 200, filter: "OIII"), // AT OIII median
            (fwhm: 5.0, ecc: 0.1, snr: 100, stars: 200, filter: "OIII"),
        ])

        var config = AutoRejectConfig()
        config.mode = .relative
        config.useFWHM = true
        config.fwhmMultiplier = 1.5
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false

        let rejected = store.previewAutoReject(config: config)
        #expect(rejected.count == 1, "Only the Ha outlier should be rejected")
        #expect(rejected.first === entries[2])
    }
}
