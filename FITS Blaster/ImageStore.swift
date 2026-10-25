//
//  ImageStore.swift
//  FITS Blaster
//
//  Core class: stored properties, sort/filter/grouping helpers, navigation, and
//  selection. File operations live in ImageStoreFileOperations.swift; the loading
//  and reprocessing pipeline is LoadPipeline (`pipeline`), with the per-file work in
//  FrameLoading.swift.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - ImageStore

/// Manages a collection of FITS images: the session's entries, sorting, filtering,
/// grouping, navigation and selection. Loading and re-rendering are done by `pipeline`.
@Observable
@MainActor
final class ImageStore {
    var entries: [ImageEntry] = []
    var selectedEntry: ImageEntry?

    /// Loads and re-renders the entries; holds the batch state the progress UI shows.
    let pipeline = LoadPipeline()

    init() {
        pipeline.store = self
    }

    /// IDs of entries flagged for batch operations and the "Flagged" sidebar filter.
    /// Populated by cmd+click, shift+click, chart drag-select, and Auto-Flag.
    /// Completely independent of the cursor (`selectedEntry`).
    var flaggedEntryIDs: Set<UUID> = [] {
        didSet { updateVisibilityFilteredEntries() }
    }

    /// Sub-selection within the Flagged view, built by shift+click.
    /// Used only for batch reject inside that view; cleared on plain click or view switch.
    /// Has no relationship to `flaggedEntryIDs`.
    var markedForRejectionIDs: Set<UUID> = []
    var errorMessage: String?

    /// Drives the error alert: true while there is a message; dismissing the alert clears it.
    var isShowingError: Bool {
        get { errorMessage != nil }
        set { if !newValue { errorMessage = nil } }
    }
    /// Set by ⌘O in the menu; the toolbar runs the Open Folder flow and resets it.
    var openFolderRequested: Bool = false

    var thumbnailSortOrder: ThumbnailSortOrder = .filename {
        didSet { updateCachedSort() }
    }
    var thumbnailSortAscending: Bool = true {
        didSet { updateCachedSort() }
    }

    /// Remembers the last-selected entry per filter group so switching back restores the cursor.
    private var cursorPerFilterGroup: [FilterGroup?: UUID] = [:]

    /// Remembers the last-selected entry per rejection-visibility mode so switching back restores the cursor.
    private var cursorPerVisibility: [RejectionVisibility: UUID] = [:]

    /// The filter group currently highlighted in the sidebar filter strip.
    /// `nil` means "show all groups". Cleared on reset.
    var sidebarFilterGroup: FilterGroup? = nil {
        didSet {
            // Save cursor for the group we're leaving.
            if let sel = selectedEntry { cursorPerFilterGroup[oldValue] = sel.id }
            updateVisibilityFilteredEntries()
            // Restore cursor for the group we're entering, or fall back to first visible.
            if let savedID = cursorPerFilterGroup[sidebarFilterGroup],
               let entry = entries.first(where: { $0.id == savedID }),
               isVisible(entry) {
                selectedEntry = entry
            } else {
                ensureCursorVisible()
            }
        }
    }

    /// Controls which images are visible in the sidebar and session chart.
    var rejectionVisibility: RejectionVisibility = .all {
        didSet {
            if let sel = selectedEntry { cursorPerVisibility[oldValue] = sel.id }
            updateVisibilityFilteredEntries()
            if let savedID = cursorPerVisibility[rejectionVisibility],
               let entry = entries.first(where: { $0.id == savedID }),
               isVisible(entry) {
                selectedEntry = entry
            } else {
                ensureCursorVisible()
            }
        }
    }

    // MARK: - Folder grouping

    /// Display name of the root folder most recently opened via the panel or drag-drop.
    /// Shown as the section header for root-level files in subfolder mode.
    /// Internal (not private(set)) so the file-operations extension can update it.
    var rootFolderName: String = ""

