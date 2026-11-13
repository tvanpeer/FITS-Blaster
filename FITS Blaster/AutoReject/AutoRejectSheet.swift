//
//  AutoRejectSheet.swift
//  FITS Blaster
//

import SwiftUI

// MARK: - AutoRejectSheet

struct AutoRejectSheet: View {
    @Binding var isPresented: Bool
    @Environment(ImageStore.self) private var store

    /// Starts from the settings saved when the sheet last closed (issue #15).
    @State private var config = AutoRejectConfigStore.load()
    /// The number of frames the current thresholds select. Worked out when the thresholds
    /// change and, while a folder loads, every 250 ms and once at the end — not in `body`,
    /// which would then redraw for every metric that arrives (step 10c).
    @State private var previewCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(isDefault: config == AutoRejectConfig()) {
                config = AutoRejectConfig()
            }
            Divider()
            Form {
                ModePicker(mode: $config.mode,
                           smallGroups: config.isAnyRelativeCheckOn ? store.groupsTooSmallForRelativeChecks : [])
                ForEach(AutoRejectThreshold.all) { threshold in
                    if let limit = threshold.limit(for: config.mode) {
                        ThresholdSection(threshold: threshold, limit: limit, config: $config)
                    }
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
        .onChange(of: config) { _, _ in updatePreviewCount() }
        // Every change is kept, also after Cancel; saved once here rather than on every
        // slider step.
        .onDisappear { AutoRejectConfigStore.save(config) }
        .task(id: store.pipeline.isBatchProcessing) {
            updatePreviewCount()
            guard store.pipeline.isBatchProcessing else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: SessionChartData.refreshInterval)
                guard !Task.isCancelled else { return }
                updatePreviewCount()
            }
        }
    }

    private func updatePreviewCount() {
        previewCount = store.previewAutoReject(config: config).count
    }
}

// MARK: - Sub-views

private struct SheetHeader: View {
    /// True when every setting equals its default; the reset button is then disabled.
    let isDefault: Bool
    let onReset: () -> Void

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
            Button("Reset to Defaults", action: onReset)
                .disabled(isDefault)
        }
        .padding()
    }
}

private struct ModePicker: View {
    @Binding var mode: AutoRejectConfig.Mode
    /// Filter groups too small for relative checks, shown as a note in relative mode.
    let smallGroups: [(group: FilterGroup, frameCount: Int)]

    /// "Ha (2 frames), OIII (1 frame)".
    private var smallGroupList: String {
        smallGroups.map { "\($0.group.rawValue) (\($0.frameCount) frame\($0.frameCount == 1 ? "" : "s"))" }
            .formatted(.list(type: .and))
    }

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
            if !smallGroups.isEmpty {
                Label("""
                    Too few frames to compare with a median in \(smallGroupList): relative checks need at least \
                    \(GroupStats.minimumFramesForRelativeChecks) frames and skip these groups. Eccentricity and frames \
                    without stars are still checked.
                    """,
                      systemImage: "info.circle")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// One check of `AutoRejectThreshold.all`: its toggle and, when on, the limit of the
/// current mode with its value text and slider.
private struct ThresholdSection: View {
    let threshold: AutoRejectThreshold
    let limit: AutoRejectThreshold.Limit
    @Binding var config: AutoRejectConfig

    var body: some View {
        Section(threshold.title) {
            Toggle(threshold.toggleLabel, isOn: $config[dynamicMember: threshold.isOn])
            if config[keyPath: threshold.isOn] {
                LabeledContent(threshold.comparison) {
                    Text(AutoRejectThreshold.valueText(config[keyPath: limit.value], format: limit.format))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $config[dynamicMember: limit.value], in: limit.range, step: limit.step)
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
