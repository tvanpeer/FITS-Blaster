//
//  ImageStore.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Thumbnail sort order

enum ThumbnailSortOrder: String, CaseIterable {
    case filename     = "Name"
    case qualityScore = "Score"
    case fwhm         = "FWHM"
    case eccentricity = "Eccentricity"
    case snr          = "SNR"
    case starCount    = "Stars"
    case rejected     = "Rejected"
}

// MARK: - Export format

enum ExportFormat: String, CaseIterable {
    case plainText
    case csv

    var displayName: String {
        switch self {
        case .plainText: "Plain text (.txt)"
        case .csv:       "CSV with metrics (.csv)"
        }
    }
}

// MARK: - ImageEntry

/// Represents a single loaded FITS image entry with its processing state
@Observable
@MainActor
final class ImageEntry: Identifiable {
    let id = UUID()
    var url: URL
    let originalURL: URL
    let fileName: String

    /// The stretched full-size display image (kept in memory for fast switching)
    var displayImage: NSImage?

    /// A small thumbnail for the sidebar
    var thumbnail: NSImage?

    /// Image dimensions and metadata summary
    var imageInfo: String = ""

    /// Whether this entry is still being processed
    var isProcessing: Bool = true

    /// Whether this image has been rejected (file moved to REJECTED subdirectory)
    var isRejected: Bool = false

    /// Security-scoped bookmark for the parent directory (needed for file moves)
    var directoryBookmark: Data?

    /// Error message if loading/stretching failed
    var errorMessage: String?

    /// Quality metrics computed from raw pixel data (nil if disabled or not yet available)
    var metrics: FrameMetrics?

    /// Full set of ever-computed metric values — preserved across config toggle changes
    /// so re-enabling a metric never requires re-reading the FITS file.
    var cachedMetrics: FrameMetrics?

    /// 256-bin pixel histogram from raw float data (nil until loaded)
    var histogram: [Int]?

    /// All FITS header key-value pairs parsed from the file
    var headers: [String: String] = [:]