    /// Root folder URLs that have been opened in this session.
    /// Used to detect when the user opens the same directory a second time.
    /// Internal (not private) so the file-operations extension can update it.
    var knownRootURLs: Set<URL> = []

    /// Security-scoped bookmarks of the folders opened, dropped or granted in this run
    /// of the app, by folder. Each new frame gets the bookmark of the folder it is in
    /// (CODE_AUDIT §5.13). Kept on Reset: the access stays valid until the app quits.
    var sessionBookmarks: [URL: Data] = [:]

    /// Set when rejecting needs access to a folder the sandbox hasn't granted;
    /// ContentView asks the user. See `FolderAccessRequest`.
    var folderAccessRequest: FolderAccessRequest?

    /// Whether a missing folder permission is answered with `folderAccessRequest`. Only
    /// in the sandboxed (App Store) build: without the sandbox a permission error is a
    /// real one (e.g. a read-only share) and is reported as an error.
    var asksForFolderAccess = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    /// Sorted list of unique subfolder paths present across all loaded entries.
    /// Empty string ("") represents root-level files. Updated at batch boundaries.
    private(set) var activeFolderPaths: [String] = []

    /// Entries grouped first by subfolder, then by filter, ready for sidebar rendering.
    /// Stored (not computed) to avoid O(n) re-derivation on every SwiftUI render pass.
    /// Updated only at batch boundaries alongside `groupStatistics`.
    private(set) var groupedByFolderAndFilter: [FolderGroup] = []

    /// Folder paths whose thumbnail rows are currently collapsed in the sidebar.
    /// Stored here (not in the view) so keyboard navigation can skip hidden entries.
    var collapsedFolderPaths: Set<String> = []

    func toggleFolderCollapsed(_ path: String) {
        if collapsedFolderPaths.contains(path) {
            collapsedFolderPaths.remove(path)
        } else {
            collapsedFolderPaths.insert(path)
        }
    }

    // MARK: - Filter grouping

    /// Unique filter groups present in the loaded session, in canonical display order.
    /// Stored (not computed) to avoid O(n) Set creation on every sidebar render.
    /// Updated at batch boundaries via `updateActiveFilterGroups()`.
    private(set) var activeFilterGroups: [FilterGroup] = []

    /// True when more than one filter type is present in the loaded session.
    var isMultiFilter: Bool { activeFilterGroups.count > 1 }

    /// True when entries span more than one subfolder.
    var isMultiFolder: Bool { activeFolderPaths.count > 1 }

    func updateActiveFilterGroups() {
        let present = Set(entries.map { $0.filterGroup })
        activeFilterGroups = FilterGroup.allCases.filter { present.contains($0) }
    }

    /// IDs of all entries rejected during this session.
    /// Stored as a `Set<UUID>` so `visibilityFilteredEntries` and related computed
    /// properties can read it directly — giving the `@Observable` system a concrete
    /// stored-property dependency to track, rather than relying on per-`ImageEntry`
    /// observation which `ImageStore` cannot register.
    /// Internal (not private(set)) so the file-operations extension can update it.
    var rejectedEntryIDs: Set<UUID> = []

    /// Cached sorted result of `entries` — avoids an O(n log n) sort on every render.
    /// Updated when sort settings change (`didSet`) or at batch boundaries.
    private(set) var cachedSortedEntries: [ImageEntry] = []

