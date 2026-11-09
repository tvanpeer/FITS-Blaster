//
//  BadgeProblem.swift
//  FITS Blaster
//
//  The problem a thumbnail and Inspector badge shows. Moved out of FrameMetrics.swift (step 15b, CODE_AUDIT §9.15).
//

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
