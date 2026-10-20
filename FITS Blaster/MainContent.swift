//
//  MainContent.swift
//  FITS Blaster
//

import SwiftUI

struct MainContent: View {
    let store: ImageStore

    var body: some View {
        if let entry = store.selectedEntry {
            if entry.isProcessing {
                ProgressView("Stretching \(entry.fileName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayImage = entry.displayImage {
                VStack(spacing: 0) {
                    Text(entry.fileName)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    Divider()
                    ImageViewer(entryID: entry.id, displayImage: displayImage, isFlipped: entry.isFlipped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                    ImageAdjustControls()

                    Divider()
                    InfoBar(store: store, entry: entry)
                }
            } else if let error = entry.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if !store.entries.isEmpty {
            VStack {
                Image(systemName: store.rejectionVisibility == .rejected ? "trash.slash" : "flag.slash")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
                Text(store.rejectionVisibility == .rejected ? "No rejected images" : "No flagged images")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack {
                Image(systemName: "star.circle")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
                Text("Ready to Blast through your frames?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Open a folder with \u{2318}O or drag it onto the window")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Info Bar

private struct InfoBar: View {
    let store: ImageStore
    let entry: ImageEntry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack {
            if store.isBatchProcessing {
                BatchProgressBar(store: store, showLoadedMetrics: true)
            } else if store.restretchingMessage != nil {
                BatchProgressBar(store: store, showLoadedMetrics: false)
            } else if let elapsed = store.batchElapsed {
                let n   = store.batchImageCount ?? 0
                let fps = elapsed > 0 ? Double(n) / elapsed : 0
                let mpx = store.batchMegapixels ?? 0
                let mps = elapsed > 0 && mpx > 0 ? mpx / elapsed : 0
                let mpf = n > 0 && mpx > 0 ? mpx / Double(n) : 0
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(n) images · \(fps, format: .number.precision(.fractionLength(1))) fps\(mpf > 0 ? " (\(mpf.formatted(.number.precision(.fractionLength(0)))) MP)" : "")\(mps > 0 ? " · \(mps.formatted(.number.precision(.fractionLength(0)))) MP/s" : "")")
                    .scaledFont(size: 10, monospaced: true)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !settings.isSimpleMode, settings.showMetricChips, let m = entry.metrics, m.hasData {
                HStack(spacing: 12) {
                    ForEach(Metric.allCases.filter { $0.contexts.contains(.statusChip) }) { metric in
                        if let v = metric.value(from: m) {
                            MetricChip(label: metric.chipLabel, value: metric.chipValue(from: v))
                        }
                    }
                }
            }

            if !entry.imageInfo.isEmpty {
                Text(entry.imageInfo)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Batch Progress Bar

private struct BatchProgressBar: View {
    let store: ImageStore
    let showLoadedMetrics: Bool
    @Environment(AppSettings.self) private var settings

    @State private var loadedCount: Int = 0
    @State private var metricsCount: Int = 0

    var body: some View {
        let total = store.entries.count
        VStack(alignment: .leading, spacing: 3) {
            if showLoadedMetrics {
                ProgressBarRow(label: "Loaded", value: loadedCount, total: total, color: .teal)
                if !settings.isSimpleMode {
                    ProgressBarRow(label: "Metrics", value: metricsCount, total: total, color: .indigo)
                }
            }
            if store.batchSamplingTotal > 0 {
                ProgressBarRow(label: "Sampling", value: store.batchSamplingCount, total: store.batchSamplingTotal, color: .mint)
            }
            if store.batchRestretchTotal > 0 {
                ProgressBarRow(label: "Restretching", value: store.batchRestretchCount, total: store.batchRestretchTotal, color: .orange)
            }
        }
        .task {
            repeat {
                loadedCount  = store.entries.count { !$0.isProcessing }
                metricsCount = store.entries.count { $0.metrics != nil }
                try? await Task.sleep(for: .milliseconds(200))
            } while !Task.isCancelled
        }
    }
}

private struct ProgressBarRow: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color

    private var fraction: Double {
        total > 0 ? min(1, Double(value) / Double(total)) : 0
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .scaledFont(size: 9)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
            Capsule()
                .fill(color.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .scaleEffect(x: fraction, anchor: .leading)
                        .animation(.linear(duration: 0.2), value: fraction)
                }
                .frame(height: 4)
            Text("\(value) / \(total)")
                .scaledFont(size: 9, monospaced: true)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .scaledFont(size: 10, monospaced: true)
    }
}
