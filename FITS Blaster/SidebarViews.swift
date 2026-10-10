//
//  SidebarViews.swift
//  FITS Blaster
//
//  Thumbnail sidebar and filter strip. Supporting sub-views are in their own files:
//  FilterChip, FilterGroupHeader, FolderSectionHeader, ThumbnailCell, QualityBadge, RejectionOverlay.
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
                        ForEach(ThumbnailSortOrder.allSortOptions, id: \.self) { order in
                            Text(order.label).tag(order)
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
                                FilterGroupHeader(group: group, entryCount: entries.count,
                                                     stats: store.groupStatistics[group])
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
        WrappingChips(spacing: 5) {
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
}

