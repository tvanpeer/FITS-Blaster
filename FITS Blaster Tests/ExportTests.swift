//
//  ExportTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore.exportContent / ExportTable: CSV/TSV column layout, status
//  column, POSIX decimal formatting, path styles, FITS header key filtering and order,
//  cell escaping (formula prefixes, line breaks, quotes), commonAncestorPath, writing
//  with export(to:), and header-key discovery.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct ExportTests {

    // MARK: - Helpers

    private func makeEntry(path: String,
                            metrics: FrameMetrics? = nil,
                            isRejected: Bool = false,
                            headers: [String: String] = [:]) -> ImageEntry {
        let entry = ImageEntry(url: URL(fileURLWithPath: path))
        entry.isProcessing = false
        entry.metrics = metrics
        entry.isRejected = isRejected
        entry.headers = headers
        return entry
    }

    /// Metrics with known values so tests can assert on formatted output.
    private func sampleMetrics() -> FrameMetrics {
        FrameMetrics(fwhm: 2.50, eccentricity: 0.150, snr: 100.0, starCount: 200,
                     qualityScore: 75, skyBackground: 1200.0, psfSignalWeight: 45.5)
    }

    // MARK: - CSV header columns

    @Test("CSV header contains all export metric columns when metrics are present")
    func csvHeaderContainsMetricColumns() {
        let entry = makeEntry(path: "/data/frame.fits", metrics: sampleMetrics())
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("fwhm"))
        #expect(header.contains("eccentricity"))
        #expect(header.contains("psf_signal_weight"))
        #expect(header.contains("score"))
    }

    @Test("CSV header excludes sky_bg (skyBackground is not an export metric)")
    func csvHeaderExcludesSkyBG() {
        let entry = makeEntry(path: "/data/frame.fits", metrics: sampleMetrics())
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("sky_bg") == false, "sky_bg should not appear in export columns")
    }

    @Test("CSV header omits metric columns when no frame has metrics")
    func csvHeaderOmitsMetricsWhenNone() {
        let entry = makeEntry(path: "/data/frame.fits", metrics: nil)
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("fwhm") == false)
        #expect(header.hasPrefix("path"))
    }

    @Test("CSV header includes status column when includeRejected is true")
    func csvHeaderIncludesStatus() {
        let entry = makeEntry(path: "/data/frame.fits")
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: true, headerKeys: [],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("status"))
    }

    @Test("CSV header omits status column when includeRejected is false")
    func csvHeaderOmitsStatusByDefault() {
        let entry = makeEntry(path: "/data/frame.fits")
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("status") == false)
    }

    // MARK: - CSV data rows

    @Test("Rejected frame is labelled 'rejected' in the status column")
    func csvRejectedStatus() {
        let entry = makeEntry(path: "/data/frame.fits", isRejected: true)
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: true, headerKeys: [],
                                           pathStyle: .absolute)
        let dataRow = csv.components(separatedBy: "\n").dropFirst().first ?? ""
        #expect(dataRow.contains("rejected"))
    }

    @Test("Non-rejected frame is labelled 'kept' in the status column")
    func csvKeptStatus() {
        let entry = makeEntry(path: "/data/frame.fits", isRejected: false)
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: true, headerKeys: [],
                                           pathStyle: .absolute)
        let dataRow = csv.components(separatedBy: "\n").dropFirst().first ?? ""
        #expect(dataRow.contains("kept"))
    }

    @Test("Metric values use POSIX decimal separator (dot, not comma)")
    func csvUsesPOSIXDecimal() {
        let entry = makeEntry(path: "/data/frame.fits", metrics: sampleMetrics())
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        // fwhm = 2.50 must appear as "2.50", never "2,50"
        #expect(csv.contains("2.50"), "FWHM 2.50 should use a dot decimal separator")
    }

    // MARK: - Path styles

    @Test("Absolute path style writes the full file path")
    func absolutePathStyle() {
        let entry = makeEntry(path: "/sessions/night1/frame001.fits")
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        #expect(csv.contains("/sessions/night1/frame001.fits"))
    }

    @Test("Filename path style writes only the last path component")
    func filenamePathStyle() {
        let entry = makeEntry(path: "/sessions/night1/frame001.fits")
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .filename)
        let dataRow = csv.components(separatedBy: "\n").dropFirst().first ?? ""
        #expect(dataRow.contains("frame001.fits"))
        #expect(dataRow.contains("/sessions/night1") == false)
    }

    @Test("Relative path style strips the common ancestor prefix")
    func relativePathStyle() {
        let entries = [
            makeEntry(path: "/sessions/night1/frame001.fits"),
            makeEntry(path: "/sessions/night1/frame002.fits"),
        ]
        let csv = ImageStore.exportContent(frames: entries, format: .csv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .relative)
        #expect(csv.contains("frame001.fits"))
        #expect(csv.contains("/sessions/night1/frame001.fits") == false,
                "Common ancestor /sessions/night1 should be stripped")
    }

    // MARK: - TSV

    @Test("TSV uses a tab character as the column delimiter")
    func tsvUsesTabDelimiter() {
        let entry = makeEntry(path: "/data/frame.fits", metrics: sampleMetrics())
        let tsv = ImageStore.exportContent(frames: [entry], format: .tsv,
                                           includeRejected: false, headerKeys: [],
                                           pathStyle: .absolute)
        let header = tsv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("\t"))
    }

    // MARK: - FITS header key filtering

    @Test("FITS header column is included when at least one frame has a value for it")
    func fitsHeaderColumnIncluded() {
        let entry = makeEntry(path: "/data/frame.fits",
                              headers: ["FILTER": "Ha", "EXPTIME": "300"])
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: ["FILTER"],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("FILTER"))
        #expect(csv.contains("Ha"))
    }

    @Test("FITS header column is omitted when no frame has a value for it")
    func fitsHeaderColumnOmittedWhenMissing() {
        let entry = makeEntry(path: "/data/frame.fits", headers: [:])
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: ["FILTER"],
                                           pathStyle: .absolute)
        let header = csv.components(separatedBy: "\n").first ?? ""
        #expect(header.contains("FILTER") == false)
    }

    // MARK: - commonAncestorPath

    @Test("commonAncestorPath returns the shared parent directory")
    func commonAncestorFindsParent() {
        let urls = [
            URL(fileURLWithPath: "/sessions/night1/frame001.fits"),
            URL(fileURLWithPath: "/sessions/night1/frame002.fits"),
        ]
        #expect(ExportTable.commonAncestorPath(of: urls) == "/sessions/night1")
    }

    @Test("commonAncestorPath returns the deepest common ancestor across subdirectories")
    func commonAncestorAcrossSubdirs() {
        let urls = [
            URL(fileURLWithPath: "/sessions/Ha/frame001.fits"),
            URL(fileURLWithPath: "/sessions/OIII/frame001.fits"),
        ]
        #expect(ExportTable.commonAncestorPath(of: urls) == "/sessions")
    }

    @Test("commonAncestorPath returns empty string for empty input")
    func commonAncestorEmptyInput() {
        #expect(ExportTable.commonAncestorPath(of: []) == "")
    }

    @Test("commonAncestorPath returns empty string when only the root is shared")
    func commonAncestorOnlyRoot() {
        let urls = [
            URL(fileURLWithPath: "/a/frame.fits"),
            URL(fileURLWithPath: "/b/frame.fits"),
        ]
        #expect(ExportTable.commonAncestorPath(of: urls) == "")
    }

    // MARK: - Header column order

    @Test("Header columns follow the given order, not the alphabet")
    func headerColumnOrder() {
        let entry = makeEntry(path: "/data/frame.fits",
                              headers: ["OBJECT": "M31", "EXPTIME": "120", "FILTER": "L"])
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false,
                                           headerKeys: ["OBJECT", "FILTER", "EXPTIME"],
                                           pathStyle: .filename)
        #expect(csv.components(separatedBy: "\n").first == "path,OBJECT,FILTER,EXPTIME")
    }

    // MARK: - Cell escaping (CODE_AUDIT §6.2)

    @Test("Text starting with =, +, - or @ gets a leading quote; numbers don't")
    func formulaNeutralised() {
        #expect(ExportTable.neutralisingFormula("=HYPERLINK(\"x\")") == "'=HYPERLINK(\"x\")")
        #expect(ExportTable.neutralisingFormula("+cmd") == "'+cmd")
        #expect(ExportTable.neutralisingFormula("-cmd") == "'-cmd")
        #expect(ExportTable.neutralisingFormula("@SUM(A1)") == "'@SUM(A1)")
        #expect(ExportTable.neutralisingFormula("-10.0") == "-10.0")
        #expect(ExportTable.neutralisingFormula("+5") == "+5")
        #expect(ExportTable.neutralisingFormula("M31") == "M31")
        #expect(ExportTable.neutralisingFormula("") == "")
    }

    @Test("CSV neutralises a formula in a header value and keeps negative numbers")
    func csvFormulaInHeaderValue() {
        let entry = makeEntry(path: "/data/frame.fits",
                              headers: ["OBJECT": "=1+1", "CCD-TEMP": "-10.0"])
        let csv = ImageStore.exportContent(frames: [entry], format: .csv,
                                           includeRejected: false, headerKeys: ["OBJECT", "CCD-TEMP"],
                                           pathStyle: .filename)
        #expect(csv.components(separatedBy: "\n").last == "frame.fits,'=1+1,-10.0")
    }

    @Test("CSV quotes cells with a comma, quote, newline or carriage return")
    func csvQuoting() {
        #expect(ExportTable.csvCell("a,b") == "\"a,b\"")
        #expect(ExportTable.csvCell("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(ExportTable.csvCell("a\nb") == "\"a\nb\"")
        #expect(ExportTable.csvCell("a\rb") == "\"a\rb\"")
        #expect(ExportTable.csvCell("plain") == "plain")
    }

    @Test("TSV replaces tabs and line breaks with spaces")
    func tsvCell() {
        #expect(ExportTable.tsvCell("a\tb\nc\rd") == "a b c d")
        #expect(ExportTable.tsvCell("=x") == "'=x")
    }

    // MARK: - Writing (CODE_AUDIT §5.7)

    @Test("export(to:) writes the same content as exportContent")
    func exportWritesContent() throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ImageStore()
        let entry = makeEntry(path: "/data/frame.fits", metrics: sampleMetrics(), headers: ["OBJECT": "M31"])
        store.entries = [entry]
        let url = folder.appending(component: "frames.csv")
        store.export(to: url, format: .csv, includeRejected: false, headerKeys: ["OBJECT"], pathStyle: .absolute)

        let expected = ImageStore.exportContent(frames: [entry], format: .csv, includeRejected: false,
                                                headerKeys: ["OBJECT"], pathStyle: .absolute)
        #expect(try String(contentsOf: url, encoding: .utf8) == expected)
        #expect(store.errorMessage == nil)
    }

    @Test("A failed write is reported through errorMessage")
    func exportFailureSetsError() {
        let store = ImageStore()
        store.entries = [makeEntry(path: "/data/frame.fits")]
        let url = URL(fileURLWithPath: "/nonexistent-folder-\(UUID().uuidString)/frames.csv")
        store.export(to: url, format: .csv, includeRejected: false, headerKeys: [], pathStyle: .absolute)
        #expect(store.errorMessage?.contains("frames.csv") == true)
    }

    // MARK: - Header-key discovery

    @Test("Available keys: known, present in a frame, and selected; present only from frames")
    func availableHeaderKeys() {
        let entry = makeEntry(path: "/data/frame.fits", headers: ["MYKEY": "1", "EMPTYKEY": ""])
        let (keys, present) = ExportHeaderKeys.available(in: [entry], selected: ["CUSTOM"])
        #expect(keys.contains("MYKEY"))
        #expect(keys.contains("CUSTOM"))
        #expect(keys.contains("OBJECT"))
        #expect(keys == keys.sorted())
        #expect(present == ["MYKEY"])
    }
}
