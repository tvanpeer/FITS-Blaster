//
//  MainWindow.swift
//  FITS Blaster
//
//  The app's window ids and how Window → Main Window finds the main window (step 15d,
//  CODE_AUDIT §9.11).
//

import AppKit

/// The ids of the app's SwiftUI windows (`WindowGroup(id:)`, `Window(_:id:)`, `openWindow(id:)`).
enum WindowID {
    static let main = "main"
    static let settings = "settings"
}

@MainActor
enum MainWindow {
    /// The main window: the first window that isn't Settings and is on screen or minimised
    /// in the Dock. (Hidden helper windows, such as a 500 × 500 one AppKit keeps, are
    /// neither, so they are never picked.)
    static func find() -> NSWindow? {
        NSApp.windows.first { window in
            window.identifier?.rawValue != WindowID.settings && (window.isVisible || window.isMiniaturized)
        }
    }
}
