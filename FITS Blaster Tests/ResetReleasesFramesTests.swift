//
//  ResetReleasesFramesTests.swift
//  FITS Blaster Tests
//
//  After a Reset no frame of the old session stays in memory: the stored sidebar and chart
//  lists kept every frame, with its display images, alive (M81 at 4096: 8 GB after a Reset).
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct ResetReleasesFramesTests {

    /// Holds a frame without keeping it alive.
    private final class WeakEntry {
        weak var entry: ImageEntry?
        init(_ entry: ImageEntry) { self.entry = entry }
    }

    /// Three mono 16-bit frames in `name` under `root`.
    private func writeFolder(_ name: String, in root: URL) throws -> [(url: URL, subfolderPath: String)] {
        let folder = root.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<3).map { n in
            let stored = (0..<(64 * 48)).map { i in Int16(bitPattern: UInt16(2000 + n * 100 + (i * 37) % 400) &- 32768) }
            let cards = TestFITS.imageCards(bitpix: 16, width: 64, height: 48, bzero: 32768)
            let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
            return (url: try TestFITS.write(data, fileName: "frame\(n).fits", in: folder), subfolderPath: name)
        }
    }

    @Test("A Reset lets go of every frame and empties the sidebar and chart lists")
    func resetReleasesFrames() async throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = ImageStore()
        store.pipeline.openFiles(try writeFolder("A", in: root) + writeFolder("B", in: root),
                                 maxDisplaySize: 64, metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        try #require(store.entries.count == 6)
        try #require(!store.visibleFolderSections.isEmpty)
        let weakEntries = store.entries.map(WeakEntry.init)
        let revision = store.listRevision

        store.reset()
        await store.pipeline.waitForProcessing()

        #expect(store.visibleFolderSections.isEmpty)
        #expect(store.visibilityFilteredEntries.isEmpty)
        #expect(store.listRevision > revision)
        #expect(weakEntries.allSatisfy { $0.entry == nil }, "frames still alive after Reset")
    }
}
