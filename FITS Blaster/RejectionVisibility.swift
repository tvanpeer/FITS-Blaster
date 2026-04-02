//
//  RejectionVisibility.swift
//  FITS Blaster
//

import Foundation

/// Controls which images are shown in the sidebar and session chart.
enum RejectionVisibility: String, CaseIterable {
    case all      = "All"
    /// Shows only entries that are in the flagged set (`flaggedEntryIDs`).
    case active   = "Flagged"
    case rejected = "Rejected"

    @MainActor func matches(_ entry: ImageEntry) -> Bool {
        switch self {
        case .all:      return true
        case .active:   return !entry.isRejected
        case .rejected: return entry.isRejected
        }
    }
}
