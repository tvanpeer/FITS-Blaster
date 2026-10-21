//
//  SystemKeyShortcutTests.swift
//  FITS Blaster Tests
//
//  System shortcuts must reach macOS (fn-F, 🌐 keys) or toggle full screen (⌃⌘F),
//  while FITS Blaster's own keys, including fn + arrows, keep working.
//

import AppKit
import Testing
@testable import FITS_Blaster

struct SystemKeyShortcutTests {

    @Test func controlCommandFTogglesFullScreen() {
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command], key: "f", isSpecialKey: false) == .toggleFullScreen)
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command], key: "F", isSpecialKey: false) == .toggleFullScreen)
        // fn is ignored here, as in AppKit apps.
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command, .function], key: "f", isSpecialKey: false) == .toggleFullScreen)
    }

    @Test func otherFCombinationsAreNotFullScreen() {
        #expect(SystemKeyShortcut.match(modifiers: [.command], key: "f", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.control], key: "f", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command, .shift], key: "f", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command, .option], key: "f", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.control, .command], key: "g", isSpecialKey: false) == nil)
    }

    @Test(arguments: ["f", "e", "q", "x", " "])
    func fnWithCharacterKeyGoesToSystem(key: String) {
        #expect(SystemKeyShortcut.match(modifiers: [.function], key: key, isSpecialKey: false) == .passToSystem)
    }

    @Test func fnWithSpecialKeyStaysWithTheApp() {
        // Arrow, Home and End keys carry the fn flag on their own.
        #expect(SystemKeyShortcut.match(modifiers: [.function, .numericPad], key: "\u{F701}", isSpecialKey: true) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.function, .shift], key: "\u{F700}", isSpecialKey: true) == nil)
    }

    @Test func plainKeysStayWithTheApp() {
        #expect(SystemKeyShortcut.match(modifiers: [], key: "f", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.shift], key: "F", isSpecialKey: false) == nil)
        #expect(SystemKeyShortcut.match(modifiers: [.capsLock], key: "f", isSpecialKey: false) == nil)
    }
}
