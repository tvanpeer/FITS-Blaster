//
//  DisplayRecipeTests.swift
//  FITS Blaster Tests
//
//  Every display image records how it was made (master-plan 9f part 1), and making it
//  again from its file with that recipe gives the same bytes: mono with its own clips and
//  with a group's shared clips, Bayer in grey and in colour, at a display size that
//  scales the image down.
//

import AppKit
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct DisplayRecipeTests {

    private static let width = 300, height = 200
    /// Smaller than the images, so the kernels scale down (Bayer frames are binned to 150 × 100).
    private static let displaySize = 128

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `count` 16-bit frames with a gradient, deterministic noise and a per-frame offset;
    /// with `bayer` the levels differ per CFA position and the header says RGGB.
    private func writeFiles(_ count: Int, bayer: Bool, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        try (0..<count).map { n in
            let stored = (0..<(Self.width * Self.height)).map { i -> Int16 in
                let x = i % Self.width, y = i / Self.width
                let channel = bayer ? (y % 2) * 2 + (x % 2) : 0
                let value = 2000 + channel * 1500 + (x + y) * 20 + n * 150 + (i * 37) % 400
                return Int16(bitPattern: UInt16(value) &- 32768)
            }
            let extra = bayer ? [TestFITS.card("BAYERPAT", value: "'RGGB'")] : []
            let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height,
                                            bzero: 32768, extraCards: extra)
            let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
            return (url: try TestFITS.write(data, fileName: "frame\(n).fits", in: folder), subfolderPath: "")
        }
    }

    private func load(_ files: [(url: URL, subfolderPath: String)], colour: Bool) async -> ImageStore {
        let store = ImageStore()
        store.pipeline.openFiles(files, maxDisplaySize: Self.displaySize, metricsConfig: .off,
                                 debayerColorImages: colour)
        await store.pipeline.waitForProcessing()
        return store
    }

    /// Makes the image again from the entry's file and recipe and compares the pixels.
    private func expectSameAgain(_ image: NSImage?, _ recipe: DisplayRecipe?, url: URL) async throws {
        let image = try #require(image)
        let recipe = try #require(recipe)
        let again = try #require(await FrameLoading.renderAgain(url: url, recipe: recipe))
        let original = try #require(RGBAPixels(image)), remade = try #require(RGBAPixels(again))
        #expect(original.width == remade.width && original.height == remade.height)
        #expect(original.bytes == remade.bytes)
    }

    @Test("A mono frame on its own: Phase A, with its own clips")
    func monoAlone() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(1, bayer: false, in: folder), colour: false)
        let entry = try #require(store.entries.first)
        guard case .grey(nil, Self.displaySize) = entry.greyRecipe else {
            Issue.record("Expected Phase A's grey recipe, got \(String(describing: entry.greyRecipe))")
            return
        }
        try await expectSameAgain(entry.displayImage, entry.greyRecipe, url: entry.url)
    }

    @Test("Mono frames in a group: the shared clips of the grey normalisation pass")
    func monoGroup() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: false, in: folder), colour: false)
        #expect(store.entries.count == 3)
        for entry in store.entries {
            guard case .sharedGrey(_, nil, Self.displaySize) = entry.greyRecipe else {
                Issue.record("Expected the shared grey recipe, got \(String(describing: entry.greyRecipe))")
                continue
            }
            try await expectSameAgain(entry.displayImage, entry.greyRecipe, url: entry.url)
        }
    }

    @Test("Bayer frames in grey: Phase A with 2×2 binning")
    func bayerGrey() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: true, in: folder), colour: false)
        for entry in store.entries {
            guard case .grey(.rggb, Self.displaySize) = entry.greyRecipe else {
                Issue.record("Expected Phase A's binned grey recipe, got \(String(describing: entry.greyRecipe))")
                continue
            }
            #expect(entry.displayImage === entry.cachedGreyscaleDisplay)
            try await expectSameAgain(entry.cachedGreyscaleDisplay, entry.greyRecipe, url: entry.url)
        }
    }

    @Test("Bayer frames in colour: the folder's shared clips, and the grey render beside it")
    func bayerColour() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: true, in: folder), colour: true)
        for entry in store.entries {
            guard case .colour(_, _, Self.displaySize) = entry.colourRecipe else {
                Issue.record("Expected the colour recipe, got \(String(describing: entry.colourRecipe))")
                continue
            }
            #expect(entry.displayImage === entry.cachedColourDisplay)
            try await expectSameAgain(entry.cachedColourDisplay, entry.colourRecipe, url: entry.url)
            try await expectSameAgain(entry.cachedGreyscaleDisplay, entry.greyRecipe, url: entry.url)
        }
    }

    @Test("Colour turned on after a grey load: the toggle's colour render has a recipe too")
    func colourAfterToggle() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: true, in: folder), colour: false)
        store.pipeline.recolorImages(debayer: true, maxDisplaySize: Self.displaySize, maxThumbnailSize: 120)
        await store.pipeline.waitForProcessing()
        for entry in store.entries {
            #expect(entry.displayImage === entry.cachedColourDisplay)
            try await expectSameAgain(entry.cachedColourDisplay, entry.colourRecipe, url: entry.url)
        }
    }

    @Test("A file that can't be read gives no image")
    func unreadable() async throws {
        let missing = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).fits")
        #expect(await FrameLoading.renderAgain(url: missing, recipe: .grey(bayerPattern: nil, maxDisplaySize: 128)) == nil)
        #expect(await FrameLoading.renderAgain(url: missing, recipe: .cpuGrey(maxDisplaySize: 128)) == nil)
    }
}
