//
//  TextSizeStep.swift
//  FITS Blaster
//
//  The text sizes Settings offers: one table for the font scaling and the picker
//  (step 15d, CODE_AUDIT §9.11; before, three lists that had to agree).
//

import SwiftUI

struct TextSizeStep {
    let size: DynamicTypeSize
    /// How much `scaledFont(size:)` enlarges text: macOS doesn't scale SwiftUI's semantic
    /// fonts with `dynamicTypeSize`, so the app does it.
    let fontMultiplier: CGFloat
    /// The size of this step's "A" in the Settings picker; only for the picker's look.
    let pickerFontSize: CGFloat

    /// From smallest to largest. The stored setting is the index in this list.
    static let all: [TextSizeStep] = [
        TextSizeStep(size: .xSmall,   fontMultiplier: 0.75,  pickerFontSize: 10),
        TextSizeStep(size: .small,    fontMultiplier: 0.875, pickerFontSize: 12),
        TextSizeStep(size: .medium,   fontMultiplier: 1.0,   pickerFontSize: 14),
        TextSizeStep(size: .large,    fontMultiplier: 1.15,  pickerFontSize: 17),
        TextSizeStep(size: .xLarge,   fontMultiplier: 1.30,  pickerFontSize: 20),
        TextSizeStep(size: .xxLarge,  fontMultiplier: 1.50,  pickerFontSize: 23),
        TextSizeStep(size: .xxxLarge, fontMultiplier: 1.75,  pickerFontSize: 27),
    ]
}
