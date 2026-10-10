//
//  PlaybackControls.swift
//  FITS Blaster
//

import SwiftUI

/// Play/pause button with a speed slider, shown in the toolbar.
struct PlaybackControls: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var wasPlayingBeforeDrag = false

    var body: some View {
        @Bindable var bound = settings

        Button(store.isPlaying ? "Pause" : "Play",
               systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
            guard store.selectedEntry != nil else { return }
            if store.isPlaying {
                store.stopPlayback()
            } else {
                store.startPlayback(settings: settings)
            }
        }
        .disabled(store.selectedEntry == nil)
        .tooltip(store.isPlaying
                 ? "Pause slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))"
                 : "Play slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))")

        if store.isPlaying || wasPlayingBeforeDrag {
            Slider(value: $bound.playbackSpeed, in: 0.2...5.0, step: 0.1,
                   onEditingChanged: { editing in
                if editing {
                    wasPlayingBeforeDrag = store.isPlaying
                    store.stopPlayback()
                } else if wasPlayingBeforeDrag {
                    wasPlayingBeforeDrag = false
                    store.startPlayback(settings: settings)
                }
            })
                .frame(width: 60)
            Text("\(settings.playbackSpeed, format: .number.precision(.fractionLength(1)))s")
                .scaledFont(size: 10, monospaced: true)
                .frame(width: 28, alignment: .leading)
        }
    }
}
