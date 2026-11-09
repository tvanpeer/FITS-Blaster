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

    /// The chart's frames, points and medians, rebuilt from the store when they can have
    /// changed — not read from every frame while drawing (performance audit P3).
    @State private var data = SessionChartData()

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ChartHeader(selectedMetric: $selectedMetric)
            if store.isMultiFolder {
                Divider()
                FolderFilterStrip(selectedFolderPaths: $selectedFolderPaths)
            }
            Divider()
            if data.points.isEmpty {
                ChartPlaceholder(selectedMetric: selectedMetric)
            } else {
                ChartBody(data: data, selectedMetric: selectedMetric)
            }
        }
        .background(.background)
        .onChange(of: store.activeFolderPaths) { _, newPaths in
            selectedFolderPaths = selectedFolderPaths.filter { newPaths.contains($0) }
        }
        // Rebuilt when the lists, the metric or the folder selection change…
        .onAppear { rebuild() }
        .onChange(of: store.listRevision) { _, _ in rebuild() }
        .onChange(of: selectedMetric) { _, _ in rebuild() }
        .onChange(of: selectedFolderPaths) { _, _ in rebuild() }
        // …and while a batch runs, every 250 ms (metrics arrive frame by frame), plus once
        // when it ends.
        .task(id: store.pipeline.isBatchProcessing) {
            rebuild()
            guard store.pipeline.isBatchProcessing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionChartData.refreshInterval)
                guard !Task.isCancelled else { return }
                rebuild()
            }
        }
    }

    private func rebuild() {
        data = SessionChartData.make(store: store, metric: selectedMetric, folderPaths: selectedFolderPaths)
    }
}

// MARK: - ChartHeader

private struct ChartHeader: View {
    @Binding var selectedMetric: Metric
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor

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
                    FilterLegendMark(group: group, showsShape: differentiateWithoutColor && !settings.chartUseBars)
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
        } else if store.pipeline.isBatchProcessing {
            "Computing metrics…"
        } else {
            "No \(selectedMetric.displayName) data for this session"
        }
    }
}

// MARK: - ChartBody

private struct ChartBody: View {
    /// The frames, points, medians and y-range, built by `SessionChartData.make`.
    let data: SessionChartData
    let selectedMetric: Metric

    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    /// The app's text-size setting; axis labels take a Font, not the scaledFont modifier.
    @Environment(\.fontSizeMultiplier) private var fontScale
    /// macOS "Differentiate without color": a shape per filter group (step 10d).
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiateWithoutColor
    @Environment(\.colorScheme) private var colorScheme

    @State private var dragStartX: CGFloat?
    @State private var dragCurrentX: CGFloat?
    @State private var pendingFlag: [ImageEntry] = []
    @State private var showFlagConfirm = false

    // MARK: - Body

    var body: some View {
        // Read everything outside the Chart{} builder: @ChartContentBuilder closures don't take part
        // in @Observable tracking, so changes read inside would not redraw (bars ↔ dots, 10d).
        let selectedID = store.selectedEntry?.id, flaggedIDs = store.flaggedEntryIDs
        let useBars = settings.chartUseBars
        let rejectedOpacity = settings.rejectedDotOpacity, dimmedOpacity = settings.dimmedDotOpacity
        let showsShapes = differentiateWithoutColor && !useBars  // shapes for dots only, not bars
        Chart {
            ForEach(data.medians, id: \.group) { item in
                RuleMark(y: .value("Median", item.median))
                    .foregroundStyle(item.group.color.opacity(0.40))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            ForEach(data.points, id: \.entry.id) { item in
                let isCursor = item.entry.id == selectedID
                let state = SessionChartData.DotState(
                    isCursor: isCursor,
                    isFlagged: flaggedIDs.contains(item.entry.id),
                    hasFlaggedFrames: !flaggedIDs.isEmpty,
                    isRejected: item.entry.isRejected)
                let opacity = SessionChartData.dotOpacity(state, rejectedOpacity: rejectedOpacity,
                                                          dimmedOpacity: dimmedOpacity)
                let color: Color = isCursor ? .primary : item.entry.filterGroup.chartColor(
                    differentiateWithoutColor: showsShapes, colorScheme: colorScheme)

                if useBars {
                    BarMark(
                        x: .value("Frame", item.index + 1),
                        y: .value(selectedMetric.displayName, item.value)
                    )
                    .foregroundStyle(color)
                    .opacity(opacity)
                } else if showsShapes {
                    PointMark(
                        x: .value("Frame", item.index + 1),
                        y: .value(selectedMetric.displayName, item.value)
                    )
                    .foregroundStyle(color)
                    .symbol(item.entry.filterGroup.chartSymbol.shape)
                    .symbolSize(isCursor ? FilterSymbol.cursorDotSize : FilterSymbol.dotSize)
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
        // Points sit at their frame's index in data.entries; frames without a value
        // (still processing, no stars) have no point but still take a place (CODE_AUDIT §5.9).
        .chartXScale(domain: 0...max(2, data.entries.count + 1))
        .chartYScale(domain: data.yDomain)
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
        // VoiceOver: one element with a summary and an audio graph that steps through the
        // frames. The click-and-drag layer is for the pointer only; with VoiceOver frames are
        // selected in the sidebar (step 10a).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Session chart, \(selectedMetric.displayName)")
        .accessibilityValue(data.accessibilitySummary(metric: selectedMetric))
        .accessibilityChartDescriptor(SessionChartAudioGraph(
            metric: selectedMetric, points: data.audioGraphPoints(),
            frameCount: data.entries.count, yDomain: data.yDomain))
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
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self),
              let entry = data.entry(atFrame: frameNumber) else { return }
        store.selectedEntry = entry
    }

    // MARK: - Drag tooltip

    private func hoveredInfo(proxy: ChartProxy, geo: GeometryProxy) -> (label: String, x: CGFloat)? {
        guard let currentX = dragCurrentX, let plotFrame = proxy.plotFrame else { return nil }
        let plotRect = geo[plotFrame]
        let xInPlot = currentX - plotRect.minX
        guard let frameNumber: Int = proxy.value(atX: xInPlot, as: Int.self),
              let entry = data.entry(atFrame: frameNumber),
              let value = selectedMetric.value(from: entry.metrics) else { return nil }
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

        let candidates = data.flagCandidates(fromFrame: startFrame, toFrame: endFrame)
        guard !candidates.isEmpty else { return }
        pendingFlag     = candidates
        showFlagConfirm = true
    }
}
