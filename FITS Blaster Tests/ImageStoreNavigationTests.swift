//
//  ImageStoreNavigationTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore cursor navigation, selection operations,
//  visibility filtering, and advanceCursorIfNeeded.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct ImageStoreNavigationTests {

    // MARK: - Helpers

    /// Creates an ImageStore with N entries, all finished processing.
    private func makeStore(count: Int) -> (ImageStore, [ImageEntry]) {
        let store = ImageStore()
        var entries: [ImageEntry] = []
        for i in 0..<count {
            let url = URL(fileURLWithPath: "/tmp/entry-\(i).fits")
            let entry = ImageEntry(url: url)
            entry.isProcessing = false
            store.entries.append(entry)
            entries.append(entry)
        }
        store.updateCachedSort()
        return (store, entries)
    }

    // MARK: - selectNext / selectPrevious

    @Test("selectNext moves cursor forward")
    func selectNextMovesForward() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[0]
        store.selectNext(in: entries)
        #expect(store.selectedEntry === entries[1])
    }

    @Test("selectPrevious moves cursor backward")
    func selectPreviousMovesBackward() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[2]
        store.selectPrevious(in: entries)
        #expect(store.selectedEntry === entries[1])
    }

    @Test("selectNext at last entry stays put")
    func selectNextAtEnd() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[2]
        store.selectNext(in: entries)
        #expect(store.selectedEntry === entries[2], "Should not move past the end")
    }

    @Test("selectPrevious at first entry stays put")
    func selectPreviousAtStart() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[0]
        store.selectPrevious(in: entries)
        #expect(store.selectedEntry === entries[0], "Should not move before the start")
    }

    @Test("selectNext with no selection selects first")
    func selectNextWithNoSelection() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = nil
        store.selectNext(in: entries)
        #expect(store.selectedEntry === entries[0])
    }

    @Test("selectPrevious with no selection selects first")
    func selectPreviousWithNoSelection() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = nil
        store.selectPrevious(in: entries)
        #expect(store.selectedEntry === entries[0])
    }

    // MARK: - selectFirst / selectLast

    @Test("selectFirst selects the first entry")
    func selectFirst() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[2]
        store.selectFirst(in: entries)
        #expect(store.selectedEntry === entries[0])
    }

    @Test("selectLast selects the last entry")
    func selectLast() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[0]
        store.selectLast(in: entries)
        #expect(store.selectedEntry === entries[2])
    }

    // MARK: - advanceCursorIfNeeded

    @Test("advanceCursorIfNeeded moves to next visible entry")
    func advanceCursorForward() {
        let (store, entries) = makeStore(count: 4)
        // Flag entries 0,1,2 — entry 1 (selected) will be unflagged
        store.flaggedEntryIDs = Set(entries.map { $0.id })
        store.rejectionVisibility = .active
        store.updateVisibilityFilteredEntries()
        store.selectedEntry = entries[1]

        let preOrder = store.visibilityFilteredEntries
        // Unflag entry 1 — it disappears from the flagged view
        store.flaggedEntryIDs.remove(entries[1].id)
        store.updateVisibilityFilteredEntries()

        store.advanceCursorIfNeeded(from: preOrder)
        #expect(store.selectedEntry === entries[2], "Should advance to next visible")
    }

    @Test("advanceCursorIfNeeded falls back to previous when at end")
    func advanceCursorFallback() {
        let (store, entries) = makeStore(count: 3)
        store.flaggedEntryIDs = Set(entries.map { $0.id })
        store.rejectionVisibility = .active
        store.updateVisibilityFilteredEntries()
        store.selectedEntry = entries[2]

        let preOrder = store.visibilityFilteredEntries
        // Unflag last entry
        store.flaggedEntryIDs.remove(entries[2].id)
        store.updateVisibilityFilteredEntries()

        store.advanceCursorIfNeeded(from: preOrder)
        #expect(store.selectedEntry === entries[1], "Should fall back to previous visible")
    }

    @Test("advanceCursorIfNeeded does nothing when cursor is still visible")
    func advanceCursorNoOp() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[1]
        let order = entries
        store.advanceCursorIfNeeded(from: order)
        #expect(store.selectedEntry === entries[1], "Should not move if still visible")
    }

    // MARK: - selectAllVisible / deselectAll / invertSelection

    @Test("selectAllVisible selects all visible entries")
    func selectAllVisible() {
        let (store, entries) = makeStore(count: 3)
        store.selectAllVisible()
        #expect(store.markedForRejectionIDs == Set(entries.map { $0.id }))
    }

    @Test("deselectAll clears the range selection")
    func deselectAll() {
        let (store, entries) = makeStore(count: 3)
        store.markedForRejectionIDs = Set(entries.map { $0.id })
        store.deselectAll()
        #expect(store.markedForRejectionIDs.isEmpty)
    }

    @Test("invertSelection flips the range selection")
    func invertSelection() {
        let (store, entries) = makeStore(count: 4)
        store.markedForRejectionIDs = [entries[0].id, entries[1].id]
        store.invertSelection()
        #expect(store.markedForRejectionIDs == Set([entries[2].id, entries[3].id]))
    }

    // MARK: - extendSelection

    @Test("extendSelectionNext adds next entry to range")
    func extendSelectionNext() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[0]
        store.extendSelectionNext(in: entries)
        #expect(store.markedForRejectionIDs.contains(entries[0].id))
        #expect(store.markedForRejectionIDs.contains(entries[1].id))
        #expect(store.selectedEntry === entries[1])
    }

    @Test("extendSelectionPrevious adds previous entry to range")
    func extendSelectionPrevious() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[2]
        store.extendSelectionPrevious(in: entries)
        #expect(store.markedForRejectionIDs.contains(entries[2].id))
        #expect(store.markedForRejectionIDs.contains(entries[1].id))
        #expect(store.selectedEntry === entries[1])
    }

    // MARK: - Visibility filtering

    @Test("Rejected visibility shows only rejected entries")
    func rejectedVisibility() {
        let (store, entries) = makeStore(count: 3)
        entries[1].isRejected = true
        store.rejectedEntryIDs.insert(entries[1].id)
        store.rejectionVisibility = .rejected

        #expect(store.visibilityFilteredEntries.count == 1)
        #expect(store.visibilityFilteredEntries.first === entries[1])
    }

    @Test("Flagged visibility shows only flagged entries")
    func flaggedVisibility() {
        let (store, entries) = makeStore(count: 3)
        store.flaggedEntryIDs = [entries[0].id, entries[2].id]
        store.rejectionVisibility = .active

        #expect(store.visibilityFilteredEntries.count == 2)
        #expect(store.isVisible(entries[0]) == true)
        #expect(store.isVisible(entries[1]) == false)
        #expect(store.isVisible(entries[2]) == true)
    }

    @Test("All visibility shows everything")
    func allVisibility() {
        let (store, entries) = makeStore(count: 3)
        entries[1].isRejected = true
        store.rejectedEntryIDs.insert(entries[1].id)
        store.rejectionVisibility = .all

        #expect(store.visibilityFilteredEntries.count == 3)
    }

    // MARK: - Reset

    @Test("Reset clears all state")
    func resetClearsState() {
        let (store, entries) = makeStore(count: 3)
        store.selectedEntry = entries[1]
        store.flaggedEntryIDs = [entries[0].id]
        store.markedForRejectionIDs = [entries[2].id]
        store.reset()

        #expect(store.entries.isEmpty)
        #expect(store.selectedEntry == nil)
        #expect(store.flaggedEntryIDs.isEmpty)
        #expect(store.markedForRejectionIDs.isEmpty)
        #expect(store.rejectedEntryIDs.isEmpty)
        #expect(store.visibilityFilteredEntries.isEmpty)
    }
}
