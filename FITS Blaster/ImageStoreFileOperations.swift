//
//  ImageStoreFileOperations.swift
//  FITS Blaster
//
//  Reject / undo-reject, export, FITS discovery, file panels, and drag-drop.
//

import Foundation
import AppKit
import UniformTypeIdentifiers

extension ImageStore {

    // MARK: - Bookmark / security-scoped access

    /// Resolves the directory bookmark for an entry, granting security-scoped access.
    /// The caller must call `stopAccessingSecurityScopedResource()` on the returned URL.
    ///
    /// If the stored bookmark is missing or stale, falls back to creating a fresh bookmark
    /// from the entry's parent directory — this succeeds when the user-selected.read-write
    /// entitlement still covers that directory (i.e. during the same app session).
    func accessDirectory(for entry: ImageEntry) -> URL? {
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

    // MARK: - Reject

    func rejectSelected() {
        if !markedForRejectionIDs.isEmpty {
            entries.filter { markedForRejectionIDs.contains($0.id) }.forEach { rejectEntry($0) }
        } else if let entry = selectedEntry {
            rejectEntry(entry)
        }
    }

    func rejectEntry(_ entry: ImageEntry) {
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
            if Self.isDirectory(rejectedDir) == nil {
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

    // MARK: - Flag / unflag

    /// Adds entries to the flagged set (drives the "Flagged" filter) without rejecting.
    func flagEntries(_ entriesToFlag: [ImageEntry]) {
        flaggedEntryIDs = flaggedEntryIDs.union(entriesToFlag.map(\.id))
    }

    /// Removes IDs from the flagged set.
    func unflagEntries(_ ids: Set<UUID>) {
        flaggedEntryIDs.subtract(ids)
    }

    /// Removes all entries from the flagged set.
    func deflagAll() {
        flaggedEntryIDs = []
    }

    /// Toggles the flag state of the orange range selection, or the cursor entry if no range is active.
    func toggleFlagSelected() {
        if !markedForRejectionIDs.isEmpty {
            let batch = entries.filter { markedForRejectionIDs.contains($0.id) }
            if batch.allSatisfy({ flaggedEntryIDs.contains($0.id) }) {
                unflagEntries(markedForRejectionIDs)
            } else {
                flagEntries(batch.filter { !flaggedEntryIDs.contains($0.id) })
            }
        } else {
            guard let entry = selectedEntry else { return }
            if flaggedEntryIDs.contains(entry.id) {
                unflagEntries([entry.id])
            } else {
                flagEntries([entry])
            }
        }
    }

    // MARK: - Flip

    /// Toggles the 180° display rotation for the current selection (batch or single).
    func toggleFlipSelected() {
        if !markedForRejectionIDs.isEmpty {
            let batch = entries.filter { markedForRejectionIDs.contains($0.id) }
            let allFlipped = batch.allSatisfy(\.isFlipped)
            for entry in batch { entry.isFlipped = !allFlipped }
        } else {
            guard let entry = selectedEntry else { return }
            entry.isFlipped.toggle()
        }
    }

    /// Flags all frames that match `config` by adding them to the selection.
    func applyAutoFlag(config: AutoRejectConfig) {
        flagEntries(previewAutoReject(config: config))
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
                if config.useSkyBackground, let bg = m.skyBackground, let medBG = gs?.medianSkyBackground,
                   Double(bg) > Double(medBG) * config.skyBackgroundMultiplier { return true }
                if config.usePSF, let psf = m.psfSignalWeight, let medPSF = gs?.medianPSFSignalWeight,
                   Double(psf) < Double(medPSF) * config.psfMultiplier { return true }

            case .absolute:
                if config.useFWHM, let fwhm = m.fwhm,
                   Double(fwhm) > config.absoluteFWHM { return true }
                if config.useStarCount, let stars = m.starCount,
                   Double(stars) < config.absoluteStarCountFloor { return true }
                if config.useSNR, let snr = m.snr,
                   Double(snr) < config.absoluteSNRFloor { return true }
                if config.useSkyBackground, let bg = m.skyBackground,
                   Double(bg) > config.absoluteSkyBackgroundCeiling { return true }
                if config.usePSF, let psf = m.psfSignalWeight,
                   Double(psf) < config.absolutePSFFloor { return true }
                if config.useScore,
                   Double(m.qualityScore) < config.scoreFloor { return true }
            }
            return false
        }
    }

    // MARK: - Undo reject

    func undoRejectSelected() {
        if !markedForRejectionIDs.isEmpty {
            entries.filter { markedForRejectionIDs.contains($0.id) && $0.isRejected }
                   .forEach { undoRejectEntry($0) }
        } else if let entry = selectedEntry, entry.isRejected {
            undoRejectEntry(entry)
        }
    }

    /// Removes the REJECTED folder once the last file has been moved out of it. Only a
    /// Finder `.DS_Store` may remain: hidden files the user put there (sidecars,
    /// dot-files) keep the folder, because `removeItem` would delete them with it
    /// (CODE_AUDIT §5.6).
    nonisolated static func removeFolderIfEmpty(_ folder: URL) {
        guard let contents = try? FileManager.default.contentsOfDirectory(
                  at: folder, includingPropertiesForKeys: nil),
              contents.allSatisfy({ $0.lastPathComponent == ".DS_Store" }) else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    func undoRejectEntry(_ entry: ImageEntry) {
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

            Self.removeFolderIfEmpty(currentURL.deletingLastPathComponent())
        } catch {
            errorMessage = "Failed to undo rejection of \(entry.fileName): \(error.localizedDescription)"
        }
    }

    // MARK: - Export

    /// Writes the frame list to `url` in the chosen format. A write failure is shown
    /// through `errorMessage` (CODE_AUDIT §5.7); the destination comes from
    /// `FileDialogs.chooseExportDestination`.
    ///
    /// - Parameters:
    ///   - format: Plain text (aligned report), CSV, or TSV.
    ///   - includeRejected: When true, rejected frames are also written, with a
    ///     `status` column that distinguishes `kept` from `rejected`.
    ///   - headerKeys: FITS header keys to add as extra columns, in this order.
    func export(to url: URL, format: ExportFormat, includeRejected: Bool,
                headerKeys: [String], pathStyle: PathStyle) {
        let frames = includeRejected ? entries : entries.filter { !$0.isRejected }
        let content = Self.exportContent(frames: frames, format: format,
                                         includeRejected: includeRejected,
                                         headerKeys: headerKeys,
                                         pathStyle: pathStyle)
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            errorMessage = "Could not save \(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    /// The export file content: pure, so it is unit-testable without a save panel.
    static func exportContent(frames: [ImageEntry], format: ExportFormat,
                              includeRejected: Bool, headerKeys: [String],
                              pathStyle: PathStyle) -> String {
        ExportTable(frames: frames, includeRejected: includeRejected,
                    headerKeys: headerKeys, pathStyle: pathStyle).rendered(as: format)
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
        includeSubfolders: Bool,
        includeRejected: Bool = false
    ) -> [(url: URL, subfolderPath: String)] {
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
                let name = item.lastPathComponent
                // REJECTED is handled before the includeSubfolders gate so it is picked up
                // at every depth (root, and inside each subfolder) when includeRejected is on.
                if name.caseInsensitiveCompare("REJECTED") == .orderedSame {
                    if includeRejected {
                        // Use the parent's relativePath so rejected files appear alongside
                        // their siblings in the sidebar rather than in a separate section.
                        results += collectFITSURLs(in: item, relativePath: relativePath,
                                                   excludedNames: [],
                                                   includeSubfolders: false,
                                                   includeRejected: false)
                    }
                    continue
                }
                guard includeSubfolders else { continue }
                // Skip any user-configured exclusion names (case-insensitive).
                guard !excludedNames.contains(name.lowercased()) else { continue }
                let childPath = relativePath.isEmpty ? name : "\(relativePath)/\(name)"
                results += collectFITSURLs(in: item, relativePath: childPath,
                                           excludedNames: excludedNames,
                                           includeSubfolders: true,
                                           includeRejected: includeRejected)
            } else if FITSFile.hasFITSExtension(item) {
                results.append((item, relativePath))
            }
        }
        return results
    }

