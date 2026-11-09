//
//  UpdateCheckStateTests.swift
//  FITS Blaster Tests
//
//  Step 14d (CODE_AUDIT §4.6): "Check for Updates…" follows Sparkle's canCheckForUpdates.
//

#if !APPSTORE
import Foundation
import Testing
@testable import FITS_Blaster

/// Stands in for `SPUUpdater`: a KVO-observable `canCheckForUpdates`.
private final class StandInUpdater: NSObject {
    @objc dynamic var canCheckForUpdates = true
}

@MainActor
struct UpdateCheckStateTests {

    @Test("The menu item follows canCheckForUpdates: off while a check runs, on again after")
    func followsUpdater() {
        let updater = StandInUpdater()
        let state = UpdateCheckState(source: updater, keyPath: \.canCheckForUpdates)
        #expect(state.canCheck)

        updater.canCheckForUpdates = false      // a check starts
        #expect(!state.canCheck)

        updater.canCheckForUpdates = true       // it ends
        #expect(state.canCheck)
    }

    @Test("The starting value is taken from the updater")
    func startsFromUpdater() {
        let updater = StandInUpdater()
        updater.canCheckForUpdates = false
        #expect(!UpdateCheckState(source: updater, keyPath: \.canCheckForUpdates).canCheck)
    }
}
#endif
