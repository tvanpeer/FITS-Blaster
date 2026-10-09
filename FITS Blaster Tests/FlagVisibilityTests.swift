//
//  FlagVisibilityTests.swift
//  FITS Blaster Tests
//
//  Integration tests for the auto-flag + visibility pipeline: applyAutoFlag,
//  flaggedEntryIDs state, visibilityFilteredEntries in .active mode, and deflagAll.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct FlagVisibilityTests {

    // MARK: - Helpers

    private func makeStore() -> (ImageStore, good: ImageEntry, bad: ImageEntry) {
        let store = ImageStore()

        let good = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        good.isProcessing = false
        good.metrics = FrameMetrics(fwhm: 2.0, eccentricity: 0.1, snr: 100, starCount: 200,
                                     qualityScore: 80, skyBackground: nil, psfSignalWeight: nil)

        let bad = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        bad.isProcessing = false
        bad.metrics = FrameMetrics(fwhm: 8.0, eccentricity: 0.1, snr: 100, starCount: 200,
                                    qualityScore: 80, skyBackground: nil, psfSignalWeight: nil)

        store.entries.append(good)
        store.entries.append(bad)
        store.updateGroupStatistics()
        return (store, good, bad)
    }

    private func absoluteFWHMConfig(threshold: Double) -> AutoRejectConfig {
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = true
        config.absoluteFWHM = threshold
        config.useEccentricity = false
        config.useStarCount = false
        config.useSNR = false
        return config
    }

    // MARK: - applyAutoFlag

    @Test("applyAutoFlag adds matching entries to flaggedEntryIDs")
    func autoFlagAddsToFlaggedIDs() {
        let (store, _, bad) = makeStore()
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))
        #expect(store.flaggedEntryIDs.contains(bad.id), "Bad entry should be flagged")
        #expect(store.flaggedEntryIDs.count == 1, "Exactly one entry should be flagged")
    }

    @Test("applyAutoFlag does not remove previously flagged entries")
    func autoFlagIsAdditive() {
        let (store, good, bad) = makeStore()

        // Manually flag the good entry first.
        store.flagEntries([good])
        #expect(store.flaggedEntryIDs.contains(good.id))

        // Auto-flag only the bad entry.
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))

        #expect(store.flaggedEntryIDs.contains(good.id), "Pre-existing flag should be preserved")
        #expect(store.flaggedEntryIDs.contains(bad.id),  "Bad entry should now also be flagged")
        #expect(store.flaggedEntryIDs.count == 2)
    }

    // MARK: - isVisible in .active mode

    @Test("isVisible returns true only for flagged entries in .active mode")
    func isVisibleInActiveMode() {
        let (store, good, bad) = makeStore()
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))
        store.rejectionVisibility = .active

        #expect(store.isVisible(bad)  == true,  "Flagged entry should be visible")
        #expect(store.isVisible(good) == false, "Unflagged entry should not be visible")
    }

    // MARK: - visibilityFilteredEntries in .active mode

    @Test(".active mode restricts visibilityFilteredEntries to flagged entries only")
    func visibilityFilteredInActiveMode() {
        let (store, _, bad) = makeStore()
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))
        store.rejectionVisibility = .active

        #expect(store.visibilityFilteredEntries.count == 1)
        #expect(store.visibilityFilteredEntries.first === bad)
    }

    // MARK: - deflagAll

    @Test("deflagAll clears flaggedEntryIDs")
    func deflagAllClearsSet() {
        let (store, _, _) = makeStore()
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))
        #expect(store.flaggedEntryIDs.isEmpty == false)

        store.deflagAll()
        #expect(store.flaggedEntryIDs.isEmpty)
    }

    @Test("After deflagAll, .active mode shows no entries")
    func deflagAllEmptiesActiveView() {
        let (store, _, _) = makeStore()
        store.applyAutoFlag(config: absoluteFWHMConfig(threshold: 4.0))
        store.rejectionVisibility = .active
        store.deflagAll()

        #expect(store.visibilityFilteredEntries.isEmpty,
                "No entries should be visible in .active after clearing flags")
    }
}
