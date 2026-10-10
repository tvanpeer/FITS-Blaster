//
//  ContentFocusedValues.swift
//  FITS Blaster
//

import SwiftUI

/// Applies all focused scene values so menu commands and keyboard shortcuts
/// can access the active window's store and settings. Extracted from ContentView.body
/// to keep the modifier chain short enough for the Swift type-checker.
struct ContentFocusedValues: ViewModifier {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    func body(content: Content) -> some View {
        @Bindable var bindableSettings = settings
        content
            // App-level
            .focusedSceneValue(\.simpleModeBinding,     $bindableSettings.isSimpleMode)
            .focusedSceneValue(\.debayerColorBinding,   $bindableSettings.debayerColorImages)
            .focusedSceneValue(\.toggleModeKeyString,   settings.toggleModeKey)
            .focusedSceneValue(\.debayerKeyString,      settings.debayerKey)
            .focusedSceneValue(\.openFolderAction,      FocusedAction { store.showOpenFolderOptions = true })
            // Selection actions
            .focusedSceneValue(\.selectAllAction,             FocusedAction { store.selectAllVisible() })
            .focusedSceneValue(\.deselectAllAction,           FocusedAction { store.deselectAll() })
            .focusedSceneValue(\.invertSelectionAction,       FocusedAction { store.invertSelection() })
            .focusedSceneValue(\.selectAllRejectedAction,     FocusedAction { store.selectAllRejected() })
            .focusedSceneValue(\.toggleFlagAction,            FocusedAction { store.toggleFlagSelected() })
            .focusedSceneValue(\.deflagAllAction,             FocusedAction { store.deflagAll() })
            // Key strings
            .focusedSceneValue(\.flagKeyString,               settings.flagKey)
            .focusedSceneValue(\.deflagAllKeyString,          settings.deflagAllKey)
            .focusedSceneValue(\.selectAllKeyString,          settings.selectAllKey)
            .focusedSceneValue(\.deselectAllKeyString,        settings.deselectAllKey)
            .focusedSceneValue(\.invertSelectionKeyString,    settings.invertSelectionKey)
            .focusedSceneValue(\.selectAllRejectedKeyString,  settings.selectAllRejectedKey)
            // Shift flags
            .focusedSceneValue(\.selectAllShiftFV,            settings.selectAllShift)
            .focusedSceneValue(\.deselectAllShiftFV,          settings.deselectAllShift)
            .focusedSceneValue(\.invertSelectionShiftFV,      settings.invertSelectionShift)
            .focusedSceneValue(\.selectAllRejectedShiftFV,    settings.selectAllRejectedShift)
    }
}
