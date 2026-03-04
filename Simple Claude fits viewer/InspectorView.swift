//
//  InspectorView.swift
//  Simple Claude fits viewer
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
                InspectorMetricsSection(metrics: entry?.metrics, config: settings.metricsConfig)
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
                .font(.caption.bold())
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
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        VStack(alignment: .leading, spacing: 8) {
            Text("Quality Metrics")
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 4) {
                Toggle("FWHM", isOn: $settings.computeFWHM)
                Toggle("Ecc", isOn: $settings.computeEccentricity)
                Toggle("SNR", isOn: $settings.computeSNR)
                Toggle("Stars", isOn: $settings.computeStarCount)
            }
            .toggleStyle(.button)
            .font(.caption)

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
                        .foregroundStyle(metrics.badgeColor)
                }
            } else if config.needsStarDetection {
                Text("Computing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text("All metrics disabled")
                    .font(.caption)
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
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
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
                .font(.caption.bold())
                .foregroundStyle(.secondary)

            if orderedPairs.isEmpty {
                Text("No headers available")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } else {
                VStack(spacing: 0) {
                    ForEach(orderedPairs, id: \.0) { key, value in
                        HStack(alignment: .top) {
                            Text(key)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(minWidth: 70, alignment: .leading)
                            Text(value)
                                .font(.caption)
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
