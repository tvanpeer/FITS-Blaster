//
//  ViewerStateTests.swift
//  FITS Blaster Tests
//
//  Tests for ViewerState: playback steps through the sidebar order, Reset restores the
//  defaults, and viewport updates write the fraction only on a visible change (P4).
//

import Foundation
import Observation
import Synchronization
import Testing
@testable import FITS_Blaster

@MainActor
struct ViewerStateTests {

    // MARK: - Helpers

    private func makeStore(count: Int) -> ImageStore {
        let store = ImageStore()
        for _ in 0..<count {
            let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(UUID().uuidString).fits"))
            entry.isProcessing = false
            store.entries.append(entry)
        }
        store.updateGroupStatistics()
        return store
    }

    private func geometry(offset: CGPoint, content: CGSize, container: CGSize) -> ViewportGeometry {
        ViewportGeometry(contentOffset: offset, contentSize: content, containerSize: container)
    }

    /// True when running `change` notifies observers of `viewportFraction`.
    private func notifiesFraction(_ viewer: ViewerState, _ change: () -> Void) -> Bool {
        let notified = Mutex(false)
        withObservationTracking {
            _ = viewer.viewportFraction
        } onChange: {
            notified.withLock { $0 = true }
        }
        change()
        return notified.withLock { $0 }
    }

    // MARK: - Playback

    @Test("A playback step selects the next entry in sidebar order, and ends after the last")
    func playbackSteps() {
        let store = makeStore(count: 3)
        let settings = AppSettings()
        let viewer = ViewerState()
        let ordered = store.sidebarNavigationEntries(isSimpleMode: settings.isSimpleMode)
        store.selectedEntry = ordered[0]

        #expect(viewer.advancePlayback(store: store, settings: settings))
        #expect(store.selectedEntry === ordered[1])
        #expect(viewer.advancePlayback(store: store, settings: settings))
        #expect(store.selectedEntry === ordered[2])
        #expect(!viewer.advancePlayback(store: store, settings: settings))
        #expect(store.selectedEntry === ordered[2])
    }

    @Test("Without a cursor a playback step does nothing and ends playback")
    func playbackWithoutCursor() {
        let store = makeStore(count: 2)
        store.selectedEntry = nil
        #expect(!ViewerState().advancePlayback(store: store, settings: AppSettings()))
        #expect(store.selectedEntry == nil)
    }

    @Test("Start and stop set isPlaying")
    func startStop() {
        let store = makeStore(count: 2)
        store.selectedEntry = store.entries.first
        let viewer = ViewerState()
        viewer.startPlayback(store: store, settings: AppSettings())
        #expect(viewer.isPlaying)
        viewer.stopPlayback()
        #expect(!viewer.isPlaying)
    }

    // MARK: - Reset

    @Test("Reset restores the defaults and stops playback")
    func resetRestoresDefaults() {
        let store = makeStore(count: 2)
        store.selectedEntry = store.entries.first
        let viewer = ViewerState()
        viewer.displayStretch = 2.0
        viewer.zoomAnchor = CGPoint(x: 0.3, y: 0.7)
        viewer.updateViewport(geometry(offset: CGPoint(x: 500, y: 250),
                                       content: CGSize(width: 2000, height: 1000),
                                       container: CGSize(width: 1000, height: 500)))
        viewer.startPlayback(store: store, settings: AppSettings())

        viewer.reset()

        #expect(viewer.displayStretch == 1.0)
        #expect(viewer.zoomAnchor == nil)
        #expect(viewer.viewportFraction == ViewerState.fullFrame)
        #expect(viewer.viewportCenter == .zero)
        #expect(!viewer.isPlaying)
    }

    // MARK: - Viewport

    @Test("The viewport fraction and centre follow the scroll geometry")
    func viewportFromGeometry() {
        let viewer = ViewerState()
        viewer.updateViewport(geometry(offset: CGPoint(x: 500, y: 250),
                                       content: CGSize(width: 2000, height: 1000),
                                       container: CGSize(width: 1000, height: 500)))
        #expect(viewer.viewportFraction == CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))
        #expect(viewer.viewportCenter == CGPoint(x: 0.5, y: 0.5))
    }

    @Test("A container larger than the content clamps the fraction to the full frame")
    func viewportClamped() {
        let viewer = ViewerState()
        viewer.updateViewport(geometry(offset: CGPoint(x: -10, y: -10),
                                       content: CGSize(width: 500, height: 500),
                                       container: CGSize(width: 1000, height: 800)))
        #expect(viewer.viewportFraction == ViewerState.fullFrame)
    }

    @Test("An empty content size is ignored")
    func viewportEmptyContent() {
        let viewer = ViewerState()
        viewer.updateViewport(geometry(offset: .zero, content: .zero,
                                       container: CGSize(width: 1000, height: 500)))
        #expect(viewer.viewportFraction == ViewerState.fullFrame)
        #expect(viewer.viewportCenter == .zero)
    }

    @Test("A change below the tolerance isn't written; the centre still is")
    func viewportTinyChangeNotWritten() {
        let viewer = ViewerState()
        let content = CGSize(width: 10_000, height: 10_000)
        let container = CGSize(width: 1000, height: 1000)
        viewer.updateViewport(geometry(offset: CGPoint(x: 1000, y: 1000), content: content, container: container))
        let written = viewer.viewportFraction

        // 5 points of 10 000 = 0.0005, below the tolerance of 0.001.
        let notified = notifiesFraction(viewer) {
            viewer.updateViewport(geometry(offset: CGPoint(x: 1005, y: 1000), content: content, container: container))
        }
        #expect(!notified)
        #expect(viewer.viewportFraction == written)
        #expect(viewer.viewportCenter.x == CGFloat(1005 + 500) / 10_000)
    }

    @Test("A visible change is written and notifies observers")
    func viewportVisibleChangeWritten() {
        let viewer = ViewerState()
        let content = CGSize(width: 10_000, height: 10_000)
        let container = CGSize(width: 1000, height: 1000)
        viewer.updateViewport(geometry(offset: CGPoint(x: 1000, y: 1000), content: content, container: container))

        // 20 points of 10 000 = 0.002, above the tolerance.
        let notified = notifiesFraction(viewer) {
            viewer.updateViewport(geometry(offset: CGPoint(x: 1020, y: 1000), content: content, container: container))
        }
        #expect(notified)
        #expect(viewer.viewportFraction.minX == 0.102)
    }

    @Test("The same geometry again doesn't notify observers")
    func viewportUnchangedNotWritten() {
        let viewer = ViewerState()
        let geo = geometry(offset: CGPoint(x: 500, y: 250),
                           content: CGSize(width: 2000, height: 1000),
                           container: CGSize(width: 1000, height: 500))
        viewer.updateViewport(geo)
        #expect(!notifiesFraction(viewer) { viewer.updateViewport(geo) })
    }
}
