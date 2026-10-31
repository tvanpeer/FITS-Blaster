//
//  ViewerZoomTests.swift
//  FITS Blaster Tests
//
//  The zoom steps and pan movement of the viewer's keyboard shortcuts (ViewerZoom).
//

import CoreGraphics
import Testing
@testable import FITS_Blaster

struct ViewerZoomTests {

    @Test("Zoom in and out step by ×1.25 and stay within the slider's range")
    func zoomSteps() {
        #expect(ViewerZoom.zoomedIn(from: 1.0) == 1.25)
        #expect(ViewerZoom.zoomedOut(from: 1.25) == 1.0)
        #expect(ViewerZoom.zoomedIn(from: 3.9) == 4.0)
        #expect(ViewerZoom.zoomedIn(from: 4.0) == 4.0)
        #expect(ViewerZoom.zoomedOut(from: 0.3) == 0.25)
        #expect(ViewerZoom.zoomedOut(from: 0.25) == 0.25)
    }

    @Test("Zoom to fit: the whole image in the container, within the range; nil without a size")
    func fit() {
        #expect(ViewerZoom.fitScale(image: CGSize(width: 2000, height: 1000),
                                    container: CGSize(width: 1000, height: 800)) == 0.5)
        #expect(ViewerZoom.fitScale(image: CGSize(width: 100, height: 100),
                                    container: CGSize(width: 1000, height: 800)) == 4.0)
        #expect(ViewerZoom.fitScale(image: .zero, container: CGSize(width: 1000, height: 800)) == nil)
        #expect(ViewerZoom.fitScale(image: CGSize(width: 100, height: 100), container: .zero) == nil)
    }

    private let content = CGSize(width: 4000, height: 3000)
    private let container = CGSize(width: 1000, height: 800)

    @Test("A full step pans a quarter of the view, a small one a twentieth")
    func panSteps() {
        let start = CGPoint(x: 1000, y: 1000)
        #expect(ViewerZoom.pannedOffset(start, contentSize: content, containerSize: container,
                                        direction: .right, share: ViewerZoom.panStep) == CGPoint(x: 1250, y: 1000))
        #expect(ViewerZoom.pannedOffset(start, contentSize: content, containerSize: container,
                                        direction: .down, share: ViewerZoom.panStep) == CGPoint(x: 1000, y: 1200))
        #expect(ViewerZoom.pannedOffset(start, contentSize: content, containerSize: container,
                                        direction: .left, share: ViewerZoom.panRepeatStep) == CGPoint(x: 950, y: 1000))
        #expect(ViewerZoom.pannedOffset(start, contentSize: content, containerSize: container,
                                        direction: .up, share: ViewerZoom.panRepeatStep) == CGPoint(x: 1000, y: 960))
    }

    @Test("Panning stops at the image's edges")
    func panEdges() {
        #expect(ViewerZoom.pannedOffset(CGPoint(x: 100, y: 50), contentSize: content, containerSize: container,
                                        direction: .left, share: ViewerZoom.panStep) == CGPoint(x: 0, y: 50))
        #expect(ViewerZoom.pannedOffset(CGPoint(x: 100, y: 50), contentSize: content, containerSize: container,
                                        direction: .up, share: ViewerZoom.panStep) == CGPoint(x: 100, y: 0))
        #expect(ViewerZoom.pannedOffset(CGPoint(x: 2900, y: 2100), contentSize: content, containerSize: container,
                                        direction: .right, share: ViewerZoom.panStep) == CGPoint(x: 3000, y: 2100))
        #expect(ViewerZoom.pannedOffset(CGPoint(x: 2900, y: 2100), contentSize: content, containerSize: container,
                                        direction: .down, share: ViewerZoom.panStep) == CGPoint(x: 2900, y: 2200))
    }

    @Test("When the image fits, panning doesn't move it")
    func panWhenFitting() {
        let small = CGSize(width: 800, height: 600)
        for direction in [PanDirection.left, .right, .up, .down] {
            #expect(ViewerZoom.pannedOffset(.zero, contentSize: small, containerSize: container,
                                            direction: direction, share: ViewerZoom.panStep) == .zero)
        }
    }
}
