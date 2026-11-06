//
//  SessionListsTests.swift
//  FITS Blaster Tests
//
//  The lists the sidebar and chart show are built once per change (performance audit P2,
//  P3; CODE_AUDIT §7.5b, §8.5, §9.11): the shared filter grouping and median, the stored
//  sidebar sections (equal to the filtering the sidebar did while drawing). The chart's
//  data snapshot is tested in SessionChartDataTests.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct SessionListsTests {

    private func entry(_ filter: String, folder: String = "", fwhm: Float? = 2) -> ImageEntry {
        let e = ImageEntry(url: URL(fileURLWithPath: "/data/\(folder)/\(UUID().uuidString).fits"))
        e.isProcessing = false
        e.subfolderPath = folder
        e.headers = ["FILTER": filter]
        e.metrics = FrameMetrics(fwhm: fwhm, eccentricity: 0.1, snr: 50, starCount: 100,
                                 qualityScore: 70, skyBackground: nil, psfSignalWeight: nil)
        return e
    }

    private func store(_ entries: [ImageEntry]) -> ImageStore {
        let store = ImageStore()
        store.entries = entries
        store.updateGroupStatistics()
        return store
    }

    // MARK: - Helpers

    @Test("Grouping by filter keeps the canonical group order and the entries' order")
    func groupedOrder() {
        let o1 = entry("OIII"), h1 = entry("Ha"), o2 = entry("OIII"), h2 = entry("Ha")
        let groups = FilterGroup.grouped([o1, h1, o2, h2])
        #expect(groups.map(\.group) == [.ha, .oiii])
        #expect(groups[0].entries.map(\.id) == [h1.id, h2.id])
        #expect(groups[1].entries.map(\.id) == [o1.id, o2.id])
    }

    @Test("The median is the middle value after sorting; for an even count the mean of the two middle ones")
    func median() {
        #expect([Float]().median == nil)
        #expect([Int]().median == nil)
        #expect([3, 1, 2].median == 2)
        #expect([4, 1, 3, 2].median == 2.5)
        #expect([Float(3.5)].median == 3.5)
        #expect([Float(1), 2].median == 1.5)
        #expect([Double(7), 1, 4, 9, 2, 8].median == 5.5)
    }

    // MARK: - Stored sidebar lists

    /// The sidebar's sections as it filtered them while drawing, before step 9b.
    private func oldSections(_ store: ImageStore) -> [[UUID]] {
        store.groupedByFolderAndFilter.map { folder in
            folder.filterGroups.flatMap { $0.1 }.filter { store.isVisible($0) }.map(\.id)
        }
    }

    @Test("The stored folder sections equal the sidebar's old filtering", arguments: [
        RejectionVisibility.all, .active, .rejected,
    ])
    func sectionsMatchOldFiltering(visibility: RejectionVisibility) {
        let frames = [entry("Ha", folder: "A"), entry("OIII", folder: "A"), entry("Ha", folder: "B"),
                      entry("SII", folder: "B"), entry("Ha", folder: "A")]
        let store = store(frames)
        store.flaggedEntryIDs = [frames[0].id, frames[3].id]
        store.rejectedEntryIDs = [frames[1].id]
        store.rejectionVisibility = visibility
        store.updateVisibilityFilteredEntries()

        #expect(store.visibleFolderSections.map { $0.entries.map(\.id) } == oldSections(store))
        store.sidebarFilterGroup = .ha
        #expect(store.visibleFolderSections.map { $0.entries.map(\.id) } == oldSections(store))
    }

    @Test("A rebuild raises the list revision")
    func revisionRaised() {
        let store = store([entry("Ha")])
        let before = store.listRevision
        store.flaggedEntryIDs = [store.entries[0].id]
        #expect(store.listRevision > before)
    }

}
