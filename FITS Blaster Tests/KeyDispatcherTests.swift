//
//  KeyDispatcherTests.swift
//  FITS Blaster Tests
//
//  The key monitor's rules (step 10b): every bound key, changed keys, the ⇧ variants of the
//  ⌘ shortcuts, extending the selection, panning, other modifiers, text fields, the system
//  shortcuts and the "+" alias; the one key-binding table; and the menu key equivalents.
//  The bindings are given explicitly, so the tests never read or change the app's settings.
//

import AppKit
import SwiftUI
import Testing
@testable import FITS_Blaster

@MainActor
struct KeyDispatcherTests {

    /// The app's default keys (AppSettings), written out.
    static let defaultKeys: [KeyAction: String] = [
        .first: "⇱", .last: "⇲", .previous: "↑", .next: "↓",
        .reject: "x", .undo: "u", .flag: "f", .deflagAll: "d",
        .playPause: "p", .flip: "v", .toggleMode: "g", .remove: "r", .debayer: "c",
        .zoomIn: "=", .zoomOut: "-", .zoomToFit: "0", .zoomActualSize: "9",
        .selectAll: "a", .deselectAll: "d", .invertSelection: "i", .selectAllRejected: "r",
    ]

    private func bindings(_ changes: [KeyAction: String] = [:], shifts: [KeyAction: Bool] = [:]) -> KeyBindings {
        KeyBindings(keys: Self.defaultKeys.merging(changes) { $1 }, shifts: shifts)
    }

    /// A key press for a key string: the arrows, Home and End as special keys, otherwise characters.
    private func press(_ key: String, _ modifiers: NSEvent.ModifierFlags = [], textField: Bool = false) -> KeyInput {
        let special: NSEvent.SpecialKey? = switch key {
        case "↑": .upArrow
        case "↓": .downArrow
        case "←": .leftArrow
        case "→": .rightArrow
        case "⇱": .home
        case "⇲": .end
        default:  nil
        }
        return KeyInput(modifiers: modifiers, characters: special == nil ? key : nil,
                        specialKey: special, isTextInputFocused: textField)
    }

    private func dispatch(_ press: KeyInput, _ bindings: KeyBindings) -> KeyDispatch {
        KeyDispatcher.dispatch(press, bindings: bindings)
    }

    // MARK: - Every bound key

    @Test("Every bound key does its action: plain keys alone, the others with ⌘", arguments: KeyAction.allCases)
    func everyKey(action: KeyAction) throws {
        let key = try #require(Self.defaultKeys[action])
        let kind = KeyBinding.binding(for: action).kind
        let modifiers: NSEvent.ModifierFlags = kind == .command ? .command : []
        #expect(dispatch(press(key, modifiers), bindings()) == .action(action, kind))
    }

    @Test("A changed key does the action; the old key no longer does")
    func changedKey() {
        let b = bindings([.reject: "k", .selectAll: "e"])
        #expect(dispatch(press("k"), b) == .action(.reject, .plain))
        #expect(dispatch(press("x"), b) == .notHandled)
        #expect(dispatch(press("e", .command), b) == .action(.selectAll, .command))
        #expect(dispatch(press("a", .command), b) == .notHandled)
    }

    @Test("A key bound to an arrow works as a plain key")
    func arrowBinding() {
        let b = bindings([.flag: "←"])
        #expect(dispatch(press("←"), b) == .action(.flag, .plain))
    }

    @Test("D alone deflags all, ⌘D deselects all")
    func sameLetterTwoKinds() {
        #expect(dispatch(press("d"), bindings()) == .action(.deflagAll, .plain))
        #expect(dispatch(press("d", .command), bindings()) == .action(.deselectAll, .command))
    }

    @Test("Capitals match: ⌘ shortcuts compare the key in lower case")
    func commandLowercased() {
        let p = KeyInput(modifiers: .command, characters: "A", charactersIgnoringModifiers: "A")
        #expect(dispatch(p, bindings()) == .action(.selectAll, .command))
    }

    // MARK: - ⇧ variants of the ⌘ shortcuts

    @Test("A ⌘⇧ shortcut needs ⇧, a ⌘ shortcut must not have it")
    func shiftVariants() {
        let b = bindings(shifts: [.selectAll: true])
        #expect(dispatch(press("a", [.command, .shift]), b) == .action(.selectAll, .command))
        #expect(dispatch(press("a", .command), b) == .notHandled)
        #expect(dispatch(press("i", [.command, .shift]), b) == .notHandled)
        #expect(dispatch(press("i", .command), b) == .action(.invertSelection, .command))
    }

    @Test("⌘ with ⌥ or ⌃ is not a selection shortcut")
    func commandWithOtherModifiers() {
        #expect(dispatch(press("a", [.command, .option]), bindings()) == .notHandled)
        #expect(dispatch(press("a", [.command, .control]), bindings()) == .notHandled)
    }

    // MARK: - ⇧ + previous / next, ⇧ + other keys

    @Test("⇧ + the previous / next key extends the selection")
    func extendSelection() {
        #expect(dispatch(press("↑", .shift), bindings()) == .extendSelectionPrevious)
        #expect(dispatch(press("↓", .shift), bindings()) == .extendSelectionNext)
        let b = bindings([.previous: "k", .next: "j"])
        #expect(dispatch(press("k", .shift), b) == .extendSelectionPrevious)
        #expect(dispatch(press("j", .shift), b) == .extendSelectionNext)
    }

    @Test("⇧ + another plain key does its plain action (⇧X rejects)")
    func shiftPlainKey() {
        let p = KeyInput(modifiers: .shift, characters: "X", charactersIgnoringModifiers: "X")
        #expect(dispatch(p, bindings()) == .action(.reject, .plain))
    }

