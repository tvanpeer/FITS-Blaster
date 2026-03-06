//
//  ImageStore.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 28/02/2026.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Thumbnail sort order

enum ThumbnailSortOrder: String, CaseIterable {
    case filename     = "Name"
    case qualityScore = "Score"
    case fwhm         = "FWHM"
    case eccentricity = "Eccentricity"
    case snr          = "SNR"
    case starCount    = "Stars"
    case rating       = "Rating"
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

    /// Star rating: 0 = unrated, 1–5
    var rating: Int = 0

    /// The FILTER header value, cleaned of FITS string quoting
    var filterName: String? {
        guard let raw = headers["FILTER"] else { return nil }
        let cleaned = FITSReader.cleanHeaderString(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Canonical filter group derived from the raw FILTER header value.
    var filterGroup: FilterGroup { FilterGroup.normalise(filterName) }

    init(url: URL, directoryBookmark: Data? = nil) {
        self.url = url
        self.originalURL = url
        self.fileName = url.lastPathComponent
        self.directoryBookmark = directoryBookmark
    }
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
    var batchElapsed: Double?
    var isBatchProcessing: Bool = false
    var errorMessage: String?
    var thumbnailSortOrder: ThumbnailSortOrder = .filename {
        didSet { updateCachedSort() }
    }
    var thumbnailSortAscending: Bool = true {
        didSet { updateCachedSort() }
    }

    /// The filter group currently highlighted in the sidebar filter strip.
    /// `nil` means "show all groups". Cleared on reset.
    var sidebarFilterGroup: FilterGroup? = nil

    // MARK: - Filter grouping

    /// Unique filter groups present in the loaded session, in canonical display order.
    /// Stored (not computed) to avoid O(n) Set creation on every sidebar render.
    /// Updated at batch boundaries via `updateActiveFilterGroups()`.
    private(set) var activeFilterGroups: [FilterGroup] = []

    private func updateActiveFilterGroups() {
        let present = Set(entries.map { $0.filterGroup })
        activeFilterGroups = FilterGroup.allCases.filter { present.contains($0) }
    }

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
        case .rating:
            cachedSortedEntries = entries.sorted { asc ? $0.rating < $1.rating : $0.rating > $1.rating }
        }
    }

