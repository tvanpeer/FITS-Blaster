//
//  PanDirection.swift
//  FITS Blaster
//

/// Which way a pan shortcut (⌥ + arrow key) moves the view of the image.
enum PanDirection: Equatable, Sendable {
    case left, right, up, down
}
