//
//  ViewerState.swift
//  FITS Blaster
//
//  State of the image viewer that changes while looking at frames: display contrast,
//  playback, the viewport and the zoom anchor. Kept out of ImageStore so views that only
//  read the session (sidebar, chart) aren't invalidated by scrolling or playback.
//

import SwiftUI

@Observable
@MainActor
final class ViewerState {

    // MARK: - Display adjustment

    /// Contrast multiplier applied to the displayed image (0.5 to 3.0, 1.0 = normal).
    /// Higher values produce a stronger stretch; maps to SwiftUI's .contrast() modifier.
    /// Resets with the session.
    var displayStretch: Double = 1.0

    // MARK: - Playback

    /// Whether the auto-play slideshow is currently running.
    private(set) var isPlaying: Bool = false

    /// The active playback task — stored here (not in a view) so it survives SwiftUI view rebuilds.
    @ObservationIgnored private var playbackTask: Task<Void, Never>?

    /// Starts auto-advancing through the visible entries of `store` at the interval in `settings`.
    func startPlayback(store: ImageStore, settings: AppSettings) {
        stopPlayback()
        isPlaying = true
        playbackTask = Task { @MainActor [weak self, weak store] in
            while let self, let store, !Task.isCancelled, self.isPlaying {
                try? await Task.sleep(for: .milliseconds(Int(settings.playbackSpeed * 1000)))
                guard !Task.isCancelled, self.isPlaying else { break }
                if !self.advancePlayback(store: store, settings: settings) {
                    self.isPlaying = false
                }
            }
        }
    }

    /// One playback step: selects the entry after the cursor in sidebar order.
    /// Returns false when there is no next entry (or no cursor), which ends playback.
    func advancePlayback(store: ImageStore, settings: AppSettings) -> Bool {
        let ordered = store.sidebarNavigationEntries(isSimpleMode: settings.isSimpleMode)
        guard let current = store.selectedEntry,
              let idx = ordered.firstIndex(where: { $0.id == current.id }) else {
            return false
        }
        let nextIdx = idx + 1
        guard nextIdx < ordered.count else { return false }
        store.selectedEntry = ordered[nextIdx]
        return true
    }

    /// Stops playback and cancels the timer task.
    func stopPlayback() {
        isPlaying = false
        playbackTask?.cancel()
        playbackTask = nil
    }

    // MARK: - Viewport tracking

    /// The visible area of the current image as a fraction of its full content size (0–1).
    /// Updated by the image viewer as the user scrolls or zooms (`updateViewport`).
    /// Used by the sidebar thumbnail to draw the viewport indicator box.
    private(set) var viewportFraction: CGRect = ViewerState.fullFrame

    /// Fractional position of the viewport center (0–1 in both axes).
    /// Stored so that navigating to the next image can restore the same relative scroll position.
    /// Only read when the frame changes, so not observed (performance audit P4).
    @ObservationIgnored private(set) var viewportCenter: CGPoint = .zero

    /// A change of the viewport fraction smaller than this (in every component) is not
    /// written: it moves the viewport box by less than a pixel on any thumbnail, and each
    /// write redraws the cursor's thumbnail (performance audit P4).
    static let viewportFractionTolerance: CGFloat = 0.001

    static let fullFrame = CGRect(x: 0, y: 0, width: 1, height: 1)

    /// Records the scroll geometry of the image viewer.
    func updateViewport(_ geo: ViewportGeometry) {
        let cw = geo.contentSize.width, ch = geo.contentSize.height
        guard cw > 0, ch > 0 else { return }
        let fraction = CGRect(
            x: max(0, geo.contentOffset.x / cw),
            y: max(0, geo.contentOffset.y / ch),
            width:  min(1, geo.containerSize.width  / cw),
            height: min(1, geo.containerSize.height / ch)
        )
        if Self.isVisibleChange(from: viewportFraction, to: fraction) {
            viewportFraction = fraction
        }
        viewportCenter = CGPoint(
            x: (geo.contentOffset.x + geo.containerSize.width  / 2) / cw,
            y: (geo.contentOffset.y + geo.containerSize.height / 2) / ch
        )
    }

    private static func isVisibleChange(from old: CGRect, to new: CGRect) -> Bool {
        let t = viewportFractionTolerance
        return abs(new.minX - old.minX) >= t || abs(new.minY - old.minY) >= t
            || abs(new.width - old.width) >= t || abs(new.height - old.height) >= t
    }

    // MARK: - Key repeat

    /// Set by the key monitor for every key press: true while a key is held down
    /// (auto-repeat). The sidebar then scrolls to the cursor without animation
    /// (performance audit P5). Not observed: only read when the cursor moves.
    @ObservationIgnored var isKeyRepeat = false

    /// Returns whether the last key press was an auto-repeat, and clears it, so a later
    /// click scrolls with animation again.
    func takeKeyRepeat() -> Bool {
        defer { isKeyRepeat = false }
        return isKeyRepeat
    }

    // MARK: - Zoom anchor

    /// Normalized image coordinates (0–1) of the user-set zoom anchor.
    /// When non-nil, zoom changes center on this point rather than the viewport center.
    /// Persists across image navigation (same field → same sky position).
    var zoomAnchor: CGPoint? = nil

    /// Toggled by the scope button to ask ImageViewer to scroll the anchor into the centre.
    var centerOnAnchorTrigger: Bool = false

    /// Toggled by the "Fit" button to ask ImageViewer to scale the image to fill the container.
    var fitToContainerTrigger: Bool = false

    // MARK: - Reset

    /// Restores the defaults; called together with `ImageStore.reset()`.
    func reset() {
        displayStretch = 1.0
        stopPlayback()
        viewportFraction = Self.fullFrame
        viewportCenter = .zero
        zoomAnchor = nil
    }
}
