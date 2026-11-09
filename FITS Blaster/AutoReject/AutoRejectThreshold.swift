//
//  AutoRejectThreshold.swift
//  FITS Blaster
//
//  The Auto-Flag sheet's checks as one table (step 10c, CODE_AUDIT §9.15): per check its
//  section title, toggle and comparison texts, the setting that turns it on, and per mode the
//  setting holding the limit with its slider range, step and value text. One generic section
//  draws every row; before, each check had its own copy of the section.
//

import Foundation

struct AutoRejectThreshold: Identifiable {
    /// How a limit is shown next to the comparison text.
    enum Format: Equatable, Sendable {
        /// "1.5× median" (one decimal).
        case multipleOfMedian
        /// "50% of median".
        case percentOfMedian
        /// A number with `fractionDigits` decimals and an optional unit ("3.5 px", "40").
        case number(fractionDigits: Int, unit: String? = nil)
    }

    /// The limit of a check in one mode.
    struct Limit {
        let value: WritableKeyPath<AutoRejectConfig, Double>
        let range: ClosedRange<Double>
        let step: Double
        let format: Format
    }

    /// The section title.
    let title: String
    let toggleLabel: String
    /// "Select if FWHM >".
    let comparison: String
    let isOn: WritableKeyPath<AutoRejectConfig, Bool>
    /// The limit in relative mode; nil when the check is absolute only (score).
    let relative: Limit?
    /// The limit in absolute mode.
    let absolute: Limit

    var id: String { title }

    /// The limit shown in `mode`; nil when the check isn't offered in that mode.
    func limit(for mode: AutoRejectConfig.Mode) -> Limit? {
        switch mode {
        case .relative: relative
        case .absolute: absolute
        }
    }

    /// Every check, in the sheet's order.
    @MainActor static let all: [AutoRejectThreshold] = {
        let eccentricity = Limit(value: \.eccentricityThreshold, range: 0.3...0.9, step: 0.05,
                                 format: .number(fractionDigits: 2))
        return [
            AutoRejectThreshold(
                title: "Focus (FWHM)", toggleLabel: "Enable FWHM threshold",
                comparison: "Select if FWHM >", isOn: \.useFWHM,
                relative: Limit(value: \.fwhmMultiplier, range: 1.2...3.0, step: 0.1, format: .multipleOfMedian),
                absolute: Limit(value: \.absoluteFWHM, range: 1.5...10.0, step: 0.5,
                                format: .number(fractionDigits: 1, unit: "px"))),
            // Eccentricity is absolute in both modes: the same setting.
            AutoRejectThreshold(
                title: "Trailing / Elongation", toggleLabel: "Enable eccentricity threshold",
                comparison: "Select if eccentricity >", isOn: \.useEccentricity,
                relative: eccentricity, absolute: eccentricity),
            AutoRejectThreshold(
                title: "Cloud / Haze (Star Count)", toggleLabel: "Enable star count threshold",
                comparison: "Select if stars <", isOn: \.useStarCount,
                relative: Limit(value: \.starCountMultiplier, range: 0.1...0.7, step: 0.05, format: .percentOfMedian),
                absolute: Limit(value: \.absoluteStarCountFloor, range: 5...100, step: 5,
                                format: .number(fractionDigits: 0))),
            AutoRejectThreshold(
                title: "Signal-to-Noise (SNR)", toggleLabel: "Enable SNR threshold",
                comparison: "Select if SNR <", isOn: \.useSNR,
                relative: Limit(value: \.snrMultiplier, range: 0.1...0.8, step: 0.05, format: .percentOfMedian),
                absolute: Limit(value: \.absoluteSNRFloor, range: 100.0...10_000.0, step: 100.0,
                                format: .number(fractionDigits: 0))),
            AutoRejectThreshold(
                title: "Light Pollution (Sky BG)", toggleLabel: "Enable sky background threshold",
                comparison: "Select if sky BG >", isOn: \.useSkyBackground,
                relative: Limit(value: \.skyBackgroundMultiplier, range: 1.2...3.0, step: 0.1,
                                format: .multipleOfMedian),
                absolute: Limit(value: \.absoluteSkyBackgroundCeiling, range: 500...20000, step: 500,
                                format: .number(fractionDigits: 0, unit: "ADU"))),
            AutoRejectThreshold(
                title: "PSF Signal Weight", toggleLabel: "Enable PSF signal weight threshold",
                comparison: "Select if PSF weight <", isOn: \.usePSF,
                relative: Limit(value: \.psfMultiplier, range: 0.1...0.9, step: 0.05, format: .percentOfMedian),
                absolute: Limit(value: \.absolutePSFFloor, range: 0.1...10.0, step: 0.1,
                                format: .number(fractionDigits: 1))),
            AutoRejectThreshold(
                title: "Quality Score", toggleLabel: "Enable score floor",
                comparison: "Select if score <", isOn: \.useScore,
                relative: nil,
                absolute: Limit(value: \.scoreFloor, range: 10...80, step: 5, format: .number(fractionDigits: 0))),
        ]
    }()

    /// The text of a limit next to the comparison: "1.5× median", "50% of median", "3.5 px".
    static func valueText(_ value: Double, format: Format, locale: Locale = .current) -> String {
        switch format {
        case .multipleOfMedian:
            value.formatted(.number.precision(.fractionLength(1)).locale(locale)) + "× median"
        case .percentOfMedian:
            value.formatted(.percent.precision(.fractionLength(0)).locale(locale)) + " of median"
        case let .number(fractionDigits, unit):
            value.formatted(.number.precision(.fractionLength(fractionDigits)).locale(locale))
                + (unit.map { " \($0)" } ?? "")
        }
    }
}
