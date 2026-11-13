//
//  AutoRejectConfig.swift
//  FITS Blaster
//

/// Thresholds for one-click quality-based frame rejection.
struct AutoRejectConfig: Equatable, Sendable {
    enum Mode: String, CaseIterable, Codable, Sendable {
        case relative = "Relative"
        case absolute = "Absolute"
    }

    var mode: Mode = .relative

    // FWHM
    var useFWHM: Bool = true
    var fwhmMultiplier: Double = MetricsCalculator.Constants.focusFailFWHMMultiplier   // relative: reject if FWHM > multiplier × group median
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

// MARK: - Stored between sessions

// The Auto-Flag settings as stored between sessions (issue #15; AutoRejectConfigStore).
// Encoding is synthesized (which needs this file); decoding reads each value on its own, so a
// value that is missing (a check added in a later version) or unreadable takes its default
// and the others are kept.
extension AutoRejectConfig: Codable {
    private enum CodingKeys: String, CodingKey {
        case mode
        case useFWHM, fwhmMultiplier, absoluteFWHM
        case useEccentricity, eccentricityThreshold
        case useStarCount, starCountMultiplier, absoluteStarCountFloor
        case useSNR, snrMultiplier, absoluteSNRFloor
        case useSkyBackground, skyBackgroundMultiplier, absoluteSkyBackgroundCeiling
        case usePSF, psfMultiplier, absolutePSFFloor
        case useScore, scoreFloor
    }

    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        Self.read(&mode, .mode, from: container)
        Self.read(&useFWHM, .useFWHM, from: container)
        Self.read(&fwhmMultiplier, .fwhmMultiplier, from: container)
        Self.read(&absoluteFWHM, .absoluteFWHM, from: container)
        Self.read(&useEccentricity, .useEccentricity, from: container)
        Self.read(&eccentricityThreshold, .eccentricityThreshold, from: container)
        Self.read(&useStarCount, .useStarCount, from: container)
        Self.read(&starCountMultiplier, .starCountMultiplier, from: container)
        Self.read(&absoluteStarCountFloor, .absoluteStarCountFloor, from: container)
        Self.read(&useSNR, .useSNR, from: container)
        Self.read(&snrMultiplier, .snrMultiplier, from: container)
        Self.read(&absoluteSNRFloor, .absoluteSNRFloor, from: container)
        Self.read(&useSkyBackground, .useSkyBackground, from: container)
        Self.read(&skyBackgroundMultiplier, .skyBackgroundMultiplier, from: container)
        Self.read(&absoluteSkyBackgroundCeiling, .absoluteSkyBackgroundCeiling, from: container)
        Self.read(&usePSF, .usePSF, from: container)
        Self.read(&psfMultiplier, .psfMultiplier, from: container)
        Self.read(&absolutePSFFloor, .absolutePSFFloor, from: container)
        Self.read(&useScore, .useScore, from: container)
        Self.read(&scoreFloor, .scoreFloor, from: container)
    }

    /// Replaces `value` with the stored one when it is present and readable; otherwise the
    /// default stays. A number must be finite.
    private static func read<T: Decodable>(_ value: inout T, _ key: CodingKeys,
                                           from container: KeyedDecodingContainer<CodingKeys>) {
        guard let stored = try? container.decodeIfPresent(T.self, forKey: key) else { return }
        if let number = stored as? Double, !number.isFinite { return }
        value = stored
    }
}
