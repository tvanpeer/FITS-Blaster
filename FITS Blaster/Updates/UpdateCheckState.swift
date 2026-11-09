//
//  UpdateCheckState.swift
//  FITS Blaster
//
//  Whether "Check for Updates…" can start a check now: Sparkle's `canCheckForUpdates`,
//  observed so the menu item is disabled while a check runs (step 14d, CODE_AUDIT §4.6).
//

#if !APPSTORE
import Foundation
import Observation

@MainActor @Observable
final class UpdateCheckState {

    /// False while an update check runs.
    private(set) var canCheck: Bool

    @ObservationIgnored private var observation: NSKeyValueObservation?

    /// Follows the Bool at `keyPath` on `source` (the `SPUUpdater`; a stand-in in tests).
    /// Sparkle's updater is used on the main thread only, so its changes arrive there.
    init<Source: NSObject>(source: Source, keyPath: KeyPath<Source, Bool>) {
        canCheck = source[keyPath: keyPath]
        observation = source.observe(keyPath, options: [.new]) { [weak self] _, change in
            guard let value = change.newValue else { return }
            MainActor.assumeIsolated { self?.canCheck = value }
        }
    }
}
#endif
