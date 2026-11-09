//
//  PlaybackControls.swift
//  FITS Blaster
//

import SwiftUI

/// Play/pause button with a speed slider, shown in the toolbar.
struct PlaybackControls: View {
    @Environment(ImageStore.self) private var store
    @Environment(ViewerState.self) private var viewer
    @Environment(AppSettings.self) private var settings

    @State private var wasPlayingBeforeDrag = false

    var body: some View {
        @Bindable var bound = settings

        Button(viewer.isPlaying ? "Pause" : "Play",
               systemImage: viewer.isPlaying ? "pause.fill" : "play.fill") {
            guard store.selectedEntry != nil else { return }
            if viewer.isPlaying {
                viewer.stopPlayback()
            } else {
                viewer.startPlayback(store: store, settings: settings)
            }
        }
        .disabled(store.selectedEntry == nil)
        .tooltip(viewer.isPlaying
                 ? "Pause slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))"
                 : "Play slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))")

        if viewer.isPlaying || wasPlayingBeforeDrag {
            Slider(value: $bound.playbackSpeed, in: 0.2...5.0, step: 0.1,
                   onEditingChanged: { editing in
                if editing {
                    wasPlayingBeforeDrag = viewer.isPlaying
                    viewer.stopPlayback()
                } else if wasPlayingBeforeDrag {
                    wasPlayingBeforeDrag = false
                    viewer.startPlayback(store: store, settings: settings)
                }
            })
                .frame(width: 60)
            Text("\(settings.playbackSpeed, format: .number.precision(.fractionLength(1)))s")
                .scaledFont(size: 10, monospaced: true)
                .frame(width: 28, alignment: .leading)
        }
    }
}
