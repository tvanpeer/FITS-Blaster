//
//  SmallGroupTests.swift
//  FITS Blaster Tests
//
//  Groups under 3 frames (CODE_AUDIT §5.16, step 13): no checks against the group median
//  (Auto-Flag and CLI relative mode, focus-fail and low-star badges); absolute checks,
//  eccentricity and frames without stars still apply.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct SmallGroupTests {

    private func metrics(fwhm: Float = 3, eccentricity: Float = 0.3, starCount: Int = 400) -> FrameMetrics {
        FrameMetrics(fwhm: fwhm, eccentricity: eccentricity, snr: 2000, starCount: starCount,
                     qualityScore: MetricsCalculator.qualityScore(fwhm: fwhm, eccentricity: eccentricity,
                                                                  snr: 2000, starCount: starCount),
                     skyBackground: 1000, psfSignalWeight: 100)
    }

    /// A store with one frame per metrics value, all in one filter group (no FILTER header).
    private func makeStore(_ all: [FrameMetrics], filter: String? = nil) -> (ImageStore, [ImageEntry]) {
        let store = ImageStore()
        let entries = all.map { m in
            let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
            entry.isProcessing = false
            entry.metrics = m
            if let filter { entry.headers = ["FILTER": filter] }
            store.entries.append(entry)
            return entry
        }
        store.updateGroupStatistics()
        return (store, entries)
    }

    /// Relative mode with only the FWHM check on (1.5 × median).
    private var fwhmOnly: AutoRejectConfig {
        var config = AutoRejectConfig()
        config.mode = .relative
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.useSkyBackground = false
        config.usePSF = false
        config.useFWHM = true
        return config
    }

    @Test("Two frames: a soft frame is not flagged against the median; with three it is")
    func relativeChecksNeedThreeFrames() {
        let (two, _) = makeStore([metrics(fwhm: 2), metrics(fwhm: 6)])
        // Median of 2 and 6 is 4: 6 > 1.5 × 4 would flag, but the group is too small.
        #expect(two.groupStatistics.values.first?.medianFWHM == 4)
        #expect(two.previewAutoReject(config: fwhmOnly).isEmpty)

        let (three, threeEntries) = makeStore([metrics(fwhm: 2), metrics(fwhm: 2), metrics(fwhm: 6)])
        #expect(three.previewAutoReject(config: fwhmOnly).map(\.id) == [threeEntries[2].id])
    }

    @Test("Two frames: absolute mode, eccentricity and frames without stars still flag")
    func absoluteChecksStillApply() {
        var absolute = fwhmOnly
        absolute.mode = .absolute
        absolute.absoluteFWHM = 5
        let (store, e) = makeStore([metrics(fwhm: 2), metrics(fwhm: 6)])
        #expect(store.previewAutoReject(config: absolute).map(\.id) == [e[1].id])

        var eccentricity = fwhmOnly
        eccentricity.useEccentricity = true
        let (trailed, t) = makeStore([metrics(), metrics(eccentricity: 0.8)])
        #expect(trailed.previewAutoReject(config: eccentricity).map(\.id) == [t[1].id])

        let (cloudy, c) = makeStore([metrics(), MetricsCalculator.noStars(starCount: 2, background: 1000)])
        #expect(cloudy.previewAutoReject(config: fwhmOnly).map(\.id) == [c[1].id])
    }

    @Test("Badges: no focus-fail or low-star badge in a group under 3 frames; trailing still")
    func badges() {
        let (two, e) = makeStore([metrics(fwhm: 2, starCount: 400), metrics(fwhm: 6, starCount: 40)])
        let stats = two.groupStatistics[e[1].filterGroup]
        #expect(stats?.allowsRelativeChecks == false)
        #expect(e[1].metrics?.badgeProblem(stats: stats) == nil)
        #expect(metrics(eccentricity: 0.8).badgeProblem(stats: stats) == .trailing)

        let (three, f) = makeStore([metrics(fwhm: 2), metrics(fwhm: 2), metrics(fwhm: 6)])
        #expect(f[2].metrics?.badgeProblem(stats: three.groupStatistics[f[2].filterGroup]) == .focusFail)
    }

    @Test("The groups too small for relative checks, with their frame counts")
    func smallGroupList() {
        let (store, _) = makeStore([metrics(), metrics()], filter: "Ha")
        for _ in 0..<3 {
            let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
            entry.isProcessing = false
            entry.metrics = metrics()
            entry.headers = ["FILTER": "OIII"]
            store.entries.append(entry)
        }
        // A group of frames without stars only: not listed (they fail every check anyway).
        let flat = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        flat.isProcessing = false
        flat.metrics = MetricsCalculator.noStars(starCount: 0, background: 1000)
        flat.headers = ["FILTER": "SII"]
        store.entries.append(flat)
        store.updateGroupStatistics()

        let small = store.groupsTooSmallForRelativeChecks
        #expect(small.map(\.group) == [FilterGroup.normalise("Ha")])
        #expect(small.map(\.frameCount) == [2])
    }

    @Test("Relative checks on: relative mode and a check other than eccentricity")
    func anyRelativeCheckOn() {
        var config = fwhmOnly
        #expect(config.isAnyRelativeCheckOn)
        config.useFWHM = false
        config.useEccentricity = true
        #expect(!config.isAnyRelativeCheckOn)
        config.useSNR = true
        #expect(config.isAnyRelativeCheckOn)
        config.mode = .absolute
        #expect(!config.isAnyRelativeCheckOn)
    }
}