    /// `collectFITSURLs` off the main thread, so a large folder tree on a NAS, SMB
    /// share or iCloud Drive doesn't freeze the window (CODE_AUDIT §7.4).
    @concurrent static func scanFolder(_ folder: URL, excludedNames: Set<String>,
                                       includeSubfolders: Bool, includeRejected: Bool) async
        -> [(url: URL, subfolderPath: String)] {
        collectFITSURLs(in: folder, relativePath: "", excludedNames: excludedNames,
                        includeSubfolders: includeSubfolders, includeRejected: includeRejected)
    }

    /// The collected files whose immediate parent folder is named REJECTED.
    nonisolated static func rejectedURLs(in collected: [(url: URL, subfolderPath: String)]) -> Set<URL> {
        Set(collected.filter {
            $0.url.deletingLastPathComponent().lastPathComponent
                .caseInsensitiveCompare("REJECTED") == .orderedSame
        }.map(\.url))
    }

    // MARK: - Open folder

    /// True when this folder was opened or dropped before in this session; the caller
    /// asks whether to open it again (`FileDialogs.confirmOpenAgain`).
    func isAlreadyLoaded(_ folder: URL) -> Bool {
        knownRootURLs.contains(folder)
    }

    /// Scans `folderURL` and loads its FITS files. The folder and options come from
    /// `FileDialogs.chooseFolder`; there is no panel or alert in here.
    func openFolder(at folderURL: URL, includeSubfolders: Bool, includeRejected: Bool,
                    settings: AppSettings) async {
        let excludedSet = Set(settings.excludedSubfolderNames.map { $0.lowercased() })
        let didAccess = folderURL.startAccessingSecurityScopedResource()
        let dirBookmark = try? folderURL.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        let collected = await Self.scanFolder(folderURL, excludedNames: excludedSet,
                                              includeSubfolders: includeSubfolders,
                                              includeRejected: includeRejected)
        if didAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !collected.isEmpty else {
            errorMessage = "No FITS files found in the selected folder."
            return
        }
        knownRootURLs.insert(folderURL)
        rootFolderName = folderURL.lastPathComponent
        openFiles(collected, rejectedURLs: includeRejected ? Self.rejectedURLs(in: collected) : [],
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
        let excludedSet = Set(settings.excludedSubfolderNames.map { $0.lowercased() })
        var collected: [(url: URL, subfolderPath: String)] = []
        var dirBookmark: Data?
        var singleDroppedFolderName: String?

        for url in urls {
            guard let isDirectory = Self.isDirectory(url) else { continue }

            if isDirectory {
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
            } else if FITSFile.hasFITSExtension(url) {
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
        for url in urls where Self.isDirectory(url) == true {
            knownRootURLs.insert(url)
        }

        openFiles(collected, rootFolderName: folderRootName,
                  directoryBookmark: dirBookmark,
                  maxDisplaySize: settings.maxDisplaySize,
                  maxThumbnailSize: settings.maxThumbnailSize,
                  metricsConfig: settings.effectiveMetricsConfig,
                  debayerColorImages: settings.debayerColorImages)
    }

    /// True for a folder, false for a file, nil when the item doesn't exist.
    nonisolated static func isDirectory(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
    }
}
