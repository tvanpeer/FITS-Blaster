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

    /// Batch-reject multiple entries.
    func rejectEntries(_ entriesToReject: [ImageEntry]) {
        for entry in entriesToReject { rejectEntry(entry) }
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

    // MARK: - Undo reject

    func undoRejectSelected() {
        if !markedForRejectionIDs.isEmpty {
            entries.filter { markedForRejectionIDs.contains($0.id) && $0.isRejected }
                   .forEach { undoRejectEntry($0) }
        } else if let entry = selectedEntry, entry.isRejected {
            undoRejectEntry(entry)
        }
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
        includeSubfolders: Bool,
        includeRejected: Bool = false
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
    @MainActor private final class PanelAccessoryHelper: NSObject {
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

        let collected = Self.collectFITSURLs(in: folderURL, relativePath: "",
                                             excludedNames: excludedSet,
                                             includeSubfolders: includeSubfolders,
                                             includeRejected: includeRejected)

        // Any file whose immediate parent directory is named REJECTED is a rejected file.
        let rejectedURLs: Set<URL> = includeRejected
            ? Set(collected.filter {
                $0.url.deletingLastPathComponent().lastPathComponent
                    .caseInsensitiveCompare("REJECTED") == .orderedSame
              }.map { $0.url })
            : []

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
}
