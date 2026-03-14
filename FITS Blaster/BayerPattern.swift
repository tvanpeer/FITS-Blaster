//
//  BayerPattern.swift
//  FITS Blaster
//

import Foundation

/// The four standard Bayer colour filter array patterns found in colour FITS images.
///
/// Each case identifies which colour sits at pixel (0,0) — the top-left corner of the
/// sensor's 2×2 Bayer cell. The `rOffset` encoding is passed to the Metal kernel so it
/// can resolve the colour of any pixel using only bit arithmetic.
enum BayerPattern: String {
    case rggb = "RGGB"
    case bggr = "BGGR"
    case grbg = "GRBG"
    case gbrg = "GBRG"

    /// Encodes where R sits in the 2×2 Bayer cell for the Metal kernel:
    ///
    ///   bit 0 → column parity of R pixel (0 = even column, 1 = odd column)
    ///   bit 1 → row parity of R pixel    (0 = even row,    1 = odd row)
    ///
    ///   RGGB → R at (even, even) → 0
    ///   GRBG → R at (odd,  even) → 1
    ///   GBRG → R at (even, odd)  → 2
    ///   BGGR → R at (odd,  odd)  → 3
    var rOffset: UInt32 {
        switch self {
        case .rggb: return 0
        case .grbg: return 1
        case .gbrg: return 2
        case .bggr: return 3
        }
    }

    /// Attempt to read the Bayer pattern from a FITS header dictionary.
    /// Checks `BAYERPAT`, `COLORTYP`, and `CFA_PAT` in that order.
    /// Strips FITS string quoting and trims whitespace before matching.
    static func parse(from headers: [String: String]) -> BayerPattern? {
        for key in ["BAYERPAT", "COLORTYP", "CFA_PAT"] {
            guard let raw = headers[key] else { continue }
            let cleaned = FITSReader.cleanHeaderString(raw)
                .trimmingCharacters(in: .whitespaces)
                .uppercased()
            if let pattern = BayerPattern(rawValue: cleaned) { return pattern }
        }
        return nil
    }
}
