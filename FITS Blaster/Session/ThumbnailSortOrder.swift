//
//  ThumbnailSortOrder.swift
//  FITS Blaster
//

/// Sort order for the thumbnail sidebar.
///
/// Metric-based orders are expressed as `.byMetric(Metric)` so adding a
/// new `Metric` case with a `.sort` context automatically appears in the picker.
enum ThumbnailSortOrder: Hashable {
    case filename
    case byMetric(Metric)
    case rejected

    /// Human-readable label shown in the sort picker.
    var label: String {
        switch self {
        case .filename:         return "Name"
        case .byMetric(let m):  return m.displayName
        case .rejected:         return "Rejected"
        }
    }

    /// All valid options in picker order: filename → metrics (by Metric.allCases order) → rejected.
    static var allSortOptions: [ThumbnailSortOrder] {
        [.filename]
        + Metric.allCases.filter { $0.contexts.contains(.sort) }.map { .byMetric($0) }
        + [.rejected]
    }
}
