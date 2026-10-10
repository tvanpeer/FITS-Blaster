//
//  AutoRejectSheet.swift
//  FITS Blaster
//

import SwiftUI

// MARK: - AutoRejectSheet

struct AutoRejectSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store

    @State private var config = AutoRejectConfig()

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
                SkyBackgroundSection(config: $config)
                PSFSection(config: $config)
                if config.mode == .absolute {
                    ScoreSection(config: $config)
                }
            }
            .formStyle(.grouped)
            Divider()
            SheetFooter(previewCount: previewCount,
                        isPresented: $isPresented) {
                store.applyAutoFlag(config: config)
            }
        }
        .frame(minWidth: 420, minHeight: 500)
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
                Text("Flag frames below quality thresholds for review.")
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
                    LabeledContent("Select if FWHM >") {
                        Text("\(config.fwhmMultiplier, format: .number.precision(.fractionLength(1)))× median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.fwhmMultiplier, in: 1.2...3.0, step: 0.1)
                } else {
                    LabeledContent("Select if FWHM >") {
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
                LabeledContent("Select if eccentricity >") {
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
                    LabeledContent("Select if stars <") {
                        Text("\(config.starCountMultiplier, format: .percent.precision(.fractionLength(0))) of median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.starCountMultiplier, in: 0.1...0.7, step: 0.05)
                } else {
                    LabeledContent("Select if stars <") {
                        Text("\(config.absoluteStarCountFloor, format: .number.precision(.fractionLength(0)))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absoluteStarCountFloor, in: 5...100, step: 5)
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
                    LabeledContent("Select if SNR <") {
                        Text("\(config.snrMultiplier, format: .percent.precision(.fractionLength(0))) of median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.snrMultiplier, in: 0.1...0.8, step: 0.05)
                } else {
                    LabeledContent("Select if SNR <") {
                        Text("\(config.absoluteSNRFloor, format: .number.precision(.fractionLength(0)))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absoluteSNRFloor, in: 5.0...1000.0, step: 5.0)
                }
            }
        }
    }
}

private struct SkyBackgroundSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("Light Pollution (Sky BG)") {
            Toggle("Enable sky background threshold", isOn: $config.useSkyBackground)
            if config.useSkyBackground {
                if config.mode == .relative {
                    LabeledContent("Select if sky BG >") {
                        Text("\(config.skyBackgroundMultiplier, format: .number.precision(.fractionLength(1)))× median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.skyBackgroundMultiplier, in: 1.2...3.0, step: 0.1)
                } else {
                    LabeledContent("Select if sky BG >") {
                        Text("\(config.absoluteSkyBackgroundCeiling, format: .number.precision(.fractionLength(0))) ADU")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absoluteSkyBackgroundCeiling, in: 500...20000, step: 500)
                }
            }
        }
    }
}

private struct PSFSection: View {
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section("PSF Signal Weight") {
            Toggle("Enable PSF signal weight threshold", isOn: $config.usePSF)
            if config.usePSF {
                if config.mode == .relative {
                    LabeledContent("Select if PSF weight <") {
                        Text("\(config.psfMultiplier, format: .percent.precision(.fractionLength(0))) of median")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.psfMultiplier, in: 0.1...0.9, step: 0.05)
                } else {
                    LabeledContent("Select if PSF weight <") {
                        Text("\(config.absolutePSFFloor, format: .number.precision(.fractionLength(1)))")
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $config.absolutePSFFloor, in: 0.1...10.0, step: 0.1)
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
                LabeledContent("Select if score <") {
                    Text("\(config.scoreFloor, format: .number.precision(.fractionLength(0)))")
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config.scoreFloor, in: 10...80, step: 5)
            }
        }
    }
}

private struct SheetFooter: View {
    let previewCount: Int
    @Binding var isPresented: Bool
    let onFlag: () -> Void

    var body: some View {
        HStack {
            Text(previewCount == 0
                 ? "No frames match the current thresholds"
                 : "\(previewCount) frame\(previewCount == 1 ? "" : "s") would be selected")
                .font(.callout)
                .foregroundStyle(previewCount > 0 ? .primary : .secondary)
            Spacer()
            Button("Cancel") { isPresented = false }
                .keyboardShortcut(.cancelAction)
            Button("Select \(previewCount) Frame\(previewCount == 1 ? "" : "s")") {
                onFlag()
                isPresented = false
            }
            .disabled(previewCount == 0)
            .keyboardShortcut(.defaultAction)
        }
        .padding()
    }
}
