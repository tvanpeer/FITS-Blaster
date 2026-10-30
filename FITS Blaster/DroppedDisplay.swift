//
//  DroppedDisplay.swift
//  FITS Blaster
//
//  A display image dropped to stay within the memory budget (master-plan 9f part 1):
//  how to make it again, and what the viewer shows until it is back.
//

import AppKit

struct DroppedDisplay {
    /// The recipe of the image that was shown.
    let recipe: DisplayRecipe
    /// The colour render was shown (a Bayer frame with Colour on), not the grey one.
    let isColour: Bool
    /// The thumbnail at the display image's size: blurry, but the zoom and fit stay the same.
    let placeholder: NSImage?
    /// Changes with every drop, so a redraw started for an earlier drop is recognised.
    let token: Int
}
