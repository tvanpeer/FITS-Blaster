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
        await store.waitForProcessing()

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
        await store.waitForProcessing()

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
        await store.waitForProcessing()
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
}
