//
//  KeyBinding.swift
//  FITS Blaster
//
//  The one table of configurable shortcuts (step 10b, CODE_AUDIT §9.11): which setting holds
//  each action's key, whether it is a plain key or a ⌘ shortcut, and its label in Settings.
//  The key monitor (KeyDispatcher), the Settings conflict lists and the menu items all use
//  it; before, each kept its own copy of the list.
//

import AppKit

struct KeyBinding {
    enum Kind: Sendable { case plain, command }

    let action: KeyAction
    let kind: Kind
    /// The name in Settings, also used in tests.
    let label: String
    /// The setting holding the key string ("x", "↑", " ", …).
    let key: ReferenceWritableKeyPath<AppSettings, String>
    /// ⌘ shortcuts: the setting that adds ⇧ (⌘⇧ + key instead of ⌘ + key).
    let shift: ReferenceWritableKeyPath<AppSettings, Bool>?

    /// Every binding. Within a kind, the first row whose key matches wins (the recorder
    /// prevents duplicates). The order is the key monitor's order before step 10b.
    @MainActor static let all: [KeyBinding] = [
        .init(action: .selectAll,         kind: .command, label: "Select All",
              key: \.selectAllKey,         shift: \.selectAllShift),
        .init(action: .deselectAll,       kind: .command, label: "Deselect All",
              key: \.deselectAllKey,       shift: \.deselectAllShift),
        .init(action: .invertSelection,   kind: .command, label: "Inverse Selection",
              key: \.invertSelectionKey,   shift: \.invertSelectionShift),
        .init(action: .selectAllRejected, kind: .command, label: "Select All Rejected",
              key: \.selectAllRejectedKey, shift: \.selectAllRejectedShift),
        .init(action: .first,          kind: .plain, label: "First Image",             key: \.firstImageKey,     shift: nil),
        .init(action: .last,           kind: .plain, label: "Last Image",              key: \.lastImageKey,      shift: nil),
        .init(action: .previous,       kind: .plain, label: "Previous Image",          key: \.prevImageKey,      shift: nil),
        .init(action: .next,           kind: .plain, label: "Next Image",              key: \.nextImageKey,      shift: nil),
        .init(action: .reject,         kind: .plain, label: "Reject",                  key: \.rejectKey,         shift: nil),
        .init(action: .undo,           kind: .plain, label: "Undo",                    key: \.undoKey,           shift: nil),
        .init(action: .flag,           kind: .plain, label: "Flag / Deflag",           key: \.flagKey,           shift: nil),
        .init(action: .deflagAll,      kind: .plain, label: "Deflag All",              key: \.deflagAllKey,      shift: nil),
        .init(action: .playPause,      kind: .plain, label: "Play / Pause",            key: \.playPauseKey,      shift: nil),
        .init(action: .flip,           kind: .plain, label: "Flip 180\u{00B0}",        key: \.flipKey,           shift: nil),
        .init(action: .toggleMode,     kind: .plain, label: "Toggle Simple/Geek Mode", key: \.toggleModeKey,     shift: nil),
        .init(action: .remove,         kind: .plain, label: "Remove from List",        key: \.removeKey,         shift: nil),
        .init(action: .debayer,        kind: .plain, label: "Toggle Colour Images",    key: \.debayerKey,        shift: nil),
        .init(action: .zoomIn,         kind: .plain, label: "Zoom In",                 key: \.zoomInKey,         shift: nil),
        .init(action: .zoomOut,        kind: .plain, label: "Zoom Out",                key: \.zoomOutKey,        shift: nil),
        .init(action: .zoomToFit,      kind: .plain, label: "Zoom to Fit",             key: \.zoomToFitKey,      shift: nil),
        .init(action: .zoomActualSize, kind: .plain, label: "Actual Size",             key: \.zoomActualSizeKey, shift: nil),
    ]

    /// The row for `action`.
    @MainActor static func binding(for action: KeyAction) -> KeyBinding {
        guard let binding = all.first(where: { $0.action == action }) else {
            preconditionFailure("KeyBinding.all has no row for \(action)")
        }
        return binding
    }

    // MARK: - Key strings

    /// The key string of a special key as stored in the settings: the arrows, Home (⇱) and
    /// End (⇲). Nil for every other special key (F-keys, Delete, Return, …).
    static func settingString(for special: NSEvent.SpecialKey) -> String? {
        switch special {
        case .upArrow:    "↑"
        case .downArrow:  "↓"
        case .leftArrow:  "←"
        case .rightArrow: "→"
        case .home:       "⇱"
        case .end:        "⇲"
        default:          nil
        }
    }

    /// The key string of a key press for the plain keys: a special key's setting string
    /// (nil for an unsupported special key), otherwise the typed characters in lower case.
    static func keyString(specialKey: NSEvent.SpecialKey?, characters: String?) -> String? {
        if let specialKey { return settingString(for: specialKey) }
        return characters?.lowercased()
    }
}
