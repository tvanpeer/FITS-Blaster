//
//  SessionChartView.swift
//  FITS Blaster
//

import SwiftUI
import Charts

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
    @Environment(AppSettings.self) private var settings

    @AppStorage("sessionChartMetric") private var selectedMetric: Metric = .qualityScore
    /// Subfolder paths whose entries are shown in the chart.
    /// Empty set means "All" — no folder filtering applied.
    @State private var selectedFolderPaths: Set<String> = []

    // MARK: - Derived data

    /// Entries shown in the chart strip, filtered by `selectedFolderPaths` and `rejectionVisibility`.
    private var chartEntries: [ImageEntry] {
        let base: [ImageEntry]
        if !selectedFolderPaths.isEmpty, store.isMultiFolder {
            base = store.cachedSortedEntries.filter { selectedFolderPaths.contains($0.qualifiedFolderPath) }
        } else {
            base = store.cachedSortedEntries
        }
        return base.filter { store.isVisible($0) }
    }

    /// All frames that have at least a partial metric value for the active metric,
    /// paired with their 0-based position in `chartEntries`.
    private var chartPoints: [(index: Int, entry: ImageEntry, value: Double)] {
        chartEntries.enumerated().compactMap { index, entry in
            guard let value = selectedMetric.value(from: entry.metrics) else { return nil }
            return (index: index, entry: entry, value: value)
        }
    }

    /// Per-group median of the active metric, used for threshold lines.
    /// Groups with fewer than two data points are skipped.
    ///
    /// Uses pre-cached values from `ImageStore.groupStatistics` when no folder filter
    /// is active (the common case), avoiding an O(n log n) sort on every render pass.
    /// Falls back to a live per-render computation when a folder filter is selected.
    private var groupMedians: [(group: FilterGroup, median: Double)] {
        if selectedFolderPaths.isEmpty || !store.isMultiFolder {
            return FilterGroup.allCases.compactMap { group in
                guard let stats = store.groupStatistics[group],
                      let median = selectedMetric.median(from: stats) else { return nil }
                return (group: group, median: median)
            }
        }
        let grouped = Dictionary(grouping: chartEntries) { $0.filterGroup }
        return FilterGroup.allCases.compactMap { group in
            let values = (grouped[group] ?? [])
                .compactMap { selectedMetric.value(from: $0.metrics) }
                .sorted()
            guard values.count >= 2 else { return nil }
            return (group: group, median: values[values.count / 2])
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ChartHeader(selectedMetric: $selectedMetric)
            if store.isMultiFolder {
                Divider()
                FolderFilterStrip(selectedFolderPaths: $selectedFolderPaths)
            }
            Divider()
            if chartPoints.isEmpty {
                ChartPlaceholder(selectedMetric: selectedMetric)
            } else {
                ChartBody(
                    chartEntries: chartEntries,
                    chartPoints: chartPoints,
                    groupMedians: groupMedians,
                    selectedMetric: selectedMetric
                )
            }
        }
        .background(.background)
        .onChange(of: store.activeFolderPaths) { _, newPaths in
            selectedFolderPaths = selectedFolderPaths.filter { newPaths.contains($0) }
        }
    }
}

// MARK: - ChartHeader

