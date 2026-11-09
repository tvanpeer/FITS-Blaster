//
//  AppFont.swift
//  FITS Blaster
//
//  Custom font scaling for macOS, where DynamicTypeSize does not scale
//  semantic font styles (.caption, .body, etc.) at the platform level.
//

import SwiftUI

// MARK: - Environment key

extension EnvironmentValues {
    /// Scale multiplier applied to all app text. 1.0 = default size.
    @Entry var fontSizeMultiplier: CGFloat = 1.0
}

// MARK: - Modifier

private struct ScaledTextFont: ViewModifier {
    @Environment(\.fontSizeMultiplier) var scale
    let baseSize: CGFloat
    let weight: Font.Weight
    let monospaced: Bool

    func body(content: Content) -> some View {
        var font = Font.system(size: (baseSize * scale).rounded(), weight: weight)
        if monospaced { font = font.monospacedDigit() }
        return content.font(font)
    }
}

// MARK: - View extension

extension View {
    /// Applies a font whose point size scales with `fontSizeMultiplier` from the environment.
    func scaledFont(size: CGFloat, weight: Font.Weight = .regular, monospaced: Bool = false) -> some View {
        modifier(ScaledTextFont(baseSize: size, weight: weight, monospaced: monospaced))
    }
}
