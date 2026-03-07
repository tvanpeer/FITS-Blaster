//
//  ContentView.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 28/02/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var hostingWindow: NSWindow?
    @State private var isDragTarget = false

    var body: some View {
        HSplitView {
            ThumbnailSidebar(store: store)
                .frame(minWidth: 140, idealWidth: 165, maxWidth: 220)

            VStack(spacing: 0) {
                FITSToolbar(store: store)
                Divider()
                VSplitView {
                    MainContent(store: store)
                        .frame(minHeight: 180)
                        .layoutPriority(1)
                    if !settings.isSimpleMode {
                        SessionChartView()
                            .frame(minHeight: 80, idealHeight: 160, maxHeight: 220)
                    }
                }
            }
            .frame(minWidth: settings.isSimpleMode ? 380 : 400)

            if settings.showInspector && !settings.isSimpleMode {
                InspectorView()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            }
        }
        .overlay { if isDragTarget { DropTargetOverlay() } }
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers: providers)
            return true
        }
        .focusedValue(\.simpleModeBinding, Binding(
            get: { settings.isSimpleMode },
            set: { settings.isSimpleMode = $0 }
        ))
        .frame(minWidth: minWindowWidth, minHeight: 400)
        .preferredColorScheme(settings.preferredColorScheme)
        .background(WindowAccessor { hostingWindow = $0 })
        .onChange(of: settings.metricsConfig) { _, newConfig in
            guard !settings.isSimpleMode else { return }
            store.recomputeMetrics(metricsConfig: newConfig)
        }
        .onChange(of: settings.isSimpleMode) { _, isSimple in
            if !isSimple {
                // Switching to Geek: restore cached metrics instantly (no I/O if already computed)
                store.recomputeMetrics(metricsConfig: settings.metricsConfig)
            }
            guard let window = hostingWindow else { return }
            var frame = window.frame
            if isSimple {
                if settings.showInspector { frame.size.width -= 260 }
                frame.size.width = max(frame.size.width, 500)
            } else {
                if settings.showInspector { frame.size.width += 260 }
                frame.size.width = max(frame.size.width, settings.showInspector ? 960 : 700)
            }
            window.setFrame(frame, display: true, animate: true)
        }
        .onChange(of: settings.showInspector) { _, shown in
            guard !settings.isSimpleMode, let window = hostingWindow else { return }
            let delta: CGFloat = 260
            var frame = window.frame
            frame.size.width += shown ? delta : -delta
            frame.size.width = max(frame.size.width, shown ? 960 : 700)
            window.setFrame(frame, display: true, animate: true)
        }
        .alert("Error", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK") { store.errorMessage = nil }
        } message: {
            Text(store.errorMessage ?? "")
        }
        .focusable()
        .focusEffectDisabled()
        // Navigation
        .onKeyPress(settings.firstImageKeyEquivalent) { store.selectFirst();          return .handled }
        .onKeyPress(settings.lastImageKeyEquivalent)  { store.selectLast();           return .handled }
        .onKeyPress(settings.prevKeyEquivalent)       { store.selectPrevious();       return .handled }
        .onKeyPress(settings.nextKeyEquivalent)       { store.selectNext();           return .handled }
        .onKeyPress(settings.rejectKeyEquivalent) {
            if settings.useToggleReject { store.toggleRejectSelected() } else { store.rejectSelected() }
            return .handled
        }
        .onKeyPress(settings.undoKeyEquivalent) {
            guard !settings.useToggleReject else { return .ignored }
            store.undoRejectSelected()
            return .handled
        }
        .onKeyPress(settings.toggleModeKeyEquivalent) {
            settings.isSimpleMode.toggle()
            return .handled
        }
    }

    private var minWindowWidth: CGFloat {
        if settings.isSimpleMode { return 500 }
        return settings.showInspector ? 960 : 700
    }

    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            provider.loadObject(ofClass: NSURL.self) { object, _ in
                                continuation.resume(returning: (object as? NSURL) as? URL)
                            }
                        }
                    }
                }
                for await url in group {
                    if let url { urls.append(url) }
                }
            }
            guard !urls.isEmpty else { return }
            store.openDroppedItems(urls, settings: settings)
        }
    }
}

// MARK: - Drop Target Overlay

struct DropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.blue, lineWidth: 4)
            .fill(.blue.opacity(0.04))
            .padding(4)
            .allowsHitTesting(false)
    }
}

// MARK: - Thumbnail Sidebar

struct ThumbnailSidebar: View {
    @Bindable var store: ImageStore
    @Environment(AppSettings.self) private var settings

    /// The last entry that received a plain or cmd+click — used as the anchor for shift+click range.
    @State private var lastClickedID: UUID? = nil

