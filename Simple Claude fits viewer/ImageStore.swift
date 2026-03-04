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
    var thumbnailSortOrder: ThumbnailSortOrder = .filename
    var thumbnailSortAscending: Bool = true

    var sortedEntries: [ImageEntry] {
        let asc = thumbnailSortAscending
        switch thumbnailSortOrder {
        case .filename:
            return asc ? entries : entries.reversed()
        case .qualityScore:
            return entries.sorted { a, b in
                let av = a.metrics?.qualityScore ?? -1
                let bv = b.metrics?.qualityScore ?? -1
                return asc ? av < bv : av > bv
            }
        case .fwhm:
            return entries.sorted { a, b in
                switch (a.metrics?.fwhm, b.metrics?.fwhm) {
                case let (fa?, fb?): return asc ? fa < fb : fa > fb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .eccentricity:
            return entries.sorted { a, b in
                switch (a.metrics?.eccentricity, b.metrics?.eccentricity) {
                case let (ea?, eb?): return asc ? ea < eb : ea > eb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .snr:
            return entries.sorted { a, b in
                switch (a.metrics?.snr, b.metrics?.snr) {
                case let (sa?, sb?): return asc ? sa < sb : sa > sb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .starCount:
            return entries.sorted { a, b in
                switch (a.metrics?.starCount, b.metrics?.starCount) {
                case let (ca?, cb?): return asc ? ca < cb : ca > cb
                case (_?, nil):      return true
                case (nil, _?):      return false
                default:             return false
                }
            }
        case .rating:
            return entries.sorted { asc ? $0.rating < $1.rating : $0.rating > $1.rating }
        }
    }

    // MARK: - Reset

    func reset() {
        entries = []
        selectedEntry = nil
        batchElapsed = nil
        isBatchProcessing = false
        errorMessage = nil
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
            selectedEntry = ordered[ordered.count - 1]
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
            selectedEntry = ordered[0]
        } else {
            selectedEntry = ordered[index + 1]
        }
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
        guard let entry = selectedEntry, !entry.isRejected else { return }

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
            errorMessage = "Failed to reject image: \(error.localizedDescription)"
        }
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
                  metricsConfig: settings.metricsConfig)
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
                  metricsConfig: settings.metricsConfig)
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

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        Task { [weak self] in
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

        Task { [weak self] in
            guard let self else { return }
            let maxConcurrency = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)

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

            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
        }
    }

    private nonisolated static func loadMetricsOnly(url: URL,
                                                     config: MetricsConfig) async -> FrameMetrics? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }
        guard let fits = try? FITSReader.read(from: url) else { return nil }
        return await MetricsCalculator.compute(pixels: fits.pixelValues,
                                               width: fits.width, height: fits.height,
                                               config: config)
    }

    // MARK: - Concurrent pipeline

    /// Single-phase pipeline: GPU stretch + histogram + metrics computed together
    /// from the same Metal buffer, so the file is only read once per image.
    private func processParallel(_ entriesToProcess: [ImageEntry], selectFirst: Bool,
                                  maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                                  metricsConfig: MetricsConfig = MetricsConfig()) async {

        let concurrency = max(4, min(ProcessInfo.processInfo.activeProcessorCount, 8))

        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0
            for entry in entriesToProcess {
                if activeCount >= concurrency {
                    await group.next()
                    activeCount -= 1
                }
                let url = entry.url
                group.addTask { [weak self] in
                    let result = await Self.loadDisplay(url: url,
                                                       maxDisplaySize: maxDisplaySize,
                                                       maxThumbnailSize: maxThumbnailSize,
                                                       metricsConfig: metricsConfig)
                    await MainActor.run { [weak self] in
                        entry.displayImage = result.display
                        entry.thumbnail    = result.thumb
                        entry.imageInfo    = result.info
                        entry.errorMessage = result.error
                        entry.histogram     = result.histogram
                        entry.headers       = result.headers
                        entry.cachedMetrics = result.metrics
                        entry.metrics       = result.metrics
                        entry.isProcessing  = false

                        if selectFirst, entry === entriesToProcess.first, result.display != nil {
                            self?.selectedEntry = entry
                        }
                    }
                }
                activeCount += 1
            }
        }
    }

    /// Load, GPU-stretch, and compute all metrics for a single FITS file in one pass.
    ///
    /// Metrics are computed directly from the Metal shared buffer while it is still
    /// live — eliminating the previous Phase 2 re-read of the file. The pixel data
    /// never needs to be copied into a separate [Float] array.
    private nonisolated static func loadDisplay(url: URL,
                                                maxDisplaySize: Int = 1024,
                                                maxThumbnailSize: Int = 120,
                                                metricsConfig: MetricsConfig = MetricsConfig()) async -> DisplayLoadResult {
        let didStartAccessing = url.startAccessingSecurityScopedResource()
        defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }

        // GPU path: read pixels into Metal shared buffer, compute everything from it.
        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta    = bufferResult.metadata
            let count   = meta.width * meta.height
            let info    = "\(meta.width) × \(meta.height)  |  BITPIX: \(meta.bitpix)"
            let floatPtr = bufferResult.metalBuffer.contents().assumingMemoryBound(to: Float.self)

            let histogram = MetricsCalculator.computeHistogram(ptr: floatPtr, count: count)
            // GPU path: pixel data is already in the Metal shared buffer, so the
            // detection kernel reads it without any copy. Full-frame detection —
            // no crop limit — using the detectLocalMaxima compute shader.
            let metrics   = await MetricsCalculator.compute(metalBuffer: bufferResult.metalBuffer,
                                                            device: device,
                                                            width: meta.width, height: meta.height,
                                                            config: metricsConfig)
            let display = ImageStretcher.createImage(inputBuffer: bufferResult.metalBuffer,
                                                     width: meta.width, height: meta.height,
                                                     maxDisplaySize: maxDisplaySize)
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return DisplayLoadResult(display: display, thumb: thumb, info: info, error: nil,
                                     histogram: histogram, headers: meta.headers, metrics: metrics)
        }

        // CPU fallback: read into [Float], compute everything, then release the array.
        do {
            var fits = try FITSReader.read(from: url)
            let info      = "\(fits.width) × \(fits.height)  |  BITPIX: \(fits.bitpix)"
            let histogram = MetricsCalculator.computeHistogram(pixels: fits.pixelValues,
                                                               width: fits.width, height: fits.height)
            let metrics   = await MetricsCalculator.compute(pixels: fits.pixelValues,
                                                            width: fits.width, height: fits.height,
                                                            config: metricsConfig)
            let display   = ImageStretcher.createImage(from: &fits.pixelValues, width: fits.width,
                                                       height: fits.height, maxDisplaySize: maxDisplaySize)
            let headers   = fits.headers
            fits.pixelValues = []
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return DisplayLoadResult(display: display, thumb: thumb, info: info, error: nil,
                                     histogram: histogram, headers: headers, metrics: metrics)
        } catch {
            return DisplayLoadResult(display: nil, thumb: nil, info: "", error: error.localizedDescription,
                                     histogram: nil, headers: [:], metrics: nil)
        }
    }
}

// MARK: - Private result types

private struct DisplayLoadResult {
    let display: NSImage?
    let thumb: NSImage?
    let info: String
    let error: String?
    let histogram: [Int]?
    let headers: [String: String]
    let metrics: FrameMetrics?
}

