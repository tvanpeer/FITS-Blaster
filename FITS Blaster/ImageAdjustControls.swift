//
//  ImageAdjustControls.swift
//  FITS Blaster
//

import SwiftUI

/// A compact strip of session-level display sliders: zoom, brightness, and stretch.
/// Shown below the image viewer; resets on session reset but zoom persists across launches.
struct ImageAdjustControls: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private var isDefault: Bool {
        settings.zoomScale == 1.0 && settings.targetBackground == 0.25
            && store.displayStretch == 1.0 && store.zoomAnchor == nil
    }

    var body: some View {
        HStack(spacing: 12) {
            ZoomControl()
            Divider().frame(height: 14)
            TargetBackgroundControl()
            Divider().frame(height: 14)
            StretchControl()

            Button("Defaults", systemImage: "arrow.counterclockwise") {
                settings.zoomScale = 1.0
                settings.targetBackground = 0.25
                store.displayStretch = 1.0
                store.zoomAnchor = nil
            }
            .disabled(isDefault)
            .tooltip("Reset all display adjustments")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// Each slider control is its own struct so that value changes only re-render
/// that single control, not the entire HStack. This prevents tooltip hover
/// state from being reset when any slider value changes.
struct ZoomControl: View {
    @Environment(AppSettings.self) private var settings
    @Environment(ImageStore.self) private var store

    var body: some View {
        @Bindable var bound = settings
        Button("Zoom", systemImage: "plus.magnifyingglass") {
            settings.zoomScale = 1.0
        }
        .tooltip("Zoom — click to reset")
        Slider(value: $bound.zoomScale, in: 0.25...4.0)
            .frame(width: 80)
        Button("\(settings.zoomScale, format: .number.precision(.fractionLength(1)))×") {
            settings.zoomScale = 1.0
        }
        .buttonStyle(.borderless)
        .scaledFont(size: 10, monospaced: true)
        .frame(width: 34, alignment: .leading)
        .tooltip("Click for 1:1 (100%)")
        .disabled(settings.zoomScale == 1.0)
        Button("Fit", systemImage: "arrow.up.left.and.arrow.down.right") {
            store.fitToContainerTrigger.toggle()
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .tooltip("Zoom to fit")
        if store.zoomAnchor != nil {
            Button("Centre on anchor", systemImage: "scope") {
                store.centerOnAnchorTrigger.toggle()
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .foregroundStyle(.tint)
            .tooltip("Zoom anchor active — click to centre viewport on it")
        }
    }
}

struct StretchControl: View {
    @Environment(ImageStore.self) private var store

    var body: some View {
        @Bindable var bound = store
        Button("Stretch", systemImage: "waveform.path.ecg") {
            store.displayStretch = 1.0
        }
        .tooltip("Stretch — click to reset")
        Slider(value: $bound.displayStretch, in: 0.5...3.0)
            .frame(width: 80)
    }
}
