//
//  SettingsView.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

// MARK: - Settings root

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            Tab("Interface", systemImage: "keyboard") {
                UISettingsTab()
            }
            Tab("Display", systemImage: "photo") {
                ImageDisplayTab()
            }
            Tab("Files & Folders", systemImage: "folder") {
                FilesAndFoldersTab()
            }
            Tab("Export", systemImage: "square.and.arrow.up") {
                ExportSettingsTab()
            }
        }
        .frame(minWidth: 580, minHeight: 400)
        .environment(\.fontSizeMultiplier, settings.fontSizeMultiplier)
    }
}

// MARK: - User Interface tab

struct UISettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        // The other keys of the same kind (plain or ⌘): a key already in use there is refused.
        let others: (KeyAction) -> [Binding<String>] = { action in
            let kind = KeyBinding.binding(for: action).kind
            return KeyBinding.all.filter { $0.kind == kind && $0.action != action }
                .map { $settings[dynamicMember: $0.key] }
        }

        Form {
            Section("Navigation") {
                LabeledContent("First Image") {
                    KeyRecorderButton(keyString: $settings.firstImageKey,
                                      conflictingKeys: others(.first))
                }
                LabeledContent("Last Image") {
                    KeyRecorderButton(keyString: $settings.lastImageKey,
                                      conflictingKeys: others(.last))
                }
                LabeledContent("Previous Image") {
                    KeyRecorderButton(keyString: $settings.prevImageKey,
                                      conflictingKeys: others(.previous))
                }
                LabeledContent("Next Image") {
                    KeyRecorderButton(keyString: $settings.nextImageKey,
                                      conflictingKeys: others(.next))
                }
                Toggle("Single key reject/undo (toggle)", isOn: $settings.useToggleReject)
                LabeledContent(settings.useToggleReject ? "Reject / Undo" : "Reject Image") {
                    KeyRecorderButton(keyString: $settings.rejectKey,
                                      conflictingKeys: others(.reject))
                }
                if !settings.useToggleReject {
                    LabeledContent("Undo Rejection") {
                        KeyRecorderButton(keyString: $settings.undoKey,
                                          conflictingKeys: others(.undo))
                    }
                }
                LabeledContent("Flag / Deflag") {
                    KeyRecorderButton(keyString: $settings.flagKey,
                                      conflictingKeys: others(.flag))
                }
                LabeledContent("Deflag All") {
                    KeyRecorderButton(keyString: $settings.deflagAllKey,
                                      conflictingKeys: others(.deflagAll))
                }
                LabeledContent("Toggle Simple/Geek Mode") {
                    KeyRecorderButton(keyString: $settings.toggleModeKey,
                                      conflictingKeys: others(.toggleMode))
                }
                LabeledContent("Remove from List") {
                    KeyRecorderButton(keyString: $settings.removeKey,
                                      conflictingKeys: others(.remove))
                }
                LabeledContent("Toggle Colour Images") {
                    KeyRecorderButton(keyString: $settings.debayerKey,
                                      conflictingKeys: others(.debayer))
                }
                LabeledContent("Play / Pause") {
                    KeyRecorderButton(keyString: $settings.playPauseKey,
                                      conflictingKeys: others(.playPause))
                }
                LabeledContent("Flip 180\u{00B0}") {
                    KeyRecorderButton(keyString: $settings.flipKey,
                                      conflictingKeys: others(.flip))
                }
            }

            Section("Zoom and Pan") {
                LabeledContent("Zoom In") {
                    KeyRecorderButton(keyString: $settings.zoomInKey,
                                      conflictingKeys: others(.zoomIn))
                }
                LabeledContent("Zoom Out") {
                    KeyRecorderButton(keyString: $settings.zoomOutKey,
                                      conflictingKeys: others(.zoomOut))
                }
                LabeledContent("Zoom to Fit") {
                    KeyRecorderButton(keyString: $settings.zoomToFitKey,
                                      conflictingKeys: others(.zoomToFit))
                }
                LabeledContent("Actual Size (1×)") {
                    KeyRecorderButton(keyString: $settings.zoomActualSizeKey,
                                      conflictingKeys: others(.zoomActualSize))
                }
                LabeledContent("Pan") {
                    Text("⌥ + arrow keys")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Selection") {
                LabeledContent("Select All") {
                    SelectionShortcutRow(
                        keyString: $settings.selectAllKey,
                        usesShift: $settings.selectAllShift,
                        conflictingKeys: others(.selectAll)
                    )
                }
                LabeledContent("Deselect All") {
                    SelectionShortcutRow(
                        keyString: $settings.deselectAllKey,
                        usesShift: $settings.deselectAllShift,
                        conflictingKeys: others(.deselectAll)
                    )
                }
                LabeledContent("Inverse Selection") {
                    SelectionShortcutRow(
                        keyString: $settings.invertSelectionKey,
                        usesShift: $settings.invertSelectionShift,
                        conflictingKeys: others(.invertSelection)
                    )
                }
                LabeledContent("Select All Rejected") {
                    SelectionShortcutRow(
                        keyString: $settings.selectAllRejectedKey,
                        usesShift: $settings.selectAllRejectedShift,
                        conflictingKeys: others(.selectAllRejected)
                    )
                }
            }

            Section("Appearance") {
                Picker("Theme", selection: $settings.appearanceMode) {
                    ForEach(AppearanceMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Text Size") {
                    DynamicTypeSizePicker(selection: $settings.dynamicTypeSize)
                }
            }

            #if !APPSTORE
            SoftwareUpdatesSection()
            #endif

        }
        .formStyle(.grouped)
    }
}

