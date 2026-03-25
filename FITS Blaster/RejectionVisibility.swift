//
//  RejectionVisibility.swift
//  FITS Blaster
//

import Foundation

/// Controls which images are shown in the sidebar and session chart.
enum RejectionVisibility: String, CaseIterable {
    case all      = "All"
    case selected = "Selected"
    case rejected = "Rejected"

    func matches(_ entry: ImageEntry) -> Bool {
        switch self {
        case .all:      return true
        case .selected: return !entry.isRejected
        case .rejected: return entry.isRejected
        }
    }
}
