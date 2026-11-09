//
//  SessionChartData.swift
//  FITS Blaster
//
//  What the session chart shows, built outside its body: the frames in chart order, the
//  points of the selected metric, the per-group medians and the y-axis range. The chart
//  rebuilds it when the store's lists change, and during a load at most every 250 ms,
//  instead of observing every frame's metrics and redrawing for each frame (performance
//  audit P3). The dot style, the frames under a tap or drag and the VoiceOver texts are
//  worked out here too, so they can be tested without the view (CODE_AUDIT §8.9, step 10a).
//

import Foundation

struct SessionChartData {
    /// Frames shown in the chart, in chart order (folder selection and visibility applied).
    var entries: [ImageEntry] = []
    /// Frames with a value for the metric, with their 0-based position in `entries`.
    var points: [(index: Int, entry: ImageEntry, value: Double)] = []
    /// Per-group median of the metric, for the threshold lines.
    var medians: [(group: FilterGroup, median: Double)] = []
    /// The y-axis range for the points and the medians (`yDomain(for:)`).
    var yDomain: ClosedRange<Double> = 0...1

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
                guard values.count >= 2, let median = values.median else { return nil }
                return (group: group, median: median)
            }
        }
        let yDomain = yDomain(for: points.map(\.value) + medians.map(\.median))
        return SessionChartData(entries: entries, points: points, medians: medians, yDomain: yDomain)
    }

    // MARK: - Y-axis range

    /// The y-axis range for `values`, so the chart fills the available height: 10 % of the
    /// spread below the minimum (never below 0) and above the maximum, at least 0.01. A single
    /// value (or all equal) gets a symmetric range of 20 % of the value, at least 0.5, so its
    /// dot or bar sits in the middle. No values: 0…1.
    static func yDomain(for values: [Double]) -> ClosedRange<Double> {
        guard let minVal = values.min(), let maxVal = values.max() else {
            return 0...1
        }
        guard minVal < maxVal else {
            let padding = max(abs(minVal) * 0.20, 0.5)
            return max(0, minVal - padding)...(minVal + padding)
        }
        let range   = maxVal - minVal
        let padding = max(range * 0.10, 0.01)
        let lower   = max(0, minVal - padding)
        let upper   = maxVal + padding
        return lower...upper
    }

    // MARK: - Dot style

    /// What decides how a frame's dot or bar is drawn.
    struct DotState: Equatable {
        var isCursor = false
        var isFlagged = false
        /// True when any frame in the session is flagged.
        var hasFlaggedFrames = false
        var isRejected = false
    }

    /// The opacity of a frame's dot or bar: `rejectedOpacity` for a rejected frame;
    /// `dimmedOpacity` when frames are flagged and this one is neither flagged nor the
    /// cursor; otherwise fully opaque. (The cursor's dot is also white and larger; the view
    /// draws that.)
    static func dotOpacity(_ state: DotState, rejectedOpacity: Double, dimmedOpacity: Double) -> Double {
        if state.isRejected { return rejectedOpacity }
        if state.hasFlaggedFrames && !state.isFlagged && !state.isCursor { return dimmedOpacity }
        return 1.0
    }

    // MARK: - Frames under a tap or drag

    /// The frame at chart frame number `frameNumber` (1-based, as on the x-axis); nil
    /// outside the chart's frames.
    func entry(atFrame frameNumber: Int) -> ImageEntry? {
        let index = frameNumber - 1
        return entries.indices.contains(index) ? entries[index] : nil
    }

    /// The frames from frame number `start` to `end` (1-based, either order, clamped to the
    /// chart's frames) that are not rejected: what a drag across the chart offers to select.
    @MainActor
    func flagCandidates(fromFrame start: Int, toFrame end: Int) -> [ImageEntry] {
        let lo = max(0, min(start, end) - 1)
        let hi = min(entries.count - 1, max(start, end) - 1)
        guard lo <= hi else { return [] }
        return entries[lo...hi].filter { !$0.isRejected }
    }

    // MARK: - VoiceOver

    /// A metric value as VoiceOver reads it, with its unit: "3.2 px", "1200 ADU", "72".
    static func spokenValue(_ value: Double, metric: Metric) -> String {
        let unit = switch metric {
        case .fwhm:          " px"
        case .skyBackground: " ADU"
        default:             ""
        }
        return "\(metric.formattedValue(value))\(unit)"
    }

    /// The chart's VoiceOver value: "39 frames, median 3.3 px, lowest 2.9 px, highest 4.1 px".
    /// Counts the frames with a value for the metric.
    func accessibilitySummary(metric: Metric) -> String {
        let values = points.map(\.value)
        guard let median = values.median, let lowest = values.min(), let highest = values.max() else {
            return "No \(metric.displayName) values"
        }
        let frames = values.count == 1 ? "1 frame" : "\(values.count) frames"
        return "\(frames), median \(Self.spokenValue(median, metric: metric)), "
            + "lowest \(Self.spokenValue(lowest, metric: metric)), highest \(Self.spokenValue(highest, metric: metric))"
    }

    /// One point of the chart's audio graph: x = frame number (1-based, as on the axis),
    /// y = the metric's value, label = the frame's file name.
    struct AudioGraphPoint: Equatable {
        let frame: Int
        let value: Double
        let label: String
    }

    /// The audio graph's points, one per frame with a value, in chart order.
    @MainActor
    func audioGraphPoints() -> [AudioGraphPoint] {
        points.map { AudioGraphPoint(frame: $0.index + 1, value: $0.value, label: $0.entry.fileName) }
    }
}
