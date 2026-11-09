//
//  UpdateChannel.swift
//  FITS Blaster
//
//  Which Sparkle feed an update check reads (issue #11). A beta build always reads the beta
//  feed; a stable build reads it only when the user turned on "Receive beta releases". The
//  beta feed also lists the stable releases (scripts/generate-appcast.py), so a beta user is
//  offered the next stable release and moves to it.
//
//  The choice is stored only when the user flips the switch, under a key of its own, and
//  both the switch and the update check read that stored value. Before, the setting's default
//  was worked out from the running build and written back on every launch, so the first build
//  that ran on a Mac fixed it for every later copy; and the switch showed the value loaded at
//  launch while the check read the stored one, so a change from another copy (both copies
//  share their settings) made them disagree. The old key "useBetaUpdateChannel" is no longer
//  read: its value can't be told apart from one written automatically.
//

#if !APPSTORE
import Foundation

enum UpdateChannel {
    /// The user's choice in a stable build's Settings; absent until the switch is flipped.
    static let receiveBetasKey = "receiveBetaReleases"

    /// True for a beta build ("1.24-beta.4").
    static func isBetaBuild(version: String) -> Bool {
        version.localizedCaseInsensitiveContains("beta")
    }

    /// True when this build's version is a beta.
    static var isBetaBuild: Bool {
        isBetaBuild(version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
    }

    /// True when an update check reads the beta feed: always for a beta build, and for a
    /// stable build when the user turned on "Receive beta releases" (off when never set).
    static func usesBetaFeed(version: String, defaults: UserDefaults) -> Bool {
        isBetaBuild(version: version) || defaults.bool(forKey: receiveBetasKey)
    }

    /// The feed an update check reads.
    static func feedURL(version: String, defaults: UserDefaults) -> String {
        usesBetaFeed(version: version, defaults: defaults) ? AppLinks.betaFeed : AppLinks.stableFeed
    }
}
#endif
