//
//  PathStyle.swift
//  FITS Blaster
//

/// How file paths are rendered in exports. `relative` strips the longest common
/// ancestor directory (so a single-folder session collapses to bare filenames
/// automatically). `filename` always emits just `lastPathComponent`.
enum PathStyle: String, CaseIterable {
    case absolute
    case relative
    case filename

    var displayName: String {
        switch self {
        case .absolute: "Absolute path"
        case .relative: "Relative to common folder"
        case .filename: "Filename only"
        }
    }
}
