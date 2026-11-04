//
//  KeyEquivalent+Setting.swift
//  FITS Blaster
//
//  A key setting as stored in AppSettings ("x", "↑", " ", …) as a SwiftUI key equivalent,
//  for showing the key next to a menu item.
//

import SwiftUI

extension KeyEquivalent {

    /// The key equivalent for a key setting: the arrows, Home (⇱), End (⇲), Space, or a
    /// single character. Nil for an empty or longer string.
    static func fromSetting(_ key: String) -> KeyEquivalent? {
        switch key {
        case "↑": return .upArrow
        case "↓": return .downArrow
        case "←": return .leftArrow
        case "→": return .rightArrow
        case "⇱": return .home
        case "⇲": return .end
        case " ": return .space
        default:
            guard key.count == 1, let character = key.first else { return nil }
            return KeyEquivalent(character)
        }
    }
}
