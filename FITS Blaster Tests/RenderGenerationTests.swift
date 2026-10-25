//
//  RenderGenerationTests.swift
//  FITS Blaster Tests
//
//  Colour toggles are batches and renders carry a generation (CODE_AUDIT §3.2): quick
//  toggles end on the last setting, colour turned on during a load also covers the
//  frames that weren't loaded yet, and Reset during a colour render shows nothing old.
//  These depend on order, not timing: the batch queue runs them one after another.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct RenderGenerationTests {

    private let displaySize = 1024
    private let thumbnailSize = 120

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `count` small 16-bit RGGB Bayer frames in `folder`, each with a slightly different signal.
    private func writeBayerFiles(_ count: Int, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        let width = 64, height = 64
        return try (0..<count).map { n in
            let stored = (0..<(width * height)).map { i -> Int16 in
                let x = i % width, y = i / width
                // Channel levels differ per CFA position, plus a gradient and a frame offset.
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

    private func load(_ files: [(url: URL, subfolderPath: String)], colour: Bool, into store: ImageStore) {
        store.pipeline.openFiles(files, maxDisplaySize: displaySize, maxThumbnailSize: thumbnailSize,
                                 metricsConfig: .off, debayerColorImages: colour)
    }

    private func recolor(_ store: ImageStore, colour: Bool) {
        store.pipeline.recolorImages(debayer: colour, maxDisplaySize: displaySize,
                                     maxThumbnailSize: thumbnailSize)
    }

    private func showsColour(_ entry: ImageEntry) -> Bool {
        entry.cachedColourDisplay != nil && entry.displayImage === entry.cachedColourDisplay
    }

    private func showsGrey(_ entry: ImageEntry) -> Bool {
        entry.cachedGreyscaleDisplay != nil && entry.displayImage === entry.cachedGreyscaleDisplay
    }

    @Test("Colour on, then off at once: every Bayer frame ends in grey")
    func onThenOff() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(4, in: folder), colour: false, into: store)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.allSatisfy { $0.isBayer && showsGrey($0) })

        recolor(store, colour: true)
        recolor(store, colour: false)
        await store.pipeline.waitForProcessing()

        #expect(store.entries.allSatisfy(showsGrey))
        #expect(!store.pipeline.isBatchProcessing)
    }

    @Test("Colour off, then on at once: every Bayer frame ends in colour")
    func offThenOn() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(4, in: folder), colour: true, into: store)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.allSatisfy(showsColour))

        recolor(store, colour: false)
        recolor(store, colour: true)
        await store.pipeline.waitForProcessing()

        #expect(store.entries.allSatisfy(showsColour))
    }

    @Test("Colour turned on during a load: every frame ends in colour, also those not loaded yet")
    func colourOnDuringLoad() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(6, in: folder), colour: false, into: store)
        recolor(store, colour: true)        // the load hasn't added a single frame yet
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == 6)
        #expect(store.entries.allSatisfy(showsColour))
    }

    @Test("Colour turned off during a colour load: every frame ends in grey")
    func colourOffDuringLoad() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(6, in: folder), colour: true, into: store)
        recolor(store, colour: false)
        await store.pipeline.waitForProcessing()

        #expect(store.entries.count == 6)
        #expect(store.entries.allSatisfy(showsGrey))
    }

    @Test("Toggling three times quickly ends on the last setting")
    func threeQuickToggles() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(4, in: folder), colour: false, into: store)
        await store.pipeline.waitForProcessing()

        recolor(store, colour: true)
        recolor(store, colour: false)
        recolor(store, colour: true)
        await store.pipeline.waitForProcessing()

        #expect(store.entries.allSatisfy(showsColour))
    }

    @Test("Reset during a colour render leaves an empty session and stops")
    func resetDuringColourRender() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImageStore()
        load(try writeBayerFiles(4, in: folder), colour: false, into: store)
        await store.pipeline.waitForProcessing()

        recolor(store, colour: true)
        let render = store.pipeline.processingTask
        store.reset()
        await render?.value

        #expect(store.entries.isEmpty)
        #expect(!store.pipeline.isBatchProcessing)
        #expect(store.pipeline.restretchingMessage == nil)
    }

    @Test("A colour toggle without Bayer frames and without a load does nothing")
    func toggleWithoutBayerFrames() {
        let store = ImageStore()
        recolor(store, colour: true)
        #expect(!store.pipeline.isBatchProcessing)
        #expect(store.pipeline.processingTask == nil)
    }
}
