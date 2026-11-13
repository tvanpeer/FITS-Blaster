//
//  AutoRejectConfigStoreTests.swift
//  FITS Blaster Tests
//
//  The Auto-Flag settings kept between sessions (issue #15): saved and loaded unchanged,
//  defaults when nothing or something unreadable was saved, and a missing or bad value
//  taking its own default while the others are kept.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct AutoRejectConfigStoreTests {

    /// Runs `body` with a UserDefaults of its own, so the tests never read or change the
    /// app's real settings; the suite is removed afterwards.
    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "AutoRejectConfigStoreTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            Issue.record("Could not create a UserDefaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

    /// Every value different from its default.
    private var changed: AutoRejectConfig {
        var config = AutoRejectConfig()
        config.mode = .absolute
        config.useFWHM = false
        config.fwhmMultiplier = 2.25
        config.absoluteFWHM = 4.5
        config.useEccentricity = false
        config.eccentricityThreshold = 0.65
        config.useStarCount = false
        config.starCountMultiplier = 0.35
        config.absoluteStarCountFloor = 150
        config.useSNR = false
        config.snrMultiplier = 0.45
        config.absoluteSNRFloor = 350
        config.useSkyBackground = true
        config.skyBackgroundMultiplier = 1.8
        config.absoluteSkyBackgroundCeiling = 2500
        config.usePSF = true
        config.psfMultiplier = 0.7
        config.absolutePSFFloor = 3
        config.useScore = true
        config.scoreFloor = 55
        return config
    }

    @Test("Saved settings load unchanged")
    func roundTrip() {
        withDefaults { defaults in
            #expect(changed != AutoRejectConfig())
            AutoRejectConfigStore.save(changed, to: defaults)
            #expect(AutoRejectConfigStore.load(from: defaults) == changed)
        }
    }

    @Test("Nothing saved: the defaults")
    func nothingSaved() {
        withDefaults { defaults in
            #expect(AutoRejectConfigStore.load(from: defaults) == AutoRejectConfig())
        }
    }

    @Test("Unreadable data: the defaults", arguments: [
        Data(), Data("not json".utf8), Data("[1, 2]".utf8), Data("{\"mode\": ".utf8),
    ])
    func unreadable(data: Data) {
        withDefaults { defaults in
            defaults.set(data, forKey: AutoRejectConfigStore.key)
            #expect(AutoRejectConfigStore.load(from: defaults) == AutoRejectConfig())
        }
    }

    @Test("A value of the wrong type under the key: the defaults")
    func wrongType() {
        withDefaults { defaults in
            defaults.set("absolute", forKey: AutoRejectConfigStore.key)
            #expect(AutoRejectConfigStore.load(from: defaults) == AutoRejectConfig())
        }
    }

    @Test("A missing value takes its default; the others are kept")
    func missingValue() throws {
        try withDefaults { defaults in
            let data = try JSONEncoder().encode(changed)
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object.removeValue(forKey: "scoreFloor")
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AutoRejectConfigStore.key)

            var expected = changed
            expected.scoreFloor = AutoRejectConfig().scoreFloor
            #expect(AutoRejectConfigStore.load(from: defaults) == expected)
        }
    }

    @Test("An unknown mode or a value of the wrong type takes its default; the others are kept")
    func badValues() throws {
        try withDefaults { defaults in
            let data = try JSONEncoder().encode(changed)
            var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            object["mode"] = "Sideways"
            object["absoluteFWHM"] = "wide"
            object["useSNR"] = 7.5
            defaults.set(try JSONSerialization.data(withJSONObject: object), forKey: AutoRejectConfigStore.key)

            var expected = changed
            expected.mode = .relative
            expected.absoluteFWHM = AutoRejectConfig().absoluteFWHM
            expected.useSNR = AutoRejectConfig().useSNR
            #expect(AutoRejectConfigStore.load(from: defaults) == expected)
        }
    }

    @Test("Saving again replaces the earlier settings")
    func saveReplaces() {
        withDefaults { defaults in
            AutoRejectConfigStore.save(changed, to: defaults)
            AutoRejectConfigStore.save(AutoRejectConfig(), to: defaults)
            #expect(AutoRejectConfigStore.load(from: defaults) == AutoRejectConfig())
        }
    }
}
