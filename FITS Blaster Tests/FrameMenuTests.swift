//
//  FrameMenuTests.swift
//  FITS Blaster Tests
//
//  The thumbnail bar's context menu: which frames it acts on (Finder convention), its
//  titles and reject items with and without toggle reject, and its flag, reject/undo,
//  remove and copy-path actions.
//

import Foundation
import SwiftUI
import Testing
@testable import FITS_Blaster

@MainActor
struct FrameMenuTests {

    private func makeStore(count: Int) -> (ImageStore, [ImageEntry]) {
        let store = ImageStore()
        var entries: [ImageEntry] = []
        for i in 0..<count {
            let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/entry-\(i).fits"))
            entry.isProcessing = false
            store.entries.append(entry)
            entries.append(entry)
        }
        store.updateGroupStatistics()
        return (store, entries)
    }

    private func model(targets: Int, flagged: Int = 0, rejected: Int = 0,
                       toggle: Bool = false) -> FrameMenuModel {
        FrameMenuModel(targetCount: targets, flaggedCount: flagged,
                       rejectedCount: rejected, useToggleReject: toggle)
    }

    // MARK: - Targets

    @Test("Right-click inside the orange selection acts on the whole selection, in list order")
    func targetsInsideSelection() {
        let (store, e) = makeStore(count: 5)
        store.markedForRejectionIDs = [e[3].id, e[1].id, e[2].id]
        #expect(store.frameMenuTargets(for: e[2]).map(\.id) == [e[1].id, e[2].id, e[3].id])
    }

    @Test("Right-click outside the selection acts on that frame alone; cursor and selection stay")
    func targetsOutsideSelection() {
        let (store, e) = makeStore(count: 5)
        store.selectedEntry = e[0]
        store.markedForRejectionIDs = [e[1].id, e[2].id]
        #expect(store.frameMenuTargets(for: e[4]).map(\.id) == [e[4].id])
        #expect(store.selectedEntry === e[0])
        #expect(store.markedForRejectionIDs == [e[1].id, e[2].id])
    }

    // MARK: - Model: flag

    @Test("Flag title: one frame, the unflagged ones of several, or Deflag when all are flagged")
    func flagTitles() {
        #expect(model(targets: 1).flagTitle == "Flag")
        #expect(model(targets: 1, flagged: 1).flagTitle == "Deflag")
        #expect(model(targets: 3, flagged: 1).flagTitle == "Flag 2 Frames")
        #expect(model(targets: 3, flagged: 3).flagTitle == "Deflag 3 Frames")
        #expect(model(targets: 3, flagged: 2).flagTitle == "Flag")
    }

    // MARK: - Model: reject, separate keys

    @Test("Separate keys: Reject and Undo Reject, each disabled when it has nothing to do")
    func separateRejectItems() {
        let none = model(targets: 3)
        #expect(none.rejectItems == [.reject, .undoReject])
        #expect(none.isEnabled(.reject) && !none.isEnabled(.undoReject))
        #expect(none.title(.reject) == "Reject 3 Frames")

        let all = model(targets: 3, rejected: 3)
        #expect(all.rejectItems == [.reject, .undoReject])
        #expect(!all.isEnabled(.reject) && all.isEnabled(.undoReject))
        #expect(all.title(.undoReject) == "Undo Reject 3 Frames")

        let mixed = model(targets: 5, rejected: 2)
        #expect(mixed.isEnabled(.reject) && mixed.isEnabled(.undoReject))
        #expect(mixed.title(.reject) == "Reject 3 Frames")
        #expect(mixed.title(.undoReject) == "Undo Reject 2 Frames")
    }

    // MARK: - Model: reject, toggle reject

    @Test("Toggle reject: one item that does what the reject key does")
    func toggleRejectItem() {
        #expect(model(targets: 1, toggle: true).rejectItems == [.reject])
        #expect(model(targets: 1, rejected: 1, toggle: true).rejectItems == [.undoReject])
        // Mixed: the reject key rejects the others (toggleRejectSelected), so "Reject".
        let mixed = model(targets: 5, rejected: 2, toggle: true)
        #expect(mixed.rejectItems == [.reject])
        #expect(mixed.isEnabled(.reject))
        #expect(mixed.title(.reject) == "Reject 3 Frames")
        #expect(model(targets: 4, rejected: 4, toggle: true).title(.undoReject) == "Undo Reject 4 Frames")
    }

