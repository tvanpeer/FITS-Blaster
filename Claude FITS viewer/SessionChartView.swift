//
//  SessionChartView.swift
//  FITS Blaster
//

import SwiftUI
import Charts

// MARK: - ChartMetric

/// The metric plotted on the Y-axis of the session overview chart.
enum ChartMetric: String, CaseIterable, Identifiable {
    case score        = "Score"
    case fwhm         = "FWHM"
    case eccentricity = "Ecc"
    case snr          = "SNR"
    case starCount    = "Stars"

    var id: String { rawValue }

    /// Extract a chartable Double from a FrameMetrics value.
    /// Returns nil if this metric was not computed or has no data.
    func value(for metrics: FrameMetrics?) -> Double? {
        guard let m = metrics else { return nil }
        switch self {
        case .score:
            return m.hasData ? Double(m.qualityScore) : nil
        case .fwhm:
            return m.fwhm.map(Double.init)
        case .eccentricity:
            return m.eccentricity.map(Double.init)
        case .snr:
            return m.snr.map(Double.init)
        case .starCount:
            return m.starCount.map(Double.init)
        }
    }

    /// Look up the pre-computed per-group median for this metric from cached GroupStats.
    /// Returns nil when the metric was not computed or has no data for the group.
    func median(from stats: GroupStats) -> Double? {
        switch self {
        case .score:        return stats.medianScore.map(Double.init)
        case .fwhm:         return stats.medianFWHM.map(Double.init)
        case .eccentricity: return stats.medianEccentricity.map(Double.init)
        case .snr:          return stats.medianSNR.map(Double.init)
        case .starCount:    return stats.medianStarCount.map(Double.init)
        }
    }

    /// True when a lower value represents a better frame (inverts threshold shading).
    var isLowerBetter: Bool {
        switch self {
        case .fwhm, .eccentricity: return true
        default: return false
        }
    }
}

// MARK: - SessionChartView

/// Resizable strip below the main image showing the selected quality metric
/// plotted against load order for every frame in the session.
///
/// - Each dot is one frame, coloured by its canonical filter group.
/// - Dashed horizontal lines show the per-group median for the active metric.
/// - Tap a dot to select that frame in the main viewer.
/// - Drag across a range to select multiple frames and batch-reject them.
struct SessionChartView: View {
    @Environment(ImageStore.self) private var store

    @AppStorage("sessionChartMetric") private var selectedMetric: ChartMetric = .score
    /// View-space X positions tracked during a drag gesture.
    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    /// Frames staged for batch rejection after a drag-select.
    @State private var pendingReject: [ImageEntry] = []
    @State private var showRejectConfirm = false

    /// Subfolder paths whose entries are shown in the chart.
    /// Empty set means "All" — no folder filtering applied.
    @State private var selectedFolderPaths: Set<String> = []

    // MARK: - Derived data

    /// Entries shown in the chart strip, filtered by `selectedFolderPaths`.
    /// When no folders are selected (or only one folder exists), all entries are returned.
    private var chartEntries: [ImageEntry] {
        guard !selectedFolderPaths.isEmpty, store.isMultiFolder else {
            return store.entries
        }
        return store.entries.filter { selectedFolderPaths.contains($0.qualifiedFolderPath) }
    }

    /// All frames that have at least a partial metric value for the active metric,
    /// paired with their 0-based position in `chartEntries`.
    private var chartPoints: [(index: Int, entry: ImageEntry, value: Double)] {
        chartEntries.enumerated().compactMap { index, entry in
            guard let value = selectedMetric.value(for: entry.metrics) else { return nil }
            return (index: index, entry: entry, value: value)
        }
    }

