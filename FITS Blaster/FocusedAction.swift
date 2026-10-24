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

    /// The raw key string for "Toggle Simple/Geek Mode", so the View menu command can
    /// display the correct user-configured shortcut.
    @Entry var toggleModeKeyString: String? = nil

    /// The raw key string for "Toggle Colour Images", so the View menu command can
    /// display the correct user-configured shortcut.
    @Entry var debayerKeyString: String? = nil

    /// Action for opening a folder, wired to the active window's ImageStore.
    @Entry var openFolderAction: FocusedAction? = nil

    /// Selection actions wired to the active window's ImageStore.
    @Entry var selectAllAction: FocusedAction? = nil
    @Entry var deselectAllAction: FocusedAction? = nil
    @Entry var invertSelectionAction: FocusedAction? = nil
    @Entry var selectAllRejectedAction: FocusedAction? = nil
    @Entry var toggleFlagAction: FocusedAction? = nil
    @Entry var deflagAllAction: FocusedAction? = nil

    /// Key strings for the flag shortcuts, so menu commands show the correct letters.
    @Entry var flagKeyString: String? = nil
    @Entry var deflagAllKeyString: String? = nil

    /// Key strings for the selection shortcuts, so menu commands can show the correct letter.
    @Entry var selectAllKeyString: String? = nil
    @Entry var deselectAllKeyString: String? = nil
    @Entry var invertSelectionKeyString: String? = nil
    @Entry var selectAllRejectedKeyString: String? = nil

    /// Shift flags for the selection shortcuts (true = ⌘⇧, false = ⌘).
    @Entry var selectAllShiftFV: Bool? = nil
    @Entry var deselectAllShiftFV: Bool? = nil
    @Entry var invertSelectionShiftFV: Bool? = nil
    @Entry var selectAllRejectedShiftFV: Bool? = nil
}
