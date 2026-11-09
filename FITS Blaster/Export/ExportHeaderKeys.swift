//
//  ExportHeaderKeys.swift
//  FITS Blaster
//
//  The FITS header keys offered as extra export columns: the defaults (Settings,
//  Export sheet, command-line mode), a curated list, and discovery in loaded files.
//

import Foundation

enum ExportHeaderKeys {
    /// Default columns: a session-report set covering acquisition, focus, weather and
    /// pointing fields commonly written by Boltwood, ASCOM and Indi drivers.
    static let defaults = [
        "OBJECT", "DATE-OBS", "EXPTIME", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP",
        "FOCUSPOS", "AIRMASS", "OBJCTALT",
        "AMBTEMP", "HUMIDITY"
    ]

    /// Reasonable starter set to offer even before any FITS files are loaded. The
    /// pickers also add keys from the loaded files, so rig-specific keys (e.g.
    /// FOCUSER, ROTATOR, DEWPOINT) become available.
    static let known = [
        "OBJECT", "DATE-OBS", "DATE-LOC", "EXPTIME", "EXPOSURE", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP", "SET-TEMP",
        "XBINNING", "YBINNING", "XPIXSZ", "YPIXSZ",
        "TELESCOP", "INSTRUME", "FOCALLEN", "FOCRATIO", "APERTURE",
        "FOCUSPOS", "FOCTEMP", "FOCUSER",
        "RA", "DEC", "OBJCTRA", "OBJCTDEC", "OBJCTALT", "OBJCTAZ",
        "AIRMASS", "PIERSIDE", "ROTATOR", "ROTANGLE",
        "AMBTEMP", "HUMIDITY", "DEWPOINT", "PRESSURE",
        "CLOUDCVR", "WINDSPD", "WINDDIR", "SKYBRIGHT", "SKYTEMP",
        "IMAGETYP", "FRAMETYP",
        "SITELAT", "SITELONG", "SITEELEV"
    ]

    /// The keys a picker offers, alphabetically: the known keys, the keys with a value
    /// in any loaded frame, and the selected keys (so a selected key never disappears).
    /// `present` holds the keys that have a value in at least one loaded frame; the
    /// pickers dim the others.
    @MainActor
    static func available(in entries: [ImageEntry], selected: [String]) -> (keys: [String], present: Set<String>) {
        var keys = Set(known)
        var present: Set<String> = []
        for entry in entries {
            for (key, value) in entry.headers where !value.isEmpty {
                keys.insert(key)
                present.insert(key)
            }
        }
        keys.formUnion(selected)
        return (keys.sorted(), present)
    }
}
