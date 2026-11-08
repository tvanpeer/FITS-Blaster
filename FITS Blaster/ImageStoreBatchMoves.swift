//
//  ImageStoreBatchMoves.swift
//  FITS Blaster
//
//  Rejecting and undoing several frames at once (step 11b, CODE_AUDIT §5.14). The files
//  move off the main actor, folder access is started once per folder, the list is rebuilt
//  once, and failures come in one message. A single frame still moves at once on the main
//  actor (Tom, 2026-11-08), so a quick second key press reaches the next frame.
//

import Foundation

/// What happened to a batch's frames.
private struct BatchOutcome {
    var moved: [ImageEntry] = []
    /// Frames whose folder the sandbox hasn't granted; they wait for the folder question.
    var waiting: [ImageEntry] = []
    var failures: [(fileName: String, reason: String)] = []
}

extension ImageStore {

    /// Starts a batch of 2 or more frames. It runs after any batch still running; frames
    /// already in a batch are left out. When it ends, the frames show as rejected (or
    /// restored) and the cursor moves on from `previousOrder` as after a single frame.
    func moveBatch(_ batch: [ImageEntry], kind: FrameMoves.Kind, advancingFrom previousOrder: [ImageEntry]?) {
        let batch = batch.filter { !frameMoves.movingIDs.contains($0.id) }
        guard !batch.isEmpty else { return }
        frameMoves.movingIDs.formUnion(batch.map(\.id))
        let previous = frameMoves.task
        frameMoves.task = Task { [weak self] in
            await previous?.value
            await self?.runBatch(batch, kind: kind, advancingFrom: previousOrder)
        }
    }

    private func runBatch(_ batch: [ImageEntry], kind: FrameMoves.Kind, advancingFrom previousOrder: [ImageEntry]?) async {
        guard !Task.isCancelled else { return }
        frameMoves.progress = FrameMoves.Progress(kind: kind, done: 0, total: batch.count)
        // Asked before the move: a frame whose folder wasn't granted waits for the folder
        // question instead of failing (sandboxed build), as with a single frame.
        let canAsk = Set(batch.filter { kind == .reject && asksForFolderAccess && bookmark(for: $0.url) == nil }
                              .map(\.id))
        let startedFolders = accessFolders(for: batch)

        var outcome = BatchOutcome()
        var emptiedFolders: [URL] = []
        for entry in batch {
            if Task.isCancelled { break }
            let source = entry.url
            let destination = kind == .reject ? RejectedFolder.rejectedURL(for: source) : entry.originalURL
            if let failure = await FrameMover.move(from: source, to: destination, createsFolder: kind == .reject) {
                if canAsk.contains(entry.id), failure.permissionDenied {
                    outcome.waiting.append(entry)
                } else {
                    outcome.failures.append((entry.fileName, failure.reason))
                }
            } else {
                // The new path at once, so a re-read during the batch finds the file.
                entry.url = destination
                outcome.moved.append(entry)
                if kind == .restore, !emptiedFolders.contains(source.deletingLastPathComponent()) {
                    emptiedFolders.append(source.deletingLastPathComponent())
                }
            }
            frameMoves.progress?.done += 1
        }
        if !emptiedFolders.isEmpty { await FrameMover.removeFoldersIfEmpty(emptiedFolders) }
        for folder in startedFolders { folder.stopAccessingSecurityScopedResource() }

        finishBatch(batch, kind: kind, outcome: outcome, advancingFrom: previousOrder)
    }

    /// Shows the batch's result: the moved frames as rejected or restored (frames removed
    /// from the list meanwhile are left out), one list rebuild, the cursor, the message.
    private func finishBatch(_ batch: [ImageEntry], kind: FrameMoves.Kind, outcome: BatchOutcome,
                             advancingFrom previousOrder: [ImageEntry]?) {
        let listed = Set(entries.map(\.id))
        let movedIDs = Set(outcome.moved.map(\.id)).intersection(listed)
        for entry in outcome.moved where movedIDs.contains(entry.id) { entry.isRejected = kind == .reject }
        if kind == .reject {
            rejectedEntryIDs.formUnion(movedIDs)
        } else {
            rejectedEntryIDs.subtract(movedIDs)
        }
        updateVisibilityFilteredEntries()
        if let previousOrder { advanceCursorIfNeeded(from: previousOrder) }

        if !outcome.failures.isEmpty {
            errorMessage = FrameMoves.failureMessage(kind: kind, failures: outcome.failures, total: batch.count)
        }
        let waitingListed = outcome.waiting.filter { listed.contains($0.id) }
        if let first = waitingListed.first, folderAccessRequest == nil {
            folderAccessRequest = FolderAccessRequest(folder: first.url.deletingLastPathComponent(),
                                                      entryIDs: waitingListed.map(\.id))
        }
        frameMoves.movingIDs.subtract(batch.map(\.id))
        frameMoves.progress = nil
    }
}
