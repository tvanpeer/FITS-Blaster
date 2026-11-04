//
//  FrameMenuModel.swift
//  FITS Blaster
//
//  What the thumbnail bar's context menu shows for its target frames: the titles, which
//  reject items there are and which are enabled. Plain values, so it can be tested
//  without a view (see SidebarFrameMenu).
//

import Foundation

struct FrameMenuModel: Equatable {

    /// A reject item in the menu.
    enum RejectItem: Equatable {
        case reject
        case undoReject
    }

    /// How many frames the menu acts on.
    let targetCount: Int
    /// How many of them are flagged.
    let flaggedCount: Int
    /// How many of them are rejected.
    let rejectedCount: Int
    /// The "toggle reject" setting: one reject key that rejects and undoes.
    let useToggleReject: Bool

    // MARK: Flag

    /// All targets flagged: the item deflags them. Otherwise it flags the others.
    var deflags: Bool { targetCount > 0 && flaggedCount == targetCount }

    var flagTitle: String {
        deflags ? Self.title("Deflag", count: targetCount)
                : Self.title("Flag", count: targetCount - flaggedCount)
    }

    // MARK: Reject

    /// The reject items, in menu order. With toggle reject one item, which does what the
    /// reject key does: undo when all targets are rejected, otherwise reject the others.
    /// Without it both items, each disabled when it has nothing to do.
    var rejectItems: [RejectItem] {
        if useToggleReject {
            return [targetCount > 0 && rejectedCount == targetCount ? .undoReject : .reject]
        }
        return [.reject, .undoReject]
    }

    func isEnabled(_ item: RejectItem) -> Bool {
        switch item {
        case .reject:     rejectedCount < targetCount
        case .undoReject: rejectedCount > 0
        }
    }

    func title(_ item: RejectItem) -> String {
        switch item {
        case .reject:     Self.title("Reject", count: targetCount - rejectedCount)
        case .undoReject: Self.title("Undo Reject", count: rejectedCount)
        }
    }

    // MARK: Other items

    var copyPathTitle: String { targetCount > 1 ? "Copy File Paths" : "Copy File Path" }

    var removeTitle: String {
        targetCount > 1 ? "Remove \(targetCount) Frames from List" : "Remove from List"
    }

    /// "Reject" for one frame (or none to act on), "Reject 3 Frames" for more.
    private static func title(_ verb: String, count: Int) -> String {
        count > 1 ? "\(verb) \(count) Frames" : verb
    }
}
