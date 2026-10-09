//
//  GroupStatisticsTests.swift
//  FITS Blaster Tests
//
//  Integration tests for ImageStore.updateGroupStatistics: median computation,
//  per-group isolation, skyBackground / psfSignalWeight fields, and topThirdScoreFloor.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct GroupStatisticsTests {

    // MARK: - Helpers

    private func makeEntry(
        fwhm: Float = 3.0, eccentricity: Float = 0.1,
        snr: Float = 100, starCount: Int = 200,
        qualityScore: Int = 70,
        skyBackground: Float? = nil,
        psfSignalWeight: Float? = nil,
        filter: String? = nil
    ) -> ImageEntry {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        entry.isProcessing = false
        entry.metrics = FrameMetrics(
            fwhm: fwhm, eccentricity: eccentricity, snr: snr, starCount: starCount,
            qualityScore: qualityScore, skyBackground: skyBackground,
            psfSignalWeight: psfSignalWeight)
        if let filter { entry.headers = ["FILTER": filter] }
        return entry
    }

    // MARK: - Sky background and PSF Signal Weight

    @Test("updateGroupStatistics computes medianSkyBackground correctly")
    func medianSkyBackground() {
        // Values [800, 1200, 1600] sorted → median at index 1 = 1200
        let store = ImageStore()
        for bg: Float in [1600, 800, 1200] {
            store.entries.append(makeEntry(skyBackground: bg))
        }
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.medianSkyBackground == Float(1200), "Median of [800,1200,1600] should be 1200")
    }

    @Test("updateGroupStatistics computes medianPSFSignalWeight correctly")
    func medianPSFSignalWeight() {
        // Values [30, 40, 50] sorted → median at index 1 = 40
        let store = ImageStore()
        for psf: Float in [50, 30, 40] {
            store.entries.append(makeEntry(psfSignalWeight: psf))
        }
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.medianPSFSignalWeight == Float(40), "Median of [30,40,50] should be 40")
    }

    @Test("Entries with nil skyBackground are excluded from the median")
    func nilSkyBackgroundExcluded() {
        // Entries: nil, 1000, 3000 → median of [1000, 3000], count=2, index=1 → 3000
        let store = ImageStore()
        store.entries.append(makeEntry(skyBackground: nil))
        store.entries.append(makeEntry(skyBackground: 1000))
        store.entries.append(makeEntry(skyBackground: 3000))
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.medianSkyBackground == Float(3000),
                "nil entries excluded; median of [1000,3000] at index 1 = 3000")
    }

    @Test("Group with all-nil skyBackground produces nil medianSkyBackground")
    func allNilSkyBackground() {
        let store = ImageStore()
        store.entries.append(makeEntry(skyBackground: nil))
        store.entries.append(makeEntry(skyBackground: nil))
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.medianSkyBackground == nil)
    }

    // MARK: - Per-group isolation

    @Test("updateGroupStatistics computes per-filter-group medians independently")
    func perGroupIsolation() {
        // Ha FWHM: [2.0, 3.0, 4.0] → median = 3.0
        // OIII FWHM: [5.0, 6.0, 7.0] → median = 6.0
        let store = ImageStore()
        for fwhm: Float in [2.0, 3.0, 4.0] {
            store.entries.append(makeEntry(fwhm: fwhm, filter: "Ha"))
        }
        for fwhm: Float in [5.0, 6.0, 7.0] {
            store.entries.append(makeEntry(fwhm: fwhm, filter: "OIII"))
        }
        store.updateGroupStatistics()
        let haGroup  = FilterGroup.normalise("Ha")
        let oiiiGroup = FilterGroup.normalise("OIII")
        #expect(store.groupStatistics[haGroup]?.medianFWHM == Float(3.0))
        #expect(store.groupStatistics[oiiiGroup]?.medianFWHM == Float(6.0))
    }

    @Test("Groups with no entries are absent from groupStatistics")
    func absentGroupProducesNilStats() {
        let store = ImageStore()
        store.entries.append(makeEntry(filter: "Ha"))
        store.updateGroupStatistics()
        let oiiiGroup = FilterGroup.normalise("OIII")
        #expect(store.groupStatistics[oiiiGroup] == nil)
    }

    // MARK: - Median algorithm

    @Test("Median of even-count list picks upper-middle element")
    func evenCountMedian() {
        // Four FWHM values [1, 2, 3, 4] sorted → count=4, index=2 → 3
        let store = ImageStore()
        for fwhm: Float in [4, 1, 3, 2] {
            store.entries.append(makeEntry(fwhm: fwhm))
        }
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.medianFWHM == Float(3))
    }

    // MARK: - topThirdScoreFloor

    @Test("topThirdScoreFloor is nil for groups with fewer than 3 scored entries")
    func topThirdNilForSmallGroup() {
        let store = ImageStore()
        store.entries.append(makeEntry(qualityScore: 60))
        store.entries.append(makeEntry(qualityScore: 80))
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.topThirdScoreFloor == nil)
    }

    @Test("topThirdScoreFloor is computed correctly for groups with 3 or more entries")
    func topThirdComputedCorrectly() {
        // Scores [50, 60, 70, 80, 90] sorted → count=5, floor at index 5*2/3=3 → 80
        let store = ImageStore()
        for score in [90, 50, 80, 60, 70] {
            store.entries.append(makeEntry(qualityScore: score))
        }
        store.updateGroupStatistics()
        let stats = store.groupStatistics.values.first
        #expect(stats?.topThirdScoreFloor == 80)
    }
}
