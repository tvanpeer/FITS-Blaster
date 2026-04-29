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

        // Plain keys (no modifier) — only conflict with each other.
        let plainKeys: [(label: String, key: Binding<String>)] = [
            ("First Image",             $settings.firstImageKey),
            ("Last Image",              $settings.lastImageKey),
            ("Previous Image",          $settings.prevImageKey),
            ("Next Image",              $settings.nextImageKey),
            ("Reject",                  $settings.rejectKey),
            ("Undo",                    $settings.undoKey),
            ("Flag / Deflag",           $settings.flagKey),
            ("Deflag All",              $settings.deflagAllKey),
            ("Toggle Simple/Geek Mode", $settings.toggleModeKey),
            ("Remove from List",        $settings.removeKey),
            ("Toggle Colour Images",    $settings.debayerKey),
            ("Play / Pause",            $settings.playPauseKey),
            ("Flip 180\u{00B0}",            $settings.flipKey),
        ]
        // Cmd keys — only conflict with each other.
        let cmdKeys: [(label: String, key: Binding<String>)] = [
            ("Select All",              $settings.selectAllKey),
            ("Deselect All",            $settings.deselectAllKey),
            ("Inverse Selection",       $settings.invertSelectionKey),
            ("Select All Rejected",     $settings.selectAllRejectedKey),
        ]

        Form {
            Section("Navigation") {
                LabeledContent("First Image") {
                    KeyRecorderButton(keyString: $settings.firstImageKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "First Image" }.map(\.key))
                }
                LabeledContent("Last Image") {
                    KeyRecorderButton(keyString: $settings.lastImageKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Last Image" }.map(\.key))
                }
                LabeledContent("Previous Image") {
                    KeyRecorderButton(keyString: $settings.prevImageKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Previous Image" }.map(\.key))
                }
                LabeledContent("Next Image") {
                    KeyRecorderButton(keyString: $settings.nextImageKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Next Image" }.map(\.key))
                }
                Toggle("Single key reject/undo (toggle)", isOn: $settings.useToggleReject)
                LabeledContent(settings.useToggleReject ? "Reject / Undo" : "Reject Image") {
                    KeyRecorderButton(keyString: $settings.rejectKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Reject" }.map(\.key))
                }
                if !settings.useToggleReject {
                    LabeledContent("Undo Rejection") {
                        KeyRecorderButton(keyString: $settings.undoKey,
                                          conflictingKeys: plainKeys.filter { $0.label != "Undo" }.map(\.key))
                    }
                }
                LabeledContent("Flag / Deflag") {
                    KeyRecorderButton(keyString: $settings.flagKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Flag / Deflag" }.map(\.key))
                }
                LabeledContent("Deflag All") {
                    KeyRecorderButton(keyString: $settings.deflagAllKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Deflag All" }.map(\.key))
                }
                LabeledContent("Toggle Simple/Geek Mode") {
                    KeyRecorderButton(keyString: $settings.toggleModeKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Toggle Simple/Geek Mode" }.map(\.key))
                }
                LabeledContent("Remove from List") {
                    KeyRecorderButton(keyString: $settings.removeKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Remove from List" }.map(\.key))
                }
                LabeledContent("Toggle Colour Images") {
                    KeyRecorderButton(keyString: $settings.debayerKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Toggle Colour Images" }.map(\.key))
                }
                LabeledContent("Play / Pause") {
                    KeyRecorderButton(keyString: $settings.playPauseKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Play / Pause" }.map(\.key))
                }
                LabeledContent("Flip 180\u{00B0}") {
                    KeyRecorderButton(keyString: $settings.flipKey,
                                      conflictingKeys: plainKeys.filter { $0.label != "Flip 180\u{00B0}" }.map(\.key))
                }
            }

            Section("Selection") {
                LabeledContent("Select All") {
                    SelectionShortcutRow(
                        keyString: $settings.selectAllKey,
                        usesShift: $settings.selectAllShift,
                        conflictingKeys: cmdKeys.filter { $0.label != "Select All" }.map(\.key)
                    )
                }
                LabeledContent("Deselect All") {
                    SelectionShortcutRow(
                        keyString: $settings.deselectAllKey,
                        usesShift: $settings.deselectAllShift,
                        conflictingKeys: cmdKeys.filter { $0.label != "Deselect All" }.map(\.key)
                    )
                }
                LabeledContent("Inverse Selection") {
                    SelectionShortcutRow(
                        keyString: $settings.invertSelectionKey,
                        usesShift: $settings.invertSelectionShift,
                        conflictingKeys: cmdKeys.filter { $0.label != "Inverse Selection" }.map(\.key)
                    )
                }
                LabeledContent("Select All Rejected") {
                    SelectionShortcutRow(
                        keyString: $settings.selectAllRejectedKey,
                        usesShift: $settings.selectAllRejectedShift,
                        conflictingKeys: cmdKeys.filter { $0.label != "Select All Rejected" }.map(\.key)
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
            Section("Software Updates") {
                Toggle("Receive beta releases", isOn: $settings.useBetaUpdateChannel)
                Text("When enabled, \"Check for Updates\" looks at the beta channel. Beta builds get new features first but may contain bugs. Turn this off to stay on stable releases only.")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
            #endif

        }
        .formStyle(.grouped)
    }
}

// MARK: - Image Display tab

struct ImageDisplayTab: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store

    @State private var displaySize: Int = 1024
    @State private var thumbnailSize: Int = 120
    @State private var displaySizeText: String = "1024"
    @State private var thumbnailSizeText: String = "120"

    private var parsedDisplaySize: Int {
        Int(displaySizeText).map { max(512, min($0, 8192)) } ?? displaySize
    }
    private var parsedThumbnailSize: Int {
        Int(thumbnailSizeText).map { max(40, min($0, 400)) } ?? thumbnailSize
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
                              range: 512...8192, step: 128)
                }
                LabeledContent("Max thumbnail size") {
                    SizeField(value: $thumbnailSize, text: $thumbnailSizeText,
                              range: 40...400, step: 20)
                }
                HStack {
                    Spacer()
                    Button("Apply") { apply() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isDirty)
                }
            }

            Section("Colour Images") {
                Toggle("Debayer colour FITS images", isOn: $settings.debayerColorImages)
                Text("When enabled, images with a Bayer CFA pattern (BAYERPAT/COLORTYP/CFA_PAT header) are displayed in colour using GPU-accelerated bilinear debayering. Requires Reprocess All to take effect on already-loaded images.")
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
                Text("Controls how dim rejected and non-flagged dots appear in the session chart when a flagged set is active. Flagged and cursor dots are always full brightness.")
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

        settings.maxDisplaySize   = clampedDisplay
        settings.maxThumbnailSize = clampedThumb

        if !store.entries.isEmpty {
            store.regenerateSizes(settings: settings)
        }

        resizeMainWindow(toFit: clampedDisplay)
    }

    private func resizeMainWindow(toFit maxSize: Int) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        let sidebarW:   CGFloat = 165
        let inspectorW: CGFloat = settings.showInspector ? 260 : 0
        let chromeH:    CGFloat = 90

        let wantedW = sidebarW + CGFloat(maxSize) + inspectorW + 20
        let wantedH = CGFloat(maxSize) + chromeH

        let newW = min(wantedW, visible.width)
        let newH = min(wantedH, visible.height)

        guard let window = NSApplication.shared.windows.first(where: {
            $0.isVisible && $0.title != "Settings"
        }) else { return }

        var frame = window.frame
        frame.size.width  = max(newW, settings.showInspector ? 960 : 700)
        frame.size.height = max(newH, 400)
        frame.origin.y    = window.frame.maxY - frame.size.height
        frame = frame.intersection(visible)

        window.setFrame(frame, display: true, animate: true)
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

    var body: some View {
        HStack {
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .frame(width: 70)
                .onSubmit { commit() }
            Text("px")
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

    /// Display font size for each step — purely visual, not tied to actual pt values.
    private let steps: [(size: DynamicTypeSize, fontSize: CGFloat)] = [
        (.xSmall,   10),
        (.small,    12),
        (.medium,   14),
        (.large,    17),
        (.xLarge,   20),
        (.xxLarge,  23),
        (.xxxLarge, 27),
    ]

    var body: some View {
        HStack(spacing: 0) {
            ForEach(steps, id: \.size) { step in
                let isSelected = selection == step.size
                Button {
                    selection = step.size
                } label: {
                    Text("A")
                        .font(.system(size: step.fontSize))
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
