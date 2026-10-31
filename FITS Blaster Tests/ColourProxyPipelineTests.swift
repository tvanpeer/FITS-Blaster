//
//  ColourProxyPipelineTests.swift
//  FITS Blaster Tests
//
//  A colour load keeps each frame's colour proxy from Phase A within the budget and renders
//  the folder's colour images from them, so those files are read once (master-plan 9f
//  part 2b). The images are the same bytes as when every frame is read again, with any
//  budget; no proxy outlives the load.
//

import AppKit
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct ColourProxyPipelineTests {

    private static let width = 300, height = 200
    /// Smaller than the binned 150 × 100, so the kernels scale down.
    private static let displaySize = 128
    private static let frames = 6
    /// The proxy of one frame at `displaySize` (128 × 85 pixels, 12 bytes each).
    private static var proxyBytes: Int {
        let (w, h) = ImageStretcher.bayerDisplaySize(width: width, height: height, maxDisplaySize: displaySize)
        return ColourProxy.byteCount(width: w, height: h)
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `count` 16-bit RGGB frames in `folder/name`, levels different per CFA position.
    private func writeFolder(_ name: String, count: Int, in root: URL) throws -> [(url: URL, subfolderPath: String)] {
        let folder = root.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { n in
            let stored = (0..<(Self.width * Self.height)).map { i -> Int16 in
                let x = i % Self.width, y = i / Self.width
                let channel = (y % 2) * 2 + (x % 2)
                let value = 2000 + channel * 1500 + (x + y) * 20 + n * 150 + (i * 37) % 400
                return Int16(bitPattern: UInt16(value) &- 32768)
            }
            let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height, bzero: 32768,
                                            extraCards: [TestFITS.card("BAYERPAT", value: "'RGGB'")])
            let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
            return (url: try TestFITS.write(data, fileName: "frame\(n).fits", in: folder), subfolderPath: name)
        }
    }

    /// Loads `files` with a proxy budget of `limit` bytes and returns the store, the colour
    /// pixels per file name, and how many colour renders came from a proxy.
    private func load(_ files: [(url: URL, subfolderPath: String)], limit: Int,
                      colour: Bool = true) async throws -> (ImageStore, [String: [UInt8]], Int) {
        let store = ImageStore()
        store.pipeline.colourProxies = ColourProxies(limitBytes: limit)
        store.pipeline.openFiles(files, maxDisplaySize: Self.displaySize, metricsConfig: .off,
                                 debayerColorImages: colour)
        await store.pipeline.waitForProcessing()
        var pixels: [String: [UInt8]] = [:]
        for entry in store.entries {
            let image = try #require(entry.displayImage)
            pixels["\(entry.subfolderPath)/\(entry.url.lastPathComponent)"] = try #require(RGBAPixels(image)).bytes
        }
        return (store, pixels, await store.pipeline.colourProxies.rendersFromProxy)
    }

    private func expectEmpty(_ proxies: ColourProxies) async {
        #expect(await proxies.count == 0)
        #expect(await proxies.usedBytes == 0)
    }

    @Test("Every frame from its proxy, the same bytes as reading every file again")
    func allFromProxies() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try writeFolder("A", count: Self.frames, in: root)

        let (reread, rereadPixels, rereadFromProxy) = try await load(files, limit: 0)
        let (kept, keptPixels, keptFromProxy) = try await load(files, limit: ColourProxies.defaultLimit)
        #expect(rereadFromProxy == 0)
        #expect(keptFromProxy == Self.frames)
        #expect(keptPixels == rereadPixels)
        for entry in kept.entries {
            guard case .colour = entry.colourRecipe else {
                Issue.record("Expected the colour recipe, got \(String(describing: entry.colourRecipe))")
                continue
            }
            #expect(entry.displayImage === entry.cachedColourDisplay)
        }
        await expectEmpty(kept.pipeline.colourProxies)
        await expectEmpty(reread.pipeline.colourProxies)
    }

    @Test("A budget for two proxies: two frames from them, the rest read again, the same bytes")
    func partlyFromProxies() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try writeFolder("A", count: Self.frames, in: root)

        let (_, rereadPixels, _) = try await load(files, limit: 0)
        let (store, pixels, fromProxy) = try await load(files, limit: 2 * Self.proxyBytes + Self.proxyBytes / 2)
        #expect(fromProxy == 2)
        #expect(pixels == rereadPixels)
        await expectEmpty(store.pipeline.colourProxies)
    }

    @Test("Two folders: the first folder's proxies make room for the second's")
    func twoFolders() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try writeFolder("A", count: Self.frames, in: root) + writeFolder("B", count: Self.frames, in: root)

        let (_, rereadPixels, _) = try await load(files, limit: 0)
        let (store, pixels, fromProxy) = try await load(files, limit: ColourProxies.defaultLimit)
        #expect(fromProxy == 2 * Self.frames)
        #expect(pixels == rereadPixels)
        await expectEmpty(store.pipeline.colourProxies)
    }

    @Test("A grey load keeps no proxies")
    func greyLoad() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, _, fromProxy) = try await load(try writeFolder("A", count: Self.frames, in: root),
                                                   limit: ColourProxies.defaultLimit, colour: false)
        #expect(fromProxy == 0)
        await expectEmpty(store.pipeline.colourProxies)
    }

    @Test("Cancel: no proxy is left")
    func cancel() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore()
        store.pipeline.openFiles(try writeFolder("A", count: Self.frames, in: root),
                                 maxDisplaySize: Self.displaySize, metricsConfig: .off, debayerColorImages: true)
        await Task.yield()
        store.pipeline.cancelProcessing()
        await store.pipeline.waitForProcessing()
        await expectEmpty(store.pipeline.colourProxies)
    }
}
