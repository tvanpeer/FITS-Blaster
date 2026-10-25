//
//  BatchQueueTests.swift
//  FITS Blaster Tests
//
//  LoadPipeline runs batches one at a time (CODE_AUDIT §3.1): a second batch waits for
//  the first, only the last one clears "busy", Cancel and Reset stop the running and
//  the queued batches, and a batch after Cancel waits for the cancelled one's work.
//  The test bodies wait on gates the test opens, so nothing depends on timing.
//  The pipeline holds its store weakly, so each test keeps the store alive.
//

import Foundation
import Testing
@testable import FITS_Blaster

/// A one-shot signal: `wait()` suspends until `open()` has been called.
@MainActor
final class TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct BatchQueueTests {

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `count` small 16-bit FITS files in `folder`.
    private func writeFiles(_ count: Int, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        let stored = (0..<(32 * 16)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        let data = TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 32, height: 16, bzero: 32768),
                                     pixels: TestFITS.bigEndian(stored))
        return try (0..<count).map { i in
            (url: try TestFITS.write(data, fileName: "frame\(i).fits", in: folder), subfolderPath: "")
        }
    }

    @Test("A second batch starts only after the first has finished")
    func secondWaitsForFirst() async {
        let store = ImageStore()
        let pipeline = store.pipeline
        let started = TestGate(), release = TestGate()
        var order: [String] = []

        pipeline.enqueueBatch { _, _ in
            order.append("1 start")
            started.open()
            await release.wait()
            order.append("1 end")
            return []
        }
        pipeline.enqueueBatch { _, _ in
            order.append("2")
            return []
        }

        await started.wait()
        #expect(order == ["1 start"])
        release.open()
        await pipeline.waitForProcessing()
        #expect(order == ["1 start", "1 end", "2"])
        withExtendedLifetime(store) {}   // the pipeline holds its store weakly
    }

    @Test("Busy until the last queued batch ends")
    func busyUntilLast() async {
        let store = ImageStore()
        let pipeline = store.pipeline
        let release1 = TestGate(), started2 = TestGate(), release2 = TestGate()

        pipeline.enqueueBatch { _, _ in await release1.wait(); return [] }
        pipeline.enqueueBatch { _, _ in started2.open(); await release2.wait(); return [] }

        release1.open()
        await started2.wait()
        // The first batch has ended; the second still runs.
        #expect(pipeline.isBatchProcessing)
        #expect(pipeline.processingTask != nil)

        release2.open()
        await pipeline.waitForProcessing()
        #expect(!pipeline.isBatchProcessing)
        #expect(pipeline.processingTask == nil)
        withExtendedLifetime(store) {}   // the pipeline holds its store weakly
    }

    @Test("Cancel stops the running batch and the queued ones")
    func cancelStopsRunningAndQueued() async {
        let store = ImageStore()
        let pipeline = store.pipeline
        let started = TestGate(), release = TestGate()
        var secondRan = false

        pipeline.enqueueBatch { _, _ in started.open(); await release.wait(); return [] }
        pipeline.enqueueBatch { _, _ in secondRan = true; return [] }
        let queued = pipeline.processingTask

        await started.wait()
        pipeline.cancelProcessing()
        #expect(!pipeline.isBatchProcessing)
        #expect(pipeline.processingTask == nil)

        release.open()
        await queued?.value
        #expect(!secondRan)
        #expect(!pipeline.isBatchProcessing)
        withExtendedLifetime(store) {}   // the pipeline holds its store weakly
    }

    @Test("Reset stops the batches and leaves an empty session")
    func resetStopsBatches() async {
        let store = ImageStore()
        let pipeline = store.pipeline
        let started = TestGate(), release = TestGate()
        var secondRan = false

        pipeline.enqueueBatch { _, _ in started.open(); await release.wait(); return [] }
        pipeline.enqueueBatch { _, _ in secondRan = true; return [] }
        let queued = pipeline.processingTask

        await started.wait()
        store.reset()
        release.open()
        await queued?.value
        #expect(!secondRan)
        #expect(!pipeline.isBatchProcessing)
        #expect(store.entries.isEmpty)
    }

    @Test("A batch after Cancel waits until the cancelled batch's work has ended")
    func batchAfterCancelWaits() async {
        let store = ImageStore()
        let pipeline = store.pipeline
        let started = TestGate(), release = TestGate()
        var order: [String] = []

        pipeline.enqueueBatch { _, _ in
            started.open()
            await release.wait()   // stands for work already in flight when Cancel comes
            order.append("cancelled batch ends")
            return []
        }
        await started.wait()
        pipeline.cancelProcessing()

        pipeline.enqueueBatch { _, _ in order.append("next batch"); return [] }
        release.open()
        await pipeline.waitForProcessing()
        #expect(order == ["cancelled batch ends", "next batch"])
        withExtendedLifetime(store) {}   // the pipeline holds its store weakly
    }

    @Test("The same folder opened twice quickly loads each file once")
    func sameFolderTwice() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(4, in: folder)
        let store = ImageStore()

        store.pipeline.openFiles(files)
        store.pipeline.openFiles(files)
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == files.count)
        #expect(Set(store.entries.map(\.url)).count == files.count)
        #expect(store.entries.allSatisfy { !$0.isProcessing && $0.displayImage != nil })
    }

    @Test("Reset during a load adds no frames to the new session")
    func resetDuringLoad() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(4, in: folder)
        let store = ImageStore()

        store.pipeline.openFiles(files)
        let load = store.pipeline.processingTask
        store.reset()
        await load?.value

        #expect(store.entries.isEmpty)
        #expect(!store.pipeline.isBatchProcessing)
    }

    @Test("A display-size change queued behind a load re-renders the loaded frames too")
    func regenerateQueuedBehindLoad() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(3, in: folder)
        let store = ImageStore()

        store.pipeline.openFiles(files)
        store.pipeline.regenerateSizes(settings: AppSettings())
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == files.count)
        #expect(store.entries.allSatisfy { !$0.isProcessing && $0.displayImage != nil })
        #expect(store.pipeline.batchImageCount == files.count)
    }

    @Test("A re-render queued before a frame is rejected reads the moved file (§3.9)")
    func rejectBeforeQueuedRender() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(2, in: folder)
        let store = ImageStore()
        store.pipeline.openFiles(files)
        await store.pipeline.waitForProcessing()
        let entry = try #require(store.entries.first)

        store.pipeline.regenerateSizes(settings: AppSettings())
        store.rejectEntry(entry)
        await store.pipeline.waitForProcessing()

        #expect(entry.url.path(percentEncoded: false).contains("/REJECTED/"))
        #expect(entry.displayImage != nil)
        #expect(entry.errorMessage == nil)
    }
}