    func updateCachedSort() {
        let asc = thumbnailSortAscending
        switch thumbnailSortOrder {
        case .filename:
            cachedSortedEntries = asc ? entries : entries.reversed()
        case .byMetric(let metric):
            cachedSortedEntries = entries.sorted { a, b in
                let av = metric.value(from: a.metrics)
                let bv = metric.value(from: b.metrics)
                switch (av, bv) {
                case let (av?, bv?): return asc ? av < bv : av > bv
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .rejected:
            // Rejected entries sort to the bottom (asc) or top (desc).
            // Within each group, alphabetical by filename.
            cachedSortedEntries = entries.sorted { a, b in
                if a.isRejected != b.isRejected {
                    return asc ? !a.isRejected : a.isRejected
                }
                return a.fileName.localizedStandardCompare(b.fileName) == .orderedAscending
            }
        }
        updateGroupedByFolderAndFilter()
        updateVisibilityFilteredEntries()
    }

    /// `sortedEntries` filtered to the sidebar selection, or all entries when no
    /// filter is active.
    var filteredSortedEntries: [ImageEntry] {
        guard let group = sidebarFilterGroup else { return sortedEntries }
        return sortedEntries.filter { $0.filterGroup == group }
    }

    /// Whether `entry` should be shown given the current `rejectionVisibility`.
    /// Uses stored-property sets so callers that read this method from a SwiftUI view
    /// body establish a proper `@Observable` dependency on `ImageStore`.
    func isVisible(_ entry: ImageEntry) -> Bool {
        // Filter-strip selection: hide entries that don't match the selected group.
        if let group = sidebarFilterGroup, entry.filterGroup != group {
            return false
        }
        switch rejectionVisibility {
        case .all:      return true
        case .active:   return flaggedEntryIDs.contains(entry.id)
        case .rejected: return rejectedEntryIDs.contains(entry.id)
        }
    }

    /// Sidebar-visible entries: `filteredSortedEntries` filtered by `rejectionVisibility`.
    ///
    /// **Stored property** — never computed on-demand. Updated synchronously by
    /// `updateVisibilityFilteredEntries()` which is called from every write path that
    /// affects its value: reject/undo, picker change (`rejectionVisibility.didSet`),
    /// filter-strip change (`sidebarFilterGroup.didSet`), and sort/load boundaries.
    /// Storing rather than computing ensures SwiftUI sees a plain stored-property mutation
    /// and reliably invalidates every view that reads it.
    private(set) var visibilityFilteredEntries: [ImageEntry] = []

    func updateVisibilityFilteredEntries() {
        let base = filteredSortedEntries
        switch rejectionVisibility {
        case .all:      visibilityFilteredEntries = base
        case .active:   visibilityFilteredEntries = base.filter { flaggedEntryIDs.contains($0.id) }
        case .rejected: visibilityFilteredEntries = base.filter { rejectedEntryIDs.contains($0.id) }
        }
    }

    /// `sortedEntries` grouped by filter group, in canonical FilterGroup order,
    /// filtered by `rejectionVisibility`. Groups with no visible entries are omitted.
    var visibilityGroupedSortedEntries: [(group: FilterGroup, entries: [ImageEntry])] {
        let rejIDs = rejectedEntryIDs
        let flgIDs = flaggedEntryIDs
        let vis = rejectionVisibility
        let grouped = Dictionary(grouping: sortedEntries) { $0.filterGroup }
        return FilterGroup.allCases.compactMap { group in
            guard let all = grouped[group] else { return nil }
            let visible: [ImageEntry]
            switch vis {
            case .all:      visible = all
            case .active:   visible = all.filter { flgIDs.contains($0.id) }
            case .rejected: visible = all.filter { rejIDs.contains($0.id) }
            }
            return visible.isEmpty ? nil : (group: group, entries: visible)
        }
    }

    /// Per-group statistics used for relative badge thresholds and auto-reject.
    ///
    /// Stored (not computed) so that individual per-entry metrics updates during a batch
    /// do not cause every visible ThumbnailCell to re-render and recompute O(n) stats.
    /// Updated only at batch boundaries via `updateGroupStatistics()`.
    private(set) var groupStatistics: [FilterGroup: GroupStats] = [:]

    func updateGroupStatistics() {
        let grouped = Dictionary(grouping: entries) { $0.filterGroup }
        var result: [FilterGroup: GroupStats] = [:]
        for group in FilterGroup.allCases {
            guard let groupEntries = grouped[group], !groupEntries.isEmpty else { continue }
            let fwhms  = groupEntries.compactMap { $0.metrics?.fwhm }.sorted()
            let eccs   = groupEntries.compactMap { $0.metrics?.eccentricity }.sorted()
            let stars  = groupEntries.compactMap { $0.metrics?.starCount }.sorted()
            let snrs   = groupEntries.compactMap { $0.metrics?.snr }.sorted()
            let scores = groupEntries.compactMap { $0.metrics?.qualityScore }.sorted()
            let bgs    = groupEntries.compactMap { $0.metrics?.skyBackground }.sorted()
            let psfs   = groupEntries.compactMap { $0.metrics?.psfSignalWeight }.sorted()
            result[group] = GroupStats(
                medianFWHM:            fwhms.isEmpty  ? nil : fwhms[fwhms.count / 2],
                medianEccentricity:    eccs.isEmpty   ? nil : eccs[eccs.count / 2],
                medianStarCount:       stars.isEmpty  ? nil : stars[stars.count / 2],
                medianSNR:             snrs.isEmpty   ? nil : snrs[snrs.count / 2],
                medianScore:           scores.isEmpty ? nil : scores[scores.count / 2],
                medianSkyBackground:   bgs.isEmpty    ? nil : bgs[bgs.count / 2],
                medianPSFSignalWeight: psfs.isEmpty   ? nil : psfs[psfs.count / 2],
                topThirdScoreFloor:    scores.count < 3 ? nil : scores[scores.count * 2 / 3],
                isNarrowband:          group.isNarrowband
            )
        }
        groupStatistics = result
        updateActiveFilterGroups()
        updateCachedSort()
    }

    private func updateGroupedByFolderAndFilter() {
        // Group by qualifiedFolderPath so identically-named subfolders from different
        // root folders are kept separate (e.g. "Session A/lights" vs "Session B/lights").
        let byFolder = Dictionary(grouping: sortedEntries) { $0.qualifiedFolderPath }
        let allPaths = byFolder.keys.sorted { lhs, rhs in
            if lhs.isEmpty { return true }   // root-level files sort first
            if rhs.isEmpty { return false }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
        activeFolderPaths = allPaths

        let hasMultipleRoots = Set(sortedEntries.map { $0.rootFolderName }).count > 1

        groupedByFolderAndFilter = allPaths.compactMap { qualifiedPath in
            guard let pathEntries = byFolder[qualifiedPath], !pathEntries.isEmpty else { return nil }
            let first = pathEntries[0]

            // Build a display name that is unambiguous across multiple root folders.
            let displayName: String
            if hasMultipleRoots {
                displayName = first.subfolderPath.isEmpty
                    ? first.rootFolderName
                    : "\(first.rootFolderName) / \(first.subfolderPath)"
            } else {
                displayName = first.subfolderPath.isEmpty ? rootFolderName : first.subfolderPath
            }

            let byFilter = Dictionary(grouping: pathEntries) { $0.filterGroup }
            let filterGroups: [(FilterGroup, [ImageEntry])] = FilterGroup.allCases.compactMap { group in
                guard let groupEntries = byFilter[group], !groupEntries.isEmpty else { return nil }
                return (group, groupEntries)
            }
            return FolderGroup(rootFolderName: first.rootFolderName,
                               folderPath: qualifiedPath,
                               folderDisplayName: displayName,
                               filterGroups: filterGroups)
        }
    }

    var sortedEntries: [ImageEntry] { cachedSortedEntries }

    // MARK: - Reset

    /// Removes the current selection from the list without touching files on disk.
    /// Selects the next entry after the removed block, or the previous if at the end.
    func removeSelected() {
        let idsToRemove: Set<UUID> = !flaggedEntryIDs.isEmpty
            ? flaggedEntryIDs
            : selectedEntry.map { [$0.id] } ?? []
        guard !idsToRemove.isEmpty else { return }

        // Find a replacement selection from the current sorted order.
        let ordered = sortedEntries
        let firstRemovedIdx = ordered.firstIndex { idsToRemove.contains($0.id) }

        // Pick the first non-removed entry at or after the first removal point.
        let nextEntry: ImageEntry?
        if let idx = firstRemovedIdx {
            nextEntry = ordered[idx...].first { !idsToRemove.contains($0.id) }
                ?? ordered.last { !idsToRemove.contains($0.id) }
        } else {
            nextEntry = ordered.first { !idsToRemove.contains($0.id) }
        }

        entries.removeAll { idsToRemove.contains($0.id) }
        flaggedEntryIDs = []
        // Removed IDs must not linger in the other selection state (CODE_AUDIT §5.15).
        markedForRejectionIDs.subtract(idsToRemove)
        rejectedEntryIDs.subtract(idsToRemove)
        cursorPerFilterGroup = cursorPerFilterGroup.filter { !idsToRemove.contains($0.value) }
        cursorPerVisibility = cursorPerVisibility.filter { !idsToRemove.contains($0.value) }
        selectedEntry = nextEntry
        updateGroupStatistics()
    }

    func reset() {
        entries = []
        rejectionVisibility = .all
        selectedEntry = nil
        flaggedEntryIDs = []
        markedForRejectionIDs = []
        rejectedEntryIDs = []
        pipeline.clearBatchState()
        errorMessage = nil
        sidebarFilterGroup = nil
        cursorPerFilterGroup = [:]
        cursorPerVisibility = [:]
        groupStatistics = [:]
        activeFilterGroups = []
        cachedSortedEntries = []
        rootFolderName = ""
        knownRootURLs = []
        activeFolderPaths = []
        groupedByFolderAndFilter = []
        collapsedFolderPaths = []
        visibilityFilteredEntries = []
    }

    // MARK: - Range selection helpers (Cmd+A / Cmd+D / Cmd+I)

    /// Selects all currently-visible entries as the orange range. Cursor is unchanged.
    func selectAllVisible() {
        let visible = visibilityFilteredEntries
        guard !visible.isEmpty else { return }
        markedForRejectionIDs = Set(visible.map { $0.id })
    }

    /// Orange-selects all rejected entries visible in the current view.
    /// In the Flagged view this is only rejected frames that were also flagged;
    /// in All it is every rejected frame; in Rejected it is the full list.
    func selectAllRejected() {
        let rejected = visibilityFilteredEntries.filter { $0.isRejected }
        guard !rejected.isEmpty else { NSSound.beep(); return }
        markedForRejectionIDs = Set(rejected.map { $0.id })
        selectedEntry = rejected.first
    }

    /// Clears the orange range selection. Cursor is unchanged.
    func deselectAll() {
        markedForRejectionIDs = []
    }

    /// Inverts the orange range selection within the currently-visible entries.
    func invertSelection() {
        let visible = visibilityFilteredEntries
        guard !visible.isEmpty else { return }
        markedForRejectionIDs = Set(visible.map { $0.id }).subtracting(markedForRejectionIDs)
    }

    // MARK: - Extend selection

    /// Extends the range selection one step toward earlier entries and moves the cursor.
    func extendSelectionPrevious(in ordered: [ImageEntry]) {
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else { return }
        guard index > 0 else { NSSound.beep(); return }
        let target = ordered[index - 1]
        if markedForRejectionIDs.isEmpty { markedForRejectionIDs.insert(current.id) }
        markedForRejectionIDs.insert(target.id)
        selectedEntry = target
    }

    /// Extends the range selection one step toward later entries and moves the cursor.
    func extendSelectionNext(in ordered: [ImageEntry]) {
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else { return }
        guard index < ordered.count - 1 else { NSSound.beep(); return }
        let target = ordered[index + 1]
        if markedForRejectionIDs.isEmpty { markedForRejectionIDs.insert(current.id) }
        markedForRejectionIDs.insert(target.id)
        selectedEntry = target
    }

    // MARK: - Navigation

    /// Returns entries in the same order they appear in the thumbnail sidebar,
    /// so keyboard navigation (↑/↓) matches visual position in the strip.
    ///
    /// - In simple mode, with a filter selected, or with a single folder+filter:
    ///   the sidebar is a flat list — return `visibilityFilteredEntries`.
    /// - Multi-folder: entries follow folder → filter section order.
    /// - Single folder, multiple filters: entries follow filter-group section order.
    func sidebarNavigationEntries(isSimpleMode: Bool) -> [ImageEntry] {
        // Multi-folder: always navigate in folder → filter section order, skipping collapsed.
        // Applies in both simple and geek mode since both show folder headers.
        if isMultiFolder {
            return groupedByFolderAndFilter
                .filter { !collapsedFolderPaths.contains($0.folderPath) }
                .flatMap { folder in folder.filterGroups.flatMap { $0.1 } }
                .filter { isVisible($0) }
        }
        // Simple mode (single folder) or a filter strip selection: flat list.
        if isSimpleMode || sidebarFilterGroup != nil || !isMultiFilter {
            return visibilityFilteredEntries
        }
        // Geek mode, single folder, multiple filters — grouped by filter type.
        return visibilityGroupedSortedEntries.flatMap { $0.entries }
    }

    func selectFirst(in ordered: [ImageEntry]) {
        guard let first = ordered.first else { return }
        if selectedEntry === first { NSSound.beep() } else { selectedEntry = first }
    }

    func selectLast(in ordered: [ImageEntry]) {
        guard let last = ordered.last else { return }
        if selectedEntry === last { NSSound.beep() } else { selectedEntry = last }
    }

    func selectPrevious(in ordered: [ImageEntry]) {
        guard !ordered.isEmpty else { return }
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else {
            selectedEntry = ordered.first
            return
        }
        if index == 0 {
            NSSound.beep()
        } else {
            selectedEntry = ordered[index - 1]
        }
    }

    func selectNext(in ordered: [ImageEntry]) {
        guard !ordered.isEmpty else { return }
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else {
            selectedEntry = ordered.first
            return
        }
        if index == ordered.count - 1 {
            NSSound.beep()
        } else {
            selectedEntry = ordered[index + 1]
        }
    }

    /// If the cursor entry is no longer visible (e.g. after reject or unflag),
    /// selects the nearest visible neighbour from the pre-action ordered list.
    func advanceCursorIfNeeded(from previousOrder: [ImageEntry]) {
        guard let sel = selectedEntry, !isVisible(sel) else { return }
        guard let idx = previousOrder.firstIndex(where: { $0 === sel }) else { return }
        // Try the next entry in the old order, then fall back to the previous one.
        selectedEntry = previousOrder[(idx + 1)...].first(where: { isVisible($0) })
            ?? previousOrder[..<idx].last(where: { isVisible($0) })
    }

    /// Selects the first visible entry when the current selection is hidden
    /// (e.g. after switching filter group or rejection visibility).
    private func ensureCursorVisible() {
        guard let sel = selectedEntry, !isVisible(sel) else { return }
        selectedEntry = visibilityFilteredEntries.first
    }

    /// Toggles rejection for the range selection, or the cursor entry if no range is active.
    func toggleRejectSelected() {
        if !markedForRejectionIDs.isEmpty {
            let batch = entries.filter { markedForRejectionIDs.contains($0.id) }
            if batch.allSatisfy({ $0.isRejected }) {
                batch.forEach { undoRejectEntry($0) }
            } else {
                batch.filter { !$0.isRejected }.forEach { rejectEntry($0) }
            }
        } else {
            guard let entry = selectedEntry else { return }
            if entry.isRejected { undoRejectSelected() } else { rejectSelected() }
        }
    }
}
