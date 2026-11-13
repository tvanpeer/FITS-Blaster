//
//  BatchRejectTests.swift
//  FITS Blaster Tests
//
//  Step 11b (CODE_AUDIT §5.14): rejecting and undoing several frames at once moves the
//  files off the main actor, rebuilds the list once and reports every failure in one
//  message.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct BatchRejectTests {

    private func fitsData() -> Data {
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        return TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                 pixels: TestFITS.bigEndian(stored))
    }

    /// A temporary folder with `count` frames, f01.fits …, loaded into a new store.
    private func loadFolder(frames count: Int) async throws -> (folder: URL, store: ImageStore) {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = fitsData()
        for i in 1...count {
            try data.write(to: folder.appending(component: "f\(i < 10 ? "0" : "")\(i).fits"))
        }
        let store = ImageStore()
        store.openDroppedItems([folder], includeSubfolders: false, includeRejected: false, settings: AppSettings())
        await store.pipeline.waitForProcessing()
        return (folder, store)
    }

    private func entry(_ name: String, in store: ImageStore) throws -> ImageEntry {
        try #require(store.entries.first { $0.fileName == name })
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private func setLocked(_ url: URL, _ locked: Bool) throws {
        try FileManager.default.setAttributes([.immutable: locked], ofItemAtPath: url.path(percentEncoded: false))
    }

    // MARK: - Reject and undo

    @Test("A batch with one locked file: the other 39 move, the message names the locked one")
    func lockedFileInBatch() async throws {
        let (folder, store) = try await loadFolder(frames: 40)
        let locked = folder.appending(component: "f07.fits")
        defer { try? setLocked(locked, false); try? FileManager.default.removeItem(at: folder) }
        try setLocked(locked, true)

        store.rejectEntries(store.entries)
        #expect(store.frameMoves.progress != nil || !store.frameMoves.movingIDs.isEmpty)
        await store.frameMoves.wait()

        #expect(store.entries.count(where: \.isRejected) == 39)
        #expect(store.rejectedEntryIDs.count == 39)
        #expect(try !entry("f07.fits", in: store).isRejected)
        #expect(exists(locked))
        #expect(exists(folder.appending(path: "REJECTED/f01.fits")))
        #expect(store.errorMessage == """
            1 of 40 frames could not be moved to REJECTED:
            f07.fits — the file is locked (Finder: Get Info → Locked)
            """)
        #expect(store.frameMoves.progress == nil)
        #expect(store.frameMoves.movingIDs.isEmpty)
    }

    @Test("A single locked frame: the message says it is locked")
    func lockedSingleFrame() async throws {
        let (folder, store) = try await loadFolder(frames: 2)
        let locked = folder.appending(component: "f01.fits")
        defer { try? setLocked(locked, false); try? FileManager.default.removeItem(at: folder) }
        try setLocked(locked, true)

        store.rejectEntry(try entry("f01.fits", in: store))
        #expect(try !entry("f01.fits", in: store).isRejected)
        #expect(store.errorMessage == "Failed to reject f01.fits: the file is locked (Finder: Get Info → Locked)")
    }

    @Test("Undo of a batch puts every file back and removes the empty REJECTED folder")
    func undoBatch() async throws {
        let (folder, store) = try await loadFolder(frames: 12)
        defer { try? FileManager.default.removeItem(at: folder) }

        store.rejectEntries(store.entries)
        await store.frameMoves.wait()
        #expect(store.entries.allSatisfy { $0.isRejected })

        store.undoRejectEntries(store.entries)
        await store.frameMoves.wait()
        #expect(store.entries.allSatisfy { !$0.isRejected })
        #expect(store.rejectedEntryIDs.isEmpty)
        #expect(store.entries.allSatisfy { $0.url == $0.originalURL && exists($0.url) })
        #expect(!exists(folder.appending(component: "REJECTED")))
        #expect(store.errorMessage == nil)
    }

    @Test("A frame removed from the list during the batch: its file moves, the list doesn't get it back")
    func removedDuringBatch() async throws {
        let (folder, store) = try await loadFolder(frames: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        let removed = try entry("f02.fits", in: store)

        store.rejectEntries(store.entries)
        store.removeEntries(withIDs: [removed.id], alwaysMoveCursor: false)
        await store.frameMoves.wait()

        #expect(store.entries.count == 2)
        #expect(store.entries.allSatisfy { $0.isRejected })
        #expect(!store.rejectedEntryIDs.contains(removed.id))
        #expect(exists(folder.appending(path: "REJECTED/f02.fits")))
    }

    @Test("Rejecting a frame that is still being moved is skipped")
    func secondRejectWhileMoving() async throws {
        let (folder, store) = try await loadFolder(frames: 3)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = try entry("f01.fits", in: store)

        store.rejectEntries(store.entries)
        store.rejectEntry(first)                  // still in the batch: skipped
        await store.frameMoves.wait()

        #expect(store.entries.allSatisfy { $0.isRejected })
        #expect(store.errorMessage == nil)
        #expect(RejectedFolder.isInRejectedFolder(first.url) && exists(first.url))
    }

    @Test("A batch started during another runs after it")
    func batchesInOrder() async throws {
        let (folder, store) = try await loadFolder(frames: 4)
        defer { try? FileManager.default.removeItem(at: folder) }
        let firstTwo = Array(store.entries.prefix(2)), lastTwo = Array(store.entries.suffix(2))

        store.rejectEntries(firstTwo)
        store.rejectEntries(lastTwo)
        await store.frameMoves.wait()
        #expect(store.entries.allSatisfy { $0.isRejected })

        store.undoRejectEntries(firstTwo)
        store.rejectEntries(firstTwo)             // still being restored: skipped
        await store.frameMoves.wait()
        #expect(firstTwo.allSatisfy { !$0.isRejected })
        #expect(lastTwo.allSatisfy { $0.isRejected })
    }

    // MARK: - Message

    @Test("The message lists at most 5 frames, then how many more")
    func messageFormat() {
        let failures = (1...7).map { (fileName: "f\($0).fits", reason: "locked") }
        #expect(FrameMoves.failureMessage(kind: .reject, failures: failures, total: 40) == """
            7 of 40 frames could not be moved to REJECTED:
            f1.fits — locked
            f2.fits — locked
            f3.fits — locked
            f4.fits — locked
            f5.fits — locked
            and 2 more
            """)
        #expect(FrameMoves.failureMessage(kind: .restore, failures: [(fileName: "a.fits", reason: "gone")], total: 2)
                == "1 of 2 frames could not be moved back from REJECTED:\na.fits — gone")
    }
}