    // MARK: - Pan and other modifiers

    @Test("⌥ + an arrow pans", arguments: [("←", PanDirection.left), ("→", .right), ("↑", .up), ("↓", .down)])
    func pan(key: String, direction: PanDirection) {
        #expect(dispatch(press(key, .option), bindings()) == .pan(direction))
    }

    @Test("⌥⇧ + an arrow, ⌥ + a letter, ⌃ + a letter: not ours")
    func otherModifiers() {
        #expect(dispatch(press("→", [.option, .shift]), bindings()) == .notHandled)
        #expect(dispatch(press("x", .option), bindings()) == .notHandled)
        #expect(dispatch(press("x", .control), bindings()) == .notHandled)
    }

    @Test("An unbound key and an unsupported special key are not ours")
    func unbound() {
        #expect(dispatch(press("q"), bindings()) == .notHandled)
        #expect(dispatch(KeyInput(specialKey: .f1), bindings()) == .notHandled)
    }

    // MARK: - Text fields and system shortcuts

    @Test("With a text field focused, keys go to the field")
    func textField() {
        #expect(dispatch(press("x", textField: true), bindings()) == .notHandled)
        #expect(dispatch(press("a", .command, textField: true), bindings()) == .notHandled)
        #expect(dispatch(press("↑", textField: true), bindings()) == .notHandled)
    }

    @Test("⌃⌘F toggles full screen, also in a text field; fn + a key goes to the system")
    func systemShortcuts() {
        #expect(dispatch(press("f", [.command, .control]), bindings()) == .toggleFullScreen)
        #expect(dispatch(press("f", [.command, .control], textField: true), bindings()) == .toggleFullScreen)
        #expect(dispatch(press("f", .function), bindings()) == .passToSystem)
        // Arrow keys carry the fn flag but stay ours.
        #expect(dispatch(press("↑", .function), bindings()) == .action(.previous, .plain))
    }

    // MARK: - "+" alias

    @Test("\"+\" zooms in while Zoom In is \"=\"; not when Zoom In has another key")
    func plusAlias() {
        let plus = KeyInput(modifiers: .shift, characters: "+", charactersIgnoringModifiers: "=")
        #expect(dispatch(plus, bindings()) == .action(.zoomIn, .plain))
        #expect(dispatch(plus, bindings([.zoomIn: "z"])) == .notHandled)
    }

    // MARK: - The table

    @Test("The table has exactly one row per action, no shared settings and unique labels")
    func tableComplete() {
        let rows = KeyBinding.all
        #expect(Set(rows.map(\.action)) == Set(KeyAction.allCases))
        #expect(rows.count == KeyAction.allCases.count)
        #expect(Set(rows.map(\.key)).count == rows.count)
        #expect(Set(rows.map(\.label)).count == rows.count)
        #expect(rows.allSatisfy { ($0.kind == .command) == ($0.shift != nil) })
    }

    @Test("KeyBindings reads every key and ⇧ setting from AppSettings")
    func bindingsFromSettings() {
        let settings = AppSettings()
        let b = KeyBindings(settings: settings)
        for row in KeyBinding.all {
            #expect(b.key(row.action) == settings[keyPath: row.key])
            if let shift = row.shift { #expect(b.usesShift(row.action) == settings[keyPath: shift]) }
        }
    }

    // MARK: - Key strings and menu key equivalents

    @Test("The special keys map to their key strings and back to key equivalents")
    func specialKeys() {
        struct Case { let special: NSEvent.SpecialKey, key: String, equivalent: KeyEquivalent }
        let cases = [
            Case(special: .upArrow, key: "↑", equivalent: .upArrow), Case(special: .downArrow, key: "↓", equivalent: .downArrow),
            Case(special: .leftArrow, key: "←", equivalent: .leftArrow), Case(special: .rightArrow, key: "→", equivalent: .rightArrow),
            Case(special: .home, key: "⇱", equivalent: .home), Case(special: .end, key: "⇲", equivalent: .end),
        ]
        for c in cases {
            #expect(KeyBinding.settingString(for: c.special) == c.key)
            #expect(KeyBinding.keyString(specialKey: c.special, characters: nil) == c.key)
            #expect(KeyEquivalent.fromSetting(c.key) == c.equivalent)
        }
    }

    @Test("Other special keys have no key string; characters are lower-cased")
    func keyStrings() {
        #expect(KeyBinding.settingString(for: .f1) == nil)
        #expect(KeyBinding.keyString(specialKey: .delete, characters: "\u{7F}") == nil)
        #expect(KeyBinding.keyString(specialKey: nil, characters: "X") == "x")
        #expect(KeyBinding.keyString(specialKey: nil, characters: " ") == " ")
    }

    @Test("A menu item shows the configured key: an arrow as an arrow, a fallback without a window")
    func menuKeys() {
        #expect(KeyEquivalent.menuKey(for: .flag, in: bindings(), default: "f") == KeyEquivalent("f"))
        #expect(KeyEquivalent.menuKey(for: .flag, in: bindings([.flag: "↑"]), default: "f") == .upArrow)
        #expect(KeyEquivalent.menuKey(for: .flag, in: bindings([.flag: " "]), default: "f") == .space)
        #expect(KeyEquivalent.menuKey(for: .flag, in: nil, default: "f") == KeyEquivalent("f"))
        #expect(KeyEquivalent.menuKey(for: .flag, in: bindings([.flag: ""]), default: "f") == KeyEquivalent("f"))
    }
}
