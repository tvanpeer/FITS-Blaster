//
//  AutoRejectSheet.swift
//  FITS Blaster
//

import SwiftUI

// MARK: - Auto-reject configuration

/// Thresholds for one-click quality-based frame rejection.
struct AutoRejectConfig: Sendable {
    enum Mode: String, CaseIterable, Sendable {
        case relative = "Relative"
        case absolute = "Absolute"
    }

    var mode: Mode = .relative

    // FWHM
    var useFWHM: Bool = true
    var fwhmMultiplier: Double = 1.5     // relative: reject if FWHM > multiplier × group median
    var absoluteFWHM: Double = 3.5       // absolute: reject if FWHM (px) exceeds this

    // Eccentricity — same threshold in both modes (inherently absolute)
    var useEccentricity: Bool = true
    var eccentricityThreshold: Double = 0.5

    // Star count
    var useStarCount: Bool = true
    var starCountMultiplier: Double = 0.40  // relative: reject if stars < multiplier × group median
    var absoluteStarCountFloor: Int = 20    // absolute: reject if star count falls below this

    // SNR
    var useSNR: Bool = false
    var snrMultiplier: Double = 0.50        // relative: reject if SNR < multiplier × group median
    var absoluteSNRFloor: Double = 20.0     // absolute: reject if SNR falls below this

    // Quality score (absolute mode only)
    var useScore: Bool = false
    var scoreFloor: Int = 40
}

// MARK: - AutoRejectSheet

struct AutoRejectSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store

    @State private var config = AutoRejectConfig()
    @State private var showConfirm = false

    private var previewCount: Int {
        store.previewAutoReject(config: config).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader()
            Divider()
            Form {
                ModePicker(mode: $config.mode)
                FWHMSection(config: $config)
                EccentricitySection(config: $config)
                StarCountSection(config: $config)
                SNRSection(config: $config)
                if config.mode == .absolute {
                    ScoreSection(config: $config)
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetFooter(previewCount: previewCount,
                        isPresented: $isPresented,
                        showConfirm: $showConfirm)
        }
        .frame(minWidth: 420, minHeight: 500)
        .alert("Flag \(previewCount) Frame\(previewCount == 1 ? "" : "s") for Rejection?",
               isPresented: $showConfirm) {
            Button("Move to REJECTED", role: .destructive) {
                store.applyAutoReject(config: config)
                isPresented = false
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Flagged frames will be moved to the REJECTED folder. You can undo individual frames with U.")
        }
    }
}

// MARK: - Sub-views

private struct SheetHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-Flag Frames")
                    .font(.headline)
                Text("Flag frames below quality thresholds for rejection.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding()
    }
}

private struct ModePicker: View {
    @Binding var mode: AutoRejectConfig.Mode

    var body: some View {
        Section("Threshold Mode") {
            Picker("Mode", selection: $mode) {
                ForEach(AutoRejectConfig.Mode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            Group {
                switch mode {
                case .relative:
                    Text("Thresholds are expressed as multiples of the per-filter-group median. Adapts automatically to your optics and seeing conditions.")
                case .absolute:
                    Text("Thresholds are fixed numeric values. Useful when you know the expected performance of your setup.")
                }
            }
            .scaledFont(size: 10)
            .foregroundStyle(.secondary)
        }
    }
}

private struct FWHMSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Focus (FWHM)") {
            Toggle("Enable FWHM threshold", isOn: $config.useFWHM)
            if config.useFWHM {
                if config.mode == .relative {
                    LabeledContent("Reject if FWHM >") {
                        Text("\(config.fwhmMultiplier, format: .number.precision(.fractionLength(1)))× median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.fwhmMultiplier, in: 1.2...3.0, step: 0.1)
                } else {
                    LabeledContent("Reject if FWHM >") {
                        Text("\(config.absoluteFWHM, format: .number.precision(.fractionLength(1))) px")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absoluteFWHM, in: 1.5...10.0, step: 0.5)
                }
            }
        }
    }
}

private struct EccentricitySection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Trailing / Elongation") {
            Toggle("Enable eccentricity threshold", isOn: $config.useEccentricity)
            if config.useEccentricity {
                LabeledContent("Reject if eccentricity >") {
                    Text("\(config.eccentricityThreshold, format: .number.precision(.fractionLength(2)))")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.eccentricityThreshold, in: 0.3...0.9, step: 0.05)
            }
        }
    }
}

private struct StarCountSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Cloud / Haze (Star Count)") {
            Toggle("Enable star count threshold", isOn: $config.useStarCount)
            if config.useStarCount {
                if config.mode == .relative {
                    LabeledContent("Reject if stars <") {
                        Text("\(config.starCountMultiplier, format: .percent.precision(.fractionLength(0))) of median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.starCountMultiplier, in: 0.1...0.7, step: 0.05)
                } else {
                    LabeledContent("Reject if stars <") {
                        Text("\(config.absoluteStarCountFloor)")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: Binding(
                        get: { Double(config.absoluteStarCountFloor) },
                        set: { config.absoluteStarCountFloor = Int($0) }
                    ), in: 5...100, step: 5)
                }
            }
        }
    }
}

private struct SNRSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Signal-to-Noise (SNR)") {
            Toggle("Enable SNR threshold", isOn: $config.useSNR)
            if config.useSNR {
                if config.mode == .relative {
                    LabeledContent("Reject if SNR <") {
                        Text("\(config.snrMultiplier, format: .percent.precision(.fractionLength(0))) of median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.snrMultiplier, in: 0.1...0.8, step: 0.05)
                } else {
                    LabeledContent("Reject if SNR <") {
                        Text("\(config.absoluteSNRFloor, format: .number.precision(.fractionLength(0)))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absoluteSNRFloor, in: 5.0...1000.0, step: 5.0)
                }
            }
        }
    }
}

private struct ScoreSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Quality Score") {
            Toggle("Enable score floor", isOn: $config.useScore)
            if config.useScore {
                LabeledContent("Reject if score <") {
                    Text("\(config.scoreFloor)")
                        .foregroundStyle(.secondary)
                }
                Slider(value: Binding(
                    get: { Double(config.scoreFloor) },
                    set: { config.scoreFloor = Int($0) }
                ), in: 10...80, step: 5)
            }
        }
    }
}

private struct SheetFooter: View {
    let previewCount: Int
    @Binding var isPresented: Bool
    @Binding var showConfirm: Bool

    var body: some View {
        HStack {
            Text(previewCount == 0
                 ? "No frames match the current thresholds"
                 : "\(previewCount) frame\(previewCount == 1 ? "" : "s") would be flagged")
                .font(.callout)
                .foregroundStyle(previewCount > 0 ? .primary : .secondary)
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Flag \(previewCount) Frame\(previewCount == 1 ? "" : "s")", role: .destructive) {
                showConfirm = true
            }
            .disabled(previewCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