private struct ChartHeader: View {
    @Binding var selectedMetric: Metric
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Metric.allCases.filter { $0.contexts.contains(.chart) }) { metric in
                if selectedMetric == metric {
                    Button { selectedMetric = metric } label: {
                        Text(metric.shortLabel).scaledFont(size: 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    .help(metric.helpText)
                } else {
                    Button { selectedMetric = metric } label: {
                        Text(metric.shortLabel).scaledFont(size: 10)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .help(metric.helpText)
                }
            }

            Button(settings.chartUseBars ? "Switch to dots" : "Switch to bars",
                   systemImage: settings.chartUseBars ? "chart.bar.fill" : "circle.grid.3x3.fill") {
                settings.chartUseBars.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .controlSize(.mini)
            .help(settings.chartUseBars ? "Switch to dots" : "Switch to bars")

            Spacer()

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
}

// MARK: - FolderFilterStrip

private struct FolderFilterStrip: View {
    @Binding var selectedFolderPaths: Set<String>
    @Environment(ImageStore.self) private var store

    var body: some View {
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
}

// MARK: - ChartPlaceholder

private struct ChartPlaceholder: View {
    let selectedMetric: Metric
    @Environment(ImageStore.self) private var store

    var body: some View {
        Text(message)
            .scaledFont(size: 10)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var message: String {
        if store.entries.isEmpty {
            "Open a folder with ⌘O to Blast through your session"
        } else if store.isBatchProcessing {
            "Computing metrics…"
        } else {
            "No \(selectedMetric.displayName) data for this session"
        }
    }
}

// MARK: - ChartBody

private struct ChartBody: View {
    let chartEntries: [ImageEntry]
    let chartPoints: [(index: Int, entry: ImageEntry, value: Double)]
    let groupMedians: [(group: FilterGroup, median: Double)]
    let selectedMetric: Metric

    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    /// The app's text-size setting; axis labels take a Font, not the scaledFont modifier.
    @Environment(\.fontSizeMultiplier) private var fontScale

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    @State private var pendingFlag: [ImageEntry] = []
    @State private var showFlagConfirm = false

    // MARK: - Y-axis domain

    /// Computed from the visible data so the chart fills the available height.
    /// Starts 10% below the minimum value (never below 0) and ends 10% above the
    /// maximum. Handles the single-frame case with a symmetric range so the dot/bar
    /// sits in the centre rather than overflowing the 0…1 fallback.
    private var yAxisDomain: ClosedRange<Double> {
        let pointValues  = chartPoints.map(\.value)
        let medianValues = groupMedians.map(\.median)
        let allValues    = pointValues + medianValues
        guard let minVal = allValues.min(), let maxVal = allValues.max() else {
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

    // MARK: - Body

    var body: some View {
        // Capture outside the Chart{} builder — @ChartContentBuilder closures don't
        // participate in SwiftUI's @Observable tracking, so selectedEntry changes
        // wouldn't otherwise trigger a re-render.
        let selectedID = store.selectedEntry?.id
        Chart {
            ForEach(groupMedians, id: \.group) { item in
                RuleMark(y: .value("Median", item.median))
                    .foregroundStyle(item.group.color.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            ForEach(chartPoints, id: \.entry.id) { item in
                let isCursor = item.entry.id == selectedID
                let isFlagged = store.flaggedEntryIDs.contains(item.entry.id)
                let hasFlaggedSet = !store.flaggedEntryIDs.isEmpty
                let opacity: Double = if item.entry.isRejected { settings.rejectedDotOpacity }
                    else if hasFlaggedSet && !isFlagged && !isCursor { settings.dimmedDotOpacity }
                    else { 1.0 }
                let color: Color = isCursor ? .white : item.entry.filterGroup.color

                if settings.chartUseBars {
                    BarMark(
                        x: .value("Frame", item.index + 1),
                        y: .value(selectedMetric.displayName, item.value)
                    )
                    .foregroundStyle(color)
                    .opacity(opacity)
                } else {
                    PointMark(
                        x: .value("Frame", item.index + 1),
                        y: .value(selectedMetric.displayName, item.value)
                    )
                    .foregroundStyle(color)
                    .symbolSize(isCursor ? 40 : 28)
                    .opacity(opacity)
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 10)) { value in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel {
                    if let i = value.as(Int.self) {
                        Text("\(i)").scaledFont(size: 9)
                    }
                }
            }
        }
        // Points sit at their frame's index in chartEntries; frames without a value
        // (still processing, no stars) have no point but still take a place (CODE_AUDIT §5.9).
        .chartXScale(domain: 0...max(2, chartEntries.count + 1))
        .chartYScale(domain: yAxisDomain)
        .chartYAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(.secondary.opacity(0.25))
                AxisValueLabel().font(.system(size: (9 * fontScale).rounded()))
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                dragHighlight(proxy: proxy, geo: geo)

                Rectangle()
                    .fill(.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        handleTap(at: location, proxy: proxy, geo: geo)
                    }
                    .accessibilityAddTraits(.isButton)
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

                dragTooltip(proxy: proxy, geo: geo)
            }
        }
        .alert("Select \(pendingFlag.count) Frame\(pendingFlag.count == 1 ? "" : "s")?",
               isPresented: $showFlagConfirm) {
            Button("Select") {
                store.flagEntries(pendingFlag)
                pendingFlag = []
            }
            Button("Cancel", role: .cancel) { pendingFlag = [] }
        } message: {
            Text("The frames will be added to the selection. Switch to the Selected view to inspect and reject them.")
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
                    .overlay { Rectangle().stroke(.blue.opacity(0.35), lineWidth: 1) }
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
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self) else { return }
        let index = frameNumber - 1
        guard chartEntries.indices.contains(index) else { return }
        store.selectedEntry = chartEntries[index]
    }

    // MARK: - Drag tooltip

    private func hoveredInfo(proxy: ChartProxy, geo: GeometryProxy) -> (label: String, x: CGFloat)? {
        guard let currentX = dragCurrentX, let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geo[plotFrame]
        let xInPlot = currentX - plotRect.minX
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self) else { return nil }
        let index = frameNumber - 1
        guard chartEntries.indices.contains(index),
              let value = selectedMetric.value(from: chartEntries[index].metrics) else { return nil }
        let label = "\(selectedMetric.shortLabel): \(selectedMetric.formattedValue(value))"
        let clampedX = max(50, min(currentX, geo.size.width - 50))
        return (label: label, x: clampedX)
    }

    @ViewBuilder
    private func dragTooltip(proxy: ChartProxy, geo: GeometryProxy) -> some View {
        if let info = hoveredInfo(proxy: proxy, geo: geo) {
            Text(info.label)
                .scaledFont(size: 10)
                .foregroundStyle(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(.regularMaterial, in: .rect(cornerRadius: 4))
                .fixedSize()
                .position(x: info.x, y: 14)
                .allowsHitTesting(false)
        }
    }

    private func handleDragEnd(start: CGFloat, end: CGFloat,
                               proxy: ChartProxy, geo: GeometryProxy) {
        guard abs(end - start) > 6, let plotFrame = proxy.plotFrame else { return }
        let plotRect = geo[plotFrame]
        let minX = min(start, end) - plotRect.minX
        let maxX = max(start, end) - plotRect.minX

        guard let startFrame: Int = proxy.value(atX: minX, as: Int.self),
              let endFrame:   Int = proxy.value(atX: maxX, as: Int.self) else { return }

        let lo = max(0,                    min(startFrame, endFrame) - 1)
        let hi = min(chartEntries.count - 1, max(startFrame, endFrame) - 1)
        guard lo <= hi else { return }

        let candidates = Array(chartEntries[lo...hi]).filter { !$0.isRejected }
        guard !candidates.isEmpty else { return }
        pendingFlag     = candidates
        showFlagConfirm = true
    }
}
