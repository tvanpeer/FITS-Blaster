//
//  FilterGrouping.swift
//  FITS Blaster
//
//  The one grouping of frames by filter, and the one median of a session's values, used by
//  the store's lists and statistics and by the session chart (CODE_AUDIT §9.11, §5.16).
//

import Foundation

extension FilterGroup {

    /// `entries` grouped by filter group, in canonical `FilterGroup` order, each group
    /// keeping the entries' order; groups without entries are left out.
    @MainActor
    static func grouped(_ entries: [ImageEntry]) -> [(group: FilterGroup, entries: [ImageEntry])] {
        let byGroup = Dictionary(grouping: entries) { $0.filterGroup }
        return allCases.compactMap { group in
            guard let groupEntries = byGroup[group], !groupEntries.isEmpty else { return nil }
            return (group: group, entries: groupEntries)
        }
    }
}

extension Array where Element: BinaryFloatingPoint {

    /// The median: the middle value after sorting, or for an even count the mean of the
    /// two middle values (CODE_AUDIT §5.16, step 13; before it the upper of the two).
    /// Nil for an empty array.
    var median: Double? { map { Double($0) }.trueMedian }
}

extension Array where Element: BinaryInteger {

    /// The median, as for floating-point values: for an even count the mean of the two
    /// middle values, so it can lie halfway between two counts. Nil for an empty array.
    var median: Double? { map { Double($0) }.trueMedian }
}

private extension Array where Element == Double {
    var trueMedian: Double? {
        guard !isEmpty else { return nil }
        let sorted = sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}
