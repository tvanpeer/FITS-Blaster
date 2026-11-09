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
    @Environment(ViewerState.self) private var viewer

    func body(content: Content) -> some View {
        @Bindable var bindableSettings = settings
        content
            // App-level
            .focusedSceneValue(\.simpleModeBinding,     $bindableSettings.isSimpleMode)
            .focusedSceneValue(\.debayerColourBinding,   $bindableSettings.debayerColourImages)
            .focusedSceneValue(\.openFolderAction,      FocusedAction { store.openFolderRequested = true })
            .focusedSceneValue(\.viewerCommands, ViewerCommandSet(
                zoomIn:     { settings.zoomScale = ViewerZoom.zoomedIn(from: settings.zoomScale) },
                zoomOut:    { settings.zoomScale = ViewerZoom.zoomedOut(from: settings.zoomScale) },
                zoomToFit:  { viewer.fitToContainerTrigger.toggle() },
                actualSize: { settings.zoomScale = 1.0 },
                pan:        { viewer.pan($0) },
                zoomInKey: settings.zoomInKey, zoomOutKey: settings.zoomOutKey,
                zoomToFitKey: settings.zoomToFitKey, actualSizeKey: settings.zoomActualSizeKey))
            // Selection actions
            .focusedSceneValue(\.selectAllAction,             FocusedAction { store.selectAllVisible() })
            .focusedSceneValue(\.deselectAllAction,           FocusedAction { store.deselectAll() })
            .focusedSceneValue(\.invertSelectionAction,       FocusedAction { store.invertSelection() })
            .focusedSceneValue(\.selectAllRejectedAction,     FocusedAction { store.selectAllRejected() })
            .focusedSceneValue(\.toggleFlagAction,            FocusedAction { store.toggleFlagSelected() })
            .focusedSceneValue(\.deflagAllAction,             FocusedAction { store.deflagAll() })
            // The configured keys, for the menu items' shortcuts
            .focusedSceneValue(\.keyBindings, KeyBindings(settings: settings))
    }
}