// MARK: - Image Display tab

struct ImageDisplayTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store

    @State private var displaySize: Int = DisplayDefaults.displaySize
    @State private var thumbnailSize: Int = 180
    @State private var displaySizeText = String(DisplayDefaults.displaySize)
    @State private var thumbnailSizeText: String = "180"

    private var parsedDisplaySize: Int {
        Int(displaySizeText).map { max(512, min($0, 8192)) } ?? displaySize
    }
    private var parsedThumbnailSize: Int {
        let range = AppSettings.thumbnailSizeRange
        return Int(thumbnailSizeText).map { max(range.lowerBound, min($0, range.upperBound)) } ?? thumbnailSize
    }
    private var isDirty: Bool {
        parsedDisplaySize != settings.maxDisplaySize || parsedThumbnailSize != settings.maxThumbnailSize
    }

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Sizes") {
                LabeledContent("Max display size") {
                    SizeField(value: $displaySize, text: $displaySizeText,
                              range: 512...8192, step: 128, unit: "px")
                }
                LabeledContent("Max thumbnail size") {
                    SizeField(value: $thumbnailSize, text: $thumbnailSizeText,
                              range: AppSettings.thumbnailSizeRange, step: 20, unit: "pt")
                }
                Text("""
                    The width of the thumbnails in the sidebar; the sidebar follows it, and can be dragged wider. \
                    Thumbnails are rendered at this size times the screen's scale, so they stay sharp on Retina screens.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                }
            }

            Section("Memory") {
                DisplayMemorySlider()
            }

            Section("Colour Images") {
                Toggle("Debayer colour FITS images", isOn: $settings.debayerColourImages)
                Text("""
                    When enabled, images with a Bayer CFA pattern (BAYERPAT/COLORTYP/CFA_PAT header) are displayed in \
                    colour, debayered on the GPU. Images that are already loaded are re-rendered when you change this.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Section("Quality Metrics") {
                Toggle("Show metric chips above session chart", isOn: $settings.showMetricChips)
                Text("""
                    Displays a compact chip row (FWHM, Ecc, SNR, Stars, Sky BG, PSF·S) above the chart for the selected \
                    frame. All metrics are always visible in the Inspector on the right.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Section("Session Chart Brightness") {
                LabeledContent("Rejected frames") {
                    OpacitySlider(value: $settings.rejectedDotOpacity)
                }
                LabeledContent("Non-flagged frames") {
                    OpacitySlider(value: $settings.dimmedDotOpacity)
                }
                Text("""
                    Rejected frames are always drawn at the first brightness, also when flagged or selected. Non-flagged \
                    frames are dimmed only while some frames are flagged. Flagged frames and the current frame are otherwise at full brightness.
                    """)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            displaySize       = settings.maxDisplaySize
            thumbnailSize     = settings.maxThumbnailSize
            displaySizeText   = String(settings.maxDisplaySize)
            thumbnailSizeText = String(settings.maxThumbnailSize)
        }
    }

    private func apply() {
        let clampedDisplay = parsedDisplaySize
        let clampedThumb   = parsedThumbnailSize
        displaySize   = clampedDisplay
        thumbnailSize = clampedThumb

        let displayChanged   = clampedDisplay != settings.maxDisplaySize
        let thumbnailChanged = clampedThumb   != settings.maxThumbnailSize
        settings.maxDisplaySize   = clampedDisplay
        settings.maxThumbnailSize = clampedThumb

        // A new display size needs every frame rendered again from its file; a new
        // thumbnail size only needs new thumbnails from the display images in memory.
        // The window keeps its size: only the user resizes it (Tom, 2026-11-09; before, a
        // new display size also resized the main window to fit).
        if displayChanged {
            if !store.entries.isEmpty { store.pipeline.regenerateSizes(settings: settings) }
        } else if thumbnailChanged, !store.entries.isEmpty {
            store.pipeline.regenerateThumbnails(settings: settings)
        }
    }
}

// MARK: - Files & Folders tab

struct FilesAndFoldersTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Subfolders") {
                Toggle("Include files from subfolders", isOn: $settings.includeSubfolders)
                LabeledContent("Skip folders named:") {
                    SubfolderExclusionField(tags: $settings.excludedSubfolderNames)
                }
                .alignmentGuide(.firstTextBaseline) { $0[.top] + 8 }
                Toggle("Include REJECTED folder (mark images as rejected)", isOn: $settings.includeRejectedFolder)
            }

        }
        .formStyle(.grouped)
    }
}

// MARK: - Subfolder exclusion tag field

/// A tag-style input that lets the user add/remove subfolder names to exclude.
private struct SubfolderExclusionField: View {
    @Binding var tags: [String]
    @State private var inputText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !tags.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 4) {
                        ForEach(tags, id: \.self) { tag in
                            HStack(spacing: 3) {
                                Text(tag)
                                    .scaledFont(size: 10)
                                Button("Remove \(tag)", systemImage: "xmark") {
                                    tags.removeAll { $0 == tag }
                                }
                                .labelStyle(.iconOnly)
                                .buttonStyle(.plain)
                                .scaledFont(size: 9)
                                .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.quaternary)
                            .clipShape(.rect(cornerRadius: 4))
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
            TextField("Type name and press Return to add", text: $inputText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { addTag() }
                .frame(maxWidth: 260)
            Text("Case-insensitive, exact folder name match.")
                .scaledFont(size: 9)
                .foregroundStyle(.tertiary)
        }
    }

    private func addTag() {
        let trimmed = inputText.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !tags.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            tags.append(trimmed.uppercased())
        }
        inputText = ""
    }
}

// MARK: - Size field (text entry + stepper)

private struct SizeField: View {
    @Binding var value: Int
    @Binding var text: String
    let range: ClosedRange<Int>
    let step: Int
    /// "px" or "pt", shown after the field.
    let unit: String

    var body: some View {
        HStack {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .onSubmit { commit() }
            Text(unit)
                .foregroundStyle(.secondary)
            Stepper("", value: $value, in: range, step: step)
                .labelsHidden()
                .onChange(of: value) { _, new in text = String(new) }
        }
    }

    private func commit() {
        guard let parsed = Int(text) else { text = String(value); return }
        value = max(range.lowerBound, min(parsed, range.upperBound))
        text = String(value)
    }
}

// MARK: - Dynamic type size picker

/// A row of "A" buttons of increasing size, matching the style used in
/// macOS System Settings → Displays → Text Size.
private struct DynamicTypeSizePicker: View {
    @Binding var selection: DynamicTypeSize

    private let steps = TextSizeStep.all

    var body: some View {
        HStack(spacing: 0) {
            ForEach(steps, id: \.size) { step in
                let isSelected = selection == step.size
                Button {
                    selection = step.size
                } label: {
                    Text("A")
                        .font(.system(size: step.pickerFontSize))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                        .background(isSelected ? Color.accentColor : Color.clear)
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
                if step.size != steps.last?.size {
                    Divider()
                }
            }
        }
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 6))
        .frame(maxWidth: 260)
    }
}

// MARK: - Opacity slider

/// A slider from 0 % to 100 % with a percentage label, used for chart dot brightness settings.
private struct OpacitySlider: View {
    @Binding var value: Double

    var body: some View {
        HStack {
            Slider(value: $value, in: 0...1, step: 0.05)
                .frame(maxWidth: 200)
            Text(value, format: .percent.precision(.fractionLength(0)))
                .scaledFont(size: 10, monospaced: true)
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)
        }
    }
}

// MARK: - Display memory

/// The share of the Mac's memory the display images may use, with what that is in bytes.
private struct DisplayMemorySlider: View {
    @Environment(AppSettings.self) private var settings

    private let physicalMemory = ProcessInfo.processInfo.physicalMemory

    var body: some View {
        @Bindable var settings = settings
        let percent = Binding<Double>(
            get: { Double(settings.displayMemoryPercent) },
            set: { settings.displayMemoryPercent = AppSettings.clampedDisplayMemoryPercent(Int($0.rounded())) })
        let bytes = Int64(AppSettings.displayMemoryBytes(percent: settings.displayMemoryPercent,
                                                         physicalMemory: physicalMemory))

        LabeledContent("Memory for display images") {
            HStack {
                Slider(value: percent,
                       in: Double(AppSettings.displayMemoryRange.lowerBound)...Double(AppSettings.displayMemoryRange.upperBound),
                       step: Double(AppSettings.displayMemoryStep))
                    .frame(maxWidth: 200)
                Text("""
                    \(settings.displayMemoryPercent) % — \(bytes.formatted(.byteCount(style: .memory))) of \
                    \(Int64(physicalMemory).formatted(.byteCount(style: .memory)))
                    """)
                    .scaledFont(size: 10, monospaced: true)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
        }
        Text("""
            Above this, the frames you looked at least recently give up their display images and are drawn again \
            from their files when you return to them. Thumbnails and metrics always stay.
            """)
            .scaledFont(size: 10)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Selection shortcut row

/// A row showing a modifier picker (⌘ / ⌘⇧) alongside a key recorder.
private struct SelectionShortcutRow: View {
    @Binding var keyString: String
    @Binding var usesShift: Bool
    var conflictingKeys: [Binding<String>]

    var body: some View {
        HStack(spacing: 6) {
            Picker("Modifier", selection: $usesShift) {
                Text("⌘").tag(false)
                Text("⌘⇧").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 80)
            KeyRecorderButton(keyString: $keyString, conflictingKeys: conflictingKeys)
        }
    }
}