    @Test("Copy and remove titles for one and several frames")
    func otherTitles() {
        #expect(model(targets: 1).copyPathTitle == "Copy File Path")
        #expect(model(targets: 2).copyPathTitle == "Copy File Paths")
        #expect(model(targets: 1).removeTitle == "Remove from List")
        #expect(model(targets: 4).removeTitle == "Remove 4 Frames from List")
    }

    @Test("The model counts the targets' flags and rejections")
    func modelFromStore() {
        let (store, e) = makeStore(count: 4)
        store.flaggedEntryIDs = [e[0].id, e[3].id]
        e[1].isRejected = true
        let m = store.frameMenuModel(for: [e[0], e[1], e[2]], useToggleReject: false)
        #expect(m == model(targets: 3, flagged: 1, rejected: 1))
    }

    // MARK: - Actions

    @Test("Flag: flags the unflagged targets; deflags when all are flagged; other flags stay")
    func toggleFlag() {
        let (store, e) = makeStore(count: 4)
        store.flaggedEntryIDs = [e[0].id, e[3].id]
        store.frameMenuToggleFlag([e[0], e[1]])
        #expect(store.flaggedEntryIDs == [e[0].id, e[1].id, e[3].id])
        store.frameMenuToggleFlag([e[0], e[1]])
        #expect(store.flaggedEntryIDs == [e[3].id])
    }

    @Test("Remove: the cursor stays when it isn't removed, and other flags stay")
    func removeKeepsCursor() {
        let (store, e) = makeStore(count: 4)
        store.selectedEntry = e[0]
        store.flaggedEntryIDs = [e[0].id, e[2].id]
        store.markedForRejectionIDs = [e[2].id, e[3].id]
        store.frameMenuRemove([e[2], e[3]])
        #expect(store.entries.map(\.id) == [e[0].id, e[1].id])
        #expect(store.selectedEntry === e[0])
        #expect(store.flaggedEntryIDs == [e[0].id])
        #expect(store.markedForRejectionIDs.isEmpty)
    }

    @Test("Remove: the cursor moves to the next frame when it is removed")
    func removeMovesCursor() {
        let (store, e) = makeStore(count: 4)
        store.selectedEntry = e[1]
        store.frameMenuRemove([e[1]])
        #expect(store.selectedEntry === e[2])
    }

    @Test("Copy File Path: the current paths, one per line")
    func filePathsText() {
        let urls = [URL(fileURLWithPath: "/a/LIGHT/f 1.fits"),
                    URL(fileURLWithPath: "/a/LIGHT/REJECTED/f2.fits")]
        #expect(ImageStore.filePathsText(urls) == "/a/LIGHT/f 1.fits\n/a/LIGHT/REJECTED/f2.fits")
    }

    @Test("Reject and Undo Reject move only the frames they apply to")
    func rejectAndUndo() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        let data = TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                     pixels: TestFITS.bigEndian(stored))
        for name in ["a", "b", "c"] { try data.write(to: folder.appending(component: "\(name).fits")) }

        let store = ImageStore()
        store.openDroppedItems([folder], settings: AppSettings())
        await store.pipeline.waitForProcessing()
        let a = try #require(store.entries.first { $0.fileName == "a.fits" })
        let b = try #require(store.entries.first { $0.fileName == "b.fits" })
        let c = try #require(store.entries.first { $0.fileName == "c.fits" })

        store.frameMenuReject([a])
        #expect(a.isRejected)
        // A mixed set: Reject rejects only b, Undo only undoes the rejected ones.
        store.frameMenuReject([a, b])
        #expect(a.isRejected && b.isRejected && !c.isRejected)
        #expect(store.errorMessage == nil)
        store.frameMenuUndoReject([a, c])
        #expect(!a.isRejected && b.isRejected && !c.isRejected)
        #expect(FileManager.default.fileExists(atPath: folder.appending(component: "a.fits").path(percentEncoded: false)))
        #expect(store.errorMessage == nil)
    }

    // MARK: - Key labels

    @Test("Key settings as menu key equivalents")
    func keyEquivalents() {
        #expect(KeyEquivalent.fromSetting("x") == KeyEquivalent("x"))
        #expect(KeyEquivalent.fromSetting("↑") == .upArrow)
        #expect(KeyEquivalent.fromSetting("⇲") == .end)
        #expect(KeyEquivalent.fromSetting(" ") == .space)
        #expect(KeyEquivalent.fromSetting("") == nil)
        #expect(KeyEquivalent.fromSetting("ab") == nil)
    }
}
