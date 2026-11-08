//
//  CLIRunTests.swift
//  FITS Blaster Tests
//
//  Step 12b (CODE_AUDIT §5.11, §5.12): the CLI's exit codes, the header-only CSV when no
//  frame passes the filter, and files that could not be read (listed, left out of a
//  filtered CSV). Runs the CLI in-process on temporary folders.
//

#if !APPSTORE
import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct CLIRunTests {

    /// A temporary folder with three star frames (s0–s2.fits), plus a file that is not
    /// FITS and a floating-point frame when asked; the CSV goes next to it.
    private func makeFolder(broken: Bool = false, floatingPoint: Bool = false) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let folder = root.appending(component: "LIGHT")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for seed in 0..<3 { try TestFITS.starFieldData(seed: seed).write(to: folder.appending(component: "s\(seed).fits")) }
        if broken {
            try Data(repeating: 0x41, count: 2880).write(to: folder.appending(component: "broken.fits"))
        }
        if floatingPoint {
            let cards = TestFITS.imageCards(bitpix: -32, width: 8, height: 8)
            let pixels = TestFITS.bigEndian([Float](repeating: 0.5, count: 64))
            try TestFITS.fileData(cards: cards, pixels: pixels).write(to: folder.appending(component: "stack.fits"))
        }
        return folder
    }

    private func run(_ folder: URL, _ options: [String] = []) async -> (code: CLIExitCode, csv: [String]) {
        let csvURL = folder.deletingLastPathComponent().appending(component: "out.csv")
        let code = await CLIRunner.run(arguments: ["LIGHT", "-o", "out.csv"] + options,
                                       currentDirectory: folder.deletingLastPathComponent())
        let text = (try? String(contentsOf: csvURL, encoding: .utf8)) ?? ""
        return (code, text.isEmpty ? [] : text.components(separatedBy: "\n"))
    }

    private func remove(_ folder: URL) {
        try? FileManager.default.removeItem(at: folder.deletingLastPathComponent())
    }

    /// The file names in the CSV's path column.
    private func names(_ csv: [String]) -> [String] {
        csv.dropFirst().map { String($0.split(separator: ",").first ?? "") }
    }

    // MARK: - Exit codes

    @Test("A normal run: exit 0, every frame in the CSV")
    func normalRun() async throws {
        let folder = try makeFolder()
        defer { remove(folder) }
        let result = await run(folder)
        #expect(result.code == .success)
        #expect(names(result.csv) == ["s0.fits", "s1.fits", "s2.fits"])
        #expect(result.csv.first?.hasPrefix("path,") == true)
    }

    @Test("No frame passes: a CSV with only the header row, with the same columns, exit 3")
    func nothingPasses() async throws {
        let folder = try makeFolder()
        defer { remove(folder) }
        let all = await run(folder)
        let none = await run(folder, ["-m", "abs", "-f", "0.1"])
        #expect(none.code == .nothingPassed)
        #expect(none.csv == [all.csv[0]])
    }

    @Test("A file that is not FITS: listed, a row without values in an unfiltered CSV, exit 4")
    func brokenFileUnfiltered() async throws {
        let folder = try makeFolder(broken: true)
        defer { remove(folder) }
        let result = await run(folder)
        #expect(result.code == .unreadableFiles)
        #expect(names(result.csv) == ["broken.fits", "s0.fits", "s1.fits", "s2.fits"])
    }

    @Test("A file that is not FITS in a filtered run: left out of the CSV, exit 4")
    func brokenFileFiltered() async throws {
        let folder = try makeFolder(broken: true)
        defer { remove(folder) }
        let result = await run(folder, ["-e", "0.99"])
        #expect(result.code == .unreadableFiles)
        #expect(names(result.csv) == ["s0.fits", "s1.fits", "s2.fits"])
    }

    @Test("No frame passes and a file could not be read: exit 3 wins")
    func nothingPassesWins() async throws {
        let folder = try makeFolder(broken: true)
        defer { remove(folder) }
        let result = await run(folder, ["-m", "abs", "-f", "0.1"])
        #expect(result.code == .nothingPassed)
        #expect(result.csv.count == 1)
    }

    @Test("A floating-point stack is listed as not supported, exit 4")
    func floatingPointListed() async throws {
        let folder = try makeFolder(floatingPoint: true)
        defer { remove(folder) }
        let store = ImageStore()
        store.openDroppedItems([folder], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        #expect(CLIRunner.unreadableFiles(in: store).map(\.fileName) == ["stack.fits"])

        let result = await run(folder)
        #expect(result.code == .unreadableFiles)
        #expect(names(result.csv) == ["s0.fits", "s1.fits", "s2.fits"])
    }

    @Test("Usage: no arguments 1, --help 0, an unknown option 1, a missing folder 1, no FITS files 1")
    func usage() async throws {
        let empty = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let cwd = FileManager.default.temporaryDirectory
        #expect(await CLIRunner.run(arguments: [], currentDirectory: cwd) == .usage)
        #expect(await CLIRunner.run(arguments: ["--help"], currentDirectory: cwd) == .success)
        #expect(await CLIRunner.run(arguments: [empty.path, "--fwmh", "1"], currentDirectory: cwd) == .usage)
        #expect(await CLIRunner.run(arguments: ["/no/such/folder"], currentDirectory: cwd) == .usage)
        #expect(await CLIRunner.run(arguments: [empty.path], currentDirectory: cwd) == .usage)
    }

    // MARK: - Message

    @Test("The list of files that could not be read: at most 10, then how many more")
    func unreadableMessage() {
        let files = (1...12).map { (fileName: "f\($0).fits", reason: "bad") }
        let lines = CLIRunner.unreadableMessage(files).components(separatedBy: "\n")
        #expect(lines.first == "warning: 12 files could not be read:")
        #expect(lines[1] == "  f1.fits — bad")
        #expect(lines.count == 12)
        #expect(lines.last == "  and 2 more")
        #expect(CLIRunner.unreadableMessage([(fileName: "a.fits", reason: "x")]) == "warning: 1 file could not be read:\n  a.fits — x")
    }
}
#endif
