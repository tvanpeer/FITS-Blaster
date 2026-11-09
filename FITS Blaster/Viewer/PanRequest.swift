//
//  PanRequest.swift
//  FITS Blaster
//

import CoreGraphics

/// A pan shortcut press for the image viewer, which keeps its scroll position itself.
/// `serial` makes every press a change, also two equal ones in a row.
struct PanRequest: Equatable {
    let direction: PanDirection
    /// How far, as a share of the visible area.
    let share: CGFloat
    let serial: Int
}
