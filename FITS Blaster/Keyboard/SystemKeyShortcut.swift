//
//  SystemKeyShortcut.swift
//  FITS Blaster
//
//  Key presses that belong to macOS rather than to FITS Blaster's own key bindings.
//  The window-level key monitor in ContentView checks these first, so a configured
//  plain key (for example F for flag) doesn't swallow a system shortcut.
//

import AppKit

enum SystemKeyShortcut: Equatable {
    /// ⌃⌘F. AppKit apps toggle full screen with it, but SwiftUI windows don't
    /// (macOS 27, measured 2026-10-20); the menu item only lists fn-F.
    case toggleFullScreen
    /// fn/🌐 + a character key, e.g. fn-F (Enter Full Screen) or 🌐E (Emoji & Symbols).
    /// Arrow, Home and End keys also carry the fn flag; they are special keys and stay ours.
    case passToSystem

    /// - Parameters:
    ///   - modifiers: the event's modifier flags.
    ///   - key: the event's `charactersIgnoringModifiers`.
    ///   - isSpecialKey: true when the event has a `specialKey` (arrows, Home, End, F1…).
    static func match(modifiers: NSEvent.ModifierFlags, key: String?,
                      isSpecialKey: Bool) -> SystemKeyShortcut? {
        let mods = modifiers.intersection(.deviceIndependentFlagsMask)
        if mods.intersection([.command, .control, .option, .shift]) == [.command, .control],
           key?.lowercased() == "f" {
            return .toggleFullScreen
        }
        if mods.contains(.function), !isSpecialKey {
            return .passToSystem
        }
        return nil
    }

    static func match(_ event: NSEvent) -> SystemKeyShortcut? {
        match(modifiers: event.modifierFlags, key: event.charactersIgnoringModifiers,
              isSpecialKey: event.specialKey != nil)
    }
}
