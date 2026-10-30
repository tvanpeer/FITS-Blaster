//
//  DisplaySizeChangeTests.swift
//  FITS Blaster Tests
//
//  A new display size renders every frame again at that size, the colour renders too.
//  Before 2026-10-30 a size change in colour mode showed the cached colour images of the
//  old size again; only the grey ones got the new size.
//

import AppKit
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct DisplaySizeChangeTests {

    /// 64 × 64 Bayer frames, binned to 32 × 32: a display size of 16 scales them down,
    /// 1024 doesn't.
    private let smallSize = 16
    private let largeSize = 1024
    private let thumbnailSize = 120

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeBayerFiles(_ count: Int, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        let width = 64, height = 64
        return try (0..<count).map { n in
            let stored = (0..<(width * height)).map { i -> Int16 in
                let x = i % width, y = i / width
                let channel = (y % 2) * 2 + (x % 2)
                let value = 2000 + channel * 1500 + (x + y) * 40 + n * 100 + (i * 37) % 300
                return Int16(bitPattern: UInt16(value) &- 32768)
            }
            let cards = TestFITS.imageCards(bitpix: 16, width: width, height: height, bzero: 32768,
                                            extraCards: [TestFITS.card("BAYERPAT", value: "'RGGB'")])
            let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
            return (url: try TestFITS.write(data, fileName: "bayer\(n).fits", in: folder), subfolderPath: "")
        }
    }

    private func load(_ folder: URL, colour: Bool) async throws -> ImageStore {
        let store = ImageStore()
        store.pipeline.openFiles(try writeBayerFiles(3, in: folder), maxDisplaySize: smallSize,
                                 maxThumbnailSize: thumbnailSize, metricsConfig: .off,
                                 debayerColorImages: colour)
        await store.pipeline.waitForProcessing()
        return store
    }

    private func changeSize(_ store: ImageStore, colour: Bool) async {
        store.pipeline.regenerateSizes(maxDisplaySize: largeSize, maxThumbnailSize: thumbnailSize,
                                       metricsConfig: .off, debayer: colour)
        await store.pipeline.waitForProcessing()
    }

    private func width(_ image: NSImage?) -> Int? {
        image?.cgImage(forProposedRect: nil, context: nil, hints: nil)?.width
    }

    @Test("In colour mode the colour images get the new size")
    func colourMode() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = try await load(folder, colour: true)
        #expect(store.entries.allSatisfy { width($0.displayImage) == smallSize })

        await changeSize(store, colour: true)

        for entry in store.entries {
            #expect(entry.displayImage === entry.cachedColourDisplay)
            #expect(width(entry.cachedColourDisplay) == 32)
            #expect(width(entry.cachedGreyscaleDisplay) == 32)
            #expect(entry.cachedColourThumb != nil && entry.thumbnail === entry.cachedColourThumb)
            guard case .colour(_, _, largeSize) = entry.colourRecipe else {
                Issue.record("Expected the colour recipe at the new size, got \(String(describing: entry.colourRecipe))")
                continue
            }
        }
    }

    @Test("In grey mode, colour turned on afterwards renders at the new size")
    func greyModeThenColour() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // Loaded in colour, then grey: both renders are cached at the small size.
        let store = try await load(folder, colour: true)
        store.pipeline.recolorImages(debayer: false, maxDisplaySize: smallSize, maxThumbnailSize: thumbnailSize)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.allSatisfy { width($0.cachedColourDisplay) == smallSize })

        await changeSize(store, colour: false)
        for entry in store.entries {
            #expect(entry.displayImage === entry.cachedGreyscaleDisplay)
            #expect(width(entry.displayImage) == 32)
            #expect(entry.cachedColourDisplay == nil)
        }

        store.pipeline.recolorImages(debayer: true, maxDisplaySize: largeSize, maxThumbnailSize: thumbnailSize)
        await store.pipeline.waitForProcessing()
        for entry in store.entries {
            #expect(entry.displayImage === entry.cachedColourDisplay)
            #expect(width(entry.displayImage) == 32)
        }
    }
}
