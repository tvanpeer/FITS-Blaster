//
//  ThumbnailSizeTests.swift
//  FITS Blaster Tests
//
//  The thumbnail setting is in points; thumbnails are rendered at points × screen scale,
//  so they are sharp on Retina screens. A saved value outside 40–320 is brought into range.
//  A new thumbnail size only remakes the thumbnails from the display images in memory.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct ThumbnailSizeTests {

    @Test("Rendered pixels are points × screen scale", arguments: [
        (180, 1.0, 180), (180, 2.0, 360), (180, 3.0, 540), (120, 2.0, 240), (320, 2.0, 640),
        (180, 0.0, 180),   // no screen info: at least 1×
    ])
    func renderPixels(points: Int, scale: Double, pixels: Int) {
        #expect(AppSettings.thumbnailPixels(points: points, scale: scale) == pixels)
    }

    @Test("A saved size outside the range is brought into it", arguments: [
        (400, 320), (320, 320), (180, 180), (40, 40), (20, 40),
    ])
    func savedValueClamped(saved: Int, used: Int) {
        #expect(AppSettings.clampedThumbnailSize(saved) == used)
    }

    @Test("The default is 180 points, within the range")
    func defaultSize() {
        #expect(AppSettings.thumbnailSizeRange == 40...320)
        #expect(AppSettings.thumbnailSizeRange.contains(180))
    }

    // MARK: - Thumbnails only

    private func writeFiles(_ count: Int, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        let stored = (0..<(300 * 200)).map { i in Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768) }
        let data = TestFITS.fileData(cards: TestFITS.imageCards(bitpix: 16, width: 300, height: 200, bzero: 32768),
                                     pixels: TestFITS.bigEndian(stored))
        return try (0..<count).map { (url: try TestFITS.write(data, fileName: "frame\($0).fits", in: folder), subfolderPath: "") }
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("A new thumbnail size remakes the thumbnails from memory, without reading files or a batch")
    func thumbnailsFromMemory() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.pipeline.openFiles(try writeFiles(3, in: folder), maxThumbnailSize: 120, metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.allSatisfy { $0.thumbnail?.size.width == 120 })

        // With the files gone, only the images in memory can be used.
        try FileManager.default.removeItem(at: folder)
        store.pipeline.regenerateThumbnails(size: 60)
        #expect(!store.pipeline.isBatchProcessing)
        await store.pipeline.waitForProcessing()

        for entry in store.entries {
            let thumb = try #require(entry.thumbnail)
            #expect(thumb.size.width == 60)
            let display = try #require(entry.displayImage)
            let expected = try #require(ImageStretcher.createThumbnail(from: display, maxSize: 60))
            #expect(thumb.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?
                    == expected.cgImage(forProposedRect: nil, context: nil, hints: nil)?.dataProvider?.data as Data?)
        }
    }

    @Test("A new thumbnail size during a load also covers the frames still loading")
    func thumbnailsDuringLoad() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        store.pipeline.openFiles(try writeFiles(4, in: folder), maxThumbnailSize: 120, metricsConfig: .off)
        store.pipeline.regenerateThumbnails(size: 80)   // queued behind the load
        await store.pipeline.waitForProcessing()
        #expect(store.entries.count == 4)
        #expect(store.entries.allSatisfy { $0.thumbnail?.size.width == 80 })
    }
}
