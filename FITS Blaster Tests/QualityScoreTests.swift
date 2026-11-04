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
        (nil,            nil,             20_000.0,        nil,          "SNR"),
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
        (nil,             0.9,             nil,            nil,         "Ecc ≥ 0.9"),
        (nil,             nil,             50.0,           nil,         "SNR ≤ 100"),
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
                                                snr: 20_000, starCount: 600) == 100)
    }

    // MARK: - Mid-range values

    @Test("Mid-range FWHM (4.5) scores 50")
    func midRangeFWHM() {
        #expect(MetricsCalculator.qualityScore(fwhm: 4.5, eccentricity: nil,
                                                snr: nil, starCount: nil) == 50)
    }

    @Test("Mid-range eccentricity (0.45) scores 50")
    func midRangeEccentricity() {
        #expect(MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.45,
                                                snr: nil, starCount: nil) == 50)
    }

    @Test("Mid-range SNR on the log scale (≈ 1,414, the geometric mean of 100 and 20,000) scores 50")
    func midRangeSNR() {
        #expect(MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                snr: 1_415, starCount: nil) == 50)
    }

    // MARK: - Weight renormalisation

    @Test("Two perfect metrics renormalise to 100")
    func twoMetricsRenormalise() {
        #expect(MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0,
                                                snr: nil, starCount: nil) == 100)
    }

    @Test("Perfect FWHM + worst eccentricity renormalises to 50")
    func mixedGoodAndBadRenormalises() {
        #expect(MetricsCalculator.qualityScore(fwhm: 1.5, eccentricity: 0.9,
                                                snr: nil, starCount: nil) == 50)
    }

    // MARK: - Typical astrophotography values

    @Test("Typical good frame scores 65–90")
    func typicalGoodFrame() {
        let score = MetricsCalculator.qualityScore(fwhm: 2.5, eccentricity: 0.15,
                                                    snr: 3_000, starCount: 350)
        #expect(score >= 65 && score <= 90)
    }

    @Test("Typical bad frame scores ≤ 30")
    func typicalBadFrame() {
        // Eccentricity 0.8: clearly elongated on the 0 → 0.9 scale (step 13h; was 0.4 on 0 → 0.5)
        let score = MetricsCalculator.qualityScore(fwhm: 5.5, eccentricity: 0.8,
                                                    snr: 300, starCount: 40)
        #expect(score <= 30)
    }

    // MARK: - Eccentricity scale (step 13h)

    @Test("A normal colour frame (0.5) keeps eccentricity points; a trail (0.95) gets none")
    func eccentricityScale() {
        let normal = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.5, snr: nil, starCount: nil)
        let elongated = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.7, snr: nil, starCount: nil)
        let trail = MetricsCalculator.qualityScore(fwhm: nil, eccentricity: 0.95, snr: nil, starCount: nil)
        #expect(normal == 44)
        #expect(elongated == 22)
        #expect(trail == 0)
    }
}
