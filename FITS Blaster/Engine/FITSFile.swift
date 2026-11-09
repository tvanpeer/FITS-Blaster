//
//  FITSFile.swift
//  FITS Blaster
//
//  The FITS file extensions, used by the folder scan, drops and the loading pipeline.
//

import Foundation

enum FITSFile {
    /// Lowercased extensions FITS Blaster opens.
    static let extensions: Set<String> = ["fits", "fit", "fts"]

    /// True when the URL has a FITS extension (any case).
    static func hasFITSExtension(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }
}
