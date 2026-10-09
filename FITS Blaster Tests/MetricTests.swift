//
//  MetricTests.swift
//  FITS Blaster Tests
//
//  Tests for Metric: value(from:), median(from:), isHigherBetter, and contexts.
//  These cover the new single-source-of-truth enum introduced in the betas.
//

import Testing
@testable import FITS_Blaster

struct MetricTests {

    // MARK: - Helpers

    private func fullMetrics() -> FrameMetrics {
        FrameMetrics(fwhm: 2.5, eccentricity: 0.15, snr: 100.0, starCount: 200,
                     qualityScore: 70, skyBackground: 1200.0, psfSignalWeight: 45.0)
    }

    private func fullStats() -> GroupStats {
        GroupStats(medianFWHM: 3.0, medianEccentricity: 0.2, medianStarCount: 180,
                   medianSNR: 90.0, medianScore: 65, medianSkyBackground: 1000.0,
                   medianPSFSignalWeight: 40.0, topThirdScoreFloor: 80, isNarrowband: false)
    }

    // MARK: - value(from:) — nil cases

    @Test("value(from:) returns nil for nil metrics")
    func valueNilForNilMetrics() {
        for metric in Metric.allCases {
            #expect(metric.value(from: nil) == nil, "\(metric) should return nil for nil metrics")
        }
    }

    @Test("value(from:) returns nil when metric field is nil", arguments: [
        Metric.fwhm, .eccentricity, .snr, .starCount, .skyBackground, .psfSignalWeight,
    ])
    func valueNilWhenFieldIsNil(metric: Metric) {
        let empty = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil,
                                 qualityScore: 0, skyBackground: nil, psfSignalWeight: nil)
        #expect(metric.value(from: empty) == nil, "\(metric) should be nil when field is nil")
    }

    @Test("qualityScore returns nil when hasData is false")
    func qualityScoreNilWhenNoData() {
        let empty = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil,
                                 qualityScore: 0, skyBackground: nil, psfSignalWeight: nil)
        #expect(Metric.qualityScore.value(from: empty) == nil)
    }

    // MARK: - value(from:) — extraction

    @Test("value(from:) extracts correct value for each metric", arguments: zip(
        [Metric.fwhm, .eccentricity, .snr, .starCount, .skyBackground, .psfSignalWeight, .qualityScore],
        [2.5, 0.15, 100.0, 200.0, 1200.0, 45.0, 70.0] as [Double]
    ))
    func valueExtractsCorrectValue(metric: Metric, expected: Double) {
        let v = metric.value(from: fullMetrics())
        #expect(v != nil, "\(metric) should not be nil")
        #expect(abs((v ?? 0) - expected) < 0.01, "\(metric) expected ≈ \(expected), got \(v ?? 0)")
    }

    // MARK: - median(from:) — extraction

    @Test("median(from:) extracts correct value for each metric", arguments: zip(
        [Metric.fwhm, .eccentricity, .snr, .starCount, .skyBackground, .psfSignalWeight, .qualityScore],
        [3.0, 0.2, 90.0, 180.0, 1000.0, 40.0, 65.0] as [Double]
    ))
    func medianExtractsCorrectValue(metric: Metric, expected: Double) {
        let v = metric.median(from: fullStats())
        #expect(v != nil, "\(metric) median should not be nil")
        #expect(abs((v ?? 0) - expected) < 0.01, "\(metric) median expected ≈ \(expected), got \(v ?? 0)")
    }

    // MARK: - isHigherBetter

    @Test("Lower-is-better metrics have isHigherBetter == false", arguments: [
        Metric.fwhm, .eccentricity, .skyBackground,
    ])
    func lowerIsBetter(metric: Metric) {
        #expect(metric.isHigherBetter == false, "\(metric) should be lower-is-better")
    }

    @Test("Higher-is-better metrics have isHigherBetter == true", arguments: [
        Metric.snr, .starCount, .psfSignalWeight, .qualityScore,
    ])
    func higherIsBetter(metric: Metric) {
        #expect(metric.isHigherBetter == true, "\(metric) should be higher-is-better")
    }

    // MARK: - contexts

    @Test("skyBackground is excluded from the export context")
    func skyBackgroundNotExported() {
        #expect(Metric.skyBackground.contexts.contains(.export) == false)
    }

    @Test("All metrics except skyBackground are in the export context", arguments: [
        Metric.fwhm, .eccentricity, .snr, .starCount, .psfSignalWeight, .qualityScore,
    ])
    func metricsInExportContext(metric: Metric) {
        #expect(metric.contexts.contains(.export) == true, "\(metric) should be in export context")
    }

    @Test("All metrics are in the chart context", arguments: Metric.allCases)
    func allMetricsInChartContext(metric: Metric) {
        #expect(metric.contexts.contains(.chart) == true, "\(metric) should be in chart context")
    }
}
