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

    /// Where a frame goes when it is rejected: …/Ha/x.fits → …/Ha/REJECTED/x.fits.
    static func rejectedURL(for fileURL: URL) -> URL {
        folder(for: fileURL).appending(component: fileURL.lastPathComponent)
    }

    /// Where a frame in a REJECTED folder came from: …/Ha/REJECTED/x.fits → …/Ha/x.fits.
    static func originalURL(for rejectedURL: URL) -> URL {
        rejectedURL.deletingLastPathComponent()   // …/Ha/REJECTED/
                   .deletingLastPathComponent()   // …/Ha/
                   .appending(component: rejectedURL.lastPathComponent)
    }

    /// The collected files that sit directly in a REJECTED folder.
    static func rejectedURLs(in collected: [(url: URL, subfolderPath: String)]) -> Set<URL> {
        Set(collected.map(\.url).filter(isInRejectedFolder))
    }
}
