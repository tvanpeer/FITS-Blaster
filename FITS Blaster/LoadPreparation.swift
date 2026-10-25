//
//  LoadPreparation.swift
//  FITS Blaster
//
//  What a load is doing before its frames appear: scanning the folder, then checking
//  each file's header. Over a network this can take tens of seconds, so it is shown.
//

import Foundation

enum LoadPreparation: Equatable {
    /// Listing the FITS files in a folder (count unknown yet).
    case scanning(folder: String)
    /// Reading each file's header to skip unsupported (floating-point) files.
    case checking(done: Int, total: Int)
}
