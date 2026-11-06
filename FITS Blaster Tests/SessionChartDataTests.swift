//
//  SessionChartDataTests.swift
//  FITS Blaster Tests
//
//  The session chart's data and logic outside the view (CODE_AUDIT §8.9, step 10a): the
//  frames and points, the y-axis range, the dot opacity, the frames under a tap or drag,
//  and the VoiceOver summary and audio graph.
//

import Accessibility
import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct SessionChartDataTests {

    private func entry(_ filter: String = "Ha", fwhm: Float? = 2, name: String? = nil,
                       rejected: Bool = false) -> ImageEntry {
        let e = ImageEntry(url: URL(fileURLWithPath: "/data/\(name ?? UUID().uuidString).fits"))
        e.isProcessing = false
        e.isRejected = rejected
        e.headers = ["FILTER": filter]
        e.metrics = FrameMetrics(fwhm: fwhm, eccentricity: 0.1, snr: 50, starCount: 100,
                                 qualityScore: 70, skyBackground: nil, psfSignalWeight: nil)
        return e
    }

    private func store(_ entries: [ImageEntry]) -> ImageStore {
        let store = ImageStore()
        store.entries = entries
        store.updateGroupStatistics()
        return store
    }

    private func data(_ entries: [ImageEntry]) -> SessionChartData {
        SessionChartData(entries: entries)
    }

    // MARK: - Building

    @Test("Frames without a value keep their place, medians from the group statistics")
    func make() {
        let a = entry(fwhm: 2), b = entry(fwhm: nil), c = entry(fwhm: 4)
        let data = SessionChartData.make(store: store([a, b, c]), metric: .fwhm, folderPaths: [])
        #expect(data.entries.map(\.id) == [a.id, b.id, c.id])
        #expect(data.points.map(\.index) == [0, 2])
        #expect(data.points.map(\.value) == [2, 4])
        #expect(data.medians.map(\.group) == [.ha])
        #expect(data.yDomain == SessionChartData.yDomain(for: [2, 4] + data.medians.map(\.median)))
    }

    @Test("Empty data has the 0…1 range")
    func emptyDomain() {
        #expect(SessionChartData().yDomain == 0...1)
        #expect(SessionChartData.yDomain(for: []) == 0...1)
    }

    // MARK: - Y-axis range

    @Test("A range gets 10 % of its spread on both sides")
    func spreadPadding() {
        #expect(SessionChartData.yDomain(for: [10, 20]) == 9...21)
        #expect(SessionChartData.yDomain(for: [20, 10, 15]) == 9...21)
    }

    @Test("The padding is at least 0.01")
    func minimumPadding() {
        let domain = SessionChartData.yDomain(for: [0.5, 0.55])
        #expect(abs(domain.lowerBound - 0.49) < 1e-12)
        #expect(abs(domain.upperBound - 0.56) < 1e-12)
    }

    @Test("The range never goes below 0")
    func neverBelowZero() {
        #expect(SessionChartData.yDomain(for: [0.1, 10]).lowerBound == 0)
        #expect(SessionChartData.yDomain(for: [0.2]).lowerBound == 0)
    }

    @Test("A single value sits in the middle: 20 % of the value on both sides, at least 0.5")
    func singleValue() {
        #expect(SessionChartData.yDomain(for: [100]) == 80...120)
        #expect(SessionChartData.yDomain(for: [100, 100]) == 80...120)
        #expect(SessionChartData.yDomain(for: [2]) == 1.5...2.5)
    }

    @Test("Medians outside the points widen the range")
    func mediansIncluded() {
        let a = entry(fwhm: 2), b = entry(fwhm: 4)
        var data = SessionChartData.make(store: store([a, b]), metric: .fwhm, folderPaths: [])
        data.medians = [(group: .ha, median: 10)]
        let domain = SessionChartData.yDomain(for: data.points.map(\.value) + data.medians.map(\.median))
        #expect(domain == SessionChartData.yDomain(for: [2, 4, 10]))
        #expect(domain.upperBound > 10)
    }

    // MARK: - Dot opacity

    typealias DotState = SessionChartData.DotState

    @Test("Dot opacity: rejected, dimmed while others are flagged, otherwise opaque", arguments: [
        (DotState(), 1.0),
        (DotState(isRejected: true), 0.15),
        (DotState(isCursor: true, isRejected: true), 0.15),                          // rejected wins over the cursor
        (DotState(isFlagged: true, hasFlaggedFrames: true, isRejected: true), 0.15), // and over flagged
        (DotState(hasFlaggedFrames: true), 0.5),                                     // another frame is flagged
        (DotState(isFlagged: true, hasFlaggedFrames: true), 1.0),                    // this frame is flagged
        (DotState(isCursor: true, hasFlaggedFrames: true), 1.0),                     // the cursor is never dimmed
    ])
    func dotOpacity(_ state: DotState, expected: Double) {
        #expect(SessionChartData.dotOpacity(state, rejectedOpacity: 0.15, dimmedOpacity: 0.5) == expected)
    }

    // MARK: - Tap and drag

    @Test("A frame number is 1-based; outside the frames gives nil")
    func entryAtFrame() {
        let a = entry(), b = entry()
        let data = data([a, b])
        #expect(data.entry(atFrame: 1)?.id == a.id)
        #expect(data.entry(atFrame: 2)?.id == b.id)
        #expect(data.entry(atFrame: 0) == nil)
        #expect(data.entry(atFrame: 3) == nil)
        #expect(SessionChartData().entry(atFrame: 1) == nil)
    }

    @Test("A drag gives the frames in its range, either direction, without rejected frames")
    func dragRange() {
        let frames = [entry(), entry(rejected: true), entry(), entry()]
        let data = data(frames)
        #expect(data.flagCandidates(fromFrame: 1, toFrame: 3).map(\.id) == [frames[0].id, frames[2].id])
        #expect(data.flagCandidates(fromFrame: 3, toFrame: 1).map(\.id) == [frames[0].id, frames[2].id])
        #expect(data.flagCandidates(fromFrame: 4, toFrame: 4).map(\.id) == [frames[3].id])
    }

    @Test("A drag past either end is clamped to the frames")
    func dragClamped() {
        let frames = [entry(), entry(), entry()]
        let data = data(frames)
        #expect(data.flagCandidates(fromFrame: 0, toFrame: 9).map(\.id) == frames.map(\.id))
        #expect(data.flagCandidates(fromFrame: -3, toFrame: 1).map(\.id) == [frames[0].id])
        #expect(data.flagCandidates(fromFrame: 5, toFrame: 9).isEmpty)
        #expect(SessionChartData().flagCandidates(fromFrame: 1, toFrame: 3).isEmpty)
    }

    @Test("A drag over rejected frames only gives nothing")
    func dragAllRejected() {
        let data = data([entry(rejected: true), entry(rejected: true)])
        #expect(data.flagCandidates(fromFrame: 1, toFrame: 2).isEmpty)
    }

    // MARK: - VoiceOver

    private func number(_ v: Double, digits: Int) -> String {
        v.formatted(.number.precision(.fractionLength(digits)))
    }

    @Test("A value is spoken with its unit")
    func spokenValue() {
        #expect(SessionChartData.spokenValue(3.24, metric: .fwhm) == "\(number(3.24, digits: 1)) px")
        #expect(SessionChartData.spokenValue(1200, metric: .skyBackground) == "\(number(1200, digits: 0)) ADU")
        #expect(SessionChartData.spokenValue(72, metric: .qualityScore) == "72")
        #expect(SessionChartData.spokenValue(0.456, metric: .eccentricity) == number(0.456, digits: 2))
    }

    @Test("The summary counts the frames with a value and gives median, lowest and highest")
    func summary() {
        let frames = [entry(fwhm: 2), entry(fwhm: nil), entry(fwhm: 4), entry(fwhm: 3)]
        let data = SessionChartData.make(store: store(frames), metric: .fwhm, folderPaths: [])
        #expect(data.accessibilitySummary(metric: .fwhm)
                == "3 frames, median \(number(3, digits: 1)) px, lowest \(number(2, digits: 1)) px, "
                 + "highest \(number(4, digits: 1)) px")
    }

    @Test("The summary of a single frame and of no values")
    func summaryEdgeCases() {
        let one = SessionChartData.make(store: store([entry(fwhm: 2)]), metric: .fwhm, folderPaths: [])
        #expect(one.accessibilitySummary(metric: .fwhm).hasPrefix("1 frame, "))
        #expect(SessionChartData().accessibilitySummary(metric: .fwhm) == "No FWHM values")
    }

    @Test("The audio graph has one point per frame with a value: frame number, value, file name")
    func audioGraphPoints() {
        let a = entry(fwhm: 2, name: "M42_0001"), b = entry(fwhm: nil, name: "M42_0002"), c = entry(fwhm: 4, name: "M42_0003")
        let data = SessionChartData.make(store: store([a, b, c]), metric: .fwhm, folderPaths: [])
        #expect(data.audioGraphPoints() == [
            .init(frame: 1, value: 2, label: "M42_0001.fits"),
            .init(frame: 3, value: 4, label: "M42_0003.fits"),
        ])
    }

    @Test("The audio graph's descriptor holds the same points and ranges")
    func audioGraphDescriptor() {
        let data = SessionChartData.make(store: store([entry(fwhm: 2, name: "A"), entry(fwhm: 4, name: "B")]),
                                         metric: .fwhm, folderPaths: [])
        let graph = SessionChartAudioGraph(metric: .fwhm, points: data.audioGraphPoints(),
                                           frameCount: data.entries.count, yDomain: data.yDomain)
        let descriptor = graph.makeChartDescriptor()
        #expect(descriptor.title == "Session chart, FWHM")
        #expect(descriptor.series.count == 1)
        #expect(descriptor.series[0].dataPoints.map(\.label) == ["A.fits", "B.fits"])
        #expect((descriptor.xAxis as? AXNumericDataAxisDescriptor)?.range == 1...2)
        #expect(descriptor.yAxis?.range == data.yDomain)
    }
}
