//
//  RejectedFolder.swift
//  FITS Blaster
//
//  The REJECTED folder next to the frames: its name, where a rejected frame goes and
//  where it came from. One place for the app, the folder scan, the load pipeline and the
//  CLI (step 11a, CODE_AUDIT §9.8).
//

import Foundation

enum RejectedFolder {

    /// The folder rejected frames are moved into, inside the frame's own folder.
    static let name = "REJECTED"

    /// The extension added to a rejected frame with "Rename rejected files" on, so that
    /// programs which take every FITS file in a folder tree (PixInsight's WBPP) skip it:
    /// x.fits → REJECTED/x.fits.rejected (step 16).
    static let renamedExtension = "rejected"

    /// True for a folder named REJECTED, in any case ("rejected", "Rejected").
    static func isRejectedFolder(name folderName: String) -> Bool {
        folderName.caseInsensitiveCompare(name) == .orderedSame
    }

    /// True when the file sits directly in a REJECTED folder.
    static func isInRejectedFolder(_ fileURL: URL) -> Bool {
        isRejectedFolder(name: fileURL.deletingLastPathComponent().lastPathComponent)
    }

    /// The REJECTED folder next to `fileURL`: …/Ha/x.fits → …/Ha/REJECTED/.
    static func folder(for fileURL: URL) -> URL {
        fileURL.deletingLastPathComponent().appending(path: name, directoryHint: .isDirectory)
    }

    /// Where a frame goes when it is rejected: …/Ha/x.fits → …/Ha/REJECTED/x.fits, or
    /// …/Ha/REJECTED/x.fits.rejected when `renames` (step 16).
    static func rejectedURL(for fileURL: URL, renames: Bool = false) -> URL {
        let name = fileURL.lastPathComponent
        return folder(for: fileURL).appending(component: renames ? "\(name).\(renamedExtension)" : name)
    }

    /// Where a frame in a REJECTED folder came from: …/Ha/REJECTED/x.fits → …/Ha/x.fits, and
    /// …/Ha/REJECTED/x.fits.rejected → …/Ha/x.fits (the added extension, in any case, removed).
    static func originalURL(for rejectedURL: URL) -> URL {
        rejectedURL.deletingLastPathComponent()   // …/Ha/REJECTED/
                   .deletingLastPathComponent()   // …/Ha/
                   .appending(component: originalName(of: rejectedURL))
    }

    /// The file name without the added extension: x.fits.rejected → x.fits; any other name as it is.
    static func originalName(of fileURL: URL) -> String {
        isRenamed(fileURL) ? fileURL.deletingPathExtension().lastPathComponent : fileURL.lastPathComponent
    }

    /// True for a name made by `rejectedURL(for:renames: true)`: a FITS name plus the added
    /// extension (x.fits.rejected, X.FIT.Rejected). Where the file is doesn't matter here.
    static func isRenamed(_ fileURL: URL) -> Bool {
        fileURL.pathExtension.caseInsensitiveCompare(renamedExtension) == .orderedSame
            && FITSFile.hasFITSExtension(fileURL.deletingPathExtension())
    }

    /// True for a file the app loads: a FITS name, or a renamed rejected frame directly in a
    /// REJECTED folder. A renamed file anywhere else is left alone, like any other non-FITS file.
    static func isLoadable(_ fileURL: URL) -> Bool {
        FITSFile.hasFITSExtension(fileURL) || (isRenamed(fileURL) && isInRejectedFolder(fileURL))
    }

    /// The collected files that sit directly in a REJECTED folder.
    static func rejectedURLs(in collected: [(url: URL, subfolderPath: String)]) -> Set<URL> {
        Set(collected.map(\.url).filter(isInRejectedFolder))
    }
}
