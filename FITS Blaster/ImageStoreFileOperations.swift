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

    /// The session bookmark of the deepest opened, dropped or granted folder that
    /// contains `fileURL`; nil when there is none (a dropped single file).
    func bookmark(for fileURL: URL) -> Data? {
        let path = fileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return sessionBookmarks
            .filter { path.hasPrefix(Self.folderPrefix($0.key)) }
            .max { Self.folderPrefix($0.key).count < Self.folderPrefix($1.key).count }?
            .value
    }

    /// Remembers access to `folder` for this run of the app; returns the bookmark.
    @discardableResult
    func registerFolder(_ folder: URL) -> Data? {
        guard let bookmark = try? folder.bookmarkData(options: .withSecurityScope,
                                                      includingResourceValuesForKeys: nil,
                                                      relativeTo: nil) else { return nil }
        sessionBookmarks[folder.standardizedFileURL] = bookmark
        return bookmark
    }

    /// The folder's real path (symlinks resolved, e.g. /var → /private/var) with a
    /// trailing slash, so /a/LIGHT doesn't match /a/LIGHT2.
    nonisolated static func folderPrefix(_ folder: URL) -> String {
        let path = folder.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.hasSuffix("/") ? path : path + "/"
    }

    // MARK: - Reject

    func rejectSelected() {
        if !markedForRejectionIDs.isEmpty {
            rejectEntries(entries.filter { markedForRejectionIDs.contains($0.id) })
        } else if let entry = selectedEntry {
            rejectEntries([entry])
        }
    }

    func rejectEntry(_ entry: ImageEntry) {
        rejectEntries([entry])
    }

    /// Rejects each entry. Entries whose folder the sandbox hasn't granted wait in a
    /// `folderAccessRequest` for the first such folder; the others are rejected now.
    func rejectEntries(_ entriesToReject: [ImageEntry]) {
        var waiting: [ImageEntry] = []
        for entry in entriesToReject where !entry.isRejected {
            if moveToRejected(entry) == .needsFolderAccess { waiting.append(entry) }
        }
        if let first = waiting.first, folderAccessRequest == nil {
            folderAccessRequest = FolderAccessRequest(folder: first.url.deletingLastPathComponent(),
                                                      entryIDs: waiting.map(\.id))
        }
    }

    private enum MoveResult { case moved, failed, needsFolderAccess }

    /// Moves one frame into REJECTED next to it. A missing folder permission becomes
    /// `.needsFolderAccess` when the user can grant it (sandbox) and the folder wasn't
    /// granted already; any other failure sets `errorMessage`.
    private func moveToRejected(_ entry: ImageEntry) -> MoveResult {
        let canAsk = asksForFolderAccess && bookmark(for: entry.url) == nil

        guard let dirURL = accessDirectory(for: entry) else {
            if canAsk { return .needsFolderAccess }
            errorMessage = "Failed to reject \(entry.fileName): folder access unavailable. Close and re-open the folder to restore access."
            return .failed
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
            return .moved
        } catch {
            if canAsk, Self.isPermissionDenied(error) { return .needsFolderAccess }
            errorMessage = "Failed to reject \(entry.fileName): \(error.localizedDescription)"
            return .failed
        }
    }

    /// True for "no permission" errors from FileManager (Cocoa or POSIX).
    nonisolated static func isPermissionDenied(_ error: Error) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if ns.domain == NSPOSIXErrorDomain, [Int(EPERM), Int(EACCES)].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionDenied(underlying) }
        return false
    }

    /// The user chose `folder` in answer to `folderAccessRequest`: remember it, give
    /// every frame inside it the bookmark, and reject the waiting frames.
    func grantFolderAccess(_ folder: URL) {
        guard let request = folderAccessRequest else { return }
        folderAccessRequest = nil
        guard Self.folderPrefix(request.folder).hasPrefix(Self.folderPrefix(folder)) else {
            errorMessage = "To reject these frames, choose the folder \"\(request.folder.lastPathComponent)\" (or one that contains it)."
            return
        }
        guard let bookmark = registerFolder(folder) else {
            errorMessage = "Could not get access to \"\(folder.lastPathComponent)\"."
            return
        }
        let prefix = Self.folderPrefix(folder)
        for entry in entries where entry.url.resolvingSymlinksInPath().path(percentEncoded: false).hasPrefix(prefix) {
            entry.directoryBookmark = bookmark
        }
        rejectEntries(entries.filter { request.entryIDs.contains($0.id) })
    }

    /// The user cancelled the folder-access question: nothing is rejected.
    func cancelFolderAccessRequest() {
        folderAccessRequest = nil
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
        // POSIX readdir instead of FileManager.contentsOfDirectory: on an SMB share the
        // latter was about 35 times slower (75 s against 2.3 s for 1290 files, measured
        // 2026-10-25), and readdir gives the item type without asking for each item.
        // Symlinks in the folder's path resolved, as FileManager did (/var → /private/var),
        // so the frames' URLs are the same as before.
        let folder = realFolder(folder)
        guard let listing = listDirectory(folder) else { return [] }

        var results: [(URL, String)] = []
        let sorted = listing.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        for (name, isDir) in sorted {
            let item = folder.appending(component: name, directoryHint: isDir ? .isDirectory : .notDirectory)
            if isDir {
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

    /// The folder with symlinks in its path resolved (`realpath`); unchanged when that fails.
    nonisolated static func realFolder(_ folder: URL) -> URL {
        guard let resolved = realpath(folder.path(percentEncoded: false), nil) else { return folder }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
    }

    /// The visible entries of a directory, with whether each is a folder; nil when it
    /// can't be read. Names starting with "." are skipped (the Finder "hidden" flag isn't
    /// checked: that would cost a request per file on a network share). When the file
    /// system doesn't report the type, `lstat` decides.
    nonisolated static func listDirectory(_ folder: URL) -> [(name: String, isDirectory: Bool)]? {
        let path = folder.path(percentEncoded: false)
        guard let dir = opendir(path) else { return nil }
        defer { closedir(dir) }
        var entries: [(name: String, isDirectory: Bool)] = []
        while let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }
            guard !name.hasPrefix(".") else { continue }
            let isDirectory: Bool
            switch Int32(entry.pointee.d_type) {
            case DT_DIR: isDirectory = true
            case DT_UNKNOWN:
                var info = stat()
                isDirectory = lstat(path + "/" + name, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
            default: isDirectory = false
            }
            entries.append((name, isDirectory))
        }
        return entries
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
        registerFolder(folderURL)
        preparation = .scanning(folder: folderURL.lastPathComponent)
        let collected = await Self.scanFolder(folderURL, excludedNames: excludedSet,
                                              includeSubfolders: includeSubfolders,
                                              includeRejected: includeRejected)
        preparation = nil
        if didAccess { folderURL.stopAccessingSecurityScopedResource() }

        guard !collected.isEmpty else {
            errorMessage = "No FITS files found in the selected folder."
            return
        }
        knownRootURLs.insert(folderURL)
        rootFolderName = folderURL.lastPathComponent
        openFiles(collected, rejectedURLs: includeRejected ? Self.rejectedURLs(in: collected) : [],
                  rootFolderName: folderURL.lastPathComponent,
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
        let includeSubfolders = settings.includeSubfolders

        // Sort out folders and files now, and make each dropped folder's bookmark while
        // the drop's access is fresh (CODE_AUDIT §5.13); the scan follows off the main thread.
        var items: [(url: URL, isFolder: Bool)] = []
        for url in urls {
            guard let isDirectory = Self.isDirectory(url) else { continue }
            if isDirectory {
                registerFolder(url)
                items.append((url, true))
            } else if FITSFile.hasFITSExtension(url) {
                items.append((url, false))
            }
        }
        guard !items.isEmpty else { return }

        // A drop that arrives while the previous one is still scanning waits for it.
        let previous = dropScanTask
        dropScanTask = Task { [weak self] in
            await previous?.value
            var collected: [(url: URL, subfolderPath: String)] = []
            // Each frame's root folder name, so the sidebar shows a section per dropped
            // folder; a dropped file counts as being in its parent folder.
            var rootNames: [URL: String] = [:]
            for item in items {
                if item.isFolder {
                    // Off the main thread: a large folder on a NAS doesn't freeze the window (§7.4).
                    self?.preparation = .scanning(folder: item.url.lastPathComponent)
                    let found = await Self.scanFolder(item.url, excludedNames: excludedSet,
                                                      includeSubfolders: includeSubfolders,
                                                      includeRejected: false)
                    self?.preparation = nil
                    guard !Task.isCancelled else { return }
                    collected.append(contentsOf: found)
                    for frame in found { rootNames[frame.url] = item.url.lastPathComponent }
                } else {
                    collected.append((item.url, ""))
                    rootNames[item.url] = item.url.deletingLastPathComponent().lastPathComponent
                }
            }
            guard let self, !collected.isEmpty else { return }
            // Single dropped files get no folder bookmark: the sandbox only granted the
            // file. Rejecting one asks for its folder first (folderAccessRequest).

            // One shared name (one folder, or files from one folder) is also the session's
            // root name, as when a single folder is opened.
            let distinctNames = Set(rootNames.values)
            let folderRootName = distinctNames.count == 1 ? distinctNames.first ?? "" : ""
            if !folderRootName.isEmpty { rootFolderName = folderRootName }

            // Track dropped folder URLs so we can detect if the same folder is dropped again.
            for item in items where item.isFolder { knownRootURLs.insert(item.url) }

            openFiles(collected, rootFolderName: folderRootName, rootFolderNames: rootNames,
                      maxDisplaySize: settings.maxDisplaySize,
                      maxThumbnailSize: settings.maxThumbnailSize,
                      metricsConfig: settings.effectiveMetricsConfig,
                      debayerColorImages: settings.debayerColorImages)
        }
    }

    /// True for a folder, false for a file, nil when the item doesn't exist.
    nonisolated static func isDirectory(_ url: URL) -> Bool? {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory
    }
}
