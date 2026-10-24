//
//  Metric.swift
//  FITS Blaster
//
//  Single source of truth for every measurable quality parameter.
//  Adding a new metric here automatically propagates it to every UI
//  location that filters on MetricContext.
//

import Foundation

// MARK: - MetricContext

/// Bitmask of UI locations where a metric is used.
/// Each location filters `Metric.allCases` by the relevant context.
struct MetricContext: OptionSet, Sendable {
    let rawValue: Int

    /// Thumbnail sidebar sort picker.
    static let sort       = MetricContext(rawValue: 1 << 0)
    /// Session chart metric picker.
    static let chart      = MetricContext(rawValue: 1 << 1)
    /// CSV / TSV / plain-text export columns.
    static let export     = MetricContext(rawValue: 1 << 2)
    /// Inline status chip row above the image (shown when AppSettings.showMetricChips is true).
    static let statusChip = MetricContext(rawValue: 1 << 3)
}

// MARK: - Metric

/// Every measurable quality parameter in the app.
///
/// Conformances: `String` raw value for `@AppStorage`; `CaseIterable` so
/// `allCases.filter { $0.contexts.contains(.x) }` drives each UI location.
enum Metric: String, CaseIterable, Identifiable, Sendable, Hashable {
    case fwhm
    case eccentricity
    case snr
    case starCount
    case skyBackground
    case psfSignalWeight
    case qualityScore

    var id: String { rawValue }

    // MARK: Display

    /// Full display name (sort menu, inspector rows).
    var displayName: String {
        switch self {
        case .fwhm:            return "FWHM"
        case .eccentricity:    return "Eccentricity"
        case .snr:             return "SNR"
        case .starCount:       return "Stars"
        case .skyBackground:   return "Sky BG"
        case .psfSignalWeight: return "PSF Signal"
        case .qualityScore:    return "Score"
        }
    }

    /// Compact label for chart buttons and status chips.
    var shortLabel: String {
        switch self {
        case .fwhm:            return "FWHM"
        case .eccentricity:    return "Ecc"
        case .snr:             return "SNR"
        case .starCount:       return "Stars"
        case .skyBackground:   return "Sky BG"
        case .psfSignalWeight: return "PSF·S"
        case .qualityScore:    return "Score"
        }
    }

    /// Icon label used in the inline status chip (overrides shortLabel for stars).
    var chipLabel: String {
        self == .starCount ? "★" : shortLabel
    }

    /// Column header written in CSV / TSV / plain-text exports.
    var exportKey: String {
        switch self {
        case .fwhm:            return "fwhm"
        case .eccentricity:    return "eccentricity"
        case .snr:             return "snr"
        case .starCount:       return "stars"
        case .skyBackground:   return "sky_bg"
        case .psfSignalWeight: return "psf_signal_weight"
        case .qualityScore:    return "score"
        }
    }

    var helpText: String {
        switch self {
        case .fwhm:
            return "Full Width at Half Maximum — smaller is sharper"
        case .eccentricity:
            return "Star eccentricity — closer to 0 is rounder"
        case .snr:
            return "Signal-to-Noise Ratio — higher is better"
        case .starCount:
            return "Number of detected stars"
        case .skyBackground:
            return "Median sky background in ADU — lower means darker sky"
        case .psfSignalWeight:
            return "PSF Signal Weight — integrated stellar flux relative to sky noise; higher means better transparency and/or more photons collected"
        case .qualityScore:
            return "Overall quality score (composite of all metrics)"
        }
    }

    /// True when a higher value means a better frame.
    var isHigherBetter: Bool {
        switch self {
        case .fwhm, .eccentricity, .skyBackground: return false
        default:                                    return true
        }
    }

    // MARK: Contexts

    var contexts: MetricContext {
        switch self {
        case .fwhm:            return [.sort, .chart, .export, .statusChip]
        case .eccentricity:    return [.sort, .chart, .export, .statusChip]
        case .snr:             return [.sort, .chart, .export, .statusChip]
        case .starCount:       return [.sort, .chart, .export, .statusChip]
        case .skyBackground:   return [.sort, .chart, .statusChip]
        case .psfSignalWeight: return [.sort, .chart, .export, .statusChip]
        case .qualityScore:    return [.sort, .chart, .export, .statusChip]
        }
    }

    // MARK: Value extraction

