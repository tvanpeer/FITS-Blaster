//
//  AutoRejectThresholdTests.swift
//  FITS Blaster Tests
//
//  The Auto-Flag sheet's table of checks (step 10c): every check once, the modes each check
//  is offered in, every default inside its slider range and on a step, and the value texts
//  as the sheet showed them before the table.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct AutoRejectThresholdTests {

    private let enUS = Locale(identifier: "en_US")

    @Test("Every check of AutoRejectConfig has exactly one row, in the sheet's order")
    func everyCheckOnce() {
        let rows = AutoRejectThreshold.all
        #expect(rows.map(\.title) == [
            "Focus (FWHM)", "Trailing / Elongation", "Cloud / Haze (Star Count)", "Signal-to-Noise (SNR)",
            "Light Pollution (Sky BG)", "PSF Signal Weight", "Quality Score",
        ])
        #expect(Set(rows.map(\.isOn)).count == rows.count)

        // With every row's toggle off no check is on; each row's toggle alone turns one on.
        var allOff = AutoRejectConfig()
        allOff.mode = .absolute
        for row in rows { allOff[keyPath: row.isOn] = false }
        #expect(!allOff.isAnyCheckOn)
        for row in rows {
            var config = allOff
            config[keyPath: row.isOn] = true
            #expect(config.isAnyCheckOn, "\(row.title)")
        }
    }

    @Test("Score is offered in absolute mode only; eccentricity uses one setting in both modes")
    func modes() throws {
        let rows = AutoRejectThreshold.all
        let score = try #require(rows.first { $0.isOn == \.useScore })
        #expect(score.limit(for: .relative) == nil)
        #expect(score.limit(for: .absolute) != nil)
        let ecc = try #require(rows.first { $0.isOn == \.useEccentricity })
        #expect(ecc.relative?.value == ecc.absolute.value)
        #expect(rows.filter { $0.limit(for: .relative) != nil }.count == rows.count - 1)
    }

    @Test("Every default lies inside its slider range and on a step")
    func defaultsInRange() {
        let config = AutoRejectConfig()
        for row in AutoRejectThreshold.all {
            for limit in [row.relative, row.absolute].compactMap({ $0 }) {
                let value = config[keyPath: limit.value]
                #expect(limit.range.contains(value), "\(row.title): \(value)")
                let steps = (value - limit.range.lowerBound) / limit.step
                #expect(abs(steps - steps.rounded()) < 1e-9, "\(row.title): \(value) not on a step")
            }
        }
    }

    @Test("The value texts of the defaults are the sheet's texts before step 10c")
    func valueTexts() {
        let config = AutoRejectConfig()
        var texts: [String: [String]] = [:]
        for row in AutoRejectThreshold.all {
            texts[row.title] = [row.relative, row.absolute].compactMap { $0 }.map {
                AutoRejectThreshold.valueText(config[keyPath: $0.value], format: $0.format, locale: enUS)
            }
        }
        #expect(texts["Focus (FWHM)"] == ["1.5× median", "3.5 px"])
        #expect(texts["Trailing / Elongation"] == ["0.65", "0.65"])
        #expect(texts["Cloud / Haze (Star Count)"] == ["50% of median", "20"])
        #expect(texts["Signal-to-Noise (SNR)"] == ["60% of median", "200"])
        #expect(texts["Light Pollution (Sky BG)"] == ["1.5× median", "3,000 ADU"])
        #expect(texts["PSF Signal Weight"] == ["50% of median", "1.0"])
        #expect(texts["Quality Score"] == ["40"])
    }

    @Test("AutoRejectConfig is Equatable on every setting the sheet changes")
    func configEquatable() {
        for row in AutoRejectThreshold.all {
            var changed = AutoRejectConfig()
            changed[keyPath: row.isOn].toggle()
            #expect(changed != AutoRejectConfig(), "\(row.title)")
            var moved = AutoRejectConfig()
            moved[keyPath: row.absolute.value] += row.absolute.step
            #expect(moved != AutoRejectConfig(), "\(row.title)")
        }
    }
}
