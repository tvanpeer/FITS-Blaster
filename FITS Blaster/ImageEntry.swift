//
//  ImageEntry.swift
//  FITS Blaster
//

import Foundation
import AppKit

/// Represents a single loaded FITS image entry with its processing state.
@Observable
@MainActor
final class ImageEntry: Identifiable {
    let id = UUID()
    var url: URL
    let originalURL: URL
    let fileName: String

    var displayImage: NSImage? {
        didSet {
            // A new image ends a drop, and a failed redraw with it.
            if displayImage != nil {
                droppedDisplay = nil
                redrawFailed = false
            }
            displayMemory?.imagesChanged(self)
        }
    }
    var thumbnail: NSImage?
    var imageInfo: String = ""
    var isProcessing: Bool = true
    var isRejected: Bool = false
    var isFlipped: Bool = false
    var directoryBookmark: Data?
    var errorMessage: String?
    var metrics: FrameMetrics?

    /// Full set of ever-computed metric values — preserved across config toggle changes
    /// so re-enabling a metric never requires re-reading the FITS file.
    var cachedMetrics: FrameMetrics?

    var histogram: [Int]?
    /// The FITS header, with values cleaned by `FITSReader`. Setting it stores the facts
    /// derived from it once, so reading them is free; the chart reads `filterGroup` for
    /// every point on every cursor move (CODE_AUDIT §7.5a, about 5 ms per move with 355
    /// frames when it was recomputed).
    var headers: [String: String] = [:] {
        didSet {
            filterName = headers["FILTER"].flatMap { $0.isEmpty ? nil : $0 }
            filterGroup = FilterGroup.normalise(filterName)
            bayerPattern = BayerPattern.parse(from: headers)
        }
    }

    private(set) var filterName: String?
    private(set) var filterGroup: FilterGroup = FilterGroup.normalise(nil)
    private(set) var bayerPattern: BayerPattern?

    var isBayer: Bool { bayerPattern != nil }

    /// Percentile clip bounds computed during Phase A for greyscale (non-Bayer) images.
    var greyClips: GreyClips?

    /// Per-channel clip bounds computed during the grey-pass for Bayer images.
    var bayerClips: BayerClips?

    var cachedGreyscaleDisplay: NSImage? {
        didSet { displayMemory?.imagesChanged(self) }
    }
    var cachedGreyscaleThumb: NSImage?
    var cachedColourDisplay: NSImage? {
        didSet { displayMemory?.imagesChanged(self) }
    }
    var cachedColourThumb: NSImage?

    /// How the grey render was made (the display image of a mono frame, the
    /// `cachedGreyscaleDisplay` of a Bayer frame), so it can be made again from the file.
    var greyRecipe: DisplayRecipe?
    /// How `cachedColourDisplay` was made.
    var colourRecipe: DisplayRecipe?

    /// Set while the display images are dropped to stay within the memory budget.
    private(set) var droppedDisplay: DroppedDisplay?
    /// Drawing the dropped image again couldn't read the file; the next visit tries again.
    var redrawFailed = false
    /// Told when a display image comes or goes, so it can keep to its budget.
    @ObservationIgnored weak var displayMemory: DisplayMemoryBudget?
    @ObservationIgnored private var dropCount = 0

    /// The recipe of the image shown: the colour render's, or the grey render's.
    var shownRecipe: DisplayRecipe? {
        guard let displayImage else { return nil }
        if let colour = cachedColourDisplay, displayImage === colour { return colourRecipe }
        return greyRecipe
    }

    /// A display image was dropped and isn't being made by a batch: it can be drawn again.
    var needsRedraw: Bool { droppedDisplay != nil && displayImage == nil && !isProcessing }

    /// The bytes of the display images held (each image once).
    var displayBytes: Int {
        var seen: [NSImage] = []
        var bytes = 0
        for image in [displayImage, cachedGreyscaleDisplay, cachedColourDisplay].compactMap(\.self)
        where !seen.contains(where: { $0 === image }) {
            seen.append(image)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                bytes += cg.bytesPerRow * cg.height
            }
        }
        return bytes
    }

    /// Drops the display image and the cached grey and colour renders. Thumbnails, recipes,
    /// metrics and headers stay; `redraw` brings the shown image back from the file.
    func dropDisplayImages() {
        guard let image = displayImage, let recipe = shownRecipe else { return }
        let isColour = cachedColourDisplay.map { $0 === image } ?? false
        let placeholder = thumbnail?.cgImage(forProposedRect: nil, context: nil, hints: nil)
            .map { NSImage(cgImage: $0, size: image.size) }
        dropCount += 1
        displayImage = nil
        cachedGreyscaleDisplay = nil
        cachedColourDisplay = nil
        droppedDisplay = DroppedDisplay(recipe: recipe, isColour: isColour,
                                        placeholder: placeholder, token: dropCount)
    }

    /// Forgets a drop: a batch makes the images again (a new display size).
    func forgetDrop() {
        droppedDisplay = nil
        redrawFailed = false
    }

    /// Shows a dropped image drawn again, in the cache it came from.
    func restoreDisplay(_ image: NSImage, isColour: Bool) {
        if isColour {
            cachedColourDisplay = image
        } else if isBayer {
            cachedGreyscaleDisplay = image
        }
        displayImage = image
    }

    /// Relative path from the opened root folder to this file's parent directory.
    var subfolderPath: String = ""

    /// Display name of the root folder this entry was loaded from.
    var rootFolderName: String = ""

    /// Fully qualified folder path combining root folder name and subfolder path.
    var qualifiedFolderPath: String {
        if rootFolderName.isEmpty { return subfolderPath }
        if subfolderPath.isEmpty  { return rootFolderName }
        return "\(rootFolderName)/\(subfolderPath)"
    }

    init(url: URL, originalURL: URL? = nil, directoryBookmark: Data? = nil) {
        self.url = url
        self.originalURL = originalURL ?? url
        self.fileName = url.lastPathComponent
        self.directoryBookmark = directoryBookmark
    }
}
