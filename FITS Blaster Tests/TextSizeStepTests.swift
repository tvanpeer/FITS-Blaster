//
//  TextSizeStepTests.swift
//  FITS Blaster Tests
//
//  Step 15d (CODE_AUDIT §9.11): one text-size table for the font scaling and the
//  Settings picker; the stored index and the multipliers stay as before.
//

import SwiftUI
import Testing
@testable import FITS_Blaster

@MainActor
struct TextSizeStepTests {

    @Test("The seven sizes in order, with the multipliers the app had before step 15d")
    func table() {
        #expect(AppSettings.availableTypeSizes == [.xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge])
        #expect(TextSizeStep.all.map(\.fontMultiplier) == [0.75, 0.875, 1.0, 1.15, 1.30, 1.50, 1.75])
        #expect(TextSizeStep.all.map(\.pickerFontSize) == [10, 12, 14, 17, 20, 23, 27])
    }
}
