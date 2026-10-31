//
//  PanKeysTests.swift
//  FITS Blaster Tests
//
//  The pan keys (⌥ + arrow): a tap moves a quarter of the view, holding the key scrolls in
//  small steps from the first press on, without a jump (ViewerState.panKeyDown/panKeyUp).
//

import CoreGraphics
import Testing
@testable import FITS_Blaster

@MainActor
struct PanKeysTests {

    @Test("A tap: a small step, then the rest of a quarter on release")
    func tap() {
        let viewer = ViewerState()
        viewer.panKeyDown(.right, isRepeat: false)
        #expect(viewer.panRequest?.share == ViewerZoom.panRepeatStep)
        #expect(viewer.panRequest?.direction == .right)
        viewer.panKeyUp(.right)
        #expect(viewer.panRequest?.share == ViewerZoom.panStep - ViewerZoom.panRepeatStep)
        #expect(viewer.panRequest?.serial == 2)
    }

    @Test("Held down: small steps only, nothing more on release")
    func hold() {
        let viewer = ViewerState()
        viewer.panKeyDown(.down, isRepeat: false)
        viewer.panKeyDown(.down, isRepeat: true)
        viewer.panKeyDown(.down, isRepeat: true)
        #expect(viewer.panRequest?.share == ViewerZoom.panRepeatStep)
        #expect(viewer.panRequest?.serial == 3)
        viewer.panKeyUp(.down)
        #expect(viewer.panRequest?.serial == 3)
    }

    @Test("Releasing another arrow key, or one without a pan, moves nothing")
    func otherKeyUp() {
        let viewer = ViewerState()
        viewer.panKeyUp(.left)
        #expect(viewer.panRequest == nil)
        viewer.panKeyDown(.left, isRepeat: false)
        viewer.panKeyUp(.up)
        #expect(viewer.panRequest?.serial == 1)
    }

    @Test("The View menu's Pan item: one full step")
    func menu() {
        let viewer = ViewerState()
        viewer.pan(.up)
        #expect(viewer.panRequest?.share == ViewerZoom.panStep)
        #expect(viewer.panRequest?.direction == .up)
    }
}
