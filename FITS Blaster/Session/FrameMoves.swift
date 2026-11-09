//
//  FrameMoves.swift
//  FITS Blaster
//
//  The state of batch rejects and undos (step 11b, CODE_AUDIT §5.14): which frames are
//  being moved, the progress for the info bar, and the task that does it. Owned by
//  `ImageStore`; the moves themselves are in `ImageStoreBatchMoves.swift`.
//

import Foundation

@MainActor @Observable
final class FrameMoves {

    /// Into REJECTED, or back out of it.
    enum Kind: Sendable { case reject, restore }

    /// How far the running batch is, for the info bar's progress row.
    struct Progress: Equatable {
        let kind: Kind
        var done: Int
        let total: Int
    }

    /// The running batch's progress; nil when no batch runs.
    var progress: Progress?

    /// Frames in a running or waiting batch. A reject or undo of one of them is skipped.
    var movingIDs: Set<UUID> = []

    /// The last batch started. A new batch waits for it, so batches run one after another.
    @ObservationIgnored var task: Task<Void, Never>?

    /// Waits until every batch started so far has finished.
    func wait() async {
        await task?.value
    }

    /// Stops the batches (Reset): files already moved stay where they are.
    func cancel() {
        task?.cancel()
        task = nil
        movingIDs = []
        progress = nil
    }

    /// The message for frames that could not be moved: "3 of 40 frames could not be moved
    /// to REJECTED:", one line per frame with the reason (at most `maxListed`), then
    /// "and N more".
    nonisolated static func failureMessage(kind: Kind, failures: [(fileName: String, reason: String)],
                                           total: Int, maxListed: Int = 5) -> String {
        let frames = total == 1 ? "frame" : "frames"
        let action = kind == .reject ? "moved to REJECTED" : "moved back from REJECTED"
        var lines = ["\(failures.count) of \(total) \(frames) could not be \(action):"]
        lines += failures.prefix(maxListed).map { "\($0.fileName) — \($0.reason)" }
        if failures.count > maxListed { lines.append("and \(failures.count - maxListed) more") }
        return lines.joined(separator: "\n")
    }
}
