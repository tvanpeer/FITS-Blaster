//
//  GroupStats.swift
//  FITS Blaster
//
//  Medians per filter group, for the badges, Auto-Flag and the chart. Moved out of FrameMetrics.swift (step 15b, CODE_AUDIT §9.15).
//

/// Per-filter-group summary statistics used for relative threshold comparisons
/// in badge colouring and auto-reject.
///
/// The medians are true medians: for an even number of frames the mean of the two middle
/// values (CODE_AUDIT §5.16, step 13).
struct GroupStats: Equatable {
    let medianFWHM: Double?
    let medianEccentricity: Double?
    let medianStarCount: Double?
    let medianSNR: Double?
    let medianScore: Double?
    let medianSkyBackground: Double?
    let medianPSFSignalWeight: Double?
    /// Frames the medians come from: the group's frames with metrics and stars.
    let frameCount: Int
    /// Minimum score required to place a frame in the top third of this group.
    /// Nil when the group has fewer than three frames with score data.
    let topThirdScoreFloor: Int?
    /// True for narrowband and OSC multi-narrowband groups.
    let isNarrowband: Bool

    /// Fewest frames for checks against the group median: in a smaller group a bad frame
    /// sets much of its own yardstick (CODE_AUDIT §5.16).
    static let minimumFramesForRelativeChecks = 3

    /// Whether checks against the group median apply: Auto-Flag's and the command line's
    /// relative mode, and the focus-fail and low-star badges. Absolute checks (eccentricity,
    /// absolute mode, frames without stars) apply to every group.
    var allowsRelativeChecks: Bool { frameCount >= Self.minimumFramesForRelativeChecks }
}