    /// The FILTER header value, cleaned of FITS string quoting
    var filterName: String? {
        guard let raw = headers["FILTER"] else { return nil }
        let cleaned = FITSReader.cleanHeaderString(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Canonical filter group derived from the raw FILTER header value.
    var filterGroup: FilterGroup { FilterGroup.normalise(filterName) }

    /// True if this image contains raw Bayer CFA data (BAYERPAT/COLORTYP/CFA_PAT header present).
    var isBayer: Bool { BayerPattern.parse(from: headers) != nil }

    /// Per-channel clip bounds computed during the grey-pass for Bayer images.
    /// Used by the post-batch normalisation step to compute per-folder median clips
    /// before re-rendering in colour with a consistent shared stretch.
    var bayerClips: BayerClips?

    /// Cached greyscale render (display + thumbnail) for Bayer images.
    /// Populated on first greyscale render; reused on subsequent toggles to avoid re-reads.
    var cachedGreyscaleDisplay: NSImage?
    var cachedGreyscaleThumb: NSImage?

    /// Cached colour render (display + thumbnail) for Bayer images.
    /// Populated on first colour render; reused on subsequent toggles to avoid re-reads.
    var cachedColourDisplay: NSImage?
    var cachedColourThumb: NSImage?

    /// Relative path from the opened root folder to this file's parent directory.
    /// Empty string means the file sits directly in the opened root folder.
    /// Example: "Ha" for `root/Ha/frame.fits`, "Lights/Ha" for deeper nesting.
    var subfolderPath: String = ""

    /// Display name of the root folder this entry was loaded from.
    /// Used to disambiguate identically-named subfolders across different root folders.
    var rootFolderName: String = ""

    /// Fully qualified folder path combining root folder name and subfolder path.
    /// Used as the grouping key in sidebar and chart to prevent name collisions
    /// when multiple root folders contain subfolders with the same name.
    var qualifiedFolderPath: String {
        if rootFolderName.isEmpty { return subfolderPath }
        if subfolderPath.isEmpty  { return rootFolderName }
        return "\(rootFolderName)/\(subfolderPath)"
    }

    init(url: URL, directoryBookmark: Data? = nil) {
        self.url = url
        self.originalURL = url
        self.fileName = url.lastPathComponent
        self.directoryBookmark = directoryBookmark
    }
}

// MARK: - FolderGroup

/// One subfolder's worth of entries, pre-grouped by filter for sidebar rendering.
struct FolderGroup: Identifiable {
    /// Display name of the root folder this group belongs to.
    let rootFolderName: String
    /// Qualified path: "\(rootFolderName)/\(subfolderPath)", or just subfolderPath
    /// when there is only one root folder. Used as the stable unique identifier.
    let folderPath: String
    /// Short name shown in section headers and folder pills.
    let folderDisplayName: String
    /// Entries split by their canonical filter group, in FilterGroup canonical order.
    let filterGroups: [(FilterGroup, [ImageEntry])]

    var id: String { folderPath }
    var totalCount: Int { filterGroups.reduce(0) { $0 + $1.1.count } }
}

// MARK: - ImageStore

/// Manages a collection of FITS images, handling loading and stretching.
///
/// Uses a bounded concurrent pipeline to maximize throughput:
/// CPU-bound work (FITS reading, stretching, metrics) runs in a nonisolated
/// async function so the main actor stays responsive during loading.
@Observable
@MainActor
final class ImageStore {
    var entries: [ImageEntry] = []
    var selectedEntry: ImageEntry?

    /// IDs of all entries in the multi-selection. When this contains more than
    /// one entry, reject/undo operations apply to the whole set.
    /// Any newly added IDs are automatically added to `flaggedEntryIDs` as well.
    var selectedEntryIDs: Set<UUID> = [] {
        didSet {
            let added = selectedEntryIDs.subtracting(oldValue)
            if !added.isEmpty { flaggedEntryIDs = flaggedEntryIDs.union(added) }
        }
    }
    /// IDs of entries flagged for inspection (drives the "Selected" sidebar filter).
    /// Populated by chart drag-select and Auto-Flag; independent of the multi-selection.
    var flaggedEntryIDs: Set<UUID> = [] {
        didSet { updateVisibilityFilteredEntries() }
    }
    var batchElapsed: Double?
    var isBatchProcessing: Bool = false
    /// The currently running load / reprocess task. Stored so it can be cancelled by the user.
    private(set) var processingTask: Task<Void, Never>?
    /// Non-nil while a Bayer re-render pass is running; the value is the status message to display.
    private(set) var recolouringMessage: String? = nil
    var errorMessage: String?
    var thumbnailSortOrder: ThumbnailSortOrder = .filename {
        didSet { updateCachedSort() }
    }
    var thumbnailSortAscending: Bool = true {
        didSet { updateCachedSort() }
    }

    /// The filter group currently highlighted in the sidebar filter strip.
    /// `nil` means "show all groups". Cleared on reset.
    var sidebarFilterGroup: FilterGroup? = nil {
        didSet { updateVisibilityFilteredEntries() }
    }

    /// Controls which images are visible in the sidebar and session chart.
    var rejectionVisibility: RejectionVisibility = .all {
        didSet { updateVisibilityFilteredEntries() }
    }

    // MARK: - Folder grouping

    /// Display name of the root folder most recently opened via the panel or drag-drop.
    /// Shown as the section header for root-level files in subfolder mode.
    private(set) var rootFolderName: String = ""

    /// Root folder URLs that have been opened in this session.
    /// Used to detect when the user opens the same directory a second time.
    private var knownRootURLs: Set<URL> = []

    /// Sorted list of unique subfolder paths present across all loaded entries.
    /// Empty string ("") represents root-level files. Updated at batch boundaries.
    private(set) var activeFolderPaths: [String] = []

    /// Entries grouped first by subfolder, then by filter, ready for sidebar rendering.
    /// Stored (not computed) to avoid O(n) re-derivation on every SwiftUI render pass.
    /// Updated only at batch boundaries alongside `groupStatistics`.
    private(set) var groupedByFolderAndFilter: [FolderGroup] = []

    // MARK: - Filter grouping

    /// Unique filter groups present in the loaded session, in canonical display order.
    /// Stored (not computed) to avoid O(n) Set creation on every sidebar render.
    /// Updated at batch boundaries via `updateActiveFilterGroups()`.
    private(set) var activeFilterGroups: [FilterGroup] = []

    /// True when more than one filter type is present in the loaded session.
    var isMultiFilter: Bool { activeFilterGroups.count > 1 }

    /// True when entries span more than one subfolder.
    var isMultiFolder: Bool { activeFolderPaths.count > 1 }

    private func updateActiveFilterGroups() {
        let present = Set(entries.map { $0.filterGroup })
        activeFilterGroups = FilterGroup.allCases.filter { present.contains($0) }
    }

    /// IDs of all entries rejected during this session.
    /// Stored as a `Set<UUID>` so `visibilityFilteredEntries` and related computed
    /// properties can read it directly — giving the `@Observable` system a concrete
    /// stored-property dependency to track, rather than relying on per-`ImageEntry`
    /// observation which `ImageStore` cannot register.
    private(set) var rejectedEntryIDs: Set<UUID> = []

    /// Cached sorted result of `entries` — avoids an O(n log n) sort on every render.
    /// Updated when sort settings change (`didSet`) or at batch boundaries.
    private(set) var cachedSortedEntries: [ImageEntry] = []

    private func updateCachedSort() {
        let asc = thumbnailSortAscending
        switch thumbnailSortOrder {
        case .filename:
            cachedSortedEntries = asc ? entries : entries.reversed()
        case .qualityScore:
            cachedSortedEntries = entries.sorted { a, b in
                let av = a.metrics?.qualityScore ?? -1
                let bv = b.metrics?.qualityScore ?? -1
                return asc ? av < bv : av > bv
            }
        case .fwhm:
            cachedSortedEntries = entries.sorted { a, b in
                switch (a.metrics?.fwhm, b.metrics?.fwhm) {
                case let (fa?, fb?): return asc ? fa < fb : fa > fb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .eccentricity:
            cachedSortedEntries = entries.sorted { a, b in
                switch (a.metrics?.eccentricity, b.metrics?.eccentricity) {
                case let (ea?, eb?): return asc ? ea < eb : ea > eb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .snr:
            cachedSortedEntries = entries.sorted { a, b in
                switch (a.metrics?.snr, b.metrics?.snr) {
                case let (sa?, sb?): return asc ? sa < sb : sa > sb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .starCount:
            cachedSortedEntries = entries.sorted { a, b in
                switch (a.metrics?.starCount, b.metrics?.starCount) {
                case let (ca?, cb?): return asc ? ca < cb : ca > cb
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
        switch rejectionVisibility {
        case .all:      return true
        case .selected: return flaggedEntryIDs.contains(entry.id)
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

    private func updateVisibilityFilteredEntries() {
        let base = filteredSortedEntries
        switch rejectionVisibility {
        case .all:      visibilityFilteredEntries = base
        case .selected: visibilityFilteredEntries = base.filter { flaggedEntryIDs.contains($0.id) }
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
            case .selected: visible = all.filter { flgIDs.contains($0.id) }
            case .rejected: visible = all.filter { rejIDs.contains($0.id) }
            }
            return visible.isEmpty ? nil : (group: group, entries: visible)
        }
    }

    /// `sortedEntries` grouped by filter group, in canonical FilterGroup order.
    /// Groups with no entries are omitted.
    var groupedSortedEntries: [(group: FilterGroup, entries: [ImageEntry])] {
        let grouped = Dictionary(grouping: sortedEntries) { $0.filterGroup }
        return FilterGroup.allCases.compactMap { group in
            guard let entries = grouped[group], !entries.isEmpty else { return nil }
            return (group: group, entries: entries)
        }
    }

    /// Per-group statistics used for relative badge thresholds and auto-reject.
    ///
    /// Stored (not computed) so that individual per-entry metrics updates during a batch
    /// do not cause every visible ThumbnailCell to re-render and recompute O(n) stats.
    /// Updated only at batch boundaries via `updateGroupStatistics()`.
    private(set) var groupStatistics: [FilterGroup: GroupStats] = [:]

    /// Cancels any in-progress loading or recompute batch.
    /// In-flight GPU/I/O tasks run to completion (they can't be interrupted mid-flight),
    /// but no new work is started and the UI is cleaned up immediately.
    func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        for entry in entries where entry.isProcessing {
            entry.isProcessing = false
        }
        isBatchProcessing = false
        batchElapsed = nil
    }

    private func updateGroupStatistics() {
        let grouped = Dictionary(grouping: entries) { $0.filterGroup }
        var result: [FilterGroup: GroupStats] = [:]
        for group in FilterGroup.allCases {
            guard let groupEntries = grouped[group], !groupEntries.isEmpty else { continue }
            let fwhms  = groupEntries.compactMap { $0.metrics?.fwhm }.sorted()
            let eccs   = groupEntries.compactMap { $0.metrics?.eccentricity }.sorted()
            let stars  = groupEntries.compactMap { $0.metrics?.starCount }.sorted()
            let snrs   = groupEntries.compactMap { $0.metrics?.snr }.sorted()
            let scores = groupEntries.compactMap { $0.metrics?.qualityScore }.sorted()
            result[group] = GroupStats(
                medianFWHM:         fwhms.isEmpty  ? nil : fwhms[fwhms.count / 2],
                medianEccentricity: eccs.isEmpty   ? nil : eccs[eccs.count / 2],
                medianStarCount:    stars.isEmpty  ? nil : stars[stars.count / 2],
                medianSNR:          snrs.isEmpty   ? nil : snrs[snrs.count / 2],
                medianScore:        scores.isEmpty ? nil : scores[scores.count / 2],
                topThirdScoreFloor: scores.count < 3 ? nil : scores[scores.count * 2 / 3],
                isNarrowband:       group.isNarrowband
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
        let idsToRemove: Set<UUID> = selectedEntryIDs.count > 1
            ? selectedEntryIDs
            : selectedEntry.map { [$0.id] } ?? []
        guard !idsToRemove.isEmpty else { return }

        // Find a replacement selection from the current sorted order.
        let ordered = sortedEntries
        let firstRemovedIdx = ordered.firstIndex { idsToRemove.contains($0.id) }
        let remaining = ordered.filter { !idsToRemove.contains($0.id) }
        let nextEntry: ImageEntry?
        if let idx = firstRemovedIdx {
            nextEntry = remaining.first { e in (ordered.firstIndex(where: { $0 === e }) ?? -1) >= idx } ?? remaining.last
        } else {
            nextEntry = remaining.first
        }

        entries.removeAll { idsToRemove.contains($0.id) }
        selectedEntryIDs = []
        selectedEntry = nextEntry
        updateGroupStatistics()
    }

    func reset() {
        entries = []
        rejectionVisibility = .all
        selectedEntry = nil
        selectedEntryIDs = []
        flaggedEntryIDs = []
        rejectedEntryIDs = []
        batchElapsed = nil
        isBatchProcessing = false
        errorMessage = nil
        sidebarFilterGroup = nil
        groupStatistics = [:]
        activeFilterGroups = []
        cachedSortedEntries = []
        rootFolderName = ""
        knownRootURLs = []
        activeFolderPaths = []
        groupedByFolderAndFilter = []
        visibilityFilteredEntries = []
    }

    // MARK: - Multi-selection helpers

    /// Adds all currently-visible entries (respecting filter group and rejection visibility)
    /// to the multi-selection. The focused entry is preserved.
    func selectAllVisible() {
        let visible = visibilityFilteredEntries
        guard !visible.isEmpty else { return }
        selectedEntryIDs = Set(visible.map { $0.id })
        if selectedEntry == nil || !selectedEntryIDs.contains(selectedEntry!.id) {
            selectedEntry = visible.first
        }
    }

    /// Adds all rejected entries to the multi-selection and focuses the first one.
    func selectAllRejected() {
        let rejected = entries.filter { $0.isRejected }
        guard !rejected.isEmpty else { NSSound.beep(); return }
        selectedEntryIDs = Set(rejected.map { $0.id })
        selectedEntry = rejected.first
    }

    /// Clears the multi-selection and focused entry.
    func deselectAll() {
        selectedEntryIDs = []
        selectedEntry = nil
    }

    /// Inverts the multi-selection within the currently-visible entries.
    /// Previously-selected entries are deselected; unselected ones become selected.
    func invertSelection() {
        let visible = visibilityFilteredEntries
        guard !visible.isEmpty else { return }
        let currentIDs = selectedEntryIDs.isEmpty
            ? (selectedEntry.map { [$0.id] } ?? [])
            : Array(selectedEntryIDs)
        let currentSet = Set(currentIDs)
        let inverted = Set(visible.map { $0.id }).subtracting(currentSet)
        selectedEntryIDs = inverted
        if let entry = selectedEntry, inverted.contains(entry.id) {
            // keep current focused entry if it's still in the new selection
        } else {
            selectedEntry = visible.first { inverted.contains($0.id) }
        }
    }

    // MARK: - Extend selection

    /// Extends the multi-selection one step toward earlier entries in the visible list.
    func extendSelectionPrevious() {
        let ordered = visibilityFilteredEntries
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else { return }
        guard index > 0 else { NSSound.beep(); return }
        let target = ordered[index - 1]
        if selectedEntryIDs.isEmpty { selectedEntryIDs.insert(current.id) }
        selectedEntryIDs.insert(target.id)
        selectedEntry = target
    }

    /// Extends the multi-selection one step toward later entries in the visible list.
    func extendSelectionNext() {
        let ordered = visibilityFilteredEntries
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else { return }
        guard index < ordered.count - 1 else { NSSound.beep(); return }
        let target = ordered[index + 1]
        if selectedEntryIDs.isEmpty { selectedEntryIDs.insert(current.id) }
        selectedEntryIDs.insert(target.id)
        selectedEntry = target
    }

    // MARK: - Navigation

    func selectFirst() {
        let ordered = visibilityFilteredEntries
        guard let first = ordered.first else { return }
        if selectedEntry === first { NSSound.beep() } else { selectedEntry = first; selectedEntryIDs = [] }
    }

    func selectLast() {
        let ordered = visibilityFilteredEntries
        guard let last = ordered.last else { return }
        if selectedEntry === last { NSSound.beep() } else { selectedEntry = last; selectedEntryIDs = [] }
    }

    func selectPrevious() {
        let ordered = visibilityFilteredEntries
        guard !ordered.isEmpty else { return }
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else {
            selectedEntry = ordered.first; selectedEntryIDs = []
            return
        }
        if index == 0 {
            NSSound.beep()
        } else {
            selectedEntry = ordered[index - 1]; selectedEntryIDs = []
        }
    }

    func selectNext() {
        let ordered = visibilityFilteredEntries
        guard !ordered.isEmpty else { return }
        guard let current = selectedEntry,
              let index = ordered.firstIndex(where: { $0 === current }) else {
            selectedEntry = ordered.first; selectedEntryIDs = []
            return
        }
        if index == ordered.count - 1 {
            NSSound.beep()
        } else {
            selectedEntry = ordered[index + 1]; selectedEntryIDs = []
        }
    }

    /// Toggles rejection for the selection: rejects non-rejected entries, undoes rejected ones.
    func toggleRejectSelected() {
        if selectedEntryIDs.count > 1 {
            let selected = entries.filter { selectedEntryIDs.contains($0.id) }
            if selected.allSatisfy({ $0.isRejected }) {
                selected.forEach { undoRejectEntry($0) }
            } else {
                selected.filter { !$0.isRejected }.forEach { rejectEntry($0) }
            }
        } else {
            guard let entry = selectedEntry else { return }
            if entry.isRejected { undoRejectSelected() } else { rejectSelected() }
        }
    }

    // MARK: - File Operations

    /// Resolves the directory bookmark for an entry, granting security-scoped access.
    /// The caller must call `stopAccessingSecurityScopedResource()` on the returned URL.
    ///
    /// If the stored bookmark is missing or stale, falls back to creating a fresh bookmark
    /// from the entry's parent directory — this succeeds when the user-selected.read-write
    /// entitlement still covers that directory (i.e. during the same app session).
    private func accessDirectory(for entry: ImageEntry) -> URL? {
        // Fast path: resolve the stored security-scoped bookmark.
        if let bookmark = entry.directoryBookmark {
            var isStale = false
            if let dirURL = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) {
                _ = dirURL.startAccessingSecurityScopedResource()
                if isStale {
                    // Refresh the stored bookmark while we still have access.
                    let fresh = try? dirURL.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                    entry.directoryBookmark = fresh
                }
                return dirURL
            }
        }

        // Fallback: try creating a fresh bookmark from the entry's parent directory.
        // Succeeds when user-selected.read-write still covers this location.
        let parentDir = entry.url.deletingLastPathComponent()
        guard let freshBookmark = try? parentDir.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil) else { return nil }
        entry.directoryBookmark = freshBookmark
        var isStale = false
        guard let dirURL = try? URL(resolvingBookmarkData: freshBookmark,
                                    options: .withSecurityScope,
                                    relativeTo: nil,
                                    bookmarkDataIsStale: &isStale) else { return nil }
        _ = dirURL.startAccessingSecurityScopedResource()
        return dirURL
    }

    func rejectSelected() {
        if selectedEntryIDs.count > 1 {
            entries.filter { selectedEntryIDs.contains($0.id) }.forEach { rejectEntry($0) }
        } else if let entry = selectedEntry {
            rejectEntry(entry)
        }
    }


    /// Batch-reject multiple entries.
    func rejectEntries(_ entriesToReject: [ImageEntry]) {
        for entry in entriesToReject { rejectEntry(entry) }
    }

    /// Adds entries to the flagged set (drives the "Selected" filter) without rejecting.
    func flagEntries(_ entriesToFlag: [ImageEntry]) {
        flaggedEntryIDs = flaggedEntryIDs.union(entriesToFlag.map(\.id))
    }

    /// Removes IDs from the flagged set. Used by cmd+click in "Selected" mode.
    func unflagEntries(_ ids: Set<UUID>) {
        flaggedEntryIDs.subtract(ids)
        selectedEntryIDs.subtract(ids)
    }

    /// Flags all frames that match `config` by adding them to the selection.
    func applyAutoFlag(config: AutoRejectConfig) {
        flagEntries(previewAutoReject(config: config))
    }

    private func rejectEntry(_ entry: ImageEntry) {
        guard !entry.isRejected else { return }

        guard let dirURL = accessDirectory(for: entry) else {
            errorMessage = "Failed to reject \(entry.fileName): folder access unavailable. Close and re-open the folder to restore access."
            return
        }
        defer { dirURL.stopAccessingSecurityScopedResource() }

        let originalURL = entry.url
        let parentDir = originalURL.deletingLastPathComponent()
        let rejectedDir = parentDir.appending(path: "REJECTED", directoryHint: .isDirectory)
        let destinationURL = rejectedDir.appending(component: originalURL.lastPathComponent)

        do {
            if !FileManager.default.fileExists(atPath: rejectedDir.path(percentEncoded: false)) {
                try FileManager.default.createDirectory(at: rejectedDir, withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: originalURL, to: destinationURL)
            entry.url = destinationURL
            entry.isRejected = true
            rejectedEntryIDs.insert(entry.id)
            updateVisibilityFilteredEntries()
        } catch {
            errorMessage = "Failed to reject \(entry.fileName): \(error.localizedDescription)"
        }
    }

    // MARK: - Auto-reject

    /// Returns entries that would be rejected by `config`, without touching any files.
    ///
    /// Thresholds are evaluated per filter group so that narrowband groups with naturally
    /// low star counts are not falsely penalised by relative star-count checks.
    func previewAutoReject(config: AutoRejectConfig) -> [ImageEntry] {
        let stats = groupStatistics
        return entries.filter { entry in
            guard !entry.isRejected, let m = entry.metrics else { return false }
            let gs = stats[entry.filterGroup]

            // Eccentricity is an absolute threshold in both modes.
            if config.useEccentricity,
               let ecc = m.eccentricity,
               Float(config.eccentricityThreshold) < ecc { return true }

            switch config.mode {
            case .relative:
                if config.useFWHM, let fwhm = m.fwhm, let medFWHM = gs?.medianFWHM,
                   Double(fwhm) > Double(medFWHM) * config.fwhmMultiplier { return true }
                if config.useStarCount, let stars = m.starCount, let medStars = gs?.medianStarCount,
                   Double(stars) < Double(medStars) * config.starCountMultiplier { return true }
                if config.useSNR, let snr = m.snr, let medSNR = gs?.medianSNR,
                   Double(snr) < Double(medSNR) * config.snrMultiplier { return true }

            case .absolute:
                if config.useFWHM, let fwhm = m.fwhm,
                   Double(fwhm) > config.absoluteFWHM { return true }
                if config.useStarCount, let stars = m.starCount,
                   stars < config.absoluteStarCountFloor { return true }
                if config.useSNR, let snr = m.snr,
                   Double(snr) < config.absoluteSNRFloor { return true }
                if config.useScore,
                   m.qualityScore < config.scoreFloor { return true }
            }
            return false
        }
    }

    /// Rejects all frames that match `config`, moving them to the `REJECTED/` folder.
    func applyAutoReject(config: AutoRejectConfig) {
        rejectEntries(previewAutoReject(config: config))
    }

    func undoRejectSelected() {
        if selectedEntryIDs.count > 1 {
            entries.filter { selectedEntryIDs.contains($0.id) && $0.isRejected }
                   .forEach { undoRejectEntry($0) }
        } else if let entry = selectedEntry, entry.isRejected {
            undoRejectEntry(entry)
        }
    }

    private func undoRejectEntry(_ entry: ImageEntry) {
        guard let dirURL = accessDirectory(for: entry) else {
            errorMessage = "Failed to undo rejection of \(entry.fileName): folder access unavailable. Close and re-open the folder to restore access."
            return
        }
        defer { dirURL.stopAccessingSecurityScopedResource() }

        let currentURL = entry.url
        let originalURL = entry.originalURL

        do {
            try FileManager.default.moveItem(at: currentURL, to: originalURL)
            entry.url = originalURL
            entry.isRejected = false
            rejectedEntryIDs.remove(entry.id)
            updateVisibilityFilteredEntries()

            let rejectedDir = currentURL.deletingLastPathComponent()
            let contents = try? FileManager.default.contentsOfDirectory(
                at: rejectedDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if let contents, contents.isEmpty {
                try? FileManager.default.removeItem(at: rejectedDir)
            }
        } catch {
            errorMessage = "Failed to undo rejection of \(entry.fileName): \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    /// Presents a save panel and writes a frame list in the chosen format.
    /// Only non-rejected frames are included.
    func export(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.title = "Export Frame List"
        switch format {
        case .plainText:
            panel.nameFieldStringValue = "frames.txt"
            panel.allowedContentTypes = [.plainText]
        case .csv:
            panel.nameFieldStringValue = "frames.csv"
            panel.allowedContentTypes = [.commaSeparatedText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let kept = entries.filter { !$0.isRejected }

        let content: String
        switch format {
        case .plainText:
            content = kept.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n")
        case .csv:
            var lines = ["path,fwhm,eccentricity,snr,stars"]
            for entry in kept {
                let m     = entry.metrics
                let path  = entry.url.path(percentEncoded: false)
                let fwhm  = m.flatMap { $0.fwhm }.map        { $0.formatted(.number.precision(.fractionLength(2))) } ?? ""
                let ecc   = m.flatMap { $0.eccentricity }.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? ""
                let snr   = m.flatMap { $0.snr }.map          { $0.formatted(.number.precision(.fractionLength(1))) } ?? ""
                let stars = m.flatMap { $0.starCount }.map     { String($0) } ?? ""
                lines.append("\(path),\(fwhm),\(ecc),\(snr),\(stars)")
            }
            content = lines.joined(separator: "\n")
        }

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - FITS file discovery

    /// Recursively collects FITS file URLs under `folder`, pairing each with its
    /// relative subfolder path from `relativePath`.
    ///
    /// - Parameters:
    ///   - folder: The directory to scan.
    ///   - relativePath: Prefix to prepend (empty for the root call).
    ///   - excludedNames: Lowercased subfolder names to skip entirely.
    ///   - includeSubfolders: When false, only the immediate directory is scanned.
    nonisolated static func collectFITSURLs(
        in folder: URL,
        relativePath: String,
        excludedNames: Set<String>,
        includeSubfolders: Bool
    ) -> [(url: URL, subfolderPath: String)] {
        let fitsExtensions: Set<String> = ["fits", "fit", "fts"]
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var results: [(URL, String)] = []
        let sorted = contents.sorted {
            $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
        }

        for item in sorted {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                guard includeSubfolders else { continue }
                let name = item.lastPathComponent
                // Always skip REJECTED — that's where this app moves rejected files.
                // Also skip any user-configured exclusion names (case-insensitive).
                guard name.caseInsensitiveCompare("REJECTED") != .orderedSame,
                      !excludedNames.contains(name.lowercased()) else { continue }
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                results += collectFITSURLs(in: item, relativePath: childPath,
                                           excludedNames: excludedNames,
                                           includeSubfolders: true)
            } else if fitsExtensions.contains(item.pathExtension.lowercased()) {
                results.append((item, relativePath))
            }
        }
        return results
    }

    // MARK: - File Panels

    /// Shows/hides the shared notice label when either panel checkbox is toggled
    /// to a state that differs from its stored default. Kept as a separate NSObject
    /// subclass because NSButton holds only a weak reference to its target.
    private final class PanelAccessoryHelper: NSObject {
        private let checkboxes: [(button: NSButton, defaultState: Bool)]
        private weak var noticeLabel: NSTextField?

        init(checkboxes: [(NSButton, Bool)], noticeLabel: NSTextField) {
            self.checkboxes = checkboxes
            self.noticeLabel = noticeLabel
        }

        @objc func checkboxChanged(_ sender: NSButton) {
            let anyDiffers = checkboxes.contains { ($0.button.state == .on) != $0.defaultState }
            noticeLabel?.isHidden = !anyDiffers
        }
    }

    func openFolderPanel(settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing FITS files"
        panel.prompt = "Open"

        // Accessory view: plain AppKit — NSHostingView doesn't wire @Observable correctly
        // when used outside a SwiftUI window hierarchy (NSOpenPanel accessory context).
        let excludedNames = settings.excludedSubfolderNames

        // Subfolders checkbox
        let subfolderCheckbox = NSButton(checkboxWithTitle: "Include files from subfolders",
                                         target: nil, action: nil)
        subfolderCheckbox.state = settings.includeSubfolders ? .on : .off

        // REJECTED folder checkbox
        let rejectedCheckbox = NSButton(
            checkboxWithTitle: "Include REJECTED folder (mark images as rejected)",
            target: nil, action: nil)
        rejectedCheckbox.state = settings.includeRejectedFolder ? .on : .off

        // Shared notice label — appears when either checkbox differs from its stored default.
        let noticeLabel = NSTextField(labelWithString:
            "Applies to this open only. To change the default, go to Settings → Files & Folders.")
        noticeLabel.font = .systemFont(ofSize: 10)
        noticeLabel.textColor = .systemOrange
        noticeLabel.isHidden = true
        noticeLabel.cell?.wraps = true
        noticeLabel.maximumNumberOfLines = 2

        let panelHelper = PanelAccessoryHelper(
            checkboxes: [(subfolderCheckbox, settings.includeSubfolders),
                         (rejectedCheckbox,  settings.includeRejectedFolder)],
            noticeLabel: noticeLabel
        )
        subfolderCheckbox.target = panelHelper
        subfolderCheckbox.action = #selector(PanelAccessoryHelper.checkboxChanged(_:))
        rejectedCheckbox.target = panelHelper
        rejectedCheckbox.action = #selector(PanelAccessoryHelper.checkboxChanged(_:))

        // Layout (AppKit bottom-up). Reserve space for the notice label even when hidden.
        let noticeHeight: CGFloat = 28
        let excludedHeight: CGFloat = excludedNames.isEmpty ? 0 : 30
        let containerHeight: CGFloat = 88 + excludedHeight
        let noticeLabelY: CGFloat = excludedHeight + 4
        let rejectedCheckboxY: CGFloat = noticeLabelY + noticeHeight + 4
        let subfolderCheckboxY: CGFloat = rejectedCheckboxY + 20 + 8

        let container = NSView()
        container.frame = NSRect(x: 0, y: 0, width: 480, height: containerHeight)

        subfolderCheckbox.frame = NSRect(x: 20, y: subfolderCheckboxY, width: 440, height: 20)
        rejectedCheckbox.frame  = NSRect(x: 20, y: rejectedCheckboxY,  width: 440, height: 20)
        noticeLabel.frame       = NSRect(x: 22, y: noticeLabelY,       width: 430, height: noticeHeight)

        container.addSubview(subfolderCheckbox)
        container.addSubview(rejectedCheckbox)
        container.addSubview(noticeLabel)

        if !excludedNames.isEmpty {
            let hint = NSTextField(labelWithString:
                "Skipping: \(excludedNames.joined(separator: ", "))  —  edit in Settings → Files & Folders")
            hint.font = .systemFont(ofSize: 10)
            hint.textColor = .secondaryLabelColor
            hint.cell?.wraps = true
            hint.cell?.isScrollable = false
            hint.maximumNumberOfLines = 2
            hint.frame = NSRect(x: 22, y: 4, width: 430, height: 26)
            container.addSubview(hint)
        }

        panel.accessoryView = container
        panel.isAccessoryViewDisclosed = true

        // withExtendedLifetime keeps panelHelper alive for the duration of runModal()
        // (NSButton holds only a weak reference to its target).
        let result = withExtendedLifetime(panelHelper) { panel.runModal() }
        guard result == .OK, let folderURL = panel.url else { return }

        // Use checkbox values — intentionally NOT written back to settings.
        let includeSubfolders = subfolderCheckbox.state == .on
        let includeRejected   = rejectedCheckbox.state == .on
        let excludedSet = Set(settings.excludedSubfolderNames.map { $0.lowercased() })

        let didAccess = folderURL.startAccessingSecurityScopedResource()
        let dirBookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        var collected = Self.collectFITSURLs(in: folderURL, relativePath: "",
                                             excludedNames: excludedSet,
                                             includeSubfolders: includeSubfolders)

        // Optionally scan the REJECTED subdirectory and track those URLs.
        var rejectedURLs: Set<URL> = []
        if includeRejected {
            let rejectedDir = folderURL.appending(path: "REJECTED", directoryHint: .isDirectory)
            let rejectedItems = Self.collectFITSURLs(in: rejectedDir, relativePath: "REJECTED",
                                                     excludedNames: [],
                                                     includeSubfolders: false)
            rejectedURLs = Set(rejectedItems.map { $0.url })
            collected += rejectedItems
        }

        if didAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !collected.isEmpty else {
            errorMessage = "No FITS files found in the selected folder."
            return
        }

        // Warn the user if this directory has already been loaded in this session.
        if knownRootURLs.contains(folderURL) {
            let alert = NSAlert()
            alert.messageText = "Folder Already Loaded"
            alert.informativeText = "\"\(folderURL.lastPathComponent)\" is already in your session. Any duplicate files will be skipped automatically."
            alert.addButton(withTitle: "Open Anyway")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        knownRootURLs.insert(folderURL)

        rootFolderName = folderURL.lastPathComponent
        openFiles(collected, rejectedURLs: rejectedURLs,
                  rootFolderName: folderURL.lastPathComponent,
                  directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig,
                  debayerColorImages: settings.debayerColorImages)
    }

    /// Opens dropped URLs (folders and/or individual FITS files) from a drag & drop operation.
    ///
    /// Folders are scanned according to `settings.includeSubfolders`. Individual FITS files
    /// are always added directly. Files from different directories are merged into the session.
    func openDroppedItems(_ urls: [URL], settings: AppSettings) {
        let fitsExtensions: Set<String> = ["fits", "fit", "fts"]
        let excludedSet = Set(settings.excludedSubfolderNames.map { $0.lowercased() })
        var collected: [(url: URL, subfolderPath: String)] = []
        var dirBookmark: Data?
        var singleDroppedFolderName: String?

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                if dirBookmark == nil {
                    dirBookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                }
                let folderCollected = Self.collectFITSURLs(in: url, relativePath: "",
                                                           excludedNames: excludedSet,
                                                           includeSubfolders: settings.includeSubfolders)
                collected.append(contentsOf: folderCollected)
                if urls.count == 1 { singleDroppedFolderName = url.lastPathComponent }
            } else if fitsExtensions.contains(url.pathExtension.lowercased()) {
                collected.append((url, ""))
            }
        }

        guard !collected.isEmpty else { return }

        if dirBookmark == nil, let first = collected.first {
            let parent = first.url.deletingLastPathComponent()
            dirBookmark = try? parent.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        }

        let folderRootName = singleDroppedFolderName ?? ""
        if !folderRootName.isEmpty { rootFolderName = folderRootName }

        // Track dropped folder URLs so we can detect if the same folder is dropped again.
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDir),
               isDir.boolValue {
                knownRootURLs.insert(url)
            }
        }

        openFiles(collected, rootFolderName: folderRootName,
                  directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig,
                  debayerColorImages: settings.debayerColorImages)
    }

    func openFilesPanel(settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [
            .init(filenameExtension: "fits") ?? .data,
            .init(filenameExtension: "fit")  ?? .data,
            .init(filenameExtension: "fts")  ?? .data,
        ]
        panel.message = "Select FITS files"
        panel.prompt = "Open"

        guard panel.runModal() == .OK else { return }

        let fitsURLs = panel.urls.filter {
            ["fits", "fit", "fts"].contains($0.pathExtension.lowercased())
        }
        guard !fitsURLs.isEmpty else { return }

        let firstURL = fitsURLs[0]
        let didAccess = firstURL.startAccessingSecurityScopedResource()
        let parentDir = firstURL.deletingLastPathComponent()
        let dirBookmark = try? parentDir.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        if didAccess { firstURL.stopAccessingSecurityScopedResource() }

        openFiles(fitsURLs, directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig,
                  debayerColorImages: settings.debayerColorImages)
    }

    // MARK: - Loading

    /// Convenience wrapper for callers that provide a flat list without subfolder info.
    func openFiles(_ urls: [URL], rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "", directoryBookmark: Data? = nil,
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false) {
        openFiles(urls.map { (url: $0, subfolderPath: "") },
                  rejectedURLs: rejectedURLs,
                  rootFolderName: rootFolderName,
                  directoryBookmark: directoryBookmark,
                  maxDisplaySize: maxDisplaySize,
                  maxThumbnailSize: maxThumbnailSize,
                  metricsConfig: metricsConfig,
                  debayerColorImages: debayerColorImages)
    }

    func openFiles(_ urlsWithPaths: [(url: URL, subfolderPath: String)],
                   rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "",
                   directoryBookmark: Data? = nil,
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false) {
        let selectFirst = (selectedEntry == nil)

        // Snapshot existing URLs now, on the main actor, before handing off to the task.
        let existingURLs = Set(entries.map { $0.originalURL })

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            // Phase 0: validate files off the main thread.
            //
            // peekBitpix does a synchronous FileHandle.read — moving it here via a
            // nonisolated function ensures the main thread is never blocked by slow
            // I/O (iCloud materialisation, SMB mounts, heavy disk pressure, etc.).
            let (validItems, skippedFloat) = await Self.filterItems(
                urlsWithPaths, existingURLs: existingURLs)

            // Add entries on the main actor so the sidebar shows loading spinners.
            var newEntries: [ImageEntry] = []
            for item in validItems {
                let entry = ImageEntry(url: item.url, directoryBookmark: directoryBookmark)
                entry.subfolderPath = item.subfolderPath
                entry.rootFolderName = rootFolderName
                if rejectedURLs.contains(item.url) {
                    entry.isRejected = true
                    rejectedEntryIDs.insert(entry.id)
                }
                entries.append(entry)
                newEntries.append(entry)
            }
            if !skippedFloat.isEmpty {
                let preview = skippedFloat.prefix(5).joined(separator: ", ")
                let suffix  = skippedFloat.count > 5 ? " and \(skippedFloat.count - 5) more" : ""
                errorMessage = "Skipped \(skippedFloat.count) floating-point FITS file\(skippedFloat.count == 1 ? "" : "s") (not supported): \(preview)\(suffix)"
            }
            guard !newEntries.isEmpty else {
                isBatchProcessing = false
                processingTask = nil
                return
            }

            if selectFirst { selectedEntry = newEntries[0] }

            // Populate the sort/filter cache so the sidebar renders immediately.
            updateActiveFilterGroups()
            updateCachedSort()

            await processParallel(newEntries, selectFirst: selectFirst,
                                  maxDisplaySize: maxDisplaySize,
                                  maxThumbnailSize: maxThumbnailSize,
                                  metricsConfig: metricsConfig,
                                  debayerColorImages: debayerColorImages)
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    /// Filters a list of candidate URLs off the main thread: strips unsupported
    /// extensions, removes duplicates, and reads the first header block of each
    /// remaining file to detect and reject floating-point FITS.
    ///
    /// This function is `nonisolated` so Swift runs it on the cooperative thread
    /// pool rather than the main actor, keeping the UI responsive even when files
    /// are stored on iCloud Drive, SMB mounts, or a loaded SSD.
    private nonisolated static func filterItems(
        _ items: [(url: URL, subfolderPath: String)],
        existingURLs: Set<URL>
    ) async -> (valid: [(url: URL, subfolderPath: String)], skippedFloat: [String]) {
        var valid: [(url: URL, subfolderPath: String)] = []
        var skippedFloat: [String] = []
        for item in items {
            let url = item.url
            guard ["fits", "fit", "fts"].contains(url.pathExtension.lowercased()) else { continue }
            guard !existingURLs.contains(url) else { continue }
            if let bitpix = FITSReader.peekBitpix(url: url), ![8, 16, 32].contains(bitpix) {
                skippedFloat.append(url.lastPathComponent)
                continue
            }
            valid.append(item)
        }
        return (valid, skippedFloat)
    }

    /// Reprocesses all currently loaded images with updated settings.
    func reprocessAll(settings: AppSettings) {
        let entriesToProcess = entries
        for entry in entriesToProcess {
            entry.isProcessing    = true
            entry.displayImage    = nil
            entry.thumbnail       = nil
            entry.metrics         = nil
            entry.cachedMetrics   = nil
            entry.histogram       = nil
        }

        let accessedDirs = entriesToProcess.compactMap { accessDirectory(for: $0) }

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task { [weak self] in
            guard let self else { return }
            await processParallel(entriesToProcess, selectFirst: false,
                                  maxDisplaySize: settings.maxDisplaySize,
                                  maxThumbnailSize: settings.maxThumbnailSize,
                                  metricsConfig: settings.metricsConfig,
                                  debayerColorImages: settings.debayerColorImages)
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    // MARK: - Metrics-only recompute

    /// Applies a new metrics config without re-reading FITS files where possible.
    ///
    /// - If all metrics requested by `newConfig` are already in an entry's `cachedMetrics`,
    ///   the displayed `metrics` is rebuilt from cache instantly — no I/O.
    /// - Only entries genuinely missing a newly-enabled metric trigger a file re-read,
    ///   and only for those specific missing metrics.
    func recomputeMetrics(metricsConfig: MetricsConfig) {
        let entriesToProcess = entries.filter { !$0.isProcessing }
        guard !entriesToProcess.isEmpty, !isBatchProcessing else { return }

        // Pass 1 (synchronous, no I/O): restore from cache for everything we already have.
        for entry in entriesToProcess {
            if let cached = entry.cachedMetrics {
                entry.metrics = cached.filtered(by: metricsConfig)
            }
        }

        // Refresh the sort cache now that cached metrics have been restored synchronously.
        updateCachedSort()

        // Pass 2: collect entries that still need at least one metric computed from disk.
        let needsRecompute = entriesToProcess.filter { entry in
            let c = entry.cachedMetrics
            if metricsConfig.computeFWHM         && c?.fwhm         == nil { return true }
            if metricsConfig.computeEccentricity && c?.eccentricity == nil { return true }
            if metricsConfig.computeSNR          && c?.snr          == nil { return true }
            if metricsConfig.computeStarCount    && c?.starCount    == nil { return true }
            return false
        }

        guard !needsRecompute.isEmpty else { return }

        let accessedDirs = needsRecompute.compactMap { accessDirectory(for: $0) }
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // Scale to core count, same policy as processParallel.
            let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

            await withTaskGroup(of: Void.self) { group in
                var activeCount = 0
                for entry in needsRecompute {
                    if activeCount >= maxConcurrency {
                        await group.next()
                        activeCount -= 1
                    }
                    // Only request the metrics that are actually missing from cache.
                    let c = entry.cachedMetrics
                    let missingConfig = MetricsConfig(
                        computeFWHM:         metricsConfig.computeFWHM         && c?.fwhm         == nil,
                        computeEccentricity: metricsConfig.computeEccentricity && c?.eccentricity == nil,
                        computeSNR:          metricsConfig.computeSNR          && c?.snr          == nil,
                        computeStarCount:    metricsConfig.computeStarCount    && c?.starCount    == nil
                    )
                    let url = entry.url
                    group.addTask {
                        let newMetrics = await Self.loadMetricsOnly(url: url, config: missingConfig)
                        await MainActor.run {
                            if let newMetrics {
                                let merged = (entry.cachedMetrics ?? newMetrics).merging(newMetrics)
                                entry.cachedMetrics = merged
                                entry.metrics = merged.filtered(by: metricsConfig)
                            }
                        }
                    }
                    activeCount += 1
                }
            }

            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            updateGroupStatistics()
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    private nonisolated static func loadMetricsOnly(url: URL,
                                                     config: MetricsConfig) async -> FrameMetrics? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // GPU path: read into a Metal shared buffer (same path as the initial load),
        // then run the GPU detection kernel. Much faster than the CPU fallback because
        // the Metal kernel uses the full frame, while the CPU path is limited to a crop.
        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta = bufferResult.metadata
            return await MetricsCalculator.compute(metalBuffer: bufferResult.metalBuffer,
                                                   device: device,
                                                   width: meta.width, height: meta.height,
                                                   config: config)
        }

        // CPU fallback when Metal is unavailable.
        guard let fits = try? FITSReader.read(from: url) else { return nil }
        return await MetricsCalculator.compute(pixels: fits.pixelValues,
                                               width: fits.width, height: fits.height,
                                               config: config)
    }

    // MARK: - Concurrent pipeline

    /// Two-phase pipeline per image:
    ///
    /// **Phase A** — I/O + GPU stretch + crop extraction (~100–300 ms total):
    /// image becomes visible immediately. Star crops are extracted from the
    /// MTLBuffer before it is released, so no second file read is needed.
    ///
    /// **Phase B** — GPU star-detection + Moffat fitting: runs in a detached
    /// task using the retained MTLBuffer. Concurrency is bounded by
    /// `phaseBSemaphore` (acquired in the group task after Phase A, before
    /// the slot is freed), keeping live MTLBuffer count and memory predictable.
    private func processParallel(_ entriesToProcess: [ImageEntry], selectFirst: Bool,
                                  maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                                  metricsConfig: MetricsConfig = MetricsConfig(),
                                  debayerColorImages: Bool = false) async {

        // Phase A: high I/O concurrency keeps the SSD pipeline full.
        // Phase B: bounded separately to prevent CPU/memory over-subscription.
        let ioConcurrency   = max(8, ProcessInfo.processInfo.activeProcessorCount)
        let phaseBSemaphore = AsyncSemaphore(count: max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        var phaseBTasks: [Task<Void, Never>] = []

        await withTaskGroup(of: (ImageEntry, Task<Void, Never>?).self) { group in
            var activeCount = 0
            for entry in entriesToProcess {
                if Task.isCancelled { break }

                if activeCount >= ioConcurrency {
                    if let (_, phaseB) = await group.next() {
                        if let t = phaseB { phaseBTasks.append(t) }
                    }
                    activeCount -= 1
                }
                let url = entry.url
                group.addTask { [weak self] in
                    // ── Phase A: I/O + histogram + GPU stretch ────────────────
                    let fast = await Self.loadFast(url: url,
                                                   maxDisplaySize: maxDisplaySize,
                                                   maxThumbnailSize: maxThumbnailSize,
                                                   debayerColorImages: debayerColorImages)
                    await MainActor.run { [weak self] in
                        entry.displayImage = fast.display
                        entry.thumbnail    = fast.thumb
                        entry.imageInfo    = fast.info
                        entry.errorMessage = fast.error
                        entry.histogram    = fast.histogram
                        entry.headers      = fast.headers
                        entry.bayerClips   = fast.bayerClips
                        // Pre-populate the greyscale cache so any toggle to grey is instant.
                        if BayerPattern.parse(from: fast.headers) != nil {
                            entry.cachedGreyscaleDisplay = fast.display
                            entry.cachedGreyscaleThumb   = fast.thumb
                        }
                        entry.isProcessing = false   // ← image visible now

                        if selectFirst, entry === entriesToProcess.first, fast.display != nil {
                            self?.selectedEntry = entry
                        }
                    }

                    // ── Phase B: GPU detection + Moffat fitting ───────────────
                    // Acquire a Phase B slot before spawning the detached task.
                    // This bounds the number of live MTLBuffers to phaseBSemaphore.count
                    // while still freeing this group slot immediately after.
                    guard metricsConfig.needsStarDetection else { return (entry, nil) }
                    await phaseBSemaphore.wait()
                    let phaseB = Task(priority: .utility) {
                        defer { Task { await phaseBSemaphore.signal() } }

                        let metrics: FrameMetrics?
                        if let buffer = fast.metalBuffer, let device = fast.metalDevice {
                            metrics = await MetricsCalculator.compute(
                                metalBuffer: buffer, device: device,
                                width: fast.width, height: fast.height, config: metricsConfig)
                        } else {
                            // CPU fallback: Metal was unavailable during Phase A.
                            metrics = await Self.loadMetricsOnly(url: url, config: metricsConfig)
                        }
                        await MainActor.run {
                            entry.metrics       = metrics
                            entry.cachedMetrics = metrics
                        }
                    }
                    return (entry, phaseB)
                }
                activeCount += 1
            }
            for await (_, phaseB) in group {
                if let t = phaseB { phaseBTasks.append(t) }
            }
        }

        // Wait for all Phase B tasks. On cancellation, break early — queued
        // tasks will complete in the background and harmlessly update entries.
        for task in phaseBTasks {
            if Task.isCancelled { break }
            await task.value
        }

        updateGroupStatistics()

        if !Task.isCancelled, debayerColorImages {
            await normalizeBayerStretch(entriesToProcess,
                                        maxDisplaySize: maxDisplaySize,
                                        maxThumbnailSize: maxThumbnailSize)
        }
    }

    /// Re-renders only display images and thumbnails for Bayer frames when the
    /// colour debayering preference is toggled. Does NOT touch metrics or histograms.
    ///
    /// - Colour ON:  computes missing per-channel clip bounds (if images were loaded
    ///               with debayer off), then re-renders with per-folder median clips.
    /// - Colour OFF: re-renders Bayer images as greyscale.
    func recolorImages(settings: AppSettings) {
        let debayer          = settings.debayerColorImages
        let maxDisplaySize   = settings.maxDisplaySize
        let maxThumbnailSize = settings.maxThumbnailSize
        let bayerEntries     = entries.filter { $0.isBayer }
        guard !bayerEntries.isEmpty else { return }

        let accessedDirs = bayerEntries.compactMap { accessDirectory(for: $0) }

        Task { [weak self] in
            guard let self else { return }
            defer { for d in accessedDirs { d.stopAccessingSecurityScopedResource() } }

            if debayer {
                recolouringMessage = "Rendering colour…"
                defer { recolouringMessage = nil }
                // Compute clip bounds for any entry loaded before debayer was enabled.
                let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
                await withTaskGroup(of: Void.self) { group in
                    var active = 0
                    for entry in bayerEntries where entry.bayerClips == nil {
                        if active >= concurrency { await group.next(); active -= 1 }
                        let url     = entry.url
                        let headers = entry.headers
                        group.addTask {
                            let didStart = url.startAccessingSecurityScopedResource()
                            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                            guard let pattern = BayerPattern.parse(from: headers),
                                  let device  = ImageStretcher.metalDevice,
                                  let result  = try? FITSReader.readIntoBuffer(from: url, device: device)
                            else { return }
                            let clips = ImageStretcher.computeBayerClips(
                                result.metalBuffer,
                                width: result.metadata.width, height: result.metadata.height,
                                rOffset: pattern.rOffset)
                            await MainActor.run { entry.bayerClips = clips }
                        }
                        active += 1
                    }
                }
                // Re-render in colour with per-folder median clips.
                await normalizeBayerStretch(bayerEntries, maxDisplaySize: maxDisplaySize,
                                            maxThumbnailSize: maxThumbnailSize)
            } else {
                // Re-render Bayer images as greyscale; metrics and histogram are unchanged.
                // Use cached greyscale renders if available to avoid file re-reads.
                let needsRender = bayerEntries.filter { $0.cachedGreyscaleDisplay == nil }
                if !needsRender.isEmpty {
                    recolouringMessage = "Rendering greyscale…"
                    defer { recolouringMessage = nil }
                    let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
                    await withTaskGroup(of: Void.self) { group in
                        var active = 0
                        for entry in needsRender {
                            if active >= concurrency { await group.next(); active -= 1 }
                            let url = entry.url
                            group.addTask {
                                let didStart = url.startAccessingSecurityScopedResource()
                                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                                guard let device = ImageStretcher.metalDevice,
                                      let result = try? FITSReader.readIntoBuffer(from: url, device: device)
                                else { return }
                                let display = await ImageStretcher.createImage(
                                    inputBuffer: result.metalBuffer,
                                    width: result.metadata.width, height: result.metadata.height,
                                    maxDisplaySize: maxDisplaySize)
                                let thumb = display.flatMap {
                                    ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize)
                                }
                                await MainActor.run {
                                    entry.cachedGreyscaleDisplay = display
                                    entry.cachedGreyscaleThumb   = thumb
                                    if let d = display { entry.displayImage = d }
                                    if let t = thumb   { entry.thumbnail    = t }
                                }
                            }
                            active += 1
                        }
                    }
                }
                // Apply cached renders for entries that already had them.
                for entry in bayerEntries where entry.cachedGreyscaleDisplay != nil && !needsRender.contains(where: { $0 === entry }) {
                    entry.displayImage = entry.cachedGreyscaleDisplay
                    entry.thumbnail    = entry.cachedGreyscaleThumb
                }
            }
        }
    }

    /// Post-batch colour normalisation for Bayer images.
    ///
    /// Groups Bayer entries by subfolder, computes per-channel median clip bounds,
    /// then re-renders each image in colour with the shared clips.
    /// File re-reads are cheap because the OS page cache is warm.
    private func normalizeBayerStretch(_ entries: [ImageEntry],
                                        maxDisplaySize: Int, maxThumbnailSize: Int) async {
        // Collect entries that have Bayer clips (means debayerColorImages was true during load)
        let bayerEntries = entries.filter { $0.bayerClips != nil }
        guard !bayerEntries.isEmpty else { return }
        recolouringMessage = "Rendering colour…"
        defer { recolouringMessage = nil }

        // Group by qualifiedFolderPath so each root+subfolder combination gets its own
        // median stretch — prevents cross-root colour normalisation when multiple root
        // folders contain identically-named subfolders.
        let folderGroups = Dictionary(grouping: bayerEntries, by: \.qualifiedFolderPath)

        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

        // Invalidate cached colour renders when the shared clips change (new images added, etc.)
        // We detect this by checking if any entry in a folder lacks a cached colour render.
        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0
            for (_, folderEntries) in folderGroups {
                let allClips = folderEntries.compactMap(\.bayerClips)
                let sharedClips = BayerClips.median(of: allClips)
                guard sharedClips.isValid else { continue }

                // If all entries in this folder already have a cached colour render, just swap.
                let needsRender = folderEntries.filter { $0.cachedColourDisplay == nil }
                if needsRender.isEmpty {
                    for entry in folderEntries {
                        entry.displayImage = entry.cachedColourDisplay
                        entry.thumbnail    = entry.cachedColourThumb
                    }
                    continue
                }

                for entry in folderEntries {
                    if activeCount >= concurrency {
                        await group.next()
                        activeCount -= 1
                    }
                    // If this specific entry is cached, apply immediately without a task.
                    if entry.cachedColourDisplay != nil && !needsRender.contains(where: { $0 === entry }) {
                        entry.displayImage = entry.cachedColourDisplay
                        entry.thumbnail    = entry.cachedColourThumb
                        continue
                    }
                    let url      = entry.url
                    let headers  = entry.headers
                    group.addTask {
                        guard let pattern = BayerPattern.parse(from: headers) else { return }
                        guard let (display, thumb) = await Self.recolorBayerEntry(
                            url: url, rOffset: pattern.rOffset, clips: sharedClips,
                            maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize
                        ) else { return }
                        await MainActor.run {
                            entry.cachedColourDisplay = display
                            entry.cachedColourThumb   = thumb
                            entry.displayImage = display
                            entry.thumbnail    = thumb
                        }
                    }
                    activeCount += 1
                }
            }
        }
    }

    /// Re-reads a single FITS file and renders it in colour with the given shared clip bounds.
    /// Called by `normalizeBayerStretch`; file reads are fast from the warm OS page cache.
    private nonisolated static func recolorBayerEntry(
        url: URL, rOffset: UInt32, clips: BayerClips,
        maxDisplaySize: Int, maxThumbnailSize: Int
    ) async -> (display: NSImage, thumb: NSImage?)? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let device = ImageStretcher.metalDevice,
              let result = try? FITSReader.readIntoBuffer(from: url, device: device)
        else { return nil }

        guard let display = await ImageStretcher.createBayerImage(
            inputBuffer: result.metalBuffer,
            width: result.metadata.width, height: result.metadata.height,
            rOffset: rOffset, clips: clips, maxDisplaySize: maxDisplaySize
        ) else { return nil }

        let thumb = ImageStretcher.createThumbnail(from: display, maxSize: maxThumbnailSize)
        return (display, thumb)
    }

    /// Phase A of the loading pipeline: read the FITS file, compute the histogram,
    /// and GPU-stretch to produce the display image and thumbnail.
    ///
    /// The returned `FastLoadResult.metalBuffer` is retained so Phase B can run
    /// GPU star-detection on the same buffer without a second file read.
    private nonisolated static func loadFast(url: URL,
                                              maxDisplaySize: Int = 1024,
                                              maxThumbnailSize: Int = 120,
                                              debayerColorImages: Bool = false) async -> FastLoadResult {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta     = bufferResult.metadata
            let floatPtr = bufferResult.metalBuffer.contents().assumingMemoryBound(to: Float.self)
            let histogram = MetricsCalculator.computeHistogram(ptr: floatPtr,
                                                               count: meta.width * meta.height,
                                                               minVal: meta.minValue,
                                                               maxVal: meta.maxValue)

            // Always render a greyscale image immediately so the UI shows something fast.
            // For Bayer images with debayering enabled, also compute per-channel clip bounds
            // so the post-batch normalise pass can re-render in colour with shared median clips.
            let display = await ImageStretcher.createImage(inputBuffer: bufferResult.metalBuffer,
                                                           width: meta.width, height: meta.height,
                                                           maxDisplaySize: maxDisplaySize)
            let bayerClips: BayerClips?
            if debayerColorImages, let pattern = BayerPattern.parse(from: meta.headers) {
                bayerClips = ImageStretcher.computeBayerClips(bufferResult.metalBuffer,
                                                              width: meta.width, height: meta.height,
                                                              rOffset: pattern.rOffset)
            } else {
                bayerClips = nil
            }

            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            // metalBuffer is retained in FastLoadResult so Phase B can use it.
            return FastLoadResult(
                display: display, thumb: thumb,
                info: "\(meta.width) × \(meta.height)  |  BITPIX: \(meta.bitpix)",
                error: nil, histogram: histogram, headers: meta.headers,
                metalBuffer: bufferResult.metalBuffer, metalDevice: device,
                width: meta.width, height: meta.height, bitpix: meta.bitpix,
                bayerClips: bayerClips)
        }

        do {
            var fits  = try FITSReader.read(from: url)
            let histogram = MetricsCalculator.computeHistogram(pixels: fits.pixelValues,
                                                               minVal: fits.minValue, maxVal: fits.maxValue)
            let display = ImageStretcher.createImage(from: &fits.pixelValues,
                                                     width: fits.width, height: fits.height,
                                                     maxDisplaySize: maxDisplaySize)
            let info    = "\(fits.width) × \(fits.height)  |  BITPIX: \(fits.bitpix)"
            let headers = fits.headers
            let w = fits.width, h = fits.height
            fits.pixelValues = []
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return FastLoadResult(display: display, thumb: thumb, info: info, error: nil,
                                  histogram: histogram, headers: headers,
                                  metalBuffer: nil, metalDevice: nil,
                                  width: w, height: h, bitpix: fits.bitpix,
                                  bayerClips: nil)
        } catch {
            return FastLoadResult(display: nil, thumb: nil, info: "", error: error.localizedDescription,
                                  histogram: nil, headers: [:],
                                  metalBuffer: nil, metalDevice: nil,
                                  width: 0, height: 0, bitpix: 0,
                                  bayerClips: nil)
        }
    }
}

// MARK: - Private result types

private struct FastLoadResult {
    let display:     NSImage?
    let thumb:       NSImage?
    let info:        String
    let error:       String?
    let histogram:   [Int]?
    let headers:     [String: String]
    /// Raw FITS float pixels in a Metal shared buffer. Passed to Phase B so
    /// GPU detection and Moffat fitting can run without a second file read.
    /// Released when the Phase B task ends. `nil` when the CPU fallback path
    /// was used (Metal unavailable).
    let metalBuffer: MTLBuffer?
    let metalDevice: MTLDevice?
    let width:       Int
    let height:      Int
    /// Original FITS BITPIX value.
    let bitpix:      Int
    /// Per-channel Bayer clip bounds computed during the grey-pass.
    /// `nil` for non-Bayer images or when `debayerColorImages` is false.
    let bayerClips:  BayerClips?
}

// MARK: - AsyncSemaphore

/// Async-friendly counting semaphore. Callers that exceed the concurrency cap
/// are suspended and resumed in FIFO order as earlier callers call `signal()`.
private actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}

