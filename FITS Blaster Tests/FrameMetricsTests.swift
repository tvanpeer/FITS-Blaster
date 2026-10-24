//
//  FrameMetricsTests.swift
//  FITS Blaster Tests
//
//  Tests for FrameMetrics: filtered(by:), hasData, badgeProblem, and MetricsConfig.
//

import Testing
@testable import FITS_Blaster

struct FrameMetricsTests {

    // MARK: - Helpers

    private func fullMetrics(fwhm: Float = 3.0, eccentricity: Float = 0.2,
                             snr: Float = 100, starCount: Int = 200) -> FrameMetrics {
        FrameMetrics(fwhm: fwhm, eccentricity: eccentricity, snr: snr, starCount: starCount,
                     qualityScore: MetricsCalculator.qualityScore(fwhm: fwhm, eccentricity: eccentricity,
                                                                   snr: snr, starCount: starCount),
                     skyBackground: nil, psfSignalWeight: nil)
    }

    private func broadbandStats(medianFWHM: Float = 3.0, medianStarCount: Int = 200) -> GroupStats {
        GroupStats(medianFWHM: medianFWHM, medianEccentricity: 0.2,
                   medianStarCount: medianStarCount, medianSNR: 100,
                   medianScore: 70, medianSkyBackground: nil, medianPSFSignalWeight: nil,
                   topThirdScoreFloor: 80, isNarrowband: false)
    }

    // MARK: - hasData

    @Test("hasData with all metrics")
    func hasDataWithAllMetrics() {
        #expect(fullMetrics().hasData == true)
    }

    @Test("hasData with no metrics")
    func hasDataWithNoMetrics() {
        let m = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 0,
                             skyBackground: nil, psfSignalWeight: nil)
        #expect(m.hasData == false)
    }

    @Test("hasData with single metric")
    func hasDataWithSingleMetric() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: nil, snr: nil, starCount: nil, qualityScore: 50,
                             skyBackground: nil, psfSignalWeight: nil)
        #expect(m.hasData == true)
    }

    // MARK: - filtered(by:)

    @Test("With metrics on, filtered returns the metrics unchanged")
    func filteredOnKeepsEverything() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: 100, starCount: 200,
                             qualityScore: MetricsCalculator.qualityScore(fwhm: 3.0, eccentricity: 0.2,
                                                                           snr: 100, starCount: 200),
                             skyBackground: 1200, psfSignalWeight: 45)
        let on = m.filtered(by: MetricsConfig())
        #expect(on.fwhm == m.fwhm)
        #expect(on.eccentricity == m.eccentricity)
        #expect(on.snr == m.snr)
        #expect(on.starCount == m.starCount)
        #expect(on.qualityScore == m.qualityScore)
        #expect(on.skyBackground == m.skyBackground)
        #expect(on.psfSignalWeight == m.psfSignalWeight)
    }

    @Test("With metrics off, filtered hides the star metrics and keeps sky and PSF·S")
    func filteredOffHidesStarMetrics() {
        let m = FrameMetrics(fwhm: 3.0, eccentricity: 0.2, snr: 100, starCount: 200,
                             qualityScore: 70, skyBackground: 1200, psfSignalWeight: 45)
        let off = m.filtered(by: .off)
        #expect(off.fwhm == nil)
        #expect(off.eccentricity == nil)
        #expect(off.snr == nil)
        #expect(off.starCount == nil)
        #expect(off.qualityScore == 0)
        #expect(off.skyBackground == 1200)
        #expect(off.psfSignalWeight == 45)
    }

    // MARK: - MetricsConfig

    @Test("needsStarDetection follows the on/off switch")
    func needsStarDetection() {
        #expect(MetricsConfig().needsStarDetection == true)
        #expect(MetricsConfig.off.needsStarDetection == false)
    }

    // MARK: - badgeProblem

    @Test("Trailing detected when eccentricity > 0.5")
    func trailingDetected() {
        #expect(fullMetrics(eccentricity: 0.6).badgeProblem(stats: broadbandStats()) == .trailing)
    }

    @Test("Trailing not detected at eccentricity = 0.5")
    func trailingNotDetectedAtThreshold() {
        #expect(fullMetrics(eccentricity: 0.5).badgeProblem(stats: broadbandStats()) != .trailing)
    }

    @Test("Focus fail detected when FWHM > median × 1.5")
    func focusFailDetected() {
        let m = fullMetrics(fwhm: 5.0, eccentricity: 0.1)
        #expect(m.badgeProblem(stats: broadbandStats(medianFWHM: 3.0)) == .focusFail)
    }

    @Test("Low stars detected for broadband")
    func lowStarsDetectedBroadband() {
        let m = fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 50)
        #expect(m.badgeProblem(stats: broadbandStats(medianStarCount: 200)) == .lowStars)
    }

    @Test("Low stars uses tighter threshold for narrowband")
    func lowStarsNarrowbandThreshold() {
        let stats = GroupStats(medianFWHM: 3.0, medianEccentricity: 0.2,
                               medianStarCount: 100, medianSNR: 80,
                               medianScore: 60, medianSkyBackground: nil, medianPSFSignalWeight: nil,
                               topThirdScoreFloor: 70, isNarrowband: true)

        // 35 stars > 30% of 100 → no problem
        #expect(fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 35)
            .badgeProblem(stats: stats) == nil)
        // 25 stars < 30% of 100 → lowStars
        #expect(fullMetrics(fwhm: 3.0, eccentricity: 0.1, starCount: 25)
            .badgeProblem(stats: stats) == .lowStars)
    }

    @Test("No problem detected for normal values")
    func noProblemDetected() {
        #expect(fullMetrics().badgeProblem(stats: broadbandStats()) == nil)
    }

    @Test("No problem with nil stats (only trailing possible)")
    func noProblemWithNilStats() {
        #expect(fullMetrics().badgeProblem(stats: nil) == nil)
    }

    @Test("Trailing takes priority over focus fail")
    func trailingTakesPriority() {
        let m = fullMetrics(fwhm: 8.0, eccentricity: 0.7)
        #expect(m.badgeProblem(stats: broadbandStats()) == .trailing)
    }
}
