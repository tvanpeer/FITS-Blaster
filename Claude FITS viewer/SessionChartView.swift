//
//  SessionChartView.swift
//  Simple Claude fits viewer
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

    @State private var selectedMetric: ChartMetric = .score
    /// View-space X positions tracked during a drag gesture.
    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    /// Frames staged for batch rejection after a drag-select.
    @State private var pendingReject: [ImageEntry] = []
    @State private var showRejectConfirm = false

    // MARK: - Derived data

    /// All frames that have at least a partial metric value for the active metric,
    /// paired with their stable load index (position in entries array).
    private var chartPoints: [(index: Int, entry: ImageEntry, value: Double)] {
        store.entries.enumerated().compactMap { index, entry in
            guard let value = selectedMetric.value(for: entry.metrics) else { return nil }
            return (index: index, entry: entry, value: value)
        }
    }

    /// Per-group median of the active metric, used for threshold lines.
    /// Groups with fewer than two data points are skipped.
    private var groupMedians: [(group: FilterGroup, median: Double)] {
        let grouped = Dictionary(grouping: store.entries) { $0.filterGroup }
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
            Divider()
            if chartPoints.isEmpty {
                placeholder
            } else {
                chart
            }
        }
        .background(.background)
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
                Button(metric.rawValue) { selectedMetric = metric }
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
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 5)
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
            .font(.caption)
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
                    .annotation(position: .trailing, alignment: .center) {
                        Text(item.group.rawValue)
                            .font(.system(size: 7))
                            .foregroundStyle(item.group.color.opacity(0.70))
                    }
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
        // Chart X axis is 1-based frame numbers; subtract 1 for the entries array index
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self) else { return }
        let index = frameNumber - 1
        guard store.entries.indices.contains(index) else { return }
        store.selectedEntry = store.entries[index]
    }

    private func handleDragEnd(start: CGFloat, end: CGFloat,
                               proxy: ChartProxy, geo: GeometryProxy) {
        guard abs(end - start) > 6, let plotFrame = proxy.plotFrame else { return }
        let plotRect = geo[plotFrame]
        let minX = min(start, end) - plotRect.minX
        let maxX = max(start, end) - plotRect.minX

        guard let startFrame: Int = proxy.value(atX: minX, as: Int.self),
              let endFrame:   Int = proxy.value(atX: maxX, as: Int.self) else { return }

        // Convert 1-based frame numbers to 0-based array indices
        let lo = max(0,                       min(startFrame, endFrame) - 1)
        let hi = min(store.entries.count - 1, max(startFrame, endFrame) - 1)
        guard lo <= hi else { return }

        let candidates = Array(store.entries[lo...hi]).filter { !$0.isRejected }
        guard !candidates.isEmpty else { return }
        pendingReject    = candidates
        showRejectConfirm = true
    }
}