    /// Ordered list of entries currently rendered in the sidebar, used for shift+click range.
    private var visibleEntries: [ImageEntry] {
        if settings.isSimpleMode { return store.entries }
        if store.sidebarFilterGroup != nil || store.activeFilterGroups.count <= 1 {
            return store.filteredSortedEntries
        }
        return store.groupedSortedEntries.flatMap { $0.entries }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isSimpleMode {
                // Sort controls (Geek mode only)
                HStack(spacing: 4) {
                    Text("Sort")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Sort", selection: $store.thumbnailSortOrder) {
                        ForEach(ThumbnailSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .font(.caption)
                    Button(store.thumbnailSortAscending ? "Sort Ascending" : "Sort Descending",
                           systemImage: store.thumbnailSortAscending ? "arrow.up" : "arrow.down") {
                        store.thumbnailSortAscending.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.caption)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                // Filter strip — only shown when multiple filter groups are present
                if store.activeFilterGroups.count > 1 {
                    Divider()
                    FilterStrip(store: store)
                }

                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        if settings.isSimpleMode {
                            // Simple mode: plain filename-ordered flat list, no grouping
                            ForEach(store.entries) { entry in
                                thumbnailButton(for: entry)
                            }
                        } else if store.sidebarFilterGroup != nil || store.activeFilterGroups.count <= 1 {
                            // Flat list: a specific filter is selected, or only one group exists
                            ForEach(store.filteredSortedEntries) { entry in
                                thumbnailButton(for: entry)
                            }
                        } else {
                            // Grouped list: one section per filter group
                            ForEach(store.groupedSortedEntries, id: \.group) { group, entries in
                                Section {
                                    ForEach(entries) { entry in
                                        thumbnailButton(for: entry)
                                    }
                                } header: {
                                    FilterGroupHeader(group: group, entries: entries)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .scrollIndicators(.hidden)
                .background(.background)
                .onChange(of: store.selectedEntry?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }

    private func thumbnailButton(for entry: ImageEntry) -> some View {
        Button {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                // Cmd+click: toggle this entry in/out of the multi-selection.
                if store.selectedEntryIDs.contains(entry.id) {
                    store.selectedEntryIDs.remove(entry.id)
                    if store.selectedEntry === entry {
                        store.selectedEntry = store.entries.first { store.selectedEntryIDs.contains($0.id) }
                    }
                } else {
                    if let current = store.selectedEntry { store.selectedEntryIDs.insert(current.id) }
                    store.selectedEntryIDs.insert(entry.id)
                    store.selectedEntry = entry
                }
                lastClickedID = entry.id
            } else if mods.contains(.shift), let lastID = lastClickedID {
                // Shift+click: range-select from last clicked entry to this one.
                let visible = visibleEntries
                if let fromIdx = visible.firstIndex(where: { $0.id == lastID }),
                   let toIdx   = visible.firstIndex(where: { $0.id == entry.id }) {
                    let range = fromIdx <= toIdx ? fromIdx...toIdx : toIdx...fromIdx
                    if store.selectedEntryIDs.isEmpty, let current = store.selectedEntry {
                        store.selectedEntryIDs.insert(current.id)
                    }
                    store.selectedEntryIDs.formUnion(visible[range].map { $0.id })
                    store.selectedEntry = entry
                }
            } else {
                // Plain click: single select, clear any multi-selection.
                store.selectedEntryIDs = []
                store.selectedEntry = entry
                lastClickedID = entry.id
            }
        } label: {
            ThumbnailCell(entry: entry,
                          isSelected: store.selectedEntry === entry || store.selectedEntryIDs.contains(entry.id))
        }
        .buttonStyle(.plain)
        .id(entry.id)
    }
}

// MARK: - Filter strip

struct FilterStrip: View {
    @Bindable var store: ImageStore

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                FilterChip(label: "All",
                           color: .accentColor,
                           isSelected: store.sidebarFilterGroup == nil) {
                    store.sidebarFilterGroup = nil
                }
                ForEach(store.activeFilterGroups) { group in
                    FilterChip(label: group.rawValue,
                               color: group.color,
                               isSelected: store.sidebarFilterGroup == group) {
                        store.sidebarFilterGroup =
                            store.sidebarFilterGroup == group ? nil : group
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 5)
        }
        .scrollIndicators(.hidden)
    }
}

struct FilterChip: View {
    let label: String
    let color: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.caption2.bold())
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(isSelected ? color : color.opacity(0.15))
                .foregroundStyle(isSelected ? .white : color)
                .clipShape(.rect(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Filter group header

struct FilterGroupHeader: View {
    let group: FilterGroup
    let entries: [ImageEntry]

    private var medianFWHM: Float? {
        let values = entries.compactMap { $0.metrics?.fwhm }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    private var medianScore: Int? {
        let values = entries.compactMap { $0.metrics?.qualityScore }.sorted()
        guard !values.isEmpty else { return nil }
        return values[values.count / 2]
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(group.color)
                .frame(width: 8, height: 8)
            Text(group.rawValue)
                .font(.caption.bold())
            Text("\(entries.count)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let fwhm = medianFWHM {
                Text("\(fwhm, format: .number.precision(.fractionLength(1)))px")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let score = medianScore {
                Text("▸\(score)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.regularMaterial)
    }
}

// MARK: - Toolbar

struct FITSToolbar: View {
    let store: ImageStore
    @Environment(AppSettings.self) private var settings
    @State private var showExportSheet = false
    @State private var showAutoRejectSheet = false

    var body: some View {
        HStack {
            Button("Open Folder…") {
                store.openFolderPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Open Files…") {
                store.openFilesPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Reset") {
                store.reset()
            }
            .disabled(store.entries.isEmpty)

            if store.selectedEntryIDs.count > 1 {
                Divider().frame(height: 20)
                Text("\(store.selectedEntryIDs.count) selected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !settings.isSimpleMode {
                Button("Auto-Flag", systemImage: "wand.and.stars") {
                    showAutoRejectSheet = true
                }
                .help("Auto-flag frames below quality thresholds")
                .disabled(store.entries.isEmpty)
            }

            Button("Export…", systemImage: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(store.entries.isEmpty)

            // Mode toggle: dial.low = "switch to Simple", dial.high = "switch to Geek"
            Button("", systemImage: settings.isSimpleMode ? "dial.high" : "dial.low") {
                settings.isSimpleMode.toggle()
            }
            .help(settings.isSimpleMode ? "Switch to Geek Mode (⌘⇧M)" : "Switch to Simple Mode (⌘⇧M)")

            if !settings.isSimpleMode {
                Button("", systemImage: "sidebar.right") {
                    settings.showInspector.toggle()
                }
                .help(settings.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(isPresented: $showExportSheet)
                .environment(store)
        }
        .sheet(isPresented: $showAutoRejectSheet) {
            AutoRejectSheet(isPresented: $showAutoRejectSheet)
                .environment(store)
        }
    }
}

// MARK: - Main Content

struct MainContent: View {
    let store: ImageStore

    var body: some View {
        if let entry = store.selectedEntry {
            if entry.isProcessing {
                ProgressView("Stretching \(entry.fileName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayImage = entry.displayImage {
                VStack(spacing: 0) {
                    Text(entry.fileName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    Divider()
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: displayImage)
                    }
                    .id(entry.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.hidden)

                    Divider()
                    InfoBar(store: store, entry: entry)
                }
            } else if let error = entry.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack {
                Image(systemName: "star.circle")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
                Text("Open a folder of FITS files to view them")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Use the button above or \u{2318}O")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Info Bar

private struct InfoBar: View {
    let store: ImageStore
    let entry: ImageEntry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack {
            if store.isBatchProcessing {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("Processing…").font(.caption).foregroundStyle(.secondary)
            } else if let elapsed = store.batchElapsed {
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(store.entries.count) images")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Inline metrics summary (Geek mode only)
            if !settings.isSimpleMode, let m = entry.metrics, m.hasData {
                HStack(spacing: 12) {
                    if let v = m.fwhm        { MetricChip(label: "FWHM", value: "\(v.formatted(.number.precision(.fractionLength(1)))) px") }
                    if let v = m.eccentricity { MetricChip(label: "Ecc",  value: v.formatted(.number.precision(.fractionLength(2)))) }
                    if let v = m.snr          { MetricChip(label: "SNR",  value: v.formatted(.number.precision(.fractionLength(0)))) }
                    if let v = m.starCount     { MetricChip(label: "★",   value: "\(v)") }
                }
            }

            if !entry.imageInfo.isEmpty {
                Text(entry.imageInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .font(.caption.monospacedDigit())
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let entry: ImageEntry
    let isSelected: Bool
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private var groupStats: GroupStats? {
        store.groupStatistics[entry.filterGroup]
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailImage
                if !settings.isSimpleMode, let metrics = entry.metrics, metrics.hasData {
                    let stats = groupStats
                    let problem = metrics.badgeProblem(stats: stats)
                    let topThirdFloor = stats?.topThirdScoreFloor ?? Int.max
                    QualityBadge(score: metrics.qualityScore,
                                 color: metrics.badgeColor(problem: problem,
                                                           isTopThird: metrics.qualityScore >= topThirdFloor),
                                 problem: problem,
                                 tooltipText: metrics.tooltipString)
                }
            }

            Text(entry.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            if !settings.isSimpleMode {
                HStack(spacing: 4) {
                    if let filter = entry.filterName {
                        Text(filter)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if entry.isProcessing {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView().scaleEffect(0.6) }
        } else if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: 4))
                .overlay { if entry.isRejected { RejectionOverlay() } }
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
        }
    }
}

// MARK: - Quality Badge

struct QualityBadge: View {
    let score: Int
    let color: Color
    let problem: BadgeProblem?
    let tooltipText: String

    var body: some View {
        HStack(spacing: 2) {
            if let problem {
                Image(systemName: problem.systemImage)
                    .font(.system(size: 7))
            }
            Text("\(score)")
                .font(.caption2.bold())
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(color)
        .clipShape(.rect(cornerRadius: 3))
        .foregroundStyle(.white)
        .padding(4)
        .help(tooltipText)
    }
}

// MARK: - Rejection Overlay

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.onWindow(nsView.window) }
    }
}

// MARK: - Rejection Overlay

struct RejectionOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: w, y: h))
                path.move(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: 0, y: h))
            }
            .stroke(.red, lineWidth: 3)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ImageStore())
}
