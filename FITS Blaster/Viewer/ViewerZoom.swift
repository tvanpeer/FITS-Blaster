//
//  ViewerZoom.swift
//  FITS Blaster
//
//  The zoom steps and the pan movement of the image viewer's keyboard shortcuts, kept
//  apart from the view so they can be tested.
//

import CoreGraphics

enum ViewerZoom {

    /// The zoom slider's range; the shortcuts stay within it.
    static let range: ClosedRange<Double> = 0.25...4.0
    /// Zoom in or out multiplies or divides by this.
    static let step = 1.25
    /// A tap on a pan key moves this share of the visible area (the menu's Pan items too)…
    static let panStep: CGFloat = 1.0 / 4
    /// …and while the key is held, each press and repeat this much smaller one, so holding
    /// it scrolls (about half a view per second at the default key repeat) without a jump.
    static let panRepeatStep: CGFloat = 1.0 / 20

    static func zoomedIn(from zoom: Double) -> Double {
        clamped(zoom * step)
    }

    static func zoomedOut(from zoom: Double) -> Double {
        clamped(zoom / step)
    }

    static func clamped(_ zoom: Double) -> Double {
        min(range.upperBound, max(range.lowerBound, zoom))
    }

    /// The zoom at which the whole image fits the container, within the slider's range;
    /// nil without a size.
    static func fitScale(image: CGSize, container: CGSize) -> Double? {
        guard image.width > 0, image.height > 0, container.width > 0, container.height > 0 else { return nil }
        return clamped(min(container.width / image.width, container.height / image.height))
    }

    /// The scroll offset after moving `share` of the visible area in `direction`, kept
    /// within the image. In a direction where the image fits, nothing moves.
    static func pannedOffset(_ offset: CGPoint, contentSize: CGSize, containerSize: CGSize,
                             direction: PanDirection, share: CGFloat) -> CGPoint {
        let maxX = max(0, contentSize.width  - containerSize.width)
        let maxY = max(0, contentSize.height - containerSize.height)
        var x = offset.x, y = offset.y
        switch direction {
        case .left:  x -= containerSize.width  * share
        case .right: x += containerSize.width  * share
        case .up:    y -= containerSize.height * share
        case .down:  y += containerSize.height * share
        }
        return CGPoint(x: min(maxX, max(0, x)), y: min(maxY, max(0, y)))
    }
}
