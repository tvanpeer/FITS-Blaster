//
//  SessionChartData.swift
//  FITS Blaster
//
//  What the session chart shows, built outside its body: the frames in chart order, the
//  points of the selected metric and the per-group medians. The chart rebuilds it when the
//  store's lists change, and during a load at most every 250 ms, instead of observing every
//  frame's metrics and redrawing for each frame (performance audit P3).
//

import Foundation

struct SessionChartData {
    /// Frames shown in the chart, in chart order (folder selection and visibility applied).
    var entries: [ImageEntry] = []
    /// Frames with a value for the metric, with their 0-based position in `entries`.
    var points: [(index: Int, entry: ImageEntry, value: Double)] = []
    /// Per-group median of the metric, for the threshold lines.
    var medians: [(group: FilterGroup, median: Double)] = []

    /// How often the chart's data is rebuilt while a batch is loading.
    static let refreshInterval: Duration = .milliseconds(250)

    /// Builds the data from the store for `metric`, showing only `folderPaths` (all when empty).
    @MainActor
    static func make(store: ImageStore, metric: Metric, folderPaths: Set<String>) -> SessionChartData {
        let base: [ImageEntry]
        if !folderPaths.isEmpty, store.isMultiFolder {
            base = store.cachedSortedEntries.filter { folderPaths.contains($0.qualifiedFolderPath) }
        } else {
            base = store.cachedSortedEntries
        }
        let entries = base.filter { store.isVisible($0) }
        let points = entries.enumerated().compactMap { index, entry -> (index: Int, entry: ImageEntry, value: Double)? in
            guard let value = metric.value(from: entry.metrics) else { return nil }
            return (index: index, entry: entry, value: value)
        }

        // Pre-cached group statistics when no folder filter is active (the common case);
        // the chart's own frames when a folder filter is selected. Groups with fewer than
        // two values are skipped.
        let medians: [(group: FilterGroup, median: Double)]
        if folderPaths.isEmpty || !store.isMultiFolder {
            medians = FilterGroup.allCases.compactMap { group in
                guard let stats = store.groupStatistics[group],
                      let median = metric.median(from: stats) else { return nil }
                return (group: group, median: median)
            }
        } else {
            medians = FilterGroup.grouped(entries).compactMap { group, groupEntries in
                let values = groupEntries.compactMap { metric.value(from: $0.metrics) }
                guard values.count >= 2, let median = values.upperMedian else { return nil }
                return (group: group, median: median)
            }
        }
        return SessionChartData(entries: entries, points: points, medians: medians)
    }
}
