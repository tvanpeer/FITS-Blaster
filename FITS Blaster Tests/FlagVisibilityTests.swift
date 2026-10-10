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

    private func makePSFStore() -> (ImageStore, highPSF: ImageEntry, lowPSF: ImageEntry) {
        let store = ImageStore()

        let high = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        high.isProcessing = false
        high.metrics = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil,
                                     qualityScore: 50, skyBackground: nil, psfSignalWeight: 8.0)

        let low = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
        low.isProcessing = false
        low.metrics = FrameMetrics(fwhm: nil, eccentricity: nil, snr: nil, starCount: nil,
                                    qualityScore: 50, skyBackground: nil, psfSignalWeight: 2.0)

        store.entries.append(high)
        store.entries.append(low)
        store.updateGroupStatistics()
        return (store, high, low)
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

    // MARK: - PSF autoflag

    @Test("applyAutoFlag with relative PSF threshold flags the low-PSF entry")
    func psfRelativeAutoflag() {
        // Median PSF = (8.0 + 2.0) / 2 = 5.0; multiplier 0.5 → floor = 2.5; low (2.0) < 2.5 → flagged
        let (store, _, lowPSF) = makePSFStore()
        var config = AutoRejectConfig()
        config.mode = .relative
        config.usePSF = true
        config.psfMultiplier = 0.5
        store.applyAutoFlag(config: config)

        #expect(store.flaggedEntryIDs.contains(lowPSF.id), "Low-PSF entry should be flagged")
        #expect(store.flaggedEntryIDs.count == 1, "Only the low-PSF entry should be flagged")
    }

    @Test("applyAutoFlag with absolute PSF threshold flags entries below the floor")
    func psfAbsoluteAutoflag() {
        let (store, _, lowPSF) = makePSFStore()
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.usePSF = true
        config.absolutePSFFloor = 3.0   // low entry (2.0) is below floor; high entry (8.0) is not
        store.applyAutoFlag(config: config)

        #expect(store.flaggedEntryIDs.contains(lowPSF.id), "Low-PSF entry should be flagged")
        #expect(store.flaggedEntryIDs.count == 1, "Only the low-PSF entry should be flagged")
    }
}
