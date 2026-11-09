//
//  AutoRejectConfig.swift
//  FITS Blaster
//

/// Thresholds for one-click quality-based frame rejection.
struct AutoRejectConfig: Equatable, Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case relative = "Relative"
        case absolute = "Absolute"
    }

    var mode: Mode = .relative

    // FWHM
    var useFWHM: Bool = true
    var fwhmMultiplier: Double = 1.5     // relative: reject if FWHM > multiplier × group median
    var absoluteFWHM: Double = 3.5       // absolute: reject if FWHM (px) exceeds this

    // Eccentricity — same threshold in both modes (inherently absolute). The default is the
    // red "trailing" badge's limit (step 13h; was 0.5).
    var useEccentricity: Bool = true
    var eccentricityThreshold: Double = MetricsCalculator.Constants.trailingEccentricity

    // Star count
    var useStarCount: Bool = true
    var starCountMultiplier: Double = 0.50   // step 13h (was 0.40): catches thin cloud
    var absoluteStarCountFloor: Double = 20   // stored as Double for direct Slider binding

    // SNR
    var useSNR: Bool = true
    var snrMultiplier: Double = 0.60         // step 13h (was 0.50): catches thin cloud
    var absoluteSNRFloor: Double = 200.0   // star flux ÷ σ (step 13b; was 20 on the old peak ÷ σ)

    // Sky background
    var useSkyBackground: Bool = false
    var skyBackgroundMultiplier: Double = 1.5
    var absoluteSkyBackgroundCeiling: Double = 3000.0

    // PSF signal weight (higher = better)
    var usePSF: Bool = false
    var psfMultiplier: Double = 0.5
    var absolutePSFFloor: Double = 1.0

    // Quality score (absolute mode only)
    var useScore: Bool = false
    var scoreFloor: Double = 40   // stored as Double for direct Slider binding

    /// Every check off (the CLI turns on only the checks given on the command line).
    static var allDisabled: AutoRejectConfig {
        var config = AutoRejectConfig()
        config.useFWHM = false
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        config.useSkyBackground = false
        config.usePSF = false
        config.useScore = false
        return config
    }

    /// True when at least one check is on in the current mode (the score check only counts
    /// in absolute mode). A frame without stars fails every check (step 13g).
    var isAnyCheckOn: Bool {
        useFWHM || useEccentricity || useStarCount || useSNR || useSkyBackground || usePSF
            || (mode == .absolute && useScore)
    }

    /// True in relative mode with at least one check against the group median on (all
    /// checks except eccentricity, which is absolute in both modes).
    var isAnyRelativeCheckOn: Bool {
        mode == .relative && (useFWHM || useStarCount || useSNR || useSkyBackground || usePSF)
    }
}
