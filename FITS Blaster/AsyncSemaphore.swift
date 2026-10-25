//
//  AsyncSemaphore.swift
//  FITS Blaster
//

import Foundation

/// Async-friendly counting semaphore. Callers that exceed the concurrency cap
/// are suspended and resumed in FIFO order as earlier callers call `signal()`.
/// A waiting caller whose task is cancelled is resumed at once, without a slot,
/// so Cancel doesn't leave work queued behind the cap (CODE_AUDIT §3.4).
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    init(count: Int) { self.count = count }

    /// Takes a slot, waiting for one if needed. Returns false, without a slot, when the
    /// task is cancelled before or while waiting; the caller must then not `signal()`.
    func wait() async -> Bool {
        if Task.isCancelled { return false }
        if count > 0 {
            count -= 1
            return true
        }
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                waiters.append((id, continuation))
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    /// Releases a slot taken by `wait()`, handing it to the longest waiter if there is one.
    func signal() {
        if waiters.isEmpty {
            count += 1
        } else {
            waiters.removeFirst().continuation.resume(returning: true)
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(returning: false)
    }
}
