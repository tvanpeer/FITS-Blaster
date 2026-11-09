//
//  DisplayMemoryBudget.swift
//  FITS Blaster
//
//  Keeps the display images within a memory budget (master-plan 9f part 1). Over the
//  budget, the frames viewed least recently lose their display images (`dropDisplayImages`);
//  the cursor and the frames read ahead around it are never dropped. Without a limit, as
//  in the command line, the render tests and the unit tests, every image stays.
//

import Foundation

@MainActor
final class DisplayMemoryBudget {

    /// The most bytes of display images to hold; nil keeps every image.
    var limitBytes: Int? {
        didSet { scheduleTrim() }
    }

    /// Frames that are never dropped: the cursor and the frames read ahead around it.
    var protectedIDs: Set<UUID> = []

    private weak var store: ImageStore?
    /// When each frame was last viewed, or got its first image.
    private var lastViewed: [UUID: UInt64] = [:]
    private var clock: UInt64 = 0
    /// The pending trim: images come in bursts during a load, one trim handles a burst.
    private var trimTask: Task<Void, Never>?

    init(store: ImageStore) {
        self.store = store
    }

    /// The cursor is on `entry` now.
    func viewed(_ entry: ImageEntry) {
        clock += 1
        lastViewed[entry.id] = clock
    }

    /// A display image of `entry` came or went. A frame never viewed counts as viewed when
    /// its first image comes, so of those the earliest loaded go first.
    func imagesChanged(_ entry: ImageEntry) {
        if lastViewed[entry.id] == nil {
            clock += 1
            lastViewed[entry.id] = clock
        }
        scheduleTrim()
    }

    /// Forgets the viewing order (a new session).
    func reset() {
        trimTask?.cancel()
        trimTask = nil
        lastViewed = [:]
        protectedIDs = []
    }

    /// Waits for a pending trim (the tests).
    func waitForTrim() async {
        await trimTask?.value
    }

    private func scheduleTrim() {
        guard limitBytes != nil, trimTask == nil else { return }
        trimTask = Task { [weak self] in
            await Task.yield()
            guard !Task.isCancelled else { return }
            self?.trimTask = nil
            self?.trim()
        }
    }

    /// Drops the display images of the frames viewed least recently until the rest fit.
    func trim() {
        guard let limit = limitBytes, let store else { return }
        var total = 0
        var candidates: [(entry: ImageEntry, bytes: Int, viewed: UInt64)] = []
        for entry in store.entries {
            let bytes = entry.displayBytes
            guard bytes > 0 else { continue }
            total += bytes
            let viewed = lastViewed[entry.id] ?? 0
            // A frame a batch is making, or without a recipe, can't be drawn again.
            guard entry !== store.selectedEntry, !protectedIDs.contains(entry.id),
                  !entry.isProcessing, entry.shownRecipe != nil else { continue }
            candidates.append((entry, bytes, viewed))
        }
        guard total > limit else { return }
        for candidate in candidates.sorted(by: { $0.viewed < $1.viewed }) {
            guard total > limit else { break }
            candidate.entry.dropDisplayImages()
            total -= candidate.bytes
        }
    }
}
