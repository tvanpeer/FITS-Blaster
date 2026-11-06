//
//  SessionChartAudioGraph.swift
//  FITS Blaster
//
//  The session chart's audio graph for VoiceOver (Apple's chart descriptor). With the chart
//  focused, VoiceOver's "Chart details" play the values as tones and step through the frames,
//  each read with its frame number, file name and value (step 10a). Swift Charts on its own
//  bundles the dots into ranges of frame numbers, so single frames can't be reached.
//

import Accessibility
import SwiftUI

struct SessionChartAudioGraph: AXChartDescriptorRepresentable {
    let metric: Metric
    let points: [SessionChartData.AudioGraphPoint]
    /// The chart's x range in frame numbers (1…frame count) and its y range.
    let frameCount: Int
    let yDomain: ClosedRange<Double>

    func makeChartDescriptor() -> AXChartDescriptor {
        let metric = metric
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Frame",
            range: 1...Double(max(1, frameCount)),
            gridlinePositions: []
        ) { "Frame \(Int($0))" }
        let yAxis = AXNumericDataAxisDescriptor(
            title: metric.displayName,
            range: yDomain,
            gridlinePositions: []
        ) { SessionChartData.spokenValue($0, metric: metric) }
        let series = AXDataSeriesDescriptor(
            name: metric.displayName,
            isContinuous: false,
            dataPoints: points.map { AXDataPoint(x: Double($0.frame), y: $0.value, label: $0.label) }
        )
        return AXChartDescriptor(
            title: "Session chart, \(metric.displayName)",
            summary: nil,
            xAxis: xAxis,
            yAxis: yAxis,
            additionalAxes: [],
            series: [series]
        )
    }
}
