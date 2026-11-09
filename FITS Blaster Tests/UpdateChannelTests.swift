//
//  UpdateChannelTests.swift
//  FITS Blaster Tests
//
//  Which Sparkle feed an update check reads (issue #11): a beta build always the beta feed,
//  a stable build only after the user turned on "Receive beta releases"; the choice is not
//  written by loading the settings, and the old key is not read.
//

#if !APPSTORE
import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct UpdateChannelTests {

    /// A UserDefaults of its own, so the tests never read or change the app's real settings.
    private func makeDefaults() -> UserDefaults {
        let name = "UpdateChannelTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("Beta and stable versions are told apart", arguments: [
        ("1.24-beta.4", true), ("1.23.1-beta.3", true), ("1.24-Beta.1", true),
        ("1.23.1", false), ("1.24", false), ("", false),
    ])
    func betaBuild(version: String, isBeta: Bool) {
        #expect(UpdateChannel.isBetaBuild(version: version) == isBeta)
    }

    @Test("Without a stored choice, a beta build reads the beta feed and a stable build the stable feed")
    func noChoice() {
        let defaults = makeDefaults()
        #expect(UpdateChannel.feedURL(version: "1.24-beta.4", defaults: defaults) == AppLinks.betaFeed)
        #expect(UpdateChannel.feedURL(version: "1.23.1", defaults: defaults) == AppLinks.stableFeed)
    }

    @Test("A stable build follows the stored choice")
    func stableFollowsChoice() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: UpdateChannel.receiveBetasKey)
        #expect(UpdateChannel.feedURL(version: "1.23.1", defaults: defaults) == AppLinks.betaFeed)
        defaults.set(false, forKey: UpdateChannel.receiveBetasKey)
        #expect(UpdateChannel.feedURL(version: "1.23.1", defaults: defaults) == AppLinks.stableFeed)
    }

    @Test("A beta build reads the beta feed whatever is stored (case B and D of issue #11)")
    func betaIgnoresChoice() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: UpdateChannel.receiveBetasKey)
        #expect(UpdateChannel.feedURL(version: "1.24-beta.4", defaults: defaults) == AppLinks.betaFeed)
    }

    @Test("The old key, written automatically by earlier versions, is not read")
    func oldKeyIgnored() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "useBetaUpdateChannel")
        #expect(UpdateChannel.feedURL(version: "1.23.1", defaults: defaults) == AppLinks.stableFeed)
    }

    @Test("The check reads the stored value at the moment of checking")
    func readsAtCheckTime() {
        let defaults = makeDefaults()
        #expect(!UpdateChannel.usesBetaFeed(version: "1.23.1", defaults: defaults))
        defaults.set(true, forKey: UpdateChannel.receiveBetasKey)   // e.g. switched in another copy
        #expect(UpdateChannel.usesBetaFeed(version: "1.23.1", defaults: defaults))
    }

    @Test("Loading the settings doesn't write the choice (case B of issue #11)")
    func loadingWritesNothing() {
        // AppSettings writes to the standard defaults; only compare, never change them.
        let before = UserDefaults.standard.object(forKey: UpdateChannel.receiveBetasKey) as? Bool
        _ = AppSettings()
        let after = UserDefaults.standard.object(forKey: UpdateChannel.receiveBetasKey) as? Bool
        #expect(before == after)
    }

    @Test("The stable feed comes from Info.plist's SUFeedURL; the beta feed sits next to it")
    func feedAddresses() {
        #expect(AppLinks.stableFeed == "https://astrophoto-app.com/appcast.xml")
        #expect(AppLinks.betaFeed == "https://astrophoto-app.com/appcast-beta.xml")
    }
}
#endif
