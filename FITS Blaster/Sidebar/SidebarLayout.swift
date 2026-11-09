//
//  SidebarLayout.swift
//  FITS Blaster
//
//  The sidebar's width follows the thumbnail size setting (the shown width of a thumbnail):
//  thumbnail plus the cell padding, never narrower than its controls need, and draggable
//  wider with SidebarDivider. One place for these numbers, used by the layout and the
//  window minimum.
//

import CoreGraphics

enum SidebarLayout {

    /// The padding around a thumbnail in its cell, on each side (SwiftUI's default `.padding()`).
    static let cellPadding: CGFloat = 16

    /// The narrowest the sidebar gets: the Sort row, the "Show" picker (All / Flagged /
    /// Rejected) and the widest filter pill fit in it. Smaller thumbnails are centred.
    static let controlsWidth: CGFloat = 170

    /// How much wider than its natural width the sidebar can be dragged; the extra space is
    /// left around the thumbnails.
    static let extraDragWidth: CGFloat = 240

    /// The sidebar's natural width for thumbnails `thumbnailWidth` points wide.
    static func width(forThumbnail thumbnailWidth: Int) -> CGFloat {
        max(controlsWidth, CGFloat(thumbnailWidth) + 2 * cellPadding)
    }

    /// The widest the sidebar can be dragged for that thumbnail width.
    static func maxWidth(forThumbnail thumbnailWidth: Int) -> CGFloat {
        width(forThumbnail: thumbnailWidth) + extraDragWidth
    }
}
