//
//  OpenFolderTests.swift
//  FITS Blaster Tests
//
//  ImageStore.openFolder(at:): the folder scan off the main thread, REJECTED
//  handling, "already loaded", an empty folder; and the shared helpers
//  rejectedURLs(in:), isDirectory and FITSFile.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct OpenFolderTests {

    /// A folder with two frames, a REJECTED folder with one frame, and a non-FITS file.
    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        let rejected = folder.appending(component: "REJECTED")
        try FileManager.default.createDirectory(at: rejected, withIntermediateDirectories: true)
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        let data = TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                     pixels: TestFITS.bigEndian(stored))
        try data.write(to: folder.appending(component: "a.fits"))
        try data.write(to: folder.appending(component: "b.FIT"))
        try data.write(to: rejected.appending(component: "c.fits"))
        try Data("notes".utf8).write(to: folder.appending(component: "notes.txt"))
        return folder
    }

    @Test("Without REJECTED: the two frames in the folder are loaded")
    func openWithoutRejected() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()

        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(store.entries.map(\.fileName).sorted() == ["a.fits", "b.FIT"])
        #expect(store.entries.allSatisfy { !$0.isRejected })
        #expect(store.rootFolderName == folder.lastPathComponent)
    }

    @Test("With REJECTED: the rejected frame is loaded and marked rejected")
    func openWithRejected() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()

        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: true, settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == 3)
        #expect(store.entries.filter(\.isRejected).map(\.fileName) == ["c.fits"])
    }

    @Test("A folder is 'already loaded' after it was opened")
    func alreadyLoaded() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        #expect(store.isAlreadyLoaded(folder) == false)

        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()
        #expect(store.isAlreadyLoaded(folder))
    }

    @Test("A folder without FITS files sets an error and loads nothing")
    func emptyFolder() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()

        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        #expect(store.entries.isEmpty)
        #expect(store.errorMessage == "No FITS files found in the selected folder.")
        #expect(store.isAlreadyLoaded(folder) == false)
    }

    @Test("rejectedURLs picks the files whose parent is REJECTED, in any case")
    func rejectedURLsRule() {
        let collected: [(url: URL, subfolderPath: String)] = [
            (URL(fileURLWithPath: "/n/a.fits"), ""),
            (URL(fileURLWithPath: "/n/REJECTED/b.fits"), ""),
            (URL(fileURLWithPath: "/n/Ha/rejected/c.fits"), "Ha"),
        ]
        #expect(ImageStore.rejectedURLs(in: collected)
                == [URL(fileURLWithPath: "/n/REJECTED/b.fits"), URL(fileURLWithPath: "/n/Ha/rejected/c.fits")])
    }

    @Test("isDirectory: true for a folder, false for a file, nil when missing")
    func isDirectoryCheck() throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(ImageStore.isDirectory(folder) == true)
        #expect(ImageStore.isDirectory(folder.appending(component: "a.fits")) == false)
        #expect(ImageStore.isDirectory(folder.appending(component: "missing")) == nil)
    }

    @Test("FITS extensions in any case; others not")
    func fitsExtensions() {
        #expect(FITSFile.hasFITSExtension(URL(fileURLWithPath: "/x/a.fits")))
        #expect(FITSFile.hasFITSExtension(URL(fileURLWithPath: "/x/a.FIT")))
        #expect(FITSFile.hasFITSExtension(URL(fileURLWithPath: "/x/a.fts")))
        #expect(!FITSFile.hasFITSExtension(URL(fileURLWithPath: "/x/a.xisf")))
        #expect(!FITSFile.hasFITSExtension(URL(fileURLWithPath: "/x/fits")))
    }

    // MARK: - Dropped folders in the sidebar

    @Test("Two dropped folders each get their own sidebar section")
    func droppedFoldersGetSections() async throws {
        let parent = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = parent.appending(component: "Night 1")
        let second = parent.appending(component: "Night 2")
        for folder in [first, second] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let source = try makeFolder()
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.copyItem(at: source.appending(component: "a.fits"), to: first.appending(component: "a.fits"))
        try FileManager.default.copyItem(at: source.appending(component: "a.fits"), to: second.appending(component: "b.fits"))

        let store = ImageStore()
        store.openDroppedItems([first, second], settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(Set(store.entries.map(\.rootFolderName)) == ["Night 1", "Night 2"])
        #expect(store.groupedByFolderAndFilter.map(\.folderDisplayName).sorted() == ["Night 1", "Night 2"])
    }

    @Test("Files dropped from one folder take that folder's name")
    func droppedFilesTakeParentName() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.openDroppedItems([folder.appending(component: "a.fits"), folder.appending(component: "b.FIT")],
                               settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(store.entries.allSatisfy { $0.rootFolderName == folder.lastPathComponent })
        #expect(store.rootFolderName == folder.lastPathComponent)
    }

    @Test("Two drops in quick succession both load, in order")
    func twoQuickDrops() async throws {
        let first = try makeFolder()
        let second = try makeFolder()
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

        let store = ImageStore()
        store.openDroppedItems([first], settings: AppSettings())
        store.openDroppedItems([second], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == 4)
        #expect(store.isAlreadyLoaded(first) && store.isAlreadyLoaded(second))
    }

    // MARK: - Progress while preparing a load

    @Test("The candidates are the FITS files not loaded yet, in order; no file is read")
    func candidates() {
        let a = URL(fileURLWithPath: "/nowhere/a.fits"), b = URL(fileURLWithPath: "/nowhere/b.FIT")
        let c = URL(fileURLWithPath: "/nowhere/c.fits")
        let items: [(url: URL, subfolderPath: String)] = [
            (a, ""), (URL(fileURLWithPath: "/nowhere/notes.txt"), ""), (b, ""), (c, ""),
        ]
        // The files don't exist: candidates() only looks at names.
        let result = FrameLoading.candidates(items, existingURLs: [c])
        #expect(result.map(\.url) == [a, b])
    }

    // MARK: - Unsupported files are left out by Phase A

    private func writeFITS(bitpix: Int, name: String, in folder: URL) throws {
        let pixels: Data
        switch bitpix {
        case -32: pixels = TestFITS.bigEndian([Float](repeating: 1000, count: 64 * 48))
        default:
            pixels = TestFITS.bigEndian((0..<(64 * 48)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) })
        }
        let cards = TestFITS.imageCards(bitpix: bitpix, width: 64, height: 48, bzero: bitpix == 16 ? 32768 : nil)
        _ = try TestFITS.write(TestFITS.fileData(cards: cards, pixels: pixels), fileName: name, in: folder)
    }

    @Test("A 16-bit stack with colour planes is left out like a floating-point file")
    func multiChannelLeftOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeFITS(bitpix: 16, name: "frame.fits", in: folder)
        let planes: [Int16] = (0..<(64 * 48 * 3)).map { (i: Int) -> Int16 in
            let level: Int = 1000 + (i * 37) % 20000
            return Int16(bitPattern: UInt16(level) &- 32768)
        }
        var cards = TestFITS.imageCards(bitpix: 16, width: 64, height: 48, bzero: 32768)
        cards[2] = TestFITS.card("NAXIS", int: 3)
        cards.insert(TestFITS.card("NAXIS3", int: 3), at: 5)
        _ = try TestFITS.write(TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(planes)),
                               fileName: "stack-rgb.fits", in: folder)
        let store = ImageStore()
        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()
        #expect(store.entries.map(\.fileName) == ["frame.fits"])
        #expect(store.errorMessage == "Skipped 1 file FITS Blaster doesn't load (floating-point or multi-channel stacks): stack-rgb.fits")
    }

    @Test("After Reset during a load no message about skipped files is shown")
    func noSkippedMessageAfterReset() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        for i in 0..<6 { try writeFITS(bitpix: i % 2 == 0 ? -32 : 16, name: "f\(i).fits", in: folder) }
        let store = ImageStore()
        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        let load = store.pipeline.processingTask
        store.reset()
        await load?.value
        #expect(store.entries.isEmpty)
        #expect(store.errorMessage == nil)
    }

    @Test("Floating-point files are left out during the load and named in one message")
    func floatFilesLeftOut() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try writeFITS(bitpix: -32, name: "a-float.fits", in: folder)   // first: the cursor starts here
        try writeFITS(bitpix: 16, name: "b.fits", in: folder)
        try writeFITS(bitpix: -32, name: "c-float.fits", in: folder)
        try writeFITS(bitpix: 16, name: "d.fits", in: folder)
        let store = ImageStore()
        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(store.entries.map(\.fileName).sorted() == ["b.fits", "d.fits"])
        #expect(store.errorMessage == "Skipped 2 files FITS Blaster doesn't load (floating-point or multi-channel stacks): a-float.fits, c-float.fits"
                || store.errorMessage == "Skipped 2 files FITS Blaster doesn't load (floating-point or multi-channel stacks): c-float.fits, a-float.fits")
        #expect(store.selectedEntry.map { selected in store.entries.contains { $0 === selected } } == true)
        #expect(store.pipeline.batchImageCount == 2)
        #expect(store.entries.allSatisfy { $0.displayImage != nil })
    }

    @Test("No preparation status is left after a load")
    func preparationClearedAfterLoad() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        await store.openFolder(at: folder, includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()
        #expect(store.pipeline.preparation == nil)

        store.openDroppedItems([folder], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        #expect(store.pipeline.preparation == nil)
    }

    // MARK: - The readdir scan gives the same result as the FileManager scan

    /// The scan as it was before 2026-10-25 (FileManager.contentsOfDirectory), as reference.
    private func referenceScan(_ folder: URL, relativePath: String, excluded: Set<String>,
                               subfolders: Bool, rejected: Bool) -> [(url: URL, subfolderPath: String)] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var results: [(url: URL, subfolderPath: String)] = []
        for item in contents.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false {
                let name = item.lastPathComponent
                if name.caseInsensitiveCompare("REJECTED") == .orderedSame {
                    if rejected { results += referenceScan(item, relativePath: relativePath, excluded: [], subfolders: false, rejected: false) }
                    continue
                }
                guard subfolders, !excluded.contains(name.lowercased()) else { continue }
                results += referenceScan(item, relativePath: relativePath.isEmpty ? name : "\(relativePath)/\(name)",
                                         excluded: excluded, subfolders: true, rejected: rejected)
            } else if FITSFile.hasFITSExtension(item) {
                results.append((item, relativePath))
            }
        }
        return results
    }

    @Test("The readdir scan finds the same files, in the same order, as the FileManager scan",
          arguments: [(false, false), (true, false), (false, true), (true, true)])
    func scanMatchesReference(subfolders: Bool, rejected: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for dir in ["Ha", "Ha/REJECTED", "OIII", "FLAT", "Darks/nested", "REJECTED", "Ünïcödé map"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        for file in ["frame10.fits", "frame2.fits", "frame1.FIT", "note.txt", ".hidden.fits",
                     "Ha/a.fts", "Ha/REJECTED/r.fits", "OIII/b.fits", "FLAT/flat.fits",
                     "Darks/nested/d.fits", "REJECTED/top.fits", "Ünïcödé map/ü.fits"] {
            try Data([0]).write(to: root.appending(path: file))
        }
        let excluded: Set<String> = ["flat", "dark", "bias", "calib"]

        let new = ImageStore.collectFITSURLs(in: root, relativePath: "", excludedNames: excluded,
                                             includeSubfolders: subfolders, includeRejected: rejected)
        let old = referenceScan(root, relativePath: "", excluded: excluded, subfolders: subfolders, rejected: rejected)

        #expect(new.map { $0.url.path(percentEncoded: false) } == old.map { $0.url.path(percentEncoded: false) })
        #expect(new.map(\.subfolderPath) == old.map(\.subfolderPath))
        #expect(!new.isEmpty)
    }

    @Test("A folder that can't be read gives no files")
    func unreadableFolder() {
        #expect(ImageStore.collectFITSURLs(in: URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"),
                                           relativePath: "", excludedNames: [], includeSubfolders: true).isEmpty)
    }
}
