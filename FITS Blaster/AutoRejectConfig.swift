//
//  AutoRejectConfig.swift
//  FITS Blaster
//

/// Thresholds for one-click quality-based frame rejection.
struct AutoRejectConfig: Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case relative = "Relative"
        case absolute = "Absolute"
    }

    var mode: Mode = .relative

    // FWHM
    var useFWHM: Bool = true
    var fwhmMultiplier: Double = 1.5     // relative: reject if FWHM > multiplier × group median
    var absoluteFWHM: Double = 3.5       // absolute: reject if FWHM (px) exceeds this

    // Eccentricity — same threshold in both modes (inherently absolute)
    var useEccentricity: Bool = true
    var eccentricityThreshold: Double = 0.5

    // Star count
    var useStarCount: Bool = true
    var starCountMultiplier: Double = 0.40
    var absoluteStarCountFloor: Double = 20   // stored as Double for direct Slider binding

    // SNR
    var useSNR: Bool = true
    var snrMultiplier: Double = 0.50
    var absoluteSNRFloor: Double = 20.0

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
}