    /// Y-axis domain computed from the visible data so the chart fills the available height.
    /// Starts 10% below the minimum value (never below 0 for counts/scores) and ends
    /// 10% above the maximum, so data always occupies most of the plot area.
    private var yAxisDomain: ClosedRange<Double> {
        // Include both data points and median lines so neither gets clipped.
        let pointValues  = chartPoints.map(\.value)
        let medianValues = groupMedians.map(\.median)
        let allValues    = pointValues + medianValues
        guard let minVal = allValues.min(), let maxVal = allValues.max(), minVal < maxVal else {
            return 0...1
        }
        let range   = maxVal - minVal
        let padding = max(range * 0.10, 0.01)  // at least a tiny margin for flat data
        let lower   = max(0, minVal - padding)
        let upper   = maxVal + padding
        return lower...upper
    }

    /// Per-group median of the active metric, used for threshold lines.
    /// Groups with fewer than two data points are skipped.
    ///
    /// Uses pre-cached values from `ImageStore.groupStatistics` when no folder filter
    /// is active (the common case), avoiding an O(n log n) sort on every render pass.
    /// Falls back to a live per-render computation when a folder filter is selected.
    private var groupMedians: [(group: FilterGroup, median: Double)] {
        if selectedFolderPaths.isEmpty || !store.isMultiFolder {
            // Fast path: read pre-computed medians — no sort needed.
            return FilterGroup.allCases.compactMap { group in
                guard let stats = store.groupStatistics[group],
                      let median = selectedMetric.median(from: stats) else { return nil }
                return (group: group, median: median)
            }
        }
        // Folder-filtered subset: compute from the visible entries.
        let grouped = Dictionary(grouping: chartEntries) { $0.filterGroup }
        return FilterGroup.allCases.compactMap { group in
            let values = (grouped[group] ?? [])
                .compactMap { selectedMetric.value(for: $0.metrics) }
                .sorted()
            guard values.count >= 2 else { return nil }
            return (group: group, median: values[values.count / 2])
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.isMultiFolder {
                Divider()
                folderStrip
            }
            Divider()
            if chartPoints.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        .background(.background)
        .onChange(of: store.activeFolderPaths) { _, newPaths in
            selectedFolderPaths = selectedFolderPaths.filter { newPaths.contains($0) }
        }
        .alert("Reject \(pendingReject.count) Frame\(pendingReject.count == 1 ? "" : "s")?",
               isPresented: $showRejectConfirm) {
            Button("Reject", role: .destructive) {
                store.rejectEntries(pendingReject)
                pendingReject = []
            }
            Button("Cancel", role: .cancel) { pendingReject = [] }
        } message: {
            Text("The selected frames will be moved to the REJECTED folder. You can undo individual frames with U.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 4) {
            // Metric selector
            ForEach(ChartMetric.allCases) { metric in
                Button { selectedMetric = metric } label: {
                    Text(metric.rawValue).scaledFont(size: 10)
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
                .tint(selectedMetric == metric ? .accentColor : nil)
            }

            Spacer()

            // Filter legend — only groups present in the session
            ForEach(store.activeFilterGroups) { group in
                HStack(spacing: 3) {
                    Circle()
                        .fill(group.color)
                        .frame(width: 7, height: 7)
                    Text(group.rawValue)
                        .scaledFont(size: 9)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
    }

    // MARK: - Folder strip

    private var folderStrip: some View {
        WrappingChips(spacing: 4) {
            FilterChip(label: "All", color: .accentColor,
                       isSelected: selectedFolderPaths.isEmpty) {
                selectedFolderPaths = []
            }
            ForEach(store.activeFolderPaths, id: \.self) { path in
                let displayName = store.groupedByFolderAndFilter
                    .first { $0.folderPath == path }?.folderDisplayName ?? path
                FilterChip(label: displayName.isEmpty ? "Root" : displayName,
                           color: .accentColor,
                           isSelected: selectedFolderPaths.contains(path)) {
                    if selectedFolderPaths.contains(path) {
                        selectedFolderPaths.remove(path)
                    } else {
                        selectedFolderPaths.insert(path)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 4)
    }

    // MARK: - Placeholder

    private var placeholder: some View {
        let message: String
        if store.entries.isEmpty {
            message = "Open a folder of FITS files to see the session chart"
        } else if store.isBatchProcessing {
            message = "Computing metrics…"
        } else {
            message = "No \(selectedMetric.rawValue) data for this session"
        }
        return Text(message)
            .scaledFont(size: 10)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Chart

    private var chart: some View {
        Chart {
            // Dashed median threshold lines, one per filter group
            ForEach(groupMedians, id: \.group) { item in
                RuleMark(y: .value("Median", item.median))
                    .foregroundStyle(item.group.color.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            // One dot per frame
            ForEach(chartPoints, id: \.entry.id) { item in
                PointMark(
                    x: .value("Frame", item.index + 1),   // 1-based label
                    y: .value(selectedMetric.rawValue, item.value)
                )
                .foregroundStyle(item.entry.filterGroup.color)
                // Enlarge the selected frame's dot so it stands out
                .symbolSize(store.selectedEntry === item.entry ? 90 : 28)
                // Dim rejected frames so they recede visually
                .opacity(item.entry.isRejected ? 0.25 : 1.0)
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 10)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel {
                    if let i = value.as(Int.self) {
                        Text("\(i)").font(.system(size: 9))
                    }
                }
            }
        }
        .chartXScale(domain: 1...max(1, chartPoints.count))
        .chartYScale(domain: yAxisDomain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel().font(.system(size: 9))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                // Drag-selection highlight rectangle
                dragHighlight(proxy: proxy, geo: geo)

                // Transparent overlay that captures tap + drag gestures
                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleTap(at: location, proxy: proxy, geo: geo)
                    }
                    .gesture(
                        DragGesture(minimumDistance: 6)
                            .onChanged { value in
                                dragStartX   = value.startLocation.x
                                dragCurrentX = value.location.x
                            }
                            .onEnded { value in
                                handleDragEnd(start: value.startLocation.x,
                                              end:   value.location.x,
                                              proxy: proxy, geo: geo)
                                dragStartX   = nil
                                dragCurrentX = nil
                            }
                    )
            }
        }
    }

    // MARK: - Drag highlight

    @ViewBuilder
    private func dragHighlight(proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let startX = dragStartX, let currentX = dragCurrentX,
           let plotFrame = proxy.plotFrame {
            let plotRect = geo[plotFrame]
            let lo = max(plotRect.minX, min(startX, currentX))
            let hi = min(plotRect.maxX, max(startX, currentX))
            if hi > lo {
                Rectangle()
                    .fill(.blue.opacity(0.12))
                    .overlay(Rectangle().stroke(.blue.opacity(0.35), lineWidth: 1))
                    .frame(width: hi - lo, height: plotRect.height)
                    .offset(x: lo, y: plotRect.minY)
                    .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Gesture handlers

    private func handleTap(at location: CGPoint, proxy: ChartProxy, geo: GeometryProxy) {
        guard let plotFrame = proxy.plotFrame else { return }
        let xInPlot = location.x - geo[plotFrame].minX
        // Chart X axis is 1-based frame numbers; subtract 1 for the chartEntries index
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self) else { return }
        let index = frameNumber - 1
        let entries = chartEntries
        guard entries.indices.contains(index) else { return }
        store.selectedEntry = entries[index]
    }

    private func handleDragEnd(start: CGFloat, end: CGFloat,
                               proxy: ChartProxy, geo: GeometryProxy) {
        guard abs(end - start) > 6, let plotFrame = proxy.plotFrame else { return }
        let plotRect = geo[plotFrame]
        let minX = min(start, end) - plotRect.minX
        let maxX = max(start, end) - plotRect.minX

        guard let startFrame: Int = proxy.value(atX: minX, as: Int.self),
              let endFrame:   Int = proxy.value(atX: maxX, as: Int.self) else { return }

        let entries = chartEntries
        let lo = max(0,                min(startFrame, endFrame) - 1)
        let hi = min(entries.count - 1, max(startFrame, endFrame) - 1)
        guard lo <= hi else { return }

        let candidates = Array(entries[lo...hi]).filter { !$0.isRejected }
        guard !candidates.isEmpty else { return }
        pendingReject    = candidates
        showRejectConfirm = true
    }
}
