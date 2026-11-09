//
//  MetricsConfig.swift
//  FITS Blaster
//
//  Which metrics a load computes. Moved out of FrameMetrics.swift (step 15b, CODE_AUDIT §9.15).
//

/// Subset of AppSettings needed for metrics computation.
/// Plain Sendable value type for safe capture in nonisolated background tasks.
/// Metrics are all on (Geek mode) or all off (Simple mode, and passes that only
/// re-render images); there are no per-metric switches.
struct MetricsConfig: Sendable, Equatable {
    var computeMetrics: Bool = true

    /// Simple mode: no star detection, star metrics hidden.
    static let off = MetricsConfig(computeMetrics: false)

    /// True when star detection has to run.
    var needsStarDetection: Bool { computeMetrics }
}
