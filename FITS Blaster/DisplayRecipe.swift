//
//  DisplayRecipe.swift
//  FITS Blaster
//
//  How a display image was made: the kernel, its stretch values and the display size.
//  With it the image can be made again from its file with the same bytes, so a display
//  image can be dropped to stay within a memory budget (master-plan step 9f part 1).
//

import Foundation

enum DisplayRecipe: Sendable {
    /// Metal greyscale stretch with the image's own clips, as in Phase A. With a Bayer
    /// pattern the kernel bins 2×2.
    case grey(bayerPattern: BayerPattern?, maxDisplaySize: Int)
    /// Metal greyscale stretch with the shared clips of a (folder, filter) group, as in the
    /// grey normalisation pass.
    case sharedGrey(clips: GreyClips, bayerPattern: BayerPattern?, maxDisplaySize: Int)
    /// Metal debayer and stretch with the folder's shared clips, as in the colour render.
    case colour(rOffset: UInt32, clips: BayerClips, maxDisplaySize: Int)
    /// CPU stretch with the image's own clips, as in Phase A without Metal.
    case cpuGrey(maxDisplaySize: Int)
}
