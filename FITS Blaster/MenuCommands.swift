//
//  MenuCommands.swift
//  FITS Blaster
//
//  Menu bar command views used by FitsBlasterApp.
//

import Sparkle
import SwiftUI

/// Opens the main window (⌘N). If a main window is already open or miniaturised
/// it is brought to the front rather than opening a second instance.
struct MainWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Main Window") {
            if let win = NSApp.windows.first(where: {
                $0.identifier?.rawValue != "settings" && ($0.isVisible || $0.isMiniaturized)
            }) {
                win.deminiaturize(nil)
                win.makeKeyAndOrderFront(nil)
            } else {
                openWindow(id: "main")
            }
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

/// Adds an explicit Close Window (⌘W) item. macOS provides this automatically,
/// but making it visible in the menu satisfies App Review guidelines.
struct CloseWindowCommand: View {
    var body: some View {
        Button("Close Window") {
            NSApp.keyWindow?.close()
        }
        .keyboardShortcut("w", modifiers: .command)
    }
}

/// Adds a "Settings… ⌘," menu item to the File menu.
struct SettingsMenuCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Settings…") {
            openWindow(id: "settings")
        }
        .keyboardShortcut(",", modifiers: .command)
    }
}

/// Toggles colour debayering from the View menu.
/// ContentView's onChange(of: settings.debayerColorImages) triggers the reprocess.
struct DebayerColourCommand: View {
    @FocusedValue(\.debayerColorBinding) var debayerColor
    @FocusedValue(\.debayerKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("c")
        Button(debayerColor?.wrappedValue == true ? "✓ Colour Images" : "Colour Images") {
            debayerColor?.wrappedValue.toggle()
        }
        .disabled(debayerColor == nil)
        .keyboardShortcut(equiv, modifiers: [])
    }
}

/// Opens the folder panel via the File menu (⌘O).
struct OpenFolderCommand: View {
    @FocusedValue(\.openFolderAction) var action

    var body: some View {
        Button("Open Folder…") { action?() }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(action == nil)
    }
}

/// Selects all visible frames in the active window.
struct SelectAllCommand: View {
    @FocusedValue(\.selectAllAction)   var action
    @FocusedValue(\.selectAllKeyString) var keyString
    @FocusedValue(\.selectAllShiftFV)   var usesShift

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("a")
        let mods: EventModifiers = usesShift == true ? [.command, .shift] : .command
        Button("Select All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Deselects all frames.
struct DeselectAllCommand: View {
    @FocusedValue(\.deselectAllAction)   var action
    @FocusedValue(\.deselectAllKeyString) var keyString
    @FocusedValue(\.deselectAllShiftFV)   var usesShift

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("d")
        let mods: EventModifiers = usesShift == true ? [.command, .shift] : .command
        Button("Deselect All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Inverts the selection within visible frames.
struct InvertSelectionCommand: View {
    @FocusedValue(\.invertSelectionAction)   var action
    @FocusedValue(\.invertSelectionKeyString) var keyString
    @FocusedValue(\.invertSelectionShiftFV)   var usesShift

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("i")
        let mods: EventModifiers = usesShift == true ? [.command, .shift] : .command
        Button("Inverse Selection") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Selects all rejected frames in the active window (⌘R by default).
struct SelectAllRejectedCommand: View {
    @FocusedValue(\.selectAllRejectedAction)   var action
    @FocusedValue(\.selectAllRejectedKeyString) var keyString
    @FocusedValue(\.selectAllRejectedShiftFV)   var usesShift

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("r")
        let mods: EventModifiers = usesShift == true ? [.command, .shift] : .command
        Button("Select All Rejected") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Toggles the flag state of the current selection.
struct ToggleFlagCommand: View {
    @FocusedValue(\.toggleFlagAction) var action
    @FocusedValue(\.flagKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("f")
        Button("(De)flag") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: [])
    }
}

/// Removes all entries from the flagged set.
struct DeflagAllCommand: View {
    @FocusedValue(\.deflagAllAction) var action
    @FocusedValue(\.deflagAllKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("d")
        Button("Deflag All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: [])
    }
}

/// Menu item that triggers a manual update check via Sparkle.
struct CheckForUpdatesView: View {
    let updater: SPUUpdater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
    }
}

/// Toggles Simple/Geek mode from the View menu using the focused window's binding.
struct SimpleModeCommand: View {
    @FocusedValue(\.simpleModeBinding) var isSimpleMode
    @FocusedValue(\.toggleModeKeyString) var keyString

    var body: some View {
        let equiv: KeyEquivalent = keyString.flatMap(\.first).map { KeyEquivalent($0) } ?? KeyEquivalent("g")
        Button(isSimpleMode?.wrappedValue == true ? "✓ Simple Mode" : "Simple Mode") {
            isSimpleMode?.wrappedValue.toggle()
        }
        .disabled(isSimpleMode == nil)
        .keyboardShortcut(equiv, modifiers: [])
    }
}
