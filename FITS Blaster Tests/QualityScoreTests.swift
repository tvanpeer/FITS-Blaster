//
//  QualityScoreTests.swift
//  FITS Blaster Tests
//
//  Tests for MetricsCalculator.qualityScore: weight renormalisation,
//  boundary values, and expected scores for typical astrophotography data.
//

import Testing
@testable import FITS_Blaster

struct QualityScoreTests {

    // MARK: - Perfect single-metric scores (each alone → 100)

    @Test("Perfect single metric scores 100", arguments: [
        (1.5 as Float?, nil   as Float?, nil   as Float?, nil  as Int?, "FWHM"),
        (nil,            0.0,             nil,             nil,          "Eccentricity"),
        (nil,            nil,             250.0,           nil,          "SNR"),
        (nil,            nil,             nil,             600,          "Star count"),
    ])
    func perfectSingleMetric(fwhm: Float?, ecc: Float?, snr: Float?, stars: Int?, label: String) {
        let score = MetricsCalculator.qualityScore(fwhm: fwhm, eccentricity: ecc,
                                                    snr: snr, starCount: stars)
        #expect(score == 100, "Perfect \(label) alone should score 100")
    }

    // MARK: - Worst single-metric scores (each alone → 0)

    @Test("Worst single metric scores 0", arguments: [
        (10.0 as Float?, nil   as Float?, nil  as Float?, nil as Int?, "FWHM ≥ 7"),
        (nil,             0.6,             nil,            nil,         "Ecc ≥ 0.5"),
        (nil,             nil,             5.0,            nil,         "SNR ≤ 10"),
        (nil,             nil,             nil,            0,           "0 stars"),
    ])
    func worstSingleMetric(fwhm: Float?, ecc: Float?, snr: Float?, stars: Int?, label: String) {
        let score = MetricsCalculator.qualityScore(fwhm: fwhm, eccentricity: ecc,
                                                    snr: snr, starCount: stars)
        #expect(score == 0, "Worst \(label) alone should score 0")
    }

    // MARK: - All nil / all perfect

    @Test("All nil returns zero")
    func allNilReturnsZero() {
        #expect(MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                snr: nil, starCount: nil) == 0)
    }

    @Test("All perfect scores 100")
    func allPerfectScores100() {
        #expect(MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0,
                                                snr: 250, starCount: 600) == 100)
    }

    // MARK: - Mid-range values

    @Test("Mid-range FWHM (4.5) scores 50")
    func midRangeFWHM() {
        #expect(MetricsCalculator.qualityScore(fwhm: 4.5, eccentricity: nil,
                                                snr: nil, starCount: nil) == 50)
    }

    @Test("Mid-range eccentricity (0.25) scores 50")
    func midRangeEccentricity() {
        #expect(MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.25,
                                                snr: nil, starCount: nil) == 50)
    }

    @Test("Mid-range SNR (105) scores 50")
    func midRangeSNR() {
        #expect(MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                snr: 105, starCount: nil) == 50)
    }

    // MARK: - Weight renormalisation

    @Test("Two perfect metrics renormalise to 100")
    func twoMetricsRenormalise() {
        #expect(MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0,
                                                snr: nil, starCount: nil) == 100)
    }

    @Test("Perfect FWHM + worst eccentricity renormalises to 50")
    func mixedGoodAndBadRenormalises() {
        #expect(MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0.6,
                                                snr: nil, starCount: nil) == 50)
    }

    // MARK: - Typical astrophotography values

    @Test("Typical good frame scores 65–90")
    func typicalGoodFrame() {
        let score = MetricsCalculator.qualityScore(fwhm: 2.5, eccentricity: 0.15,
                                                    snr: 120, starCount: 350)
        #expect(score >= 65 && score <= 90)
    }

    @Test("Typical bad frame scores ≤ 30")
    func typicalBadFrame() {
        let score = MetricsCalculator.qualityScore(fwhm: 5.5, eccentricity: 0.4,
                                                    snr: 25, starCount: 40)
        #expect(score <= 30)
    }
}
