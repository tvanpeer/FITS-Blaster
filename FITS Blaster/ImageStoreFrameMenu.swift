//
//  ImageStoreFrameMenu.swift
//  FITS Blaster
//
//  The actions of the thumbnail bar's context menu. They act on explicit frames (the
//  orange selection, or the right-clicked frame), not on "the selection", so the keys
//  and their functions keep their own behaviour.
//

import Foundation

extension ImageStore {

    /// The frames a right-click on `entry` acts on, as in Finder: the whole orange
    /// selection when `entry` is part of it, otherwise `entry` alone. In list order.
    func frameMenuTargets(for entry: ImageEntry) -> [ImageEntry] {
        guard markedForRejectionIDs.contains(entry.id) else { return [entry] }
        return entries.filter { markedForRejectionIDs.contains($0.id) }
    }

    /// The menu's state for these frames.
    func frameMenuModel(for targets: [ImageEntry], useToggleReject: Bool) -> FrameMenuModel {
        FrameMenuModel(targetCount: targets.count,
                       flaggedCount: targets.count(where: { flaggedEntryIDs.contains($0.id) }),
                       rejectedCount: targets.count(where: \.isRejected),
                       useToggleReject: useToggleReject)
    }

    /// Deflags the frames when all are flagged, otherwise flags the others (as the flag key).
    func frameMenuToggleFlag(_ targets: [ImageEntry]) {
        if targets.allSatisfy({ flaggedEntryIDs.contains($0.id) }) {
            unflagEntries(Set(targets.map(\.id)))
        } else {
            flagEntries(targets.filter { !flaggedEntryIDs.contains($0.id) })
        }
    }

    /// Rejects the frames that aren't rejected yet.
    func frameMenuReject(_ targets: [ImageEntry]) {
        rejectEntries(targets)
    }

    /// Undoes the rejection of the frames that are rejected.
    func frameMenuUndoReject(_ targets: [ImageEntry]) {
        targets.filter(\.isRejected).forEach { undoRejectEntry($0) }
    }

    /// Takes the frames out of the list; the files stay on disk. The cursor moves only
    /// when it was one of them.
    func frameMenuRemove(_ targets: [ImageEntry]) {
        removeEntries(withIDs: Set(targets.map(\.id)), alwaysMoveCursor: false)
    }

    /// The frames' current file paths (a rejected frame's path in REJECTED/), one per line.
    nonisolated static func filePathsText(_ urls: [URL]) -> String {
        urls.map { $0.path(percentEncoded: false) }.joined(separator: "\n")
    }
}
