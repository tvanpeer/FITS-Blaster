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
    ///
    /// - Parameters:
    ///   - format: Plain text (paths), CSV, or TSV.
    ///   - includeRejected: When true, rejected frames are also written. In plain
    ///     text they get a trailing `# REJECTED` marker; in CSV/TSV a `status`
    ///     column distinguishes `kept` from `rejected`.
    ///   - headerKeys: FITS header keys to add as extra columns in CSV/TSV.
    ///     Ignored for plain text.
    func export(format: ExportFormat, includeRejected: Bool, headerKeys: [String], pathStyle: PathStyle) {
        let panel = NSSavePanel()
        panel.title = "Export Frame List"
        panel.nameFieldStringValue = "frames.\(format.fileExtension)"
        switch format {
        case .plainText: panel.allowedContentTypes = [.plainText]
        case .csv:       panel.allowedContentTypes = [.commaSeparatedText]
        case .tsv:       panel.allowedContentTypes = [.tabSeparatedText]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let frames = includeRejected ? entries : entries.filter { !$0.isRejected }
        let content = Self.exportContent(frames: frames, format: format,
                                         includeRejected: includeRejected,
                                         headerKeys: headerKeys,
                                         pathStyle: pathStyle)
        try? content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Pure builder so the output is unit-testable without showing a save panel.
    /// Numbers are formatted with a fixed `en_US_POSIX` locale so CSV files written
    /// on Dutch / German / French systems do not produce comma-decimal collisions
    /// with the comma delimiter.
    static func exportContent(frames: [ImageEntry], format: ExportFormat,
                              includeRejected: Bool, headerKeys: [String],
                              pathStyle: PathStyle) -> String {
        let basePath = pathStyle == .relative
            ? commonAncestorPath(of: frames.map { $0.url })
            : ""

        // Drop selected header keys for which no frame has any value. The
        // user is informed upfront in the picker (absent keys appear dimmed),
        // so silently omitting empty columns here keeps the output clean.
        // Plain text additionally surfaces what was dropped via a footer line.
        let usedKeys = headerKeys.filter { key in
            frames.contains { entry in
                let raw = entry.headers[key] ?? ""
                return !FITSReader.cleanHeaderString(raw).isEmpty
            }
        }
        let skippedKeys = headerKeys.filter { !usedKeys.contains($0) }

        switch format {
        case .plainText:
            return formatPaddedReport(frames: frames,
                                      includeRejected: includeRejected,
                                      headerKeys: usedKeys,
                                      skippedKeys: skippedKeys,
                                      pathStyle: pathStyle,
                                      basePath: basePath)

        case .csv, .tsv:
            let delim = format.delimiter

            // Metric columns are omitted entirely when no frame has any metric
            // data — typically a Simple-mode session that never computed them.
            // If any frame has values (even partial), keep the columns so the
            // CSV stays parseable and rows with missing data are simply blank.
            let includeMetrics = frames.contains {
                ($0.metrics ?? $0.cachedMetrics) != nil
            }

            var headerCols = ["path"]
            if includeRejected { headerCols.append("status") }
            if includeMetrics {
                headerCols.append(contentsOf: ["fwhm", "eccentricity", "snr", "stars", "score"])
            }
            headerCols.append(contentsOf: usedKeys)

            var lines = [headerCols.map { quote($0, format: format) }.joined(separator: delim)]

            for entry in frames {
                var cols: [String] = []
                cols.append(formatPath(entry.url, style: pathStyle, basePath: basePath))
                if includeRejected { cols.append(entry.isRejected ? "rejected" : "kept") }
                if includeMetrics {
                    // Prefer cachedMetrics when metrics is nil (e.g. user
                    // disabled a metric after the first compute) so the export
                    // still carries the values that were measured at some
                    // point during the session.
                    let m = entry.metrics ?? entry.cachedMetrics
                    cols.append(formatFraction(m?.fwhm,         digits: 2))
                    cols.append(formatFraction(m?.eccentricity, digits: 3))
                    cols.append(formatFraction(m?.snr,          digits: 1))
                    cols.append(m?.starCount.map { String($0) } ?? "")
                    cols.append(m.map { String($0.qualityScore) } ?? "")
                }
                for key in usedKeys {
                    let raw = entry.headers[key] ?? ""
                    cols.append(FITSReader.cleanHeaderString(raw))
                }
                lines.append(cols.map { quote($0, format: format) }.joined(separator: delim))
            }
            return lines.joined(separator: "\n")
        }
    }

    /// Builds a space-padded, human-readable report (the plain-text export
    /// format). Columns mirror the CSV/TSV layout, but each cell is padded so
    /// the file lines up cleanly in any text editor. Numeric columns are right-
    /// aligned; everything else is left-aligned. The trailing column is not
    /// padded out, to keep lines free of trailing whitespace.
    private static func formatPaddedReport(frames: [ImageEntry],
                                           includeRejected: Bool,
                                           headerKeys: [String],
                                           skippedKeys: [String],
                                           pathStyle: PathStyle,
                                           basePath: String) -> String {
        let includeMetrics = frames.contains {
            ($0.metrics ?? $0.cachedMetrics) != nil
        }

        var headerCols = ["path"]
        if includeRejected { headerCols.append("status") }
        if includeMetrics {
            headerCols.append(contentsOf: ["fwhm", "eccentricity", "snr", "stars", "score"])
        }
        headerCols.append(contentsOf: headerKeys)

        var rows: [[String]] = [headerCols]
        for entry in frames {
            var cols: [String] = []
            cols.append(formatPath(entry.url, style: pathStyle, basePath: basePath))
            if includeRejected { cols.append(entry.isRejected ? "rejected" : "kept") }
            if includeMetrics {
                let m = entry.metrics ?? entry.cachedMetrics
                cols.append(formatFraction(m?.fwhm,         digits: 2))
                cols.append(formatFraction(m?.eccentricity, digits: 3))
                cols.append(formatFraction(m?.snr,          digits: 1))
                cols.append(m?.starCount.map { String($0) } ?? "")
                cols.append(m.map { String($0.qualityScore) } ?? "")
            }
            for key in headerKeys {
                let raw = entry.headers[key] ?? ""
                cols.append(sanitizePadded(FITSReader.cleanHeaderString(raw)))
            }
            rows.append(cols)
        }

        let columnCount = headerCols.count
        var widths = Array(repeating: 0, count: columnCount)
        for row in rows {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // A column is right-aligned when every non-empty data value parses as
        // a number — captures fwhm/snr/score/stars and numeric FITS headers
        // like EXPTIME, GAIN, AIRMASS without hard-coding key names.
        var rightAlign = Array(repeating: false, count: columnCount)
        for i in 0..<columnCount {
            let header = headerCols[i]
            if header == "path" || header == "status" { continue }
            var anyValue = false
            var allNumeric = true
            for row in rows.dropFirst() where i < row.count && !row[i].isEmpty {
                anyValue = true
                if Double(row[i]) == nil { allNumeric = false; break }
            }
            rightAlign[i] = anyValue && allNumeric
        }

        let separator = "  "
        let lines = rows.map { row -> String in
            row.enumerated().map { (i, cell) -> String in
                let isLast = (i == columnCount - 1)
                let pad = max(0, widths[i] - cell.count)
                if rightAlign[i] {
                    return String(repeating: " ", count: pad) + cell
                }
                return isLast ? cell : cell + String(repeating: " ", count: pad)
            }.joined(separator: separator)
        }
        var report = lines.joined(separator: "\n")
        if !skippedKeys.isEmpty {
            report += "\n\n# Skipped columns with no data: " + skippedKeys.joined(separator: ", ")
        }
        return report
    }

    /// Replaces tabs and newlines with spaces so a value can never break the
    /// padded layout. FITS header strings essentially never contain either.
    private static func sanitizePadded(_ s: String) -> String {
        s.replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
    }

    /// Renders a file URL according to the chosen path style. For `.relative`,
    /// `basePath` should be the longest common ancestor directory; if a URL does
    /// not begin with it (which shouldn't happen in practice) the absolute path
    /// is returned as a safe fallback.
    private static func formatPath(_ url: URL, style: PathStyle, basePath: String) -> String {
        let full = url.path(percentEncoded: false)
        switch style {
        case .absolute:
            return full
        case .filename:
            return url.lastPathComponent
        case .relative:
            guard !basePath.isEmpty, full.hasPrefix(basePath) else { return full }
            let stripped = full.dropFirst(basePath.count)
            return stripped.hasPrefix("/") ? String(stripped.dropFirst()) : String(stripped)
        }
    }

    /// Longest directory shared by every URL's parent. Returns an empty string
    /// when the input is empty or the only common component is `/`.
    static func commonAncestorPath(of urls: [URL]) -> String {
        guard let first = urls.first else { return "" }
        var common = first.deletingLastPathComponent().pathComponents
        for url in urls.dropFirst() {
            let parent = url.deletingLastPathComponent().pathComponents
            var prefix: [String] = []
            for (a, b) in zip(common, parent) {
                if a == b { prefix.append(a) } else { break }
            }
            common = prefix
            if common.count <= 1 { break }
        }
        guard common.count > 1 else { return "" }
        return "/" + common.dropFirst().joined(separator: "/")
    }

    /// Formats an optional `Float` with a fixed number of decimal places, using a
    /// POSIX locale so the decimal separator is always a period regardless of the
    /// user's region. Returns "" when the value is nil.
    private static func formatFraction(_ value: Float?, digits: Int) -> String {
        guard let value else { return "" }
        return Double(value).formatted(
            .number.precision(.fractionLength(digits))
                  .grouping(.never)
                  .locale(Locale(identifier: "en_US_POSIX"))
        )
    }

    /// Quotes a cell per RFC 4180 when needed (CSV) or escapes embedded tabs/newlines
    /// (TSV). Plain text never reaches here because it bypasses the column path.
    private static func quote(_ s: String, format: ExportFormat) -> String {
        switch format {
        case .csv:
            if s.contains(",") || s.contains("\"") || s.contains("\n") {
                return "\"\(s.replacing("\"", with: "\"\""))\""
            }
            return s
        case .tsv:
            // Tabs and newlines inside a value would break the row layout; replace
            // with spaces. FITS header strings essentially never contain either.
            return s.replacing("\t", with: " ").replacing("\n", with: " ")
        case .plainText:
            return s
        }
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