    /// `sortedEntries` filtered to the sidebar selection, or all entries when no
    /// filter is active.
    var filteredSortedEntries: [ImageEntry] {
        guard let group = sidebarFilterGroup else { return sortedEntries }
        return sortedEntries.filter { $0.filterGroup == group }
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

    private func updateGroupStatistics() {
        let grouped = Dictionary(grouping: entries) { $0.filterGroup }
        var result: [FilterGroup: GroupStats] = [:]
        for group in FilterGroup.allCases {
            guard let groupEntries = grouped[group], !groupEntries.isEmpty else { continue }
            let fwhms  = groupEntries.compactMap { $0.metrics?.fwhm }.sorted()
            let stars  = groupEntries.compactMap { $0.metrics?.starCount }.sorted()
            let scores = groupEntries.compactMap { $0.metrics?.qualityScore }.sorted()
            result[group] = GroupStats(
                medianFWHM:         fwhms.isEmpty  ? nil : fwhms[fwhms.count / 2],
                medianStarCount:    stars.isEmpty  ? nil : stars[stars.count / 2],
                topThirdScoreFloor: scores.count < 3 ? nil : scores[scores.count * 2 / 3],
                isNarrowband:       group.isNarrowband
            )
        }
        groupStatistics = result
        updateActiveFilterGroups()
        updateCachedSort()
    }

    var sortedEntries: [ImageEntry] { cachedSortedEntries }

    // MARK: - Reset

    func reset() {
        entries = []
        selectedEntry = nil
        batchElapsed = nil
        isBatchProcessing = false
        errorMessage = nil
        sidebarFilterGroup = nil
        groupStatistics = [:]
        activeFilterGroups = []
        cachedSortedEntries = []
    }

    // MARK: - Navigation

    func selectFirst() {
        guard let first = sortedEntries.first else { return }
        if selectedEntry === first { NSSound.beep() } else { selectedEntry = first }
    }

    func selectLast() {
        guard let last = sortedEntries.last else { return }
        if selectedEntry === last { NSSound.beep() } else { selectedEntry = last }
    }

    func selectPrevious() {
        let ordered = sortedEntries
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

    func selectNext() {
        let ordered = sortedEntries
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

    /// Toggles rejection for the selected entry: rejects if not rejected, undoes if already rejected.
    func toggleRejectSelected() {
        guard let entry = selectedEntry else { return }
        if entry.isRejected { undoRejectSelected() } else { rejectSelected() }
    }

    // MARK: - File Operations

    /// Resolves the directory bookmark for an entry, granting security-scoped access.
    /// The caller must call `stopAccessingSecurityScopedResource()` on the returned URL.
    private func accessDirectory(for entry: ImageEntry) -> URL? {
        guard let bookmark = entry.directoryBookmark else { return nil }
        var isStale = false
        guard let dirURL = try? URL(resolvingBookmarkData: bookmark,
                                     options: .withSecurityScope,
                                     relativeTo: nil,
                                     bookmarkDataIsStale: &isStale) else { return nil }
        _ = dirURL.startAccessingSecurityScopedResource()
        return dirURL
    }

    func rejectSelected() {
        guard let entry = selectedEntry else { return }
        rejectEntry(entry)
    }

    /// Batch-reject multiple entries. Used by the session chart drag-select action.
    func rejectEntries(_ entriesToReject: [ImageEntry]) {
        for entry in entriesToReject { rejectEntry(entry) }
    }

    private func rejectEntry(_ entry: ImageEntry) {
        guard !entry.isRejected else { return }

        let dirURL = accessDirectory(for: entry)
        defer { dirURL?.stopAccessingSecurityScopedResource() }

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

            case .absolute:
                if config.useFWHM, let fwhm = m.fwhm,
                   Double(fwhm) > config.absoluteFWHM { return true }
                if config.useStarCount, let stars = m.starCount,
                   stars < config.absoluteStarCountFloor { return true }
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
        guard let entry = selectedEntry, entry.isRejected else { return }

        let dirURL = accessDirectory(for: entry)
        defer { dirURL?.stopAccessingSecurityScopedResource() }

        let currentURL = entry.url
        let originalURL = entry.originalURL

        do {
            try FileManager.default.moveItem(at: currentURL, to: originalURL)
            entry.url = originalURL
            entry.isRejected = false

            let rejectedDir = currentURL.deletingLastPathComponent()
            let contents = try? FileManager.default.contentsOfDirectory(
                at: rejectedDir, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            if let contents, contents.isEmpty {
                try? FileManager.default.removeItem(at: rejectedDir)
            }
        } catch {
            errorMessage = "Failed to undo rejection: \(error.localizedDescription)"
        }
    }

    // MARK: - Rating

    /// Set the star rating (0 = clear, 1–5) for an entry and persist to the sidecar.
    func setRating(_ rating: Int, for entry: ImageEntry?) {
        guard let entry, (0...5).contains(rating) else { return }
        guard entry.rating != rating else { return }
        entry.rating = rating
        saveSidecar(changedEntry: entry)
        if thumbnailSortOrder == .rating { updateCachedSort() }
    }

    // MARK: - Sidecar persistence

    /// Loads saved ratings from `.culling.json` sidecars for the given entries,
    /// grouping by original parent directory so multi-folder loads are handled correctly.
    private func loadSidecarRatings(for newEntries: [ImageEntry]) {
        let grouped = Dictionary(grouping: newEntries) {
            $0.originalURL.deletingLastPathComponent().path(percentEncoded: false)
        }
        for (_, group) in grouped {
            guard let first = group.first,
                  let dirURL = accessDirectory(for: first) else { continue }
            defer { dirURL.stopAccessingSecurityScopedResource() }

            let sidecarURL = dirURL.appending(component: ".culling.json")
            guard let data = try? Data(contentsOf: sidecarURL),
                  let saved = try? JSONDecoder().decode([String: Int].self, from: data) else { continue }

            for entry in group {
                if let r = saved[entry.fileName], (1...5).contains(r) {
                    entry.rating = r
                }
            }
        }
    }

    /// Saves all ratings for entries sharing the same original parent directory as `changedEntry`.
    private func saveSidecar(changedEntry: ImageEntry) {
        let dirPath = changedEntry.originalURL.deletingLastPathComponent().path(percentEncoded: false)
        let dirEntries = entries.filter {
            $0.originalURL.deletingLastPathComponent().path(percentEncoded: false) == dirPath
        }

        guard let dirURL = accessDirectory(for: changedEntry) else { return }
        defer { dirURL.stopAccessingSecurityScopedResource() }

        var ratings: [String: Int] = [:]
        for entry in dirEntries where entry.rating > 0 {
            ratings[entry.fileName] = entry.rating
        }

        let sidecarURL = dirURL.appending(component: ".culling.json")
        if let data = try? JSONEncoder().encode(ratings) {
            try? data.write(to: sidecarURL, options: .atomic)
        }
    }

    // MARK: - Export

    /// Presents a save panel and writes a frame list in the chosen format.
    /// Only non-rejected frames with `rating >= minimumRating` are included.
    func export(format: ExportFormat, minimumRating: Int) {
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

        let kept = entries.filter { !$0.isRejected && $0.rating >= minimumRating }

        let content: String
        switch format {
        case .plainText:
            content = kept.map { $0.url.path(percentEncoded: false) }.joined(separator: "\n")
        case .csv:
            var lines = ["path,rating,fwhm,eccentricity,snr,stars"]
            for entry in kept {
                let m     = entry.metrics
                let path  = entry.url.path(percentEncoded: false)
                let r     = String(entry.rating)
                let fwhm  = m.flatMap { $0.fwhm }.map        { $0.formatted(.number.precision(.fractionLength(2))) } ?? ""
                let ecc   = m.flatMap { $0.eccentricity }.map { $0.formatted(.number.precision(.fractionLength(3))) } ?? ""
                let snr   = m.flatMap { $0.snr }.map          { $0.formatted(.number.precision(.fractionLength(1))) } ?? ""
                let stars = m.flatMap { $0.starCount }.map     { String($0) } ?? ""
                lines.append("\(path),\(r),\(fwhm),\(ecc),\(snr),\(stars)")
            }
            content = lines.joined(separator: "\n")
        }

        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    // MARK: - File Panels

    func openFolderPanel(settings: AppSettings) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder containing FITS files"
        panel.prompt = "Open"

        guard panel.runModal() == .OK, let folderURL = panel.url else { return }

        let didAccess = folderURL.startAccessingSecurityScopedResource()
        let dirBookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)

        let fitsExtensions: Set<String> = ["fits", "fit", "fts"]
        let fitsURLs: [URL]
        if let contents = try? FileManager.default.contentsOfDirectory(
            at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            fitsURLs = contents
                .filter { fitsExtensions.contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            fitsURLs = []
        }

        if didAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !fitsURLs.isEmpty else {
            errorMessage = "No FITS files found in the selected folder."
            return
        }

        openFiles(fitsURLs, directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig)
    }

    /// Opens dropped URLs (folders and/or individual FITS files) from a drag & drop operation.
    ///
    /// Folders are expanded to their immediate FITS contents. Individual FITS files are used
    /// directly. Files from different directories are all added to the current session.
    func openDroppedItems(_ urls: [URL], settings: AppSettings) {
        let fitsExtensions: Set<String> = ["fits", "fit", "fts"]
        var fitsURLs: [URL] = []
        var dirBookmark: Data?

        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(
                atPath: url.path(percentEncoded: false), isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                // Dropped folder: build a security-scoped bookmark and list FITS files.
                if dirBookmark == nil {
                    dirBookmark = try? url.bookmarkData(
                        options: .withSecurityScope,
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil)
                }
                if let contents = try? FileManager.default.contentsOfDirectory(
                    at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
                    let fits = contents
                        .filter { fitsExtensions.contains($0.pathExtension.lowercased()) }
                        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                    fitsURLs.append(contentsOf: fits)
                }
            } else if fitsExtensions.contains(url.pathExtension.lowercased()) {
                fitsURLs.append(url)
            }
        }

        guard !fitsURLs.isEmpty else { return }

        // For individual dropped files, try to bookmark the parent directory.
        if dirBookmark == nil, let first = fitsURLs.first {
            let parent = first.deletingLastPathComponent()
            dirBookmark = try? parent.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
        }

        openFiles(fitsURLs, directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig)
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
                  metricsConfig: settings.effectiveMetricsConfig)
    }

    // MARK: - Loading

    func openFiles(_ urls: [URL], directoryBookmark: Data? = nil,
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig()) {
        let selectFirst = (selectedEntry == nil)

        var newEntries: [ImageEntry] = []
        for url in urls {
            guard ["fits", "fit", "fts"].contains(url.pathExtension.lowercased()) else { continue }
            let entry = ImageEntry(url: url, directoryBookmark: directoryBookmark)
            entries.append(entry)
            newEntries.append(entry)
        }
        guard !newEntries.isEmpty else { return }

        if selectFirst { selectedEntry = newEntries[0] }

        // Restore saved ratings before processing starts
        loadSidecarRatings(for: newEntries)

        // Populate the sort/filter cache so the sidebar renders immediately
        // with loading spinners while the batch processes in the background.
        updateActiveFilterGroups()
        updateCachedSort()

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            await processParallel(newEntries, selectFirst: selectFirst,
                                  maxDisplaySize: maxDisplaySize,
                                  maxThumbnailSize: maxThumbnailSize,
                                  metricsConfig: metricsConfig)
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
        }
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

        Task { [weak self] in
            guard let self else { return }
            await processParallel(entriesToProcess, selectFirst: false,
                                  maxDisplaySize: settings.maxDisplaySize,
                                  maxThumbnailSize: settings.maxThumbnailSize,
                                  metricsConfig: settings.metricsConfig)
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
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

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // Cap at 2: each recompute task now uses the GPU path (readIntoBuffer +
            // Metal star detection), so two tasks keep the GPU and I/O pipeline full
            // without flooding the thread pool or starving the UI.
            let maxConcurrency = 2

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

            updateGroupStatistics()
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
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
                                                   bitpix: meta.bitpix, config: config)
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
    /// **Phase A** — I/O + GPU stretch (fast, ~100–300 ms): image becomes visible
    /// immediately after the file is read and stretched. The Metal buffer is kept
    /// alive in `FastLoadResult` so Phase B can read from it without a second disk hit.
    ///
    /// **Phase B** — quality metrics (slower, runs after Phase A returns): star
    /// detection + shape measurement computed from the already-loaded buffer.
    /// The user sees the image while metrics are being computed in the background.
    private func processParallel(_ entriesToProcess: [ImageEntry], selectFirst: Bool,
                                  maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                                  metricsConfig: MetricsConfig = MetricsConfig()) async {

        // 3 concurrent tasks: enough to keep the GPU and I/O pipeline saturated
        // without disk-thrashing on large FITS files.
        let concurrency = 3

        // Task group returns (entry, metrics) so Phase B results are applied
        // directly on the main actor in the collection loop — no second
        // MainActor.run hop, halving the number of SwiftUI render triggers.
        await withTaskGroup(of: (ImageEntry, FrameMetrics?).self) { group in
            var activeCount = 0
            for entry in entriesToProcess {
                if activeCount >= concurrency {
                    if let (e, m) = await group.next() {
                        e.metrics      = m
                        e.cachedMetrics = m
                    }
                    activeCount -= 1
                }
                let url = entry.url
                group.addTask { [weak self] in
                    // ── Phase A: I/O + histogram + GPU stretch ────────────────
                    let fast = await Self.loadFast(url: url,
                                                   maxDisplaySize: maxDisplaySize,
                                                   maxThumbnailSize: maxThumbnailSize)
                    await MainActor.run { [weak self] in
                        entry.displayImage = fast.display
                        entry.thumbnail    = fast.thumb
                        entry.imageInfo    = fast.info
                        entry.errorMessage = fast.error
                        entry.histogram    = fast.histogram
                        entry.headers      = fast.headers
                        entry.isProcessing = false   // ← image visible now

                        if selectFirst, entry === entriesToProcess.first, fast.display != nil {
                            self?.selectedEntry = entry
                        }
                    }

                    // ── Phase B: quality metrics ──────────────────────────────
                    // Reuses the Metal buffer from Phase A (no second file read).
                    // Falls back to loadMetricsOnly only when Metal was unavailable.
                    let metrics: FrameMetrics?
                    if let buffer = fast.metalBuffer, let device = fast.metalDevice {
                        metrics = await MetricsCalculator.compute(
                            metalBuffer: buffer, device: device,
                            width: fast.width, height: fast.height,
                            bitpix: fast.bitpix, config: metricsConfig)
                    } else if metricsConfig.needsStarDetection {
                        metrics = await Self.loadMetricsOnly(url: url, config: metricsConfig)
                    } else {
                        metrics = nil
                    }

                    return (entry, metrics)
                }
                activeCount += 1
            }
            // Drain remaining tasks, applying metrics on the main actor directly.
            for await (e, m) in group {
                e.metrics      = m
                e.cachedMetrics = m
            }
        }

        updateGroupStatistics()
    }

    /// Phase A of the loading pipeline: read the FITS file, compute the histogram,
    /// and GPU-stretch to produce the display image and thumbnail.
    ///
    /// Does NOT compute quality metrics — those run in Phase B from the returned
    /// Metal buffer, keeping the two phases independent.
    private nonisolated static func loadFast(url: URL,
                                              maxDisplaySize: Int = 1024,
                                              maxThumbnailSize: Int = 120) async -> FastLoadResult {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta     = bufferResult.metadata
            let floatPtr = bufferResult.metalBuffer.contents().assumingMemoryBound(to: Float.self)
            let histogram = MetricsCalculator.computeHistogram(ptr: floatPtr,
                                                               count: meta.width * meta.height)
            let display = ImageStretcher.createImage(inputBuffer: bufferResult.metalBuffer,
                                                     width: meta.width, height: meta.height,
                                                     maxDisplaySize: maxDisplaySize)
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return FastLoadResult(
                display: display, thumb: thumb,
                info: "\(meta.width) × \(meta.height)  |  BITPIX: \(meta.bitpix)",
                error: nil, histogram: histogram, headers: meta.headers,
                metalBuffer: bufferResult.metalBuffer, metalDevice: device,
                width: meta.width, height: meta.height, bitpix: meta.bitpix)
        }

        do {
            var fits  = try FITSReader.read(from: url)
            let histogram = MetricsCalculator.computeHistogram(pixels: fits.pixelValues,
                                                               width: fits.width, height: fits.height)
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
                                  metalBuffer: nil, metalDevice: nil, width: w, height: h, bitpix: fits.bitpix)
        } catch {
            return FastLoadResult(display: nil, thumb: nil, info: "", error: error.localizedDescription,
                                  histogram: nil, headers: [:],
                                  metalBuffer: nil, metalDevice: nil, width: 0, height: 0, bitpix: 0)
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
    /// Raw FITS float pixels — kept alive so Phase B (metrics) can read them
    /// without a second file read. `nil` when the CPU fallback was used.
    let metalBuffer: MTLBuffer?
    let metalDevice: MTLDevice?
    let width:       Int
    let height:      Int
    /// Original FITS BITPIX value — forwarded to MetricsCalculator so it can
    /// skip NMS for integer images (BITPIX > 0) where it is not needed.
    let bitpix:      Int
}

