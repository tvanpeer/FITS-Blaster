//
//  FocusedAction.swift
//  FITS Blaster
//

import SwiftUI

// MARK: - FocusedAction

/// Wraps a `() -> Void` for use as an `@Entry` FocusedValue.
/// Equality always returns `true` so SwiftUI doesn't re-invalidate dependents
/// when the closure is re-created on a view update. Reactivity comes from the
/// `@Observable` objects captured inside the closure, not from the value itself.
/// `callAsFunction()` lets existing `action?()` call sites compile unchanged.
struct FocusedAction: Equatable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func callAsFunction() { body() }
    static func == (lhs: Self, rhs: Self) -> Bool { true }
}

// MARK: - Focused Values

extension FocusedValues {
    /// Exposes `AppSettings.isSimpleMode` as a Binding so menu commands can toggle it.
    @Entry var simpleModeBinding: Binding<Bool>? = nil

    /// Exposes `AppSettings.debayerColorImages` as a Binding so the View menu command
    /// can toggle it. ContentView watches this value and re-renders the loaded images
    /// (`recolorImages`) on change.
    @Entry var debayerColorBinding: Binding<Bool>? = nil

    /// The active window's shortcut keys, so the menu items show the configured keys.
    @Entry var keyBindings: KeyBindings? = nil

    /// Zoom and pan of the active window's image viewer, with their keys (View menu).
    @Entry var viewerCommands: ViewerCommandSet? = nil

    /// Action for opening a folder, wired to the active window's ImageStore.
    @Entry var openFolderAction: FocusedAction? = nil

    /// Selection actions wired to the active window's ImageStore.
    @Entry var selectAllAction: FocusedAction? = nil
    @Entry var deselectAllAction: FocusedAction? = nil
    @Entry var invertSelectionAction: FocusedAction? = nil
    @Entry var selectAllRejectedAction: FocusedAction? = nil
    @Entry var toggleFlagAction: FocusedAction? = nil
    @Entry var deflagAllAction: FocusedAction? = nil
}
