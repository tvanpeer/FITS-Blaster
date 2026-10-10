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
    var headers: [String: String] = [:]

    var filterName: String? {
        guard let raw = headers["FILTER"] else { return nil }
        let cleaned = FITSReader.cleanHeaderString(raw)
        return cleaned.isEmpty ? nil : cleaned
    }

    var filterGroup: FilterGroup { FilterGroup.normalise(filterName) }

    var isBayer: Bool { BayerPattern.parse(from: headers) != nil }

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
