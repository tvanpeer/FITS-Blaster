//
//  BatchStatsTests.swift
//  FITS Blaster Tests
//
//  Tests that the info bar's load statistics (image count, megapixels) describe
//  the last batch only, not the whole session.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct BatchStatsTests {

    private static let width = 64
    private static let height = 32

    /// Writes `count` small 16-bit FITS files with a gradient into a new temporary folder.
    private func writeFiles(_ count: Int, prefix: String, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        try (0..<count).map { i in
            let url = folder.appending(component: "\(prefix)-\(i).fits")
            try fitsData().write(to: url)
            return (url: url, subfolderPath: "")
        }
    }

    private func fitsData() -> Data {
        let stored = (0..<(Self.width * Self.height)).map { i in
            Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768)
        }
        let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height, bzero: 32768)
        return TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
    }

    @Test("A second batch reports only its own images and megapixels")
    func secondBatchCountsOnlyItself() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ImageStore()
        store.pipeline.openFiles(try writeFiles(3, prefix: "first", in: folder))
        await store.pipeline.waitForProcessing()
        #expect(store.pipeline.batchImageCount == 3)

        store.pipeline.openFiles(try writeFiles(2, prefix: "second", in: folder))
        await store.pipeline.waitForProcessing()
        #expect(store.entries.count == 5)
        #expect(store.pipeline.batchImageCount == 2)
        let expected = 2.0 * Double(Self.width * Self.height) / 1_000_000
        #expect(abs((store.pipeline.batchMegapixels ?? 0) - expected) < 1e-9)
    }
}
