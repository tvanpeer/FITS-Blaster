//
//  ImageStore.swift
//  FITS Blaster
//
//  Core class: stored properties, sort/filter/grouping helpers, navigation, and
//  selection. File operations live in ImageStoreFileOperations.swift; the loading
//  and reprocessing pipeline lives in ImageStorePipeline.swift.
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

    init(url: URL, originalURL: URL? = nil, directoryBookmark: Data? = nil) {
        self.url = url
        self.originalURL = originalURL ?? url
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
    var batchElapsed: Double?
    var isBatchProcessing: Bool = false

    /// The currently running load / reprocess task. Stored so it can be cancelled by the user.
    /// Internal (not private(set)) so the pipeline extension can update it.
    var processingTask: Task<Void, Never>?

    // MARK: - Batch progress counters
    // batchLoadedCount and batchMetricsCount are intentionally absent: updating them
    // per-image via MainActor.run creates back-pressure that serialises the pipeline.
    // BatchProgressBar polls entry state every 200 ms instead (see its .task modifier).
    // Only the lower-frequency colour/sampling counters are stored here.
    /// Set to the Bayer entry count when normalizeBayerStretch begins; 0 at all other times.
    var batchBayerTotal: Int = 0
    var batchColourCount: Int = 0
    /// Tracks per-channel clip sampling before colour rendering begins (recolorImages path).
    var batchSamplingTotal: Int = 0
    var batchSamplingCount: Int = 0

    /// Non-nil while a Bayer re-render pass is running; the value is the status message to display.
    /// Internal (not private(set)) so the pipeline extension can update it.
    var recolouringMessage: String? = nil

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
    /// Internal (not private(set)) so the file-operations extension can update it.
    var rootFolderName: String = ""

    /// Root folder URLs that have been opened in this session.
    /// Used to detect when the user opens the same directory a second time.
    /// Internal (not private) so the file-operations extension can update it.
    var knownRootURLs: Set<URL> = []

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
        let idsToRemove: Set<UUID> = !flaggedEntryIDs.isEmpty
            ? flaggedEntryIDs
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
        flaggedEntryIDs = []
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
        collapsedFolderPaths = []
        visibilityFilteredEntries = []
        batchBayerTotal = 0
        batchColourCount = 0
        batchSamplingTotal = 0
        batchSamplingCount = 0
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
