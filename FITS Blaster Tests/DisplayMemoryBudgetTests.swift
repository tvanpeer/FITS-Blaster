//
//  DisplayMemoryBudgetTests.swift
//  FITS Blaster Tests
//
//  The display images stay within the memory budget (master-plan 9f part 1): without a
//  limit nothing is dropped; over it the frames viewed least recently go first, never the
//  cursor or the frames around it; a dropped frame is drawn again when the cursor comes,
//  byte-identical, with its thumbnail at the image's size meanwhile; a file that can't be
//  read marks the frame, and the next visit tries again. A thumbnail-size change, the
//  colour toggle and playback work with dropped frames too (1c).
//

import AppKit
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct DisplayMemoryBudgetTests {

    private static let width = 300, height = 200
    /// Each grey display image: 300 × 200, one byte per pixel.
    private static let greyBytes = 300 * 200

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func writeFiles(_ count: Int, bayer: Bool = false, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
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
            return (url: try TestFITS.write(data, fileName: String(format: "frame%02d.fits", n), in: folder),
                    subfolderPath: "")
        }
    }

    private func load(_ files: [(url: URL, subfolderPath: String)], colour: Bool = false) async -> ImageStore {
        let store = ImageStore()
        store.pipeline.openFiles(files, metricsConfig: .off, debayerColorImages: colour)
        await store.pipeline.waitForProcessing()
        return store
    }

    private func pixels(_ image: NSImage?) throws -> RGBAPixels {
        let image = try #require(image)
        return try #require(RGBAPixels(image))
    }

    private func held(_ store: ImageStore) -> Int {
        store.entries.reduce(0) { $0 + $1.displayBytes }
    }

    /// Moves the cursor like the arrow keys do and waits for the redraws it starts.
    private func move(_ store: ImageStore, to entry: ImageEntry) async {
        store.selectedEntry = entry
        await store.pipeline.waitForProcessing()
    }

    @Test("Without a limit every display image stays")
    func noLimit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(6, in: folder))
        store.displayMemory.trim()
        #expect(store.displayMemory.limitBytes == nil)
        #expect(store.entries.allSatisfy { $0.displayImage != nil && $0.droppedDisplay == nil })
    }

    @Test("Over the limit the frames viewed least recently are dropped, never the cursor")
    func dropsLeastRecentlyViewed() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(6, in: folder))
        let entries = store.entries
        #expect(held(store) == 6 * Self.greyBytes)
        // Viewed in this order: 4, 0, 5; the others never (their images came at load time).
        for index in [4, 0, 5] { store.displayMemory.viewed(entries[index]) }
        store.selectedEntry = entries[5]

        store.displayMemory.limitBytes = 3 * Self.greyBytes
        store.displayMemory.trim()

        #expect(held(store) <= 3 * Self.greyBytes)
        // Never viewed go first (1, 2, 3), so the viewed ones stay.
        #expect(entries[1].droppedDisplay != nil && entries[2].droppedDisplay != nil && entries[3].droppedDisplay != nil)
        #expect([0, 4, 5].allSatisfy { entries[$0].displayImage != nil })
        // Thumbnails and metrics stay; the placeholder has the display image's size.
        for index in [1, 2, 3] {
            #expect(entries[index].thumbnail != nil)
            #expect(entries[index].droppedDisplay?.placeholder?.size == NSSize(width: Self.width, height: Self.height))
        }
    }

    @Test("Raising the limit draws nothing; lowering it drops at once")
    func changingTheLimit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(4, in: folder))
        store.selectedEntry = store.entries[0]
        store.displayMemory.limitBytes = Self.greyBytes
        await store.displayMemory.waitForTrim()
        #expect(store.entries.filter { $0.droppedDisplay != nil }.count == 3)

        store.displayMemory.limitBytes = 10 * Self.greyBytes
        await store.displayMemory.waitForTrim()
        #expect(store.entries.filter { $0.droppedDisplay != nil }.count == 3)
    }

    @Test("A dropped frame is drawn again when the cursor comes, byte-identical")
    func redrawOnVisit() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, in: folder))
        let target = store.entries[2]
        let before = try pixels(target.displayImage)
        store.selectedEntry = store.entries[0]
        target.dropDisplayImages()
        #expect(target.needsRedraw)

        store.displayMemory.limitBytes = 10 * Self.greyBytes
        await move(store, to: target)

        let after = try pixels(target.displayImage)
        #expect(after.bytes == before.bytes)
        #expect(target.droppedDisplay == nil && !target.redrawFailed)
    }

    @Test("A colour frame comes back in colour; its grey render stays dropped")
    func redrawColour() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: true, in: folder), colour: true)
        let target = store.entries[1]
        let before = try pixels(target.cachedColourDisplay)
        store.selectedEntry = store.entries[0]
        target.dropDisplayImages()
        #expect(target.droppedDisplay?.isColour == true)

        store.displayMemory.limitBytes = 100 * Self.greyBytes
        await move(store, to: target)

        #expect(target.displayImage === target.cachedColourDisplay)
        #expect(target.cachedGreyscaleDisplay == nil)
        let after = try pixels(target.displayImage)
        #expect(after.bytes == before.bytes)
    }

    @Test("The frames ahead in the direction of travel are kept and drawn again")
    func readAhead() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(14, in: folder))
        let order = store.sidebarNavigationEntries(isSimpleMode: false)
        store.selectedEntry = order[0]
        for entry in order.dropFirst() { entry.dropDisplayImages() }
        store.displayMemory.limitBytes = 100 * Self.greyBytes

        // Forward from 2 to 3: 3 + eight ahead (4…11) + two behind (2, 1).
        store.selectedEntry = order[2]
        await move(store, to: order[3])
        let expected = Set((1...11).map { order[$0].id })
        #expect(store.displayMemory.protectedIDs == expected)
        #expect((1...11).allSatisfy { order[$0].displayImage != nil })
        #expect([12, 13].allSatisfy { order[$0].droppedDisplay != nil })

        // Backward from 13 to 12: 12 + eight before (11…4) + one after (13).
        store.selectedEntry = order[13]
        await move(store, to: order[12])
        #expect(store.displayMemory.protectedIDs == Set((4...13).map { order[$0].id }))
        #expect([12, 13].allSatisfy { order[$0].displayImage != nil })
    }

    @Test("A file that can't be read marks the frame; the next visit tries again")
    func unreadableFile() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, in: folder))
        let target = store.entries[2]
        let saved = try Data(contentsOf: target.url)
        store.selectedEntry = store.entries[0]
        target.dropDisplayImages()
        store.displayMemory.limitBytes = 10 * Self.greyBytes

        try FileManager.default.removeItem(at: target.url)
        await move(store, to: target)
        #expect(target.redrawFailed)
        #expect(target.displayImage == nil && target.droppedDisplay?.placeholder != nil)

        try saved.write(to: target.url)
        await move(store, to: store.entries[0])
        await move(store, to: target)
        #expect(!target.redrawFailed && target.displayImage != nil)
    }

    // MARK: - Features that used the images in memory (1c)

    @Test("A thumbnail-size change makes the dropped frames' thumbnails from their files, as a normal store does")
    func thumbnailsOfDroppedFrames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(4, bayer: true, in: folder)
        let store = await load(files, colour: true)
        let reference = await load(files, colour: true)
        store.selectedEntry = store.entries[0]
        for entry in store.entries.dropFirst() { entry.dropDisplayImages() }
        store.displayMemory.limitBytes = 100 * Self.greyBytes

        store.pipeline.regenerateThumbnails(size: 60)
        reference.pipeline.regenerateThumbnails(size: 60)
        await store.pipeline.waitForProcessing()
        await reference.pipeline.waitForProcessing()

        for (entry, expected) in zip(store.entries, reference.entries) {
            #expect(try pixels(entry.thumbnail).bytes == pixels(expected.thumbnail).bytes)
        }
        for entry in store.entries.dropFirst() {
            // Still dropped: the image drawn for the thumbnail isn't kept.
            #expect(entry.displayImage == nil && entry.cachedColourDisplay == nil)
            #expect(entry.cachedColourThumb === entry.thumbnail)
            let placeholder = try #require(entry.droppedDisplay?.placeholder)
            #expect(placeholder.size == entry.droppedDisplay?.displaySize)
            #expect(try pixels(placeholder).width == 60)
        }
    }

    @Test("Colour off with dropped frames: their grey image is the load's, binned 2×2")
    func greyToggleOfDroppedFrames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(3, bayer: true, in: folder), colour: true)
        let loadGrey = try store.entries.map { try pixels($0.cachedGreyscaleDisplay) }
        store.selectedEntry = store.entries[0]
        for entry in store.entries.dropFirst() { entry.dropDisplayImages() }

        store.pipeline.recolorImages(debayer: false, maxDisplaySize: 1024, maxThumbnailSize: 120)
        await store.pipeline.waitForProcessing()

        for (entry, expected) in zip(store.entries, loadGrey) {
            #expect(entry.displayImage === entry.cachedGreyscaleDisplay)
            let grey = try pixels(entry.displayImage)
            #expect(grey.width == expected.width && grey.height == expected.height)
            #expect(grey.bytes == expected.bytes)
            guard case .grey(.rggb, 1024) = entry.greyRecipe else {
                Issue.record("Expected the binned grey recipe, got \(String(describing: entry.greyRecipe))")
                continue
            }
        }
    }

    @Test("Colour on with dropped frames: their colour images are a colour load's")
    func colourToggleOfDroppedFrames() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(3, bayer: true, in: folder)
        let store = await load(files, colour: false)
        let reference = await load(files, colour: true)
        store.selectedEntry = store.entries[0]
        for entry in store.entries.dropFirst() { entry.dropDisplayImages() }

        store.pipeline.recolorImages(debayer: true, maxDisplaySize: 1024, maxThumbnailSize: 120)
        await store.pipeline.waitForProcessing()

        for (entry, expected) in zip(store.entries, reference.entries) {
            #expect(entry.displayImage === entry.cachedColourDisplay)
            #expect(try pixels(entry.displayImage).bytes == pixels(expected.cachedColourDisplay).bytes)
            #expect(entry.droppedDisplay == nil)
        }
    }

    @Test("Playback reads ahead like the arrow keys")
    func playbackReadsAhead() async throws {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = await load(try writeFiles(12, in: folder))
        let order = store.sidebarNavigationEntries(isSimpleMode: false)
        store.selectedEntry = order[0]
        for entry in order.dropFirst() { entry.dropDisplayImages() }
        store.displayMemory.limitBytes = 100 * Self.greyBytes

        let viewer = ViewerState()
        #expect(viewer.advancePlayback(store: store, settings: AppSettings()))
        await store.pipeline.waitForProcessing()

        #expect(store.selectedEntry === order[1])
        // 1 + eight ahead (2…9) + one behind (0, which wasn't dropped).
        #expect((1...9).allSatisfy { order[$0].displayImage != nil })
        #expect([10, 11].allSatisfy { order[$0].droppedDisplay != nil })
    }

    @Test("The setting is a share of the memory, 10–90 % in steps of 10")
    func setting() {
        #expect(AppSettings.clampedDisplayMemoryPercent(50) == 50)
        #expect(AppSettings.clampedDisplayMemoryPercent(5) == 10)
        #expect(AppSettings.clampedDisplayMemoryPercent(95) == 90)
        #expect(AppSettings.clampedDisplayMemoryPercent(44) == 40)
        let sixteenGB: UInt64 = 16 << 30
        #expect(AppSettings.displayMemoryBytes(percent: 50, physicalMemory: sixteenGB) == 8 << 30)
        #expect(AppSettings.displayMemoryBytes(percent: 10, physicalMemory: sixteenGB) == Int(sixteenGB / 10))
    }
}
