//
//  ThumbnailRow.swift
//  FITS Blaster
//

import SwiftUI

/// Reads the per-frame selection state from the store and passes it to `ThumbnailCell`
/// as plain values. When the cursor moves, every visible row re-reads these cheap values,
/// but only the cells whose values changed are redrawn (CODE_AUDIT §8.1).
struct ThumbnailRow: View {
    let entry: ImageEntry
    @Environment(ImageStore.self) private var store

    var body: some View {
        ThumbnailCell(
            entry: entry,
            isCursor: store.selectedEntry === entry,
            isFlagged: store.flaggedEntryIDs.contains(entry.id),
            isMarkedForRejection: store.markedForRejectionIDs.contains(entry.id),
            groupStats: store.groupStatistics[entry.filterGroup]
        )
    }
}
