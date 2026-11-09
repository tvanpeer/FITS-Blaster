//
//  FrameAccessibilityTests.swift
//  FITS Blaster Tests
//
//  Step 10d: what VoiceOver says for a thumbnail and the main image, and the session
//  chart's shape per filter group for "Differentiate without color".
//

import SwiftUI
import Testing
@testable import FITS_Blaster

struct FrameAccessibilityTests {

    private func thumbnail(score: Int? = 72, problem: BadgeProblem? = nil, isTopThird: Bool = false,
                           isFlagged: Bool = false, isRejected: Bool = false, isFlipped: Bool = false,
                           filter: String? = "L", loadState: FrameAccessibility.LoadState = .loaded) -> String {
        FrameAccessibility.Thumbnail(fileName: "M31_0001.fits", filter: filter, score: score, problem: problem,
                                     isTopThird: isTopThird, isFlagged: isFlagged, isRejected: isRejected,
                                     isFlipped: isFlipped, loadState: loadState).label
    }

    // MARK: - Thumbnail

    @Test("A plain frame: file name, filter and score")
    func plain() {
        #expect(thumbnail() == "M31_0001.fits, filter L, score 72")
    }

    @Test("Every state in one label, in a fixed order")
    func everyState() {
        #expect(thumbnail(isTopThird: true, isFlagged: true, isRejected: true, isFlipped: true)
                == "M31_0001.fits, filter L, score 72, top third, flagged, rejected, flipped")
    }

    @Test("A badge problem replaces \"top third\", as on the badge",
          arguments: [(BadgeProblem.trailing, "trailing stars"), (.focusFail, "focus problem"),
                      (.lowStars, "low star count")])
    func problem(problem: BadgeProblem, spoken: String) {
        #expect(thumbnail(problem: problem, isTopThird: true) == "M31_0001.fits, filter L, score 72, \(spoken)")
    }

    @Test("Without a badge (Simple mode, no metrics) the score parts are left out")
    func noBadge() {
        #expect(thumbnail(score: nil, problem: .trailing, isTopThird: true, isFlagged: true)
                == "M31_0001.fits, filter L, flagged")
    }

    @Test("Without a filter header, no filter part")
    func noFilter() {
        #expect(thumbnail(filter: nil) == "M31_0001.fits, score 72")
    }

    @Test("Loading and failed frames say so")
    func loadStates() {
        #expect(thumbnail(score: nil, loadState: .loading) == "M31_0001.fits, filter L, loading")
        #expect(thumbnail(score: nil, loadState: .failed) == "M31_0001.fits, filter L, could not load")
    }

    // MARK: - Main image

    @Test("The main image: Frame, file name, flagged and rejected")
    func mainImage() {
        #expect(FrameAccessibility.mainImageLabel(fileName: "a.fits", isFlagged: false, isRejected: false)
                == "Frame, a.fits")
        #expect(FrameAccessibility.mainImageLabel(fileName: "a.fits", isFlagged: true, isRejected: true)
                == "Frame, a.fits, flagged, rejected")
    }

    // MARK: - Folder header

    @Test("A folder header: name, number of frames, and open or closed")
    func folderHeader() {
        #expect(FrameAccessibility.folderHeaderLabel(name: "B", frameCount: 20) == "Folder B, 20 frames")
        #expect(FrameAccessibility.folderHeaderLabel(name: "B", frameCount: 1) == "Folder B, 1 frame")
        #expect(FrameAccessibility.folderHeaderValue(isCollapsed: false) == "expanded")
        #expect(FrameAccessibility.folderHeaderValue(isCollapsed: true) == "collapsed")
    }

    // MARK: - Filter header

    @Test("A filter header: filter, number of frames, and the medians where shown")
    func filterHeader() {
        let us = Locale(identifier: "en_US")
        #expect(FrameAccessibility.filterHeaderLabel(group: .luminance, frameCount: 12, medianFWHM: 3.24,
                                                     medianScore: 71.6, locale: us)
                == "Filter L, 12 frames, median FWHM 3.2 pixels, median score 72")
        #expect(FrameAccessibility.filterHeaderLabel(group: .ha, frameCount: 1) == "Filter Ha, 1 frame")
        #expect(FrameAccessibility.filterHeaderLabel(group: .unfiltered, frameCount: 5) == "Unfiltered, 5 frames")
    }

    // MARK: - Chart shapes

    @Test("Every filter group has its own chart shape, and every shape is used")
    func shapesUnique() {
        let symbols = FilterGroup.allCases.map(\.chartSymbol)
        #expect(Set(symbols).count == FilterGroup.allCases.count)
        #expect(Set(symbols) == Set(FilterSymbol.allCases))
    }

    @Test("The common filters get the solid shapes (Tom, 2026-11-07)")
    func commonFiltersSolid() {
        let expected: [FilterGroup: FilterSymbol] = [
            .luminance: .circle, .red: .square, .green: .triangle, .blue: .diamond,
            .ha: .pentagon, .oiii: .plus, .sii: .cross, .hbeta: .asterisk,
        ]
        for (group, symbol) in expected { #expect(group.chartSymbol == symbol, "\(group)") }
    }

    // MARK: - Chart colours

    /// WCAG contrast of `colour` against a grey background with sRGB value `background`.
    private func contrast(_ colour: Color, onGrey background: Double) -> Double {
        let c = colour.resolve(in: EnvironmentValues())
        let luminance = 0.2126 * Double(c.linearRed) + 0.7152 * Double(c.linearGreen) + 0.0722 * Double(c.linearBlue)
        let bg = background <= 0.04045 ? background / 12.92 : pow((background + 0.055) / 1.055, 2.4)
        let (lighter, darker) = luminance > bg ? (luminance, bg) : (bg, luminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    @Test("With Differentiate without color every chart colour has at least 6:1 contrast", arguments: FilterGroup.allCases)
    func highContrast(group: FilterGroup) {
        // The window background on macOS 27: #1E1E1E in dark mode, white in light mode.
        let dark = group.chartColour(differentiateWithoutColor: true, colorScheme: .dark)
        let light = group.chartColour(differentiateWithoutColor: true, colorScheme: .light)
        #expect(contrast(dark, onGrey: 0x1E / 255.0) >= 5.99, "\(group) dark")
        #expect(contrast(light, onGrey: 1.0) >= 5.99, "\(group) light")
    }

    @Test("Without the setting the chart keeps the group's own colour")
    func normalColour() {
        for group in FilterGroup.allCases {
            #expect(group.chartColour(differentiateWithoutColor: false, colorScheme: .dark) == group.colour)
            #expect(group.chartColour(differentiateWithoutColor: false, colorScheme: .light) == group.colour)
        }
    }
}
