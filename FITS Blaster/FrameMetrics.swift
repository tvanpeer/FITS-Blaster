//
//  FrameMetrics.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

// MARK: - Config

/// Subset of AppSettings needed for metrics computation.
/// Plain Sendable value type for safe capture in nonisolated background tasks.
struct MetricsConfig: Sendable, Equatable {
    var computeFWHM: Bool = true
    var computeEccentricity: Bool = true
    var computeSNR: Bool = true
    var computeStarCount: Bool = true

    /// True when at least one metric requires star detection.
    var needsStarDetection: Bool {
        computeFWHM || computeEccentricity || computeSNR || computeStarCount
    }
}

// MARK: - Badge Problem

/// A detected quality defect used to drive the two-tier thumbnail badge system.
enum BadgeProblem {
    /// Stars significantly more elongated than round — trailing or collimation issue.
    case trailing
    /// FWHM significantly above the filter-group median — focus failure or poor seeing.
    case focusFail
    /// Star count well below the filter-group median — haze, thin cloud, or dew.
    case lowStars

    var systemImage: String {
        switch self {
        case .trailing:  "arrow.up.right"
        case .focusFail: "scope"
        case .lowStars:  "cloud.fill"
        }
    }
}

// MARK: - Group Statistics

/// Per-filter-group summary statistics used for relative threshold comparisons
/// in badge colouring and auto-reject.
struct GroupStats {
    let medianFWHM: Float?
    let medianEccentricity: Float?
    let medianStarCount: Int?
    let medianSNR: Float?
    let medianScore: Int?
    /// Minimum score required to place a frame in the top third of this group.
    /// Nil when the group has fewer than three frames with score data.
    let topThirdScoreFloor: Int?
    /// True for narrowband and OSC multi-narrowband groups.
    let isNarrowband: Bool
}

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
    /// Composite quality score 0–100 derived from whichever metrics were enabled
    let qualityScore: Int

    // MARK: Merge / Filter

    /// Returns a new FrameMetrics keeping only config-enabled fields non-nil,
    /// with the quality score recomputed for the active subset.
    func filtered(by config: MetricsConfig) -> FrameMetrics {
        let f  = config.computeFWHM         ? fwhm         : nil
        let e  = config.computeEccentricity ? eccentricity : nil
        let s  = config.computeSNR          ? snr          : nil
        let sc = config.computeStarCount    ? starCount    : nil
        return FrameMetrics(fwhm: f, eccentricity: e, snr: s, starCount: sc,
                            qualityScore: MetricsCalculator.qualityScore(fwhm: f, eccentricity: e, snr: s, starCount: sc))
    }

    /// Returns a new FrameMetrics merging self with `other`, preferring `other`'s non-nil values.
    func merging(_ other: FrameMetrics) -> FrameMetrics {
        let f  = other.fwhm         ?? fwhm
        let e  = other.eccentricity ?? eccentricity
        let s  = other.snr          ?? snr
        let sc = other.starCount    ?? starCount
        return FrameMetrics(fwhm: f, eccentricity: e, snr: s, starCount: sc,
                            qualityScore: MetricsCalculator.qualityScore(fwhm: f, eccentricity: e, snr: s, starCount: sc))
    }

    /// True when at least one metric was actually computed.
    var hasData: Bool {
        fwhm != nil || eccentricity != nil || snr != nil || starCount != nil
    }

    // MARK: Badge

    /// Simple score-based colour for inline metric displays (inspector, etc.)
    var scoreColor: Color {
        switch qualityScore {
        case 80...: .green
        case 60...: .yellow
        case 40...: .orange
        default:    .red
        }
    }

    /// Returns the worst detected quality problem, or nil when no threshold is exceeded.
    ///
    /// Priority order: trailing → focus fail → low star count.
    /// Returns nil when group stats are unavailable or no threshold is met.
    func badgeProblem(stats: GroupStats?) -> BadgeProblem? {
        // Trailing is the most visually obvious problem — check first.
        if let ecc = eccentricity, ecc > 0.5 { return .trailing }

        // Focus failure: FWHM significantly above the group median.
        if let fwhm = fwhm, let medFWHM = stats?.medianFWHM, fwhm > medFWHM * 1.5 {
            return .focusFail
        }

        // Low star count: haze or cloud. Narrowband frames naturally have fewer
        // stars so use a tighter relative threshold (30 % vs 40 %).
        if let stars = starCount, let medStars = stats?.medianStarCount {
            let threshold = stats?.isNarrowband == true ? 0.30 : 0.40
            if Double(stars) < Double(medStars) * threshold { return .lowStars }
        }

        return nil
    }

    /// Badge colour encoding the worst detected problem.
    ///
    /// - Red: trailing or focus failure.
    /// - Amber: low star count.
    /// - Green: no problem and frame is in the top third of its group by score.
    /// - Grey: no problem detected, not in top third.
    func badgeColor(problem: BadgeProblem?, isTopThird: Bool) -> Color {
        if let problem {
            switch problem {
            case .trailing, .focusFail: return .red
            case .lowStars:             return Color(red: 0.85, green: 0.55, blue: 0.0)
            }
        }
        return isTopThird ? .green : Color(white: 0.55)
    }

    /// Compact tooltip showing all available metrics, suitable for `.help()`.
    var tooltipString: String {
        var parts: [String] = []
        if let v = fwhm         { parts.append("FWHM \(v.formatted(.number.precision(.fractionLength(1))))px") }
        if let v = eccentricity { parts.append("Ecc \(v.formatted(.number.precision(.fractionLength(2))))") }
        if let v = snr          { parts.append("SNR \(v.formatted(.number.precision(.fractionLength(0))))") }
        if let v = starCount    { parts.append("\(v) stars") }
        return parts.joined(separator: " · ")
    }
}
