//
//  MenuCommands.swift
//  FITS Blaster
//
//  Menu bar command views used by FitsBlasterApp.
//

#if !APPSTORE
import Sparkle
#endif
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
/// ContentView's onChange(of: settings.debayerColourImages) re-renders the loaded images.
struct DebayerColourCommand: View {
    @FocusedValue(\.debayerColourBinding) var debayerColour
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .debayer, in: keyBindings, default: "c")
        Button(debayerColour?.wrappedValue == true ? "✓ Colour Images" : "Colour Images") {
            debayerColour?.wrappedValue.toggle()
        }
        .disabled(debayerColour == nil)
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
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .selectAll, in: keyBindings, default: "a")
        let mods: EventModifiers = keyBindings?.usesShift(.selectAll) == true ? [.command, .shift] : .command
        Button("Select All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Deselects all frames.
struct DeselectAllCommand: View {
    @FocusedValue(\.deselectAllAction)   var action
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .deselectAll, in: keyBindings, default: "d")
        let mods: EventModifiers = keyBindings?.usesShift(.deselectAll) == true ? [.command, .shift] : .command
        Button("Deselect All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Inverts the selection within visible frames.
struct InvertSelectionCommand: View {
    @FocusedValue(\.invertSelectionAction)   var action
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .invertSelection, in: keyBindings, default: "i")
        let mods: EventModifiers = keyBindings?.usesShift(.invertSelection) == true ? [.command, .shift] : .command
        Button("Inverse Selection") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Selects all rejected frames in the active window (⌘R by default).
struct SelectAllRejectedCommand: View {
    @FocusedValue(\.selectAllRejectedAction)   var action
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .selectAllRejected, in: keyBindings, default: "r")
        let mods: EventModifiers = keyBindings?.usesShift(.selectAllRejected) == true ? [.command, .shift] : .command
        Button("Select All Rejected") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: mods)
    }
}

/// Toggles the flag state of the current selection.
struct ToggleFlagCommand: View {
    @FocusedValue(\.toggleFlagAction) var action
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .flag, in: keyBindings, default: "f")
        Button("(De)flag") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: [])
    }
}

/// Removes all entries from the flagged set.
struct DeflagAllCommand: View {
    @FocusedValue(\.deflagAllAction) var action
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .deflagAll, in: keyBindings, default: "d")
        Button("Deflag All") { action?() }
            .disabled(action == nil)
            .keyboardShortcut(equiv, modifiers: [])
    }
}

#if !APPSTORE
/// Menu item that triggers a manual update check via Sparkle; disabled while a check
/// runs (step 14d, CODE_AUDIT §4.6).
struct CheckForUpdatesView: View {
    let updater: SPUUpdater
    let state: UpdateCheckState

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!state.canCheck)
    }
}
#endif

/// Toggles Simple/Geek mode from the View menu using the focused window's binding.
struct SimpleModeCommand: View {
    @FocusedValue(\.simpleModeBinding) var isSimpleMode
    @FocusedValue(\.keyBindings) var keyBindings

    var body: some View {
        let equiv = KeyEquivalent.menuKey(for: .toggleMode, in: keyBindings, default: "g")
        Button(isSimpleMode?.wrappedValue == true ? "✓ Simple Mode" : "Simple Mode") {
            isSimpleMode?.wrappedValue.toggle()
        }
        .disabled(isSimpleMode == nil)
        .keyboardShortcut(equiv, modifiers: [])
    }
}
