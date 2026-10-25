//
//  FolderTracker.swift
//  FITS Blaster
//

import Foundation

/// Tracks per-folder Phase A completion counts across concurrent tasks.
/// When all entries in a folder have completed Phase A, `complete(path:)` returns
/// `true` exactly once — the signal to fire that folder's colour normalisation task.
actor FolderTracker {
    private var completions: [String: Int] = [:]
    private let totals: [String: Int]

    @MainActor
    init(grouping entries: [ImageEntry]) {
        totals = Dictionary(grouping: entries, by: { $0.qualifiedFolderPath })
            .mapValues(\.count)
    }

    /// Records one Phase A completion for `path`.
    /// Returns `true` if this call is the last completion for that folder.
    func complete(path: String) -> Bool {
        completions[path, default: 0] += 1
        return completions[path] == totals[path]
    }
}
