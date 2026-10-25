//
//  FolderAccessTests.swift
//  FITS Blaster Tests
//
//  Folder access for rejecting (CODE_AUDIT §5.13): each dropped folder keeps its own
//  bookmark, and a frame whose folder can't be written asks for access first when
//  that can help (the sandboxed build). The tests run without the sandbox, so a
//  read-only folder stands in for a folder the sandbox hasn't granted: moving a frame
//  out of it fails with the same "no permission" error.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct FolderAccessTests {

    private func fitsData() -> Data {
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        return TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                 pixels: TestFITS.bigEndian(stored))
    }

    /// A new folder in the temporary directory with one frame, `name`.
    private func makeFolder(frame name: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try fitsData().write(to: folder.appending(component: name))
        return folder
    }

    private func setReadOnly(_ folder: URL, _ readOnly: Bool) throws {
        try FileManager.default.setAttributes([.posixPermissions: readOnly ? 0o555 : 0o755],
                                              ofItemAtPath: folder.path(percentEncoded: false))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    // MARK: - Bookmarks per folder

    @Test("Frames dropped from two folders each get their own folder's bookmark")
    func bookmarksPerDroppedFolder() async throws {
        let first = try makeFolder(frame: "a.fits")
        let second = try makeFolder(frame: "b.fits")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }

        let store = ImageStore()
        store.openDroppedItems([first, second], settings: AppSettings())
        await store.pipeline.waitForProcessing()

        let a = try #require(store.entries.first { $0.fileName == "a.fits" })
        let b = try #require(store.entries.first { $0.fileName == "b.fits" })
        #expect(a.directoryBookmark != nil)
        #expect(a.directoryBookmark == store.sessionBookmarks[first.standardizedFileURL])
        #expect(b.directoryBookmark == store.sessionBookmarks[second.standardizedFileURL])
        #expect(a.directoryBookmark != b.directoryBookmark)
    }

    @Test("bookmark(for:) takes the deepest folder, and LIGHT doesn't match LIGHT2")
    func bookmarkLookup() {
        let store = ImageStore()
        store.sessionBookmarks = [URL(fileURLWithPath: "/n/LIGHT"): Data([1]),
                                  URL(fileURLWithPath: "/n/LIGHT/Ha"): Data([2])]
        #expect(store.bookmark(for: URL(fileURLWithPath: "/n/LIGHT/a.fits")) == Data([1]))
        #expect(store.bookmark(for: URL(fileURLWithPath: "/n/LIGHT/Ha/b.fits")) == Data([2]))
        #expect(store.bookmark(for: URL(fileURLWithPath: "/n/LIGHT2/c.fits")) == nil)
    }

    // MARK: - Asking for access

    @Test("A frame that can't be moved asks for its folder, then is rejected once granted")
    func askThenReject() async throws {
        let folder = try makeFolder(frame: "a.fits")
        defer { try? setReadOnly(folder, false); try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.asksForFolderAccess = true
        store.openDroppedItems([folder.appending(component: "a.fits")], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        let entry = try #require(store.entries.first)

        try setReadOnly(folder, true)
        store.rejectEntry(entry)
        let request = try #require(store.folderAccessRequest)
        #expect(ImageStore.folderPrefix(request.folder) == ImageStore.folderPrefix(folder))
        #expect(request.entryIDs == [entry.id])
        #expect(!entry.isRejected)
        #expect(store.errorMessage == nil)

        try setReadOnly(folder, false)
        store.grantFolderAccess(folder)
        #expect(store.folderAccessRequest == nil)
        #expect(entry.isRejected)
        #expect(exists(folder.appending(path: "REJECTED/a.fits")))
        #expect(store.sessionBookmarks[folder.standardizedFileURL] != nil)
    }

    @Test("Cancelling the question rejects nothing")
    func cancelRejectsNothing() async throws {
        let folder = try makeFolder(frame: "a.fits")
        defer { try? setReadOnly(folder, false); try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.asksForFolderAccess = true
        store.openDroppedItems([folder.appending(component: "a.fits")], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        let entry = try #require(store.entries.first)

        try setReadOnly(folder, true)
        store.rejectEntry(entry)
        store.cancelFolderAccessRequest()
        #expect(store.folderAccessRequest == nil)
        #expect(!entry.isRejected)
        #expect(exists(folder.appending(component: "a.fits")))
    }

    @Test("Choosing a different folder rejects nothing and says which folder is needed")
    func wrongFolderChosen() async throws {
        let folder = try makeFolder(frame: "a.fits")
        let other = try makeFolder(frame: "b.fits")
        defer {
            try? setReadOnly(folder, false)
            try? FileManager.default.removeItem(at: folder); try? FileManager.default.removeItem(at: other)
        }
        let store = ImageStore()
        store.asksForFolderAccess = true
        store.openDroppedItems([folder.appending(component: "a.fits")], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        let entry = try #require(store.entries.first)

        try setReadOnly(folder, true)
        store.rejectEntry(entry)
        store.grantFolderAccess(other)
        #expect(!entry.isRejected)
        #expect(store.errorMessage?.contains(folder.lastPathComponent) == true)
    }

    @Test("Without the sandbox a permission error is reported, not asked")
    func directBuildReportsError() async throws {
        let folder = try makeFolder(frame: "a.fits")
        defer { try? setReadOnly(folder, false); try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.asksForFolderAccess = false
        store.openDroppedItems([folder.appending(component: "a.fits")], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        let entry = try #require(store.entries.first)

        try setReadOnly(folder, true)
        store.rejectEntry(entry)
        #expect(store.folderAccessRequest == nil)
        #expect(store.errorMessage?.hasPrefix("Failed to reject a.fits") == true)
        #expect(!entry.isRejected)
    }

    @Test("Permission errors are recognised in Cocoa, POSIX and underlying form")
    func permissionErrors() {
        #expect(ImageStore.isPermissionDenied(CocoaError(.fileWriteNoPermission)))
        #expect(ImageStore.isPermissionDenied(NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))))
        #expect(ImageStore.isPermissionDenied(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                                      userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))])))
        #expect(!ImageStore.isPermissionDenied(CocoaError(.fileNoSuchFile)))
    }
}
