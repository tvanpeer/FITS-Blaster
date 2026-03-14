//
//  InspectorView.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

// MARK: - Root inspector

struct InspectorView: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private var entry: ImageEntry? { store.selectedEntry }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                InspectorHistogramSection(histogram: entry?.histogram)
                Divider()
                InspectorMetricsSection(metrics: entry?.metrics,
                                        config: settings.metricsConfig,
                                        isProcessing: entry?.isProcessing ?? false)
                Divider()
                InspectorHeadersSection(headers: entry?.headers ?? [:])
            }
        }
        .scrollIndicators(.hidden)
        .background(.background)
    }
}

// MARK: - Histogram section

private struct InspectorHistogramSection: View {
    let histogram: [Int]?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Histogram")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(.secondary)

            if let histogram {
                HistogramView(histogram: histogram)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 72)
            }
        }
        .padding()
    }
}

// MARK: - Metrics section

private struct InspectorMetricsSection: View {
    let metrics: FrameMetrics?
    let config: MetricsConfig
    let isProcessing: Bool
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Metrics")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Toggle(isOn: $settings.computeFWHM)   { Text("FWHM").scaledFont(size: 10) }
                Toggle(isOn: $settings.computeEccentricity) { Text("Ecc").scaledFont(size: 10) }
                Toggle(isOn: $settings.computeSNR)    { Text("SNR").scaledFont(size: 10) }
                Toggle(isOn: $settings.computeStarCount)   { Text("Stars").scaledFont(size: 10) }
            }
            .toggleStyle(.button)

            if let metrics, metrics.hasData {
                VStack(spacing: 0) {
                    if config.computeFWHM, let v = metrics.fwhm {
                        MetricRow(label: "FWHM",
                                  value: "\(v.formatted(.number.precision(.fractionLength(1)))) px")
                    }
                    if config.computeEccentricity, let v = metrics.eccentricity {
                        MetricRow(label: "Eccentricity",
                                  value: v.formatted(.number.precision(.fractionLength(3))))
                    }
                    if config.computeSNR, let v = metrics.snr {
                        MetricRow(label: "SNR",
                                  value: v.formatted(.number.precision(.fractionLength(1))))
                    }
                    if config.computeStarCount, let v = metrics.starCount {
                        MetricRow(label: "Stars", value: "\(v)")
                    }
                    Divider().padding(.vertical, 4)
                    MetricRow(label: "Score", value: "\(metrics.qualityScore) / 100")
                        .foregroundStyle(metrics.scoreColor)
                }
            } else if config.needsStarDetection {
                Text(isProcessing ? "Computing…" : "No stars detected")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            } else {
                Text("All metrics disabled")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
    }
}

private struct MetricRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .scaledFont(size: 10)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .scaledFont(size: 10, monospaced: true)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - FITS headers section

private struct InspectorHeadersSection: View {
    let headers: [String: String]

    /// Keys shown at the top in this order; everything else follows alphabetically.
    private static let priorityKeys = [
        "OBJECT", "DATE-OBS", "EXPTIME", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP", "XBINNING", "YBINNING",
        "TELESCOP", "INSTRUME", "FOCALLEN", "CDELT1"
    ]

    private var orderedPairs: [(String, String)] {
        var result: [(String, String)] = []
        for key in Self.priorityKeys {
            if let val = headers[key] {
                result.append((key, FITSReader.cleanHeaderString(val)))
            }
        }
        let prioritySet = Set(Self.priorityKeys)
        let rest = headers
            .filter { !prioritySet.contains($0.key) }
            .sorted { $0.key < $1.key }
        for (k, v) in rest {
            result.append((k, FITSReader.cleanHeaderString(v)))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("FITS Headers")
                .scaledFont(size: 10, weight: .bold)
                .foregroundStyle(.secondary)

            if orderedPairs.isEmpty {
                Text("No headers available")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedPairs, id: \.0) { key, value in
                        HStack(alignment: .top) {
                            Text(key)
                                .scaledFont(size: 10, monospaced: true)
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 70, alignment: .leading)
                            Text(value)
                                .scaledFont(size: 10)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.trailing)
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 1)
                    }
                }
            }
        }
        .padding()
    }
}
