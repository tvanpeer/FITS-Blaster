//
//  RowOrder.swift
//  FITS Blaster
//
//  Which way up a frame is drawn (issue #14). N.I.N.A. writes ROWORDER = 'TOP-DOWN': the
//  first row in the file is the top of the picture, and PixInsight, Astro Pixel Processor
//  and ASI Studio show it that way, also for files without the keyword. FITS Blaster used
//  to flip every frame (the FITS standard's bottom-up order), so its pictures were upside
//  down compared with those programs. Now only a frame that says BOTTOM-UP is flipped.
//  Shared with the Quick Look extensions.
//

import Foundation

/// The order of the pixel rows in a FITS file, from its ROWORDER header.
enum RowOrder: Sendable, Equatable {
    /// The first row is the top of the picture: TOP-DOWN, and the default when the header
    /// is missing or has another value.
    case topDown
    /// The first row is the bottom of the picture: ROWORDER = 'BOTTOM-UP'.
    case bottomUp

    /// True when the rows must be drawn last to first.
    var flipsRows: Bool { self == .bottomUp }

    /// The row order of `headers` (values as `FITSReader` stores them). The value is read
    /// without regard to case, spaces or quotes.
    static func parse(from headers: [String: String]) -> RowOrder {
        guard let raw = headers["ROWORDER"] else { return .topDown }
        let cleaned = FITSReader.cleanHeaderString(raw)
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        return cleaned == "BOTTOM-UP" ? .bottomUp : .topDown
    }
}
