//
//  ZoomCommands.swift
//  FITS Blaster
//

import SwiftUI

/// Zoom and pan in the View menu, with the configured keys (pan: ⌥ + arrow keys).
/// The window's key monitor handles the keys themselves; the menu shows them and can be clicked.
struct ZoomCommands: View {
    @FocusedValue(\.viewerCommands) var commands

    var body: some View {
        Button("Zoom In") { commands?.zoomIn() }
            .keyboardShortcut(Self.key(commands?.zoomInKey, default: "="), modifiers: [])
            .disabled(commands == nil)
        Button("Zoom Out") { commands?.zoomOut() }
            .keyboardShortcut(Self.key(commands?.zoomOutKey, default: "-"), modifiers: [])
            .disabled(commands == nil)
        Button("Zoom to Fit") { commands?.zoomToFit() }
            .keyboardShortcut(Self.key(commands?.zoomToFitKey, default: "0"), modifiers: [])
            .disabled(commands == nil)
        Button("Actual Size") { commands?.actualSize() }
            .keyboardShortcut(Self.key(commands?.actualSizeKey, default: "9"), modifiers: [])
            .disabled(commands == nil)
        Menu("Pan") {
            Button("Left")  { commands?.pan(.left) }.keyboardShortcut(.leftArrow, modifiers: .option)
            Button("Right") { commands?.pan(.right) }.keyboardShortcut(.rightArrow, modifiers: .option)
            Button("Up")    { commands?.pan(.up) }.keyboardShortcut(.upArrow, modifiers: .option)
            Button("Down")  { commands?.pan(.down) }.keyboardShortcut(.downArrow, modifiers: .option)
        }
        .disabled(commands == nil)
    }

    /// The menu's key equivalent for a configured key string ("↑" etc. as arrow keys).
    private static func key(_ keyString: String?, default fallback: Character) -> KeyEquivalent {
        switch keyString {
        case "↑": .upArrow
        case "↓": .downArrow
        case "←": .leftArrow
        case "→": .rightArrow
        case "⇱": .home
        case "⇲": .end
        default: KeyEquivalent(keyString?.first ?? fallback)
        }
    }
}
