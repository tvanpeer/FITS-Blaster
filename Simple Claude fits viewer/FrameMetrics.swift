//
//  FrameMetrics.swift
//  Simple Claude fits viewer
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

    /// True when at least one metric was actually computed
    var hasData: Bool {
        fwhm != nil || eccentricity != nil || snr != nil || starCount != nil
    }

    /// Colour-coded badge colour based on quality score
    var badgeColor: Color {
        switch qualityScore {
        case 80...: .green
        case 60...: .yellow
        case 40...: .orange
        default:    .red
        }
    }
}
