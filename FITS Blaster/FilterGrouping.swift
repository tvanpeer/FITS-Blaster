//
//  FilterGrouping.swift
//  FITS Blaster
//
//  The one grouping of frames by filter, and the one median of a session's values, used by
//  the store's lists and statistics and by the session chart (CODE_AUDIT §9.11).
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

extension Array where Element: Comparable {

    /// The middle value after sorting — for an even count the upper of the two middle
    /// values, as FITS Blaster has always used (a true median for even counts is a
    /// behaviour change, decision 5, step 13). Nil for an empty array.
    var upperMedian: Element? {
        guard !isEmpty else { return nil }
        return sorted()[count / 2]
    }
}
