//
//  KeyDispatcher.swift
//  FITS Blaster
//
//  What a key press in the main window does (step 10b, CODE_AUDIT §8.9): a pure function of
//  the key press and the bindings, so every rule can be tested without a window. ContentView's
//  key monitor checks that the key belongs to its window, asks the dispatcher and carries out
//  the result.
//

import AppKit

/// The parts of a key-down event the dispatcher looks at.
struct KeyInput {
    var modifiers: NSEvent.ModifierFlags
    /// `NSEvent.characters`: with ⇧ applied ("+" for ⇧=).
    var characters: String?
    /// `NSEvent.charactersIgnoringModifiers`.
    var charactersIgnoringModifiers: String?
    var specialKey: NSEvent.SpecialKey?
    /// True when a text field or text view has keyboard focus.
    var isTextInputFocused = false

    /// For tests: `charactersIgnoringModifiers` defaults to `characters`.
    init(modifiers: NSEvent.ModifierFlags = [], characters: String? = nil,
         charactersIgnoringModifiers: String? = nil, specialKey: NSEvent.SpecialKey? = nil,
         isTextInputFocused: Bool = false) {
        self.modifiers = modifiers
        self.characters = characters
        self.charactersIgnoringModifiers = charactersIgnoringModifiers ?? characters
        self.specialKey = specialKey
        self.isTextInputFocused = isTextInputFocused
    }

    /// The event's own values, unchanged.
    init(_ event: NSEvent, isTextInputFocused: Bool) {
        modifiers = event.modifierFlags
        characters = event.characters
        charactersIgnoringModifiers = event.charactersIgnoringModifiers
        specialKey = event.specialKey
        self.isTextInputFocused = isTextInputFocused
    }
}

/// The result of a key press.
enum KeyDispatch: Equatable {
    /// Not ours: the event goes on to the system and the focused control.
    case notHandled
    /// A system shortcut that must reach macOS (fn/🌐 + key).
    case passToSystem
    /// ⌃⌘F: toggle full screen through the responder chain.
    case toggleFullScreen
    /// A configured action. A ⌘ shortcut always consumes the key; a plain key only when the
    /// action ran (Undo in toggle-reject mode doesn't, so the key goes on).
    case action(KeyAction, KeyBinding.Kind)
    /// ⇧ + the previous / next key: extend the selection.
    case extendSelectionPrevious, extendSelectionNext
    /// ⌥ + an arrow key: pan the image.
    case pan(PanDirection)
}

enum KeyDispatcher {

    /// What `press` does with `bindings`. The order of the checks is the key monitor's
    /// order before step 10b.
    static func dispatch(_ press: KeyInput, bindings: KeyBindings) -> KeyDispatch {
        // 1. System shortcuts first, so a configured plain key doesn't swallow them.
        switch SystemKeyShortcut.match(modifiers: press.modifiers, key: press.charactersIgnoringModifiers,
                                       isSpecialKey: press.specialKey != nil) {
        case .toggleFullScreen: return .toggleFullScreen
        case .passToSystem:     return .passToSystem
        case nil:               break
        }
        // 2. Don't steal from text inputs.
        if press.isTextInputFocused { return .notHandled }
        // 3. ⌘(⇧) + configured key: the selection shortcuts.
        if let action = commandShortcut(press, bindings: bindings) { return .action(action, .command) }
        // 4.–7. ⇧ + previous / next, ⌥ + arrow, plain keys.
        return keyWithoutCommand(press, bindings: bindings)
    }

    /// Step 3: the ⌘ shortcut whose key and ⇧ setting match; ⌥ and ⌃ must be up. Uses
    /// charactersIgnoringModifiers, because ⌘A can give "\u{01}" in `characters` on some systems.
    private static func commandShortcut(_ press: KeyInput, bindings: KeyBindings) -> KeyAction? {
        let mods = press.modifiers
        guard mods.contains(.command), !mods.contains(.option), !mods.contains(.control),
              let key = press.charactersIgnoringModifiers?.lowercased() else { return nil }
        let shift = mods.contains(.shift)
        return firstAction(.command, bindings: bindings) { action in
            bindings.key(action) == key && bindings.usesShift(action) == shift
        }
    }

    /// Steps 4–7, for a key press that is not a ⌘ shortcut.
    private static func keyWithoutCommand(_ press: KeyInput, bindings: KeyBindings) -> KeyDispatch {
        let mods = press.modifiers
        let key = KeyBinding.keyString(specialKey: press.specialKey, characters: press.characters)

        // 4. ⇧ + the previous / next key: extend the selection.
        if mods.contains(.shift), mods.isDisjoint(with: [.command, .option, .control]), let key {
            if key == bindings.key(.previous) { return .extendSelectionPrevious }
            if key == bindings.key(.next) { return .extendSelectionNext }
        }
        // 5. ⌥ + an arrow key: pan (the plain arrows move between frames).
        if mods.intersection([.command, .option, .control, .shift]) == .option,
           let direction = panDirection(of: press.specialKey) {
            return .pan(direction)
        }
        // 6. Other ⌘, ⌥ and ⌃ combinations are not ours. ⇧ is allowed: ⇧X rejects like X.
        guard mods.isDisjoint(with: [.command, .option, .control]), let key else { return .notHandled }
        // 7. Plain keys. "+" is ⇧= on a US keyboard: with Zoom In on "=" it zooms in too,
        // unless it has a key of its own.
        if let action = firstAction(.plain, bindings: bindings, where: { bindings.key($0) == key }) {
            return .action(action, .plain)
        }
        if key == "+", bindings.key(.zoomIn) == "=" { return .action(.zoomIn, .plain) }
        return .notHandled
    }

    /// The pan direction of an arrow key; nil for every other key.
    static func panDirection(of specialKey: NSEvent.SpecialKey?) -> PanDirection? {
        switch specialKey {
        case .leftArrow:  .left
        case .rightArrow: .right
        case .upArrow:    .up
        case .downArrow:  .down
        default:          nil
        }
    }

    /// The first action of `kind`, in table order, that satisfies `matches`.
    private static func firstAction(_ kind: KeyBinding.Kind, bindings: KeyBindings,
                                    where matches: (KeyAction) -> Bool) -> KeyAction? {
        bindings.actions(kind).first(where: matches)
    }
}
