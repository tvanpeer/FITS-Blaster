//
//  CommandClickTests.swift
//  FITS Blaster Tests
//
//  ⌘-click adds a frame to the (orange) range selection or takes it out, as in Finder, in
//  every view; it never flags or unflags (decided by Tom, 2026-10-27). Flagging the
//  selection is the flag key / "(De)flag" button (toggleFlagSelected).
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct CommandClickTests {

    private func makeStore(_ count: Int) -> (ImageStore, [ImageEntry]) {
        let store = ImageStore()
        let frames = (0..<count).map { _ in
            let e = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
            e.isProcessing = false
            return e
        }
        store.entries = frames
        store.updateGroupStatistics()
        store.selectedEntry = frames[0]
        return (store, frames)
    }

    @Test("Without a selection, ⌘-click starts one with the cursor frame and the clicked frame")
    func startsSelection() {
        let (store, f) = makeStore(5)
        store.toggleInSelection(f[3])
        #expect(store.markedForRejectionIDs == [f[0].id, f[3].id])
        #expect(store.selectedEntry === f[3])
        #expect(store.flaggedEntryIDs.isEmpty)
    }

    @Test("⌘-click inside the selection takes only that frame out; the cursor stays; nothing is flagged")
    func removesOneFrame() {
        let (store, f) = makeStore(5)
        store.markedForRejectionIDs = [f[1].id, f[2].id, f[3].id]
        store.selectedEntry = f[3]
        store.toggleInSelection(f[2])
        #expect(store.markedForRejectionIDs == [f[1].id, f[3].id])
        #expect(store.selectedEntry === f[3])
        #expect(store.flaggedEntryIDs.isEmpty)
    }

    @Test("⌘-click outside the selection adds that frame and moves the cursor to it")
    func addsOneFrame() {
        let (store, f) = makeStore(5)
        store.markedForRejectionIDs = [f[1].id, f[2].id]
        store.selectedEntry = f[2]
        store.toggleInSelection(f[4])
        #expect(store.markedForRejectionIDs == [f[1].id, f[2].id, f[4].id])
        #expect(store.selectedEntry === f[4])
        #expect(store.flaggedEntryIDs.isEmpty)
    }

    @Test("In the Flagged view ⌘-click selects too; it no longer unflags")
    func flaggedViewSelects() {
        let (store, f) = makeStore(4)
        store.flaggedEntryIDs = Set(f.map(\.id))
        store.rejectionVisibility = .active
        store.selectedEntry = f[0]
        store.toggleInSelection(f[2])
        #expect(store.flaggedEntryIDs == Set(f.map(\.id)))
        #expect(store.markedForRejectionIDs == [f[0].id, f[2].id])
    }

    @Test("Flagging the selection stays a separate action (flag key / (De)flag button)")
    func flagIsSeparate() {
        let (store, f) = makeStore(4)
        store.toggleInSelection(f[2])          // selection: f0, f2
        #expect(store.flaggedEntryIDs.isEmpty)
        store.toggleFlagSelected()
        #expect(store.flaggedEntryIDs == [f[0].id, f[2].id])
    }
}
