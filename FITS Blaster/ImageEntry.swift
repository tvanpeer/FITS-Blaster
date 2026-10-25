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

    var displayImage: NSImage?
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

    var cachedGreyscaleDisplay: NSImage?
    var cachedGreyscaleThumb: NSImage?
    var cachedColourDisplay: NSImage?
    var cachedColourThumb: NSImage?

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
