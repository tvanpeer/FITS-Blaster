//
//  SettingsView.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

// MARK: - Settings root

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        TabView {
            Tab("Keys", systemImage: "keyboard") {
                KeySettingsTab()
            }
            Tab("Images", systemImage: "photo.stack") {
                ImageSettingsTab()
            }
        }
        .frame(width: 500, height: 540)
    }
}

// MARK: - Keys tab

struct KeySettingsTab: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings

        Form {
            Section("Navigation") {
                LabeledContent("First Image") {
                    KeyRecorderButton(keyString: $settings.firstImageKey)
                }
                LabeledContent("Last Image") {
                    KeyRecorderButton(keyString: $settings.lastImageKey)
                }
                LabeledContent("Previous Image") {
                    KeyRecorderButton(keyString: $settings.prevImageKey)
                }
                LabeledContent("Next Image") {
                    KeyRecorderButton(keyString: $settings.nextImageKey)
                }
                LabeledContent("Reject Image") {
                    KeyRecorderButton(keyString: $settings.rejectKey)
                }
                LabeledContent("Undo Rejection") {
                    KeyRecorderButton(keyString: $settings.undoKey)
                }
            }

            Section("Rating") {
                LabeledContent("1 Star") {
                    KeyRecorderButton(keyString: $settings.rating1Key)
                }
                LabeledContent("2 Stars") {
                    KeyRecorderButton(keyString: $settings.rating2Key)
                }
                LabeledContent("3 Stars") {
                    KeyRecorderButton(keyString: $settings.rating3Key)
                }
                LabeledContent("4 Stars") {
                    KeyRecorderButton(keyString: $settings.rating4Key)
                }
                LabeledContent("5 Stars") {
                    KeyRecorderButton(keyString: $settings.rating5Key)
                }
                LabeledContent("Clear Rating") {
                    KeyRecorderButton(keyString: $settings.clearRatingKey)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Images tab

struct ImageSettingsTab: View {
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

        VStack(spacing: 0) {
            Form {
                Section("Appearance") {
                    Picker("Theme", selection: $settings.appearanceMode) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Sizes") {
                    LabeledContent("Max display size") {
                        SizeField(value: $displaySize, text: $displaySizeText,
                                  range: 512...8192, step: 128)
                    }
                    LabeledContent("Max thumbnail size") {
                        SizeField(value: $thumbnailSize, text: $thumbnailSizeText,
                                  range: 40...400, step: 20)
                    }
                }

            }
            .formStyle(.grouped)

            Divider()

            HStack {
                Spacer()
                Button("Apply") { apply() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!isDirty)
            }
            .padding()
        }
        .onAppear {
            displaySize        = settings.maxDisplaySize
            thumbnailSize      = settings.maxThumbnailSize
            displaySizeText    = String(settings.maxDisplaySize)
            thumbnailSizeText  = String(settings.maxThumbnailSize)
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
            store.reprocessAll(settings: settings)
        }

        resizeMainWindow(toFit: clampedDisplay)
    }

    private func resizeMainWindow(toFit maxSize: Int) {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame

        let sidebarW:   CGFloat = 165
        let inspectorW: CGFloat = settings.showInspector ? 260 : 0
        let chromeH:    CGFloat = 90   // toolbar + info bar

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
