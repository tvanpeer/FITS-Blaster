//
//  SidebarViews.swift
//  FITS Blaster
//
//  Thumbnail sidebar and all of its sub-views: filter strip, folder/filter headers,
//  thumbnail cells, quality badges, and the rejection overlay.
//

import SwiftUI

// MARK: - Thumbnail Sidebar

struct ThumbnailSidebar: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    /// The last entry that received a plain or cmd+click — used as the anchor for shift+click range.
    @State private var lastClickedID: UUID? = nil

    /// Ordered list of entries currently rendered in the sidebar, used for shift+click range.
    private var visibleEntries: [ImageEntry] {
        store.sidebarNavigationEntries(isSimpleMode: settings.isSimpleMode)
    }

    var body: some View {
        @Bindable var bindableStore = store
        VStack(spacing: 0) {
            if !settings.isSimpleMode {
                // Sort controls (Geek mode only)
                HStack(spacing: 4) {
                    Text("Sort")
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                    Picker("Sort", selection: $bindableStore.thumbnailSortOrder) {
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
                    .help(store.thumbnailSortAscending ? "Sorted ascending — click to reverse" : "Sorted descending — click to reverse")
                }
                .padding(.horizontal)
                .padding(.vertical, 6)

                // Filter strip — only shown when multiple filter groups are present
                if store.isMultiFilter {
                    Divider()
                    FilterStrip(store: bindableStore)
                }

                Divider()
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        // Note: .id(store.rejectionVisibility) below forces complete
                        // recreation of the lazy container when the filter changes,
                        // ensuring stale views don't persist across filter switches.
                        if store.isMultiFolder {
                            // Multi-folder: folder sections in both simple and geek mode.
                            // Geek mode adds filter sub-headers within each folder.
                            ForEach(store.groupedByFolderAndFilter) { folderGroup in
                                let isCollapsed = store.collapsedFolderPaths.contains(folderGroup.folderPath)
                                Section {
                                    if !isCollapsed {
                                        if !settings.isSimpleMode && folderGroup.filterGroups.count > 1 {
                                            ForEach(folderGroup.filterGroups, id: \.0) { group, groupEntries in
                                                let visibleGroupEntries = groupEntries.filter { store.isVisible($0) }
                                                if !visibleGroupEntries.isEmpty {
                                                    FolderFilterSubHeader(group: group, count: visibleGroupEntries.count)
                                                    ForEach(visibleGroupEntries) { entry in
                                                        thumbnailButton(for: entry)
                                                    }
                                                }
                                            }
                                        } else {
                                            ForEach(folderGroup.filterGroups.flatMap { $0.1 }.filter { store.isVisible($0) }) { entry in
                                                thumbnailButton(for: entry)
                                            }
                                        }
                                    }
                                } header: {
                                    let visibleCount = folderGroup.filterGroups
                                        .flatMap { $0.1 }
                                        .filter { store.isVisible($0) }
                                        .count
                                    FolderSectionHeader(
                                        folderGroup: folderGroup,
                                        visibleCount: visibleCount,
                                        isCollapsed: isCollapsed
                                    ) {
                                        store.toggleFolderCollapsed(folderGroup.folderPath)
                                    }
                                }
                            }
                        } else if store.sidebarFilterGroup != nil
                            || settings.isSimpleMode
                            || !store.isMultiFilter {
                            // Flat list: simple mode (single folder), filter selected,
                            // or only one filter type present
                            ForEach(store.visibilityFilteredEntries) { entry in
                                thumbnailButton(for: entry)
                            }
                        } else {
                            // Geek mode, single folder, multiple filters: group by filter.
                            // Header is placed inline (not in a Section) to avoid Xcode 16
                            // misresolving Section as Chart.Section when Charts is in scope.
                            ForEach(store.visibilityGroupedSortedEntries, id: \.group) { group, entries in
                                FilterGroupHeader(group: group, entries: entries)
                                ForEach(entries) { entry in
                                    thumbnailButton(for: entry)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .id(store.rejectionVisibility)
                }
                .scrollIndicators(.hidden)
                .background(.background)
                .onChange(of: store.selectedEntry?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }

            Divider()
            Picker("Show", selection: $bindableStore.rejectionVisibility) {
                ForEach(RejectionVisibility.allCases, id: \.self) { v in
                    Text(v.rawValue).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .scaledFont(size: 10)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
        // When the first image is auto-selected at load time (nil → non-nil transition),
        // seed lastClickedID so shift-click works without requiring an explicit prior click.
        .onChange(of: store.selectedEntry?.id) { oldID, newID in
            if oldID == nil, let id = newID {
                lastClickedID = id
            }
        }
        // Leaving the Flagged view clears the rejection sub-selection.
        .onChange(of: store.rejectionVisibility) { _, _ in
            store.markedForRejectionIDs = []
        }
    }

    private func thumbnailButton(for entry: ImageEntry) -> some View {
        Button {
            let mods = NSEvent.modifierFlags
            if mods.contains(.command) {
                // Cmd+click: flag/unflag the range selection (or this single entry if no range).
                // In All view → add to Flagged; in Flagged view → remove from Flagged.
                let targets: Set<UUID> = store.markedForRejectionIDs.isEmpty
                    ? [entry.id]
                    : store.markedForRejectionIDs
                store.markedForRejectionIDs = []
                if store.rejectionVisibility == .active {
                    store.unflagEntries(targets)
                    if store.selectedEntry.map({ !store.flaggedEntryIDs.contains($0.id) }) == true {
                        store.selectedEntry = store.visibilityFilteredEntries.first
                    }
                    lastClickedID = store.selectedEntry?.id
                } else {
                    store.flaggedEntryIDs.formUnion(targets)
                    lastClickedID = entry.id
                }
            } else if mods.contains(.shift), let lastID = lastClickedID ?? store.selectedEntry?.id {
                // Shift+click: select a range (orange) in any view. Move cursor.
                let visible = visibleEntries
                if let fromIdx = visible.firstIndex(where: { $0.id == lastID }),
                   let toIdx   = visible.firstIndex(where: { $0.id == entry.id }) {
                    let range = fromIdx <= toIdx ? fromIdx...toIdx : toIdx...fromIdx
                    store.markedForRejectionIDs = Set(visible[range].map { $0.id })
                    store.selectedEntry = entry
                }
                lastClickedID = entry.id
            } else {
                // Plain click: move cursor, clear range selection.
                store.markedForRejectionIDs = []
                store.selectedEntry = entry
                lastClickedID = entry.id
            }
        } label: {
            ThumbnailCell(entry: entry)
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
    let visibleCount: Int
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
                Text("\(visibleCount)")
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

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let entry: ImageEntry
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @AppStorage("sessionChartMetric") private var selectedMetric: ChartMetric = .score

    private var isCursor: Bool { store.selectedEntry === entry }
    private var isFlagged: Bool { store.flaggedEntryIDs.contains(entry.id) }
    private var isMarkedForRejection: Bool { store.markedForRejectionIDs.contains(entry.id) }

    private var groupStats: GroupStats? {
        store.groupStatistics[entry.filterGroup]
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .topLeading) {
                    thumbnailImage
                    if isFlagged {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .font(.system(size: 14))
                            .padding(4)
                    }
                }
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
                    if let value = selectedMetric.value(for: entry.metrics) {
                        Text("\(selectedMetric.shortLabel) \(selectedMetric.formattedValue(value))")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMarkedForRejection ? Color.orange.opacity(0.15) :
                      isCursor ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isMarkedForRejection ? Color.orange :
                        isCursor ? Color.accentColor : Color.clear, lineWidth: 2)
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
                .overlay {
                    if entry.isRejected { RejectionOverlay() }
                    if isCursor { ViewportBox(fraction: store.viewportFraction) }
                }
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

// MARK: - Viewport Box

/// Draws a yellow rectangle on the thumbnail indicating which portion of the image
/// is currently visible in the main image viewer. Only shown when zoomed in enough
/// that the viewport covers less than the full image in at least one axis.
private struct ViewportBox: View {
    let fraction: CGRect

    var body: some View {
        if fraction.width < 0.99 || fraction.height < 0.99 {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let boxW = max(4, fraction.width  * w)
                let boxH = max(4, fraction.height * h)
                let boxX = fraction.origin.x * w + boxW / 2
                let boxY = fraction.origin.y * h + boxH / 2
                Rectangle()
                    .stroke(Color.yellow.opacity(0.9), lineWidth: 1.5)
                    .frame(width: boxW, height: boxH)
                    .position(x: boxX, y: boxY)
            }
        }
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
