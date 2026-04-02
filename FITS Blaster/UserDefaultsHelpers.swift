//
//  UserDefaultsHelpers.swift
//  FITS Blaster
//

import Foundation

/// Typed read helpers for UserDefaults, used by AppSettings.init() to eliminate
/// repetitive if-let boilerplate while preserving the correct behaviour for each type.
enum UD {

    /// Returns the stored String, or `default` if the key has never been set.
    static func string(_ key: String, default d: String,
                       _ store: UserDefaults = .standard) -> String {
        store.string(forKey: key) ?? d
    }

    /// Returns the stored Bool, or `default` if the key has never been set.
    ///
    /// Uses `object(forKey:) as? Bool` rather than `bool(forKey:)` so that a
    /// never-set key returns `default` instead of `false`. This matters for
    /// flags whose default is `true` (e.g. `computeFWHM`): without this check,
    /// a fresh install would incorrectly disable the metric.
    static func bool(_ key: String, default d: Bool,
                     _ store: UserDefaults = .standard) -> Bool {
        (store.object(forKey: key) as? Bool) ?? d
    }

    /// Returns the stored positive Int, or `default` if the key has never been set
    /// or the stored value is ≤ 0.
    ///
    /// `integer(forKey:)` returns 0 for missing keys, which is indistinguishable
    /// from an explicitly stored zero — so we treat any non-positive value as absent.
    static func positiveInt(_ key: String, default d: Int,
                            _ store: UserDefaults = .standard) -> Int {
        let v = store.integer(forKey: key)
        return v > 0 ? v : d
    }

    /// Returns the stored String array, or `default` if the key has never been set.
    static func strings(_ key: String, default d: [String],
                        _ store: UserDefaults = .standard) -> [String] {
        store.stringArray(forKey: key) ?? d
    }

    /// Returns the stored Double, or `default` if the key has never been set.
    static func double(_ key: String, default d: Double,
                       _ store: UserDefaults = .standard) -> Double {
        (store.object(forKey: key) as? Double) ?? d
    }
}
