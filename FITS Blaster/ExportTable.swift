//
//  ExportTable.swift
//  FITS Blaster
//
//  The frame-list export, built once: column names and one row of cell texts per
//  frame. Rendered as CSV or TSV (`delimited`) or as the aligned plain-text report
//  (`padded`). Shared by the Export sheet and the command-line mode.
//

import Foundation

struct ExportTable {
    let columns: [String]
    let rows: [[String]]
    /// Selected header keys that no frame has a value for; left out of the columns.
    let skippedKeys: [String]
    /// The columns that hold FITS header values (after path, status and metrics).
    let headerColumns: Range<Int>

    /// Numbers are formatted with a fixed `en_US_POSIX` locale so CSV files written
    /// on Dutch / German / French systems do not produce comma-decimal collisions
    /// with the comma delimiter.
    @MainActor
    init(frames: [ImageEntry], includeRejected: Bool, headerKeys: [String], pathStyle: PathStyle) {
        let basePath = pathStyle == .relative
            ? Self.commonAncestorPath(of: frames.map { $0.url })
            : ""

        // Drop selected header keys for which no frame has any value. The user is
        // informed upfront in the picker (absent keys appear dimmed), so silently
        // omitting empty columns keeps the output clean. The plain-text report
        // additionally lists what was dropped in a footer line.
        let usedKeys = headerKeys.filter { key in
            frames.contains { !FITSReader.cleanHeaderString($0.headers[key] ?? "").isEmpty }
        }
        skippedKeys = headerKeys.filter { !usedKeys.contains($0) }

        // Metric columns are omitted entirely when no frame has any metric data —
        // typically a Simple-mode session that never computed them. If any frame
        // has values (even partial), the columns stay and missing values are blank.
        let includeMetrics = frames.contains { ($0.metrics ?? $0.cachedMetrics) != nil }
        let exportMetrics = Metric.allCases.filter { $0.contexts.contains(.export) }

        var columns = ["path"]
        if includeRejected { columns.append("status") }
        if includeMetrics { columns.append(contentsOf: exportMetrics.map(\.exportKey)) }
        headerColumns = columns.count..<(columns.count + usedKeys.count)
        columns.append(contentsOf: usedKeys)
        self.columns = columns

        rows = frames.map { entry in
            var cells = [Self.formatPath(entry.url, style: pathStyle, basePath: basePath)]
            if includeRejected { cells.append(entry.isRejected ? "rejected" : "kept") }
            if includeMetrics {
                // Prefer cachedMetrics when metrics is nil, so the export still carries
                // the values that were measured at some point during the session.
                let m = entry.metrics ?? entry.cachedMetrics
                cells.append(contentsOf: exportMetrics.map { $0.exportString(from: m) })
            }
            cells.append(contentsOf: usedKeys.map { FITSReader.cleanHeaderString(entry.headers[$0] ?? "") })
            return cells
        }
    }

    /// The table in the chosen export format.
    func rendered(as format: ExportFormat) -> String {
        format == .plainText ? padded() : delimited(format)
    }

    // MARK: - CSV / TSV

    /// One line per row, cells separated by the format's delimiter.
    func delimited(_ format: ExportFormat) -> String {
        let delimiter = format.delimiter
        let lines: [String] = ([columns] + rows).map { row in
            let cells: [String] = row.map { format == .tsv ? Self.tsvCell($0) : Self.csvCell($0) }
            return cells.joined(separator: delimiter)
        }
        return lines.joined(separator: "\n")
    }

    /// A CSV cell: formula-neutralised, then quoted per RFC 4180 when it contains
    /// a comma, a quote, a newline or a carriage return.
    static func csvCell(_ value: String) -> String {
        let s = neutralisingFormula(value)
        guard s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r") else { return s }
        return "\"" + s.replacing("\"", with: "\"\"") + "\""
    }

    /// A TSV cell: formula-neutralised; tabs and line breaks would break the row
    /// layout, so they become spaces. FITS header strings essentially never contain them.
    static func tsvCell(_ value: String) -> String {
        neutralisingFormula(value)
            .replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
    }

    /// Text that starts with `=`, `+`, `-` or `@` is run as a formula by Excel and
    /// Numbers; a leading `'` makes it plain text (CODE_AUDIT §6.2). Numbers such as
    /// `-10.0` (CCD-TEMP) stay as they are, so they remain numbers in a spreadsheet.
    static func neutralisingFormula(_ value: String) -> String {
        guard let first = value.first, "=+-@".contains(first), Double(value) == nil else { return value }
        return "'" + value
    }

    // MARK: - Plain-text report

    /// A space-padded, human-readable report. Columns mirror the CSV/TSV layout,
    /// but each cell is padded so the file lines up in any text editor. Numeric
    /// columns are right-aligned; everything else is left-aligned. The trailing
    /// column is not padded out, to keep lines free of trailing whitespace.
    func padded() -> String {
        let table = [columns] + rows.map { row in
            row.enumerated().map { headerColumns.contains($0.offset) ? Self.sanitisePadded($0.element) : $0.element }
        }
        let columnCount = columns.count
        var widths = Array(repeating: 0, count: columnCount)
        for row in table {
            for (i, cell) in row.enumerated() where i < columnCount {
                widths[i] = max(widths[i], cell.count)
            }
        }

        // A column is right-aligned when every non-empty data value parses as a
        // number — captures fwhm/snr/score/stars and numeric FITS headers like
        // EXPTIME, GAIN, AIRMASS without hard-coding key names.
        let rightAlign = (0..<columnCount).map { i -> Bool in
            if columns[i] == "path" || columns[i] == "status" { return false }
            let values = table.dropFirst().map { $0[i] }.filter { !$0.isEmpty }
            return !values.isEmpty && values.allSatisfy { Double($0) != nil }
        }

        let separator = "  "
        let lines = table.map { row -> String in
            row.enumerated().map { (i, cell) -> String in
                let pad = max(0, widths[i] - cell.count)
                if rightAlign[i] { return String(repeating: " ", count: pad) + cell }
                return i == columnCount - 1 ? cell : cell + String(repeating: " ", count: pad)
            }.joined(separator: separator)
        }
        var report = lines.joined(separator: "\n")
        if !skippedKeys.isEmpty {
            report += "\n\n# Skipped columns with no data: " + skippedKeys.joined(separator: ", ")
        }
        return report
    }

    /// Replaces tabs and line breaks with spaces so a value can never break the
    /// padded layout.
    private static func sanitisePadded(_ s: String) -> String {
        s.replacing("\t", with: " ").replacing("\n", with: " ").replacing("\r", with: " ")
    }

    // MARK: - Paths

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
}
