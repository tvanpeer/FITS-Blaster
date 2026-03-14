//
//  ContentView.swift
//  FITS Blaster
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
    @State private var keyMonitor: Any?

    var body: some View {
        HSplitView {
            ThumbnailSidebar(store: store)
                .frame(minWidth: 140, idealWidth: 165, maxWidth: 220)

            VStack(spacing: 0) {
                FITSToolbar(store: store)
                Divider()
                if settings.isSimpleMode {
                    MainContent(store: store)
                } else {
                    ResizableChartLayout()
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
        .focusedSceneValue(\.simpleModeBinding, Binding(
            get: { settings.isSimpleMode },
            set: { settings.isSimpleMode = $0 }
        ))
        .focusedSceneValue(\.debayerColorBinding, Binding(
            get: { settings.debayerColorImages },
            set: { settings.debayerColorImages = $0 }
        ))
        .focusedSceneValue(\.toggleModeKeyString, settings.toggleModeKey)
        .focusedSceneValue(\.debayerKeyString, settings.debayerKey)
        .frame(minWidth: minWindowWidth, minHeight: 400)
        .environment(\.fontSizeMultiplier, settings.fontSizeMultiplier)
        .preferredColorScheme(settings.preferredColorScheme)
        .background(WindowAccessor { hostingWindow = $0 })
        .onChange(of: settings.metricsConfig) { _, newConfig in
            guard !settings.isSimpleMode else { return }
            store.recomputeMetrics(metricsConfig: newConfig)
        }
        .onChange(of: settings.debayerColorImages) { _, _ in
            guard !store.entries.isEmpty else { return }
            store.recolorImages(settings: settings)
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
        .onAppear { installKeyMonitor() }
        .onDisappear { removeKeyMonitor() }
    }

    private var minWindowWidth: CGFloat {
        if settings.isSimpleMode { return 500 }
        return settings.showInspector ? 960 : 700
    }

    // MARK: - Key handling

    /// Installs a window-level key monitor so navigation keys work regardless of
    /// which subview (e.g. the sidebar List) currently holds keyboard focus.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                // Don't steal from text inputs.
                guard !(NSApp.keyWindow?.firstResponder is NSText) else { return event }
                // Don't intercept events with command/option/control modifiers.
                guard event.modifierFlags.intersection([.command, .option, .control]).isEmpty else { return event }
                guard let key = Self.keyString(from: event) else { return event }
                return self.handleKey(key) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Converts an NSEvent to the key-string format used by AppSettings (e.g. "↑", "x", " ").
    private static func keyString(from event: NSEvent) -> String? {
        if let special = event.specialKey {
            switch special {
            case .upArrow:    return "↑"
            case .downArrow:  return "↓"
            case .leftArrow:  return "←"
            case .rightArrow: return "→"
            case .home:       return "⇱"
            case .end:        return "⇲"
            default:          return nil
            }
        }
        return event.characters?.lowercased()
    }

    /// Returns true and performs the action if the key matches a configured binding.
    @discardableResult
    private func handleKey(_ key: String) -> Bool {
        switch key {
        case settings.firstImageKey:  store.selectFirst();  return true
        case settings.lastImageKey:   store.selectLast();   return true
        case settings.prevImageKey:   store.selectPrevious(); return true
        case settings.nextImageKey:   store.selectNext();   return true
        case settings.rejectKey:
            if settings.useToggleReject { store.toggleRejectSelected() } else { store.rejectSelected() }
            return true
        case settings.undoKey:
            guard !settings.useToggleReject else { return false }
            store.undoRejectSelected()
            return true
        case settings.toggleModeKey:  settings.isSimpleMode.toggle();          return true
        case settings.removeKey:      store.removeSelected();                   return true
        case settings.debayerKey:     settings.debayerColorImages.toggle();     return true
        default:                      return false
        }
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

// MARK: - Resizable Chart Layout

/// A VStack containing the main image and session chart, separated by a draggable
/// handle that persists the chart height across launches via AppStorage.
private struct ResizableChartLayout: View {
    @Environment(ImageStore.self) private var store
    @AppStorage("sessionChartHeight") private var chartHeight: Double = 200

    /// Captured at the start of each drag so we can compute relative offset.
    @State private var heightAtDragStart: Double = 200

    var body: some View {
        VStack(spacing: 0) {
            MainContent(store: store)
                .frame(minHeight: 180)

            // Drag handle
            Rectangle()
                .fill(Color.secondary.opacity(0.15))
                .frame(height: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 32, height: 3)
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // Dragging up = negative translation = chart taller
                            chartHeight = max(80, min(600,
                                heightAtDragStart - value.translation.height))
                        }
                        .onEnded { _ in
                            heightAtDragStart = chartHeight
                        }
                )

            SessionChartView()
                .frame(height: chartHeight)
        }
        .onAppear { heightAtDragStart = chartHeight }
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

    /// Folder paths whose thumbnail rows are currently hidden.
    @State private var collapsedFolderPaths: Set<String> = []

    /// Ordered list of entries currently rendered in the sidebar, used for shift+click range.
    private var visibleEntries: [ImageEntry] {
        if settings.isSimpleMode { return store.entries }
        // A filter is selected, or there's only one folder and one filter: show flat filtered list.
        if store.sidebarFilterGroup != nil
            || (!store.isMultiFilter && !store.isMultiFolder) {
            return store.filteredSortedEntries
        }
        // Multi-folder mode: return entries in folder → filter section order, skipping collapsed.
        if store.isMultiFolder {
            return store.groupedByFolderAndFilter
                .filter { !collapsedFolderPaths.contains($0.folderPath) }
                .flatMap { folder in folder.filterGroups.flatMap { $0.1 } }
        }
        // Single folder, multi-filter: existing filter-grouped order.
        return store.groupedSortedEntries.flatMap { $0.entries }
    }

    var body: some View {
        VStack(spacing: 0) {
            if !settings.isSimpleMode {
                // Sort controls (Geek mode only)
                HStack(spacing: 4) {
                    Text("Sort")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                    Picker("Sort", selection: $store.thumbnailSortOrder) {
                        ForEach(ThumbnailSortOrder.allCases, id: \.self) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .scaledFont(size: 10)
                    Button(store.thumbnailSortAscending ? "Sort Ascending" : "Sort Descending",
                           systemImage: store.thumbnailSortAscending ? "arrow.up" : "arrow.down") {
                        store.thumbnailSortAscending.toggle()
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .scaledFont(size: 10)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                // Filter strip — only shown when multiple filter groups are present
                if store.isMultiFilter {
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
                        } else if store.sidebarFilterGroup != nil
                            || (!store.isMultiFilter && !store.isMultiFolder) {
                            // Flat list: a filter is selected, or there's only one folder+filter
                            ForEach(store.filteredSortedEntries) { entry in
                                thumbnailButton(for: entry)
                            }
                        } else if store.isMultiFolder {
                            // Folder mode: one section per subfolder, with optional filter sub-headers
                            ForEach(store.groupedByFolderAndFilter) { folderGroup in
                                let isCollapsed = collapsedFolderPaths.contains(folderGroup.folderPath)
                                Section {
                                    if !isCollapsed {
                                        if folderGroup.filterGroups.count > 1 {
                                            ForEach(folderGroup.filterGroups, id: \.0) { group, groupEntries in
                                                FolderFilterSubHeader(group: group, count: groupEntries.count)
                                                ForEach(groupEntries) { entry in
                                                    thumbnailButton(for: entry)
                                                }
                                            }
                                        } else {
                                            ForEach(folderGroup.filterGroups.first?.1 ?? []) { entry in
                                                thumbnailButton(for: entry)
                                            }
                                        }
                                    }
                                } header: {
                                    FolderSectionHeader(
                                        folderGroup: folderGroup,
                                        isCollapsed: isCollapsed
                                    ) {
                                        if isCollapsed {
                                            collapsedFolderPaths.remove(folderGroup.folderPath)
                                        } else {
                                            collapsedFolderPaths.insert(folderGroup.folderPath)
                                        }
                                    }
                                }
                            }
                        } else {
                            // Single folder, multiple filters: group by filter
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
                .scaledFont(size: 9, weight: .bold)
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
                .scaledFont(size: 10, weight: .bold)
            Text("\(entries.count)")
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
            Spacer()
            if let fwhm = medianFWHM {
                Text("\(fwhm, format: .number.precision(.fractionLength(1)))px")
                    .scaledFont(size: 9, monospaced: true)
                    .foregroundStyle(.secondary)
            }
            if let score = medianScore {
                Text("▸\(score)")
                    .scaledFont(size: 9, monospaced: true)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.regularMaterial)
    }
}

// MARK: - Folder section header

struct FolderSectionHeader: View {
    let folderGroup: FolderGroup
    let isCollapsed: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 5) {
                Image(systemName: "chevron.right")
                    .scaledFont(size: 9)
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
                Image(systemName: "folder")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                Text(folderGroup.folderDisplayName)
                    .scaledFont(size: 10, weight: .bold)
                Text("\(folderGroup.totalCount)")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(.regularMaterial)
        }
        .buttonStyle(.plain)
    }
}

/// Inline filter sub-header used inside a folder section when a single folder
/// contains images from more than one filter group.
struct FolderFilterSubHeader: View {
    let group: FilterGroup
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(group.color)
                .frame(width: 6, height: 6)
            Text(group.rawValue)
                .scaledFont(size: 9, weight: .bold)
            Text("\(count)")
                .scaledFont(size: 9)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
        .padding(.vertical, 3)
        .background(.quinary)
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
                    .scaledFont(size: 10)
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
            .help(settings.isSimpleMode ? "Switch to Geek Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))" : "Switch to Simple Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))")

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
                        .scaledFont(size: 10)
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
                        .scaledFont(size: 10)
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
                    .scaledFont(size: 10)
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
                Text("Processing…").scaledFont(size: 10).foregroundStyle(.secondary)
            } else if let msg = store.recolouringMessage {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text(msg).scaledFont(size: 10).foregroundStyle(.secondary)
            } else if let elapsed = store.batchElapsed {
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(store.entries.count) images")
                    .scaledFont(size: 10, monospaced: true)
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
                    .scaledFont(size: 10)
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
        .scaledFont(size: 10, monospaced: true)
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
                .scaledFont(size: 9)
                .lineLimit(1)
                .truncationMode(.middle)

            if !settings.isSimpleMode {
                HStack(spacing: 4) {
                    if let filter = entry.filterName {
                        Text(filter)
                            .scaledFont(size: 9)
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
                    .scaledFont(size: 7)
            }
            Text("\(score)")
                .scaledFont(size: 9, weight: .bold)
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
        Task { @MainActor in self.onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in self.onWindow(nsView.window) }
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
