//
//  LoadPreparation.swift
//  FITS Blaster
//
//  What a load is doing before its frames appear: scanning the folder. Over a network this
//  can take a while, so it is shown.
//

import Foundation

enum LoadPreparation: Equatable {
    /// Listing the FITS files in a folder (count unknown yet).
    case scanning(folder: String)
}
