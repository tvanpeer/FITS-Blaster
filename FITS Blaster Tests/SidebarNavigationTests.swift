//
//  SidebarNavigationTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore.sidebarNavigationEntries(isSimpleMode:): flat-list cases
//  (simple mode, filter strip, single filter), geek-mode filter grouping, multi-folder
//  section order, and collapsed-folder exclusion.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct SidebarNavigationTests {

    // MARK: - Helpers

    private func makeEntry(filter: String? = nil, folder: String = "") -> ImageEntry {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        entry.isProcessing = false
        entry.subfolderPath = folder
        if let filter { entry.headers = ["FILTER": filter] }
        return entry
    }

    /// Returns true when every filter group in `entries` forms a single contiguous block —
    /// i.e. the same group never appears again after a different group has been seen.
    private func isGroupedContiguously(_ entries: [ImageEntry]) -> Bool {
        var seenGroups: Set<FilterGroup> = []
        var lastGroup: FilterGroup? = nil
        for entry in entries {
            let group = entry.filterGroup
            if group != lastGroup {
                if seenGroups.contains(group) { return false }   // group appeared earlier — not contiguous
                seenGroups.insert(group)
                lastGroup = group
            }
        }
        return true
    }

    // MARK: - Flat-list cases

    @Test("Simple mode returns a flat list regardless of how many filters are present")
    func simpleModeIsFlat() {
        let store = ImageStore()
        let ha1   = makeEntry(filter: "Ha")
        let oiii1 = makeEntry(filter: "OIII")
        let ha2   = makeEntry(filter: "Ha")
        for e in [ha1, oiii1, ha2] { store.entries.append(e) }
        store.updateGroupStatistics()
        // isMultiFilter = true, but isSimpleMode = true → flat list
        let result = store.sidebarNavigationEntries(isSimpleMode: true)
        #expect(result.map(\.id) == store.visibilityFilteredEntries.map(\.id))
    }

    @Test("Single-filter session returns a flat list in both modes")
    func singleFilterIsFlat() {
        let store = ImageStore()
        let e0 = makeEntry(filter: "Ha")
        let e1 = makeEntry(filter: "Ha")
        store.entries.append(e0)
        store.entries.append(e1)
        store.updateGroupStatistics()
        // isMultiFilter = false → flat list even in geek mode
        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.map(\.id) == store.visibilityFilteredEntries.map(\.id))
    }

    @Test("Active filter-strip selection returns only that group's entries")
    func filterStripReturnsGroup() {
        let store = ImageStore()
        let ha1   = makeEntry(filter: "Ha")
        let ha2   = makeEntry(filter: "Ha")
        let oiii1 = makeEntry(filter: "OIII")
        for e in [ha1, ha2, oiii1] { store.entries.append(e) }
        store.updateGroupStatistics()

        let haGroup = FilterGroup.normalise("Ha")
        store.sidebarFilterGroup = haGroup   // activate filter strip

        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.allSatisfy { $0.filterGroup == haGroup },
                "Only Ha entries should appear when the Ha filter strip is active")
        #expect(result.count == 2)
    }

    // MARK: - Geek mode: multi-filter grouping

    @Test("Geek mode groups entries by filter — same filter stays contiguous")
    func geekModeGroupsByFilter() {
        let store = ImageStore()
        // Interleave Ha and OIII entries so load order is mixed
        let ha1   = makeEntry(filter: "Ha")
        let oiii1 = makeEntry(filter: "OIII")
        let ha2   = makeEntry(filter: "Ha")
        let oiii2 = makeEntry(filter: "OIII")
        for e in [ha1, oiii1, ha2, oiii2] { store.entries.append(e) }
        store.updateGroupStatistics()

        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.count == 4)
        #expect(isGroupedContiguously(result),
                "Ha and OIII entries must each form a single contiguous block")
    }

    @Test("Geek mode includes all entries when no visibility filter is active")
    func geekModeIncludesAll() {
        let store = ImageStore()
        for filter in ["Ha", "Ha", "OIII", "OIII", "SII"] {
            store.entries.append(makeEntry(filter: filter))
        }
        store.updateGroupStatistics()
        // 5 entries, two filter groups
        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.count == 5)
    }

    // MARK: - Multi-folder

    @Test("Multi-folder mode returns entries in folder-then-filter section order")
    func multiFolderSectionOrder() {
        let store = ImageStore()
        // Two folders, each with Ha and OIII entries — added in mixed order
        let aHa   = makeEntry(filter: "Ha",   folder: "folderA")
        let bOIII = makeEntry(filter: "OIII", folder: "folderB")
        let aOIII = makeEntry(filter: "OIII", folder: "folderA")
        let bHa   = makeEntry(filter: "Ha",   folder: "folderB")
        for e in [aHa, bOIII, aOIII, bHa] { store.entries.append(e) }
        store.updateGroupStatistics()

        #expect(store.isMultiFolder, "Should be a multi-folder session")
        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.count == 4)

        // folderA entries must all precede folderB entries (folders sort alphabetically)
        let folderPaths = result.map { $0.subfolderPath }
        let firstBIdx = folderPaths.firstIndex(of: "folderB") ?? result.count
        let lastAIdx  = folderPaths.lastIndex(of: "folderA")  ?? -1
        #expect(lastAIdx < firstBIdx, "All folderA entries should precede all folderB entries")
    }

    @Test("Collapsed folder is excluded from multi-folder navigation entries")
    func collapsedFolderExcluded() {
        let store = ImageStore()
        let a1 = makeEntry(folder: "folderA")
        let a2 = makeEntry(folder: "folderA")
        let b1 = makeEntry(folder: "folderB")
        for e in [a1, a2, b1] { store.entries.append(e) }
        store.updateGroupStatistics()

        store.collapsedFolderPaths.insert("folderA")
        let result = store.sidebarNavigationEntries(isSimpleMode: false)

        #expect(result.count == 1, "Only the folderB entry should be returned")
        #expect(result.first === b1)
    }

    @Test("Multi-folder respects the active visibility filter")
    func multiFolderRespectsVisibility() {
        let store = ImageStore()
        let a1 = makeEntry(folder: "folderA")
        let a2 = makeEntry(folder: "folderA")
        let b1 = makeEntry(folder: "folderB")
        for e in [a1, a2, b1] { store.entries.append(e) }
        store.updateGroupStatistics()

        // Flag only a1 and b1, then switch to .active visibility
        store.flaggedEntryIDs = [a1.id, b1.id]
        store.rejectionVisibility = .active

        let result = store.sidebarNavigationEntries(isSimpleMode: false)
        #expect(result.count == 2, "Only the two flagged entries should appear")
        #expect(result.contains(where: { $0 === a1 }))
        #expect(result.contains(where: { $0 === b1 }))
    }
}
