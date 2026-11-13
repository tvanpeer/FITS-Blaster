//
//  AutoRejectConfigStore.swift
//  FITS Blaster
//
//  Keeps the Auto-Flag sheet's settings between sessions (issue #15): saved when the sheet
//  closes, loaded when it opens. The command line keeps its own options.
//

import Foundation

enum AutoRejectConfigStore {
    /// The UserDefaults key; the value is the settings as JSON.
    static let key = "autoFlagConfig"

    /// The saved settings, or the defaults when nothing was saved or the data can't be read.
    static func load(from defaults: UserDefaults = .standard) -> AutoRejectConfig {
        guard let data = defaults.data(forKey: key),
              let config = try? JSONDecoder().decode(AutoRejectConfig.self, from: data) else {
            return AutoRejectConfig()
        }
        return config
    }

    static func save(_ config: AutoRejectConfig, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: key)
    }
}
