//
//  RejectedFolderTests.swift
//  FITS Blaster Tests
//
//  The REJECTED folder: undo removes it only when nothing but a .DS_Store is left
//  (CODE_AUDIT §5.6), and a file rejected this session doesn't load twice when the
//  folder is reopened with its REJECTED folder (§5.8).
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct RejectedFolderTests {

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    /// A small 16-bit FITS file.
    private func fitsData() -> Data {
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        let cards = TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768)
        return TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
    }

    // MARK: - §5.6 Removing the folder after undo

    @Test("An empty folder is removed")
    func emptyFolderRemoved() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        ImageStore.removeFolderIfEmpty(folder)
        #expect(!exists(folder))
    }

    @Test("A folder with only a .DS_Store is removed")
    func dsStoreOnlyFolderRemoved() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder.appending(component: ".DS_Store"))

        ImageStore.removeFolderIfEmpty(folder)
        #expect(!exists(folder))
    }

    @Test("A folder with a hidden file is kept, and so is the file")
    func hiddenFileKeepsFolder() throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let hidden = folder.appending(component: ".notes")
        try Data("keep me".utf8).write(to: hidden)

        ImageStore.removeFolderIfEmpty(folder)
        #expect(exists(hidden))
    }

    // MARK: - §5.8 Reopening with REJECTED

    @Test("A file rejected this session isn't loaded again from REJECTED")
    func rejectedFileNotLoadedTwice() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(component: "frame.fits")
        try fitsData().write(to: file)

        let store = ImageStore()
        store.openFiles([(url: file, subfolderPath: "")])
        await store.waitForProcessing()
        let entry = try #require(store.entries.first)

        store.rejectEntry(entry)
        let rejectedFile = folder.appending(path: "REJECTED/frame.fits")
        #expect(entry.url.standardizedFileURL == rejectedFile.standardizedFileURL)
        #expect(exists(rejectedFile))

        // Reopen the folder with its REJECTED folder, as Open Folder does.
        store.openFiles([(url: entry.url, subfolderPath: "")], rejectedURLs: [entry.url])
        await store.waitForProcessing()
        #expect(store.entries.count == 1)
    }
}
