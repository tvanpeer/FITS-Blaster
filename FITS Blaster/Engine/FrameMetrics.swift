//
//  FrameMetrics.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

// MARK: - Metrics

/// Quality metrics computed from raw FITS pixel data via Accelerate heuristics.
struct FrameMetrics: Sendable {
    /// Median FWHM across detected stars, in pixels (nil if not computed)
    let fwhm: Float?
    /// Median eccentricity across detected stars, 0 = circular, 1 = line (nil if not computed)
    let eccentricity: Float?
    /// Median signal-to-noise ratio across detected stars (nil if not computed)
    let snr: Float?
    /// Number of detected star sources (nil if not computed)
    let starCount: Int?
    /// Composite quality score 0–100 from FWHM, eccentricity, SNR and star count (0 with metrics off)
    let qualityScore: Int
    /// Median sky background level in ADU, from stratified sampling (nil if star detection skipped)
    let skyBackground: Float?
    /// PSF Signal Weight: mean background-subtracted peak of the measured stars (up to the
    /// 200 brightest stars) divided by the sky sigma. Higher means brighter stars above
    /// the sky noise (transparency, exposure).
    /// Nil when no stars were successfully fitted, or the frame has no stars (`hasNoStars`).
    let psfSignalWeight: Float?

    // MARK: Filter

    /// The metrics as shown for `config`: unchanged when metrics are on. With metrics
    /// off (Simple mode) FWHM, eccentricity, SNR and star count are hidden and the score
    /// is 0; sky background and PSF Signal Weight are kept.
    func filtered(by config: MetricsConfig) -> FrameMetrics {
        guard !config.computeMetrics else { return self }
        return FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil,
                            qualityScore: MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil,
                                                                         snr: nil, starCount: nil),
                            skyBackground: skyBackground,
                            psfSignalWeight: psfSignalWeight)
    }

    /// True for a frame without stars: fewer than `minimumStars` counted, so FWHM,
    /// eccentricity, SNR and PSF·S are empty and the score is 0 (step 13g). False when
    /// metrics are off (no star count).
    var hasNoStars: Bool {
        starCount.map { $0 < MetricsCalculator.Constants.minimumStars } ?? false
    }

    /// True when at least one metric was actually computed.
    var hasData: Bool {
        fwhm != nil || eccentricity != nil || snr != nil || starCount != nil || psfSignalWeight != nil
    }

    // MARK: Badge

    /// Simple score-based colour for inline metric displays (inspector, etc.)
    var scoreColour: Color {
        switch qualityScore {
        case 80...: .green
        case 60...: .yellow
        case 40...: .orange
        default:    .red
        }
    }

    /// Returns the worst detected quality problem, or nil when no threshold is exceeded.
    ///
    /// Priority order: no stars → trailing → focus fail → low star count.
    /// Returns nil when group stats are unavailable or no threshold is met.
    func badgeProblem(stats: GroupStats?) -> BadgeProblem? {
        // No stars at all (cloud, dew, cap on, a flat): whatever the group looks like.
        if hasNoStars { return .lowStars }

        // Trailing is the most visually obvious problem — check first.
        // Same limit as Auto-Flag's default (step 13h; was 0.5, where normal colour
        // frames measure).
        if let ecc = eccentricity, Double(ecc) > MetricsCalculator.Constants.trailingEccentricity {
            return .trailing
        }

        // The checks below compare with the group median: not in groups under 3 frames.
        guard let stats, stats.allowsRelativeChecks else { return nil }

        // Focus failure: FWHM significantly above the group median.
        if let fwhm = fwhm, let medFWHM = stats.medianFWHM, Double(fwhm) > medFWHM * 1.5 {
            return .focusFail
        }

        // Low star count: haze or cloud. Narrowband frames naturally have fewer
        // stars so use a tighter relative threshold (30 % vs 40 %).
        if let stars = starCount, let medStars = stats.medianStarCount {
            let threshold = stats.isNarrowband ? 0.30 : 0.40
            if Double(stars) < medStars * threshold { return .lowStars }
        }

        return nil
    }

    /// Badge colour encoding the worst detected problem.
    ///
    /// - Red: trailing or focus failure.
    /// - Amber: low star count.
    /// - Green: no problem and frame is in the top third of its group by score.
    /// - Grey: no problem detected, not in top third.
    func badgeColour(problem: BadgeProblem?, isTopThird: Bool) -> Color {
        if let problem {
            return switch problem {
            case .trailing, .focusFail: .red
            case .lowStars:             Color(red: 0.85, green: 0.55, blue: 0.0)
            }
        }
        return isTopThird ? .green : Color(white: 0.55)
    }

    /// Compact tooltip showing all available metrics, suitable for `.help()`.
    var tooltipString: String {
        Metric.allCases
            .filter { $0.contexts.contains(.statusChip) }
            .compactMap { metric -> String? in
                guard let v = metric.value(from: self) else { return nil }
                return metric.tooltipPart(from: v)
            }
            .joined(separator: " · ")
    }
}
