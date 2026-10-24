//
//  RemoveSelectedTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore.removeSelected: cursor placement after single-entry removal,
//  end-of-list fallback, batch-flagged removal, precedence of flags over cursor, and
//  no-op guard.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct RemoveSelectedTests {

    // MARK: - Helpers

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

    // MARK: - Single-entry cursor removal

    @Test("Removing the cursor from the middle advances to the next entry")
    func removeCursorAtMiddle() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[1]
        store.removeSelected()

        #expect(store.entries.count == 2)
        #expect(store.entries.contains(where: { $0 === entries[1] }) == false)
        #expect(store.selectedEntry === entries[2], "Cursor should advance to entries[2]")
    }

    @Test("Removing the cursor at the last position falls back to the previous entry")
    func removeCursorAtEnd() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[2]
        store.removeSelected()

        #expect(store.entries.count == 2)
        #expect(store.selectedEntry === entries[1], "Cursor should fall back to entries[1]")
    }

    @Test("Removing the only entry leaves cursor nil and entries empty")
    func removeSingleEntry() {
        let (store, entries) = makeStore(count: 1)
        store.selectedEntry = entries[0]
        store.removeSelected()

        #expect(store.entries.isEmpty)
        #expect(store.selectedEntry == nil)
    }

    // MARK: - Selection state after removal

    @Test("Removed entries leave no IDs in the reject sets")
    func removedIDsLeaveRejectSets() {
        let (store, entries) = makeStore(count: 3)
        store.markedForRejectionIDs = [entries[1].id, entries[2].id]
        store.rejectedEntryIDs = [entries[1].id]
        store.selectedEntry = entries[1]
        store.removeSelected()

        #expect(store.markedForRejectionIDs == [entries[2].id])
        #expect(store.rejectedEntryIDs.isEmpty)
    }

    // MARK: - Batch (flagged) removal

    @Test("Removing a flagged batch from the middle advances cursor past the batch")
    func removeFlaggedBatchAtMiddle() {
        // entries: [0, 1, 2, 3]; flags on 1+2 → removed; cursor should land on 3
        let (store, entries) = makeStore(count: 4)
        store.selectedEntry = entries[0]
        store.flaggedEntryIDs = [entries[1].id, entries[2].id]
        store.removeSelected()

        #expect(store.entries.count == 2)
        #expect(store.entries.contains(where: { $0 === entries[1] }) == false)
        #expect(store.entries.contains(where: { $0 === entries[2] }) == false)
        #expect(store.selectedEntry === entries[3], "Cursor should advance past the removed batch")
    }

    @Test("Removing a flagged batch at the end falls back to the entry before the batch")
    func removeFlaggedBatchAtEnd() {
        // entries: [0, 1, 2, 3]; flags on 2+3 → removed; cursor should fall back to 1
        let (store, entries) = makeStore(count: 4)
        store.flaggedEntryIDs = [entries[2].id, entries[3].id]
        store.removeSelected()

        #expect(store.entries.count == 2)
        #expect(store.selectedEntry === entries[1], "Cursor should fall back to entries[1]")
    }

    @Test("After batch removal flaggedEntryIDs is cleared")
    func flaggedIDsClearedAfterRemoval() {
        let (store, entries) = makeStore(count: 3)
        store.flaggedEntryIDs = [entries[0].id, entries[1].id]
        store.removeSelected()

        #expect(store.flaggedEntryIDs.isEmpty)
    }

    // MARK: - Flags take precedence over cursor

    @Test("When flags are set, flagged entries are removed rather than the cursor entry")
    func flaggedTakesPrecedenceOverCursor() {
        // Cursor on entry 0; entries 2+3 are flagged → 2 and 3 removed, 0 survives
        let (store, entries) = makeStore(count: 4)
        store.selectedEntry = entries[0]
        store.flaggedEntryIDs = [entries[2].id, entries[3].id]
        store.removeSelected()

        #expect(store.entries.contains(where: { $0 === entries[0] }), "Cursor entry should survive")
        #expect(store.entries.contains(where: { $0 === entries[1] }), "Non-flagged entry should survive")
        #expect(store.entries.contains(where: { $0 === entries[2] }) == false)
        #expect(store.entries.contains(where: { $0 === entries[3] }) == false)
        // Cursor should move to entries[1] (last non-removed before the removed batch at 2+3)
        #expect(store.selectedEntry === entries[1])
    }

    // MARK: - No-op guard

    @Test("removeSelected is a no-op when nothing is selected or flagged")
    func removeWithNothingSelected() {
        let (store, _) = makeStore(count: 3)
        store.selectedEntry = nil
        store.flaggedEntryIDs = []
        store.removeSelected()

        #expect(store.entries.count == 3, "No entries should be removed")
    }
}