/// `AsyncSemaphore` hands out slots in order and releases a cancelled waiter without a
/// slot, so Cancel doesn't leave Phase B work queued (CODE_AUDIT §3.4).
@Suite(.timeLimit(.minutes(1)))
struct AsyncSemaphoreTests {

    @Test("A waiter that is cancelled gets no slot, and the slot count stays right")
    func cancelledWaiter() async {
        let semaphore = AsyncSemaphore(count: 1)
        #expect(await semaphore.wait())          // takes the only slot

        let waiter = Task { await semaphore.wait() }
        waiter.cancel()
        #expect(await waiter.value == false)

        await semaphore.signal()                 // the slot comes back…
        #expect(await semaphore.wait())          // …and can be taken again at once
    }

    @Test("A task cancelled before it waits gets no slot")
    func cancelledBeforeWaiting() async {
        let semaphore = AsyncSemaphore(count: 1)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await semaphore.wait()
        }
        #expect(await task.value == false)
        #expect(await semaphore.wait())          // the slot was never taken
    }

    @Test("A signal hands the slot to the longest waiter")
    func signalWakesWaiter() async {
        let semaphore = AsyncSemaphore(count: 1)
        #expect(await semaphore.wait())
        let waiter = Task { await semaphore.wait() }
        await Task.yield()
        await semaphore.signal()
        #expect(await waiter.value)
    }
}