    /// Extracts a chartable `Double` from `FrameMetrics`.
    /// Returns `nil` when the metric was not computed or has no data.
    func value(from metrics: FrameMetrics?) -> Double? {
        guard let metrics else { return nil }
        switch self {
        case .fwhm:            return metrics.fwhm.map(Double.init)
        case .eccentricity:    return metrics.eccentricity.map(Double.init)
        case .snr:             return metrics.snr.map(Double.init)
        case .starCount:       return metrics.starCount.map(Double.init)
        case .skyBackground:   return metrics.skyBackground.map(Double.init)
        case .psfSignalWeight: return metrics.psfSignalWeight.map(Double.init)
        case .qualityScore:    return metrics.hasData ? Double(metrics.qualityScore) : nil
        }
    }

    /// Looks up the pre-computed per-group median from cached `GroupStats`.
    func median(from stats: GroupStats) -> Double? {
        switch self {
        case .fwhm:            return stats.medianFWHM.map(Double.init)
        case .eccentricity:    return stats.medianEccentricity.map(Double.init)
        case .snr:             return stats.medianSNR.map(Double.init)
        case .starCount:       return stats.medianStarCount.map(Double.init)
        case .skyBackground:   return stats.medianSkyBackground.map(Double.init)
        case .psfSignalWeight: return stats.medianPSFSignalWeight.map(Double.init)
        case .qualityScore:    return stats.medianScore.map(Double.init)
        }
    }

    // MARK: Formatting

    /// Formats a value for compact display in charts and status chips.
    func formattedValue(_ value: Double) -> String {
        switch self {
        case .qualityScore, .starCount, .skyBackground:
            return value.formatted(.number.precision(.fractionLength(0)))
        case .fwhm, .snr, .psfSignalWeight:
            return value.formatted(.number.precision(.fractionLength(1)))
        case .eccentricity:
            return value.formatted(.number.precision(.fractionLength(2)))
        }
    }

    /// Full chip value string including unit suffix where applicable.
    /// Whole-number text for a metric value. `Int(_:)` traps on NaN, ±Inf and values
    /// outside `Int`'s range; those show as "–" instead.
    static func wholeNumberText(_ v: Double,
                                rounding rule: FloatingPointRoundingRule = .toNearestOrAwayFromZero) -> String {
        Int(exactly: v.rounded(rule)).map(String.init) ?? "–"
    }

    func chipValue(from v: Double) -> String {
        switch self {
        case .fwhm:            return "\(v.formatted(.number.precision(.fractionLength(1)))) px"
        case .eccentricity:    return v.formatted(.number.precision(.fractionLength(2)))
        case .snr:             return v.formatted(.number.precision(.fractionLength(0)))
        case .starCount:       return v.formatted(.number.precision(.fractionLength(0)))
        case .skyBackground:   return "\(Metric.wholeNumberText(v)) ADU"
        case .psfSignalWeight: return v.formatted(.number.precision(.fractionLength(0)))
        case .qualityScore:    return v.formatted(.number.precision(.fractionLength(0)))
        }
    }

    /// Compact "label value" fragment suitable for joining into a tooltip string.
    func tooltipPart(from v: Double) -> String {
        switch self {
        case .starCount:    return "\(Metric.wholeNumberText(v, rounding: .towardZero)) stars"
        case .skyBackground: return "\(shortLabel) \(Metric.wholeNumberText(v)) ADU"
        case .fwhm:         return "\(shortLabel) \(v.formatted(.number.precision(.fractionLength(1))))px"
        default:            return "\(shortLabel) \(formattedValue(v))"
        }
    }

    // MARK: Export formatting

    /// Formats this metric's value for export using POSIX locale (no locale-specific decimal separator).
    func exportString(from metrics: FrameMetrics?) -> String {
        guard let metrics else { return "" }
        switch self {
        case .fwhm:            return posixFormat(metrics.fwhm.map(Double.init),            digits: 2)
        case .eccentricity:    return posixFormat(metrics.eccentricity.map(Double.init),    digits: 3)
        case .snr:             return posixFormat(metrics.snr.map(Double.init),             digits: 1)
        case .starCount:       return metrics.starCount.map { String($0) } ?? ""
        case .skyBackground:
            assertionFailure("Sky background has no export context")
            return ""
        case .psfSignalWeight: return posixFormat(metrics.psfSignalWeight.map(Double.init), digits: 1)
        case .qualityScore:    return metrics.hasData ? String(metrics.qualityScore) : ""
        }
    }

    private func posixFormat(_ v: Double?, digits: Int) -> String {
        guard let v else { return "" }
        return v.formatted(
            .number.precision(.fractionLength(digits))
                   .grouping(.never)
                   .locale(Locale(identifier: "en_US_POSIX")))
    }
}
