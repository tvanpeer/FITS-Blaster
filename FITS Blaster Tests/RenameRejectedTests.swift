//
//  RenameRejectedTests.swift
//  FITS Blaster Tests
//
//  Step 16: with "Rename rejected files" on, a rejected frame becomes
//  REJECTED/x.fits.rejected so PixInsight's WBPP skips it; undo restores x.fits; opening a
//  folder and the command line's -r recognise both names.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct RenameRejectedTests {

    private func fitsData() -> Data {
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        return TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                 pixels: TestFITS.bigEndian(stored))
    }

    /// A temporary folder with the given files (paths relative to it, e.g. "REJECTED/b.fits.rejected").
    private func makeFolder(_ files: [String]) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let data = fitsData()
        for file in files {
            let url = folder.appending(path: file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        return folder
    }

    private func open(_ folder: URL, includeRejected: Bool = false) async -> ImageStore {
        let store = ImageStore()
        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: includeRejected,
                               settings: AppSettings())
        await store.pipeline.waitForProcessing()
        return store
    }

    private func exists(_ folder: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: path).path(percentEncoded: false))
    }

    private func entry(_ name: String, in store: ImageStore) throws -> ImageEntry {
        try #require(store.entries.first { $0.fileName == name })
    }

    // MARK: - Names

    @Test("Names both ways, for every FITS extension and in any case",
          arguments: [("x.fits", "x.fits.rejected"), ("x.fit", "x.fit.rejected"), ("X.FTS", "X.FTS.rejected"),
                      ("M31 #0001.fits", "M31 #0001.fits.rejected")])
    func names(original: String, renamed: String) {
        let file = URL(fileURLWithPath: "/n/Ha/\(original)")
        let rejected = RejectedFolder.rejectedURL(for: file, renames: true)
        #expect(rejected.path(percentEncoded: false) == "/n/Ha/REJECTED/\(renamed)")
        #expect(RejectedFolder.originalURL(for: rejected) == file)
        #expect(RejectedFolder.rejectedURL(for: file).lastPathComponent == original)   // setting off
        #expect(RejectedFolder.originalURL(for: URL(fileURLWithPath: "/n/Ha/REJECTED/\(original).REJECTED")) == file)
    }

    @Test("Only a FITS name plus .rejected counts as renamed; it loads only from a REJECTED folder")
    func recognised() {
        let renamed = URL(fileURLWithPath: "/n/REJECTED/x.fits.rejected")
        #expect(RejectedFolder.isRenamed(renamed))
        #expect(RejectedFolder.isLoadable(renamed))
        #expect(!RejectedFolder.isLoadable(URL(fileURLWithPath: "/n/x.fits.rejected")))   // outside REJECTED
        #expect(!RejectedFolder.isRenamed(URL(fileURLWithPath: "/n/REJECTED/notes.rejected")))
        #expect(!RejectedFolder.isRenamed(URL(fileURLWithPath: "/n/REJECTED/x.fits")))
        #expect(RejectedFolder.isLoadable(URL(fileURLWithPath: "/n/REJECTED/x.fits")))
        #expect(RejectedFolder.originalName(of: URL(fileURLWithPath: "/n/notes.rejected")) == "notes.rejected")
    }

    // MARK: - Reject and undo

    @Test("One frame: renamed into REJECTED, shown under its own name, back on undo")
    func singleFrame() async throws {
        let folder = try makeFolder(["f1.fits", "f2.fits"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await open(folder)
        store.renamesRejectedFiles = true

        store.rejectEntry(try entry("f1.fits", in: store))
        #expect(exists(folder, "REJECTED/f1.fits.rejected"))
        #expect(!exists(folder, "f1.fits"))
        #expect(try entry("f1.fits", in: store).isRejected)

        store.undoRejectEntry(try entry("f1.fits", in: store))
        #expect(exists(folder, "f1.fits"))
        #expect(!exists(folder, "REJECTED"))
        #expect(store.errorMessage == nil)
    }

    @Test("A batch is renamed; turning the setting off before undo still restores the names")
    func batchAndSettingOff() async throws {
        let folder = try makeFolder(["f1.fits", "f2.fit", "f3.fts"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await open(folder)
        store.renamesRejectedFiles = true

        store.rejectEntries(store.entries)
        await store.frameMoves.wait()
        #expect(exists(folder, "REJECTED/f1.fits.rejected") && exists(folder, "REJECTED/f2.fit.rejected")
                && exists(folder, "REJECTED/f3.fts.rejected"))

        store.renamesRejectedFiles = false
        store.undoRejectEntries(store.entries)
        await store.frameMoves.wait()
        #expect(exists(folder, "f1.fits") && exists(folder, "f2.fit") && exists(folder, "f3.fts"))
        #expect(store.entries.allSatisfy { !$0.isRejected })
        #expect(store.errorMessage == nil)
    }

    @Test("With the setting off nothing is renamed")
    func settingOff() async throws {
        let folder = try makeFolder(["f1.fits", "f2.fits"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await open(folder)

        store.rejectEntry(try entry("f1.fits", in: store))
        #expect(exists(folder, "REJECTED/f1.fits"))
    }

    @Test("The renamed name already in REJECTED: the frame stays and the message says why")
    func nameClash() async throws {
        let folder = try makeFolder(["f1.fits", "f2.fits", "REJECTED/f1.fits.rejected"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await open(folder)
        store.renamesRejectedFiles = true

        store.rejectEntry(try entry("f1.fits", in: store))
        #expect(exists(folder, "f1.fits"))
        #expect(try !entry("f1.fits", in: store).isRejected)
        #expect(store.errorMessage == "Failed to reject f1.fits: a file with this name is already there")
    }

    // MARK: - Opening a folder, command line

    @Test("Reopening a folder with old and new names: all rejected, in name order, undo restores the name")
    func reopenMixed() async throws {
        let folder = try makeFolder(["c.fits", "REJECTED/a.fits", "REJECTED/b.fits.rejected", "notes.fits.rejected"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await open(folder, includeRejected: true)

        #expect(store.entries.map(\.fileName) == ["a.fits", "b.fits", "c.fits"])   // notes: not in REJECTED
        #expect(store.entries.map(\.isRejected) == [true, true, false])
        store.undoRejectEntry(try entry("b.fits", in: store))
        #expect(exists(folder, "b.fits"))

        let without = await open(folder)
        #expect(without.entries.map(\.fileName) == ["b.fits", "c.fits"])
    }

    @Test("Command line -r: the renamed frame is in the CSV as rejected, with its real path")
    func commandLine() async throws {
        let folder = try makeFolder(["c.fits", "REJECTED/b.fits.rejected"])
        defer { try? FileManager.default.removeItem(at: folder) }
        let csv = folder.appending(component: "out.csv")

        let code = await CLIRunner.run(arguments: [folder.path(percentEncoded: false), "-r", "-o", csv.path(percentEncoded: false)],
                                       currentDirectory: folder)
        #expect(code == .success)
        let rows = try String(contentsOf: csv, encoding: .utf8).components(separatedBy: "\n").dropFirst()
        #expect(rows.contains { $0.hasPrefix("REJECTED/b.fits.rejected,rejected,") })
        #expect(rows.contains { $0.hasPrefix("c.fits,kept,") })
    }
}
