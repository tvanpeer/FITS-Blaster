//
//  GreyPassPerFolderTests.swift
//  FITS Blaster Tests
//
//  A mono folder gets its shared grey stretch as soon as it is read, before the next
//  folder's Phase A, while its files are still in the file cache (master-plan 9f part 2a).
//  The images are the same as with the pass after the whole load: the folder's median
//  clips and the same kernel.
//

import AppKit
import Testing
@testable import FITS_Blaster

@MainActor
@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"), .timeLimit(.minutes(1)))
struct GreyPassPerFolderTests {

    private static let width = 300, height = 200
    private static let displaySize = 128
    /// More frames than Phase A reads at once, so some of a folder are read when the next
    /// folder is reached.
    private static let framesPerFolder = LoadPipeline.phaseAConcurrency + 2

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// `count` 16-bit frames in `folder/name` with a gradient, deterministic noise and a
    /// per-frame offset (`level` shifts the whole folder); with `bayer` the header says RGGB.
    private func writeFolder(_ name: String, count: Int, level: Int = 0, bayer: Bool = false,
                             in root: URL) throws -> [(url: URL, subfolderPath: String)] {
        let folder = root.appending(component: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try (0..<count).map { n in
            let stored = (0..<(Self.width * Self.height)).map { i -> Int16 in
                let x = i % Self.width, y = i / Self.width
                let channel = bayer ? (y % 2) * 2 + (x % 2) : 0
                let value = 2000 + level + channel * 1500 + (x + y) * 20 + n * 150 + (i * 37) % 400
                return Int16(bitPattern: UInt16(value) &- 32768)
            }
            let extra = bayer ? [TestFITS.card("BAYERPAT", value: "'RGGB'")] : []
            let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height,
                                            bzero: 32768, extraCards: extra)
            let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
            return (url: try TestFITS.write(data, fileName: "frame\(n).fits", in: folder), subfolderPath: name)
        }
    }

    private func entries(_ files: [(url: URL, subfolderPath: String)], in store: ImageStore) -> [ImageEntry] {
        let entries = files.map { file in
            let entry = ImageEntry(url: file.url)
            entry.subfolderPath = file.subfolderPath
            return entry
        }
        store.entries.append(contentsOf: entries)
        return entries
    }

    /// Every frame has the shared grey recipe with its folder's median clips, and its image
    /// is what that recipe makes from the file.
    private func expectFolderStretch(_ folder: [ImageEntry]) async throws {
        let clips = GreyClips.median(of: folder.compactMap(\.greyClips))
        for entry in folder {
            guard case .sharedGrey(let used, nil, Self.displaySize) = entry.greyRecipe else {
                Issue.record("Expected the shared grey recipe, got \(String(describing: entry.greyRecipe))")
                continue
            }
            #expect(used == clips)
            let image = try #require(entry.displayImage)
            let again = try #require(await FrameLoading.renderAgain(url: entry.url, recipe: .sharedGrey(
                clips: clips, bayerPattern: nil, maxDisplaySize: Self.displaySize)))
            let shown = try #require(RGBAPixels(image)), expected = try #require(RGBAPixels(again))
            #expect(shown.bytes == expected.bytes)
        }
    }

    private func ids(_ entries: [ImageEntry]) -> Set<ObjectIdentifier> {
        Set(entries.map(ObjectIdentifier.init))
    }

    @Test("Grouped by folder in the order the folders first appear; grouped input unchanged")
    func grouping() {
        func entry(_ folder: String, _ n: Int) -> ImageEntry {
            let entry = ImageEntry(url: URL(filePath: "/x/\(folder)/\(n).fits"))
            entry.subfolderPath = folder
            return entry
        }
        let a1 = entry("A", 1), b1 = entry("B", 1), a2 = entry("A", 2), c1 = entry("C", 1), b2 = entry("B", 2)
        #expect(LoadPipeline.groupedByFolder([a1, b1, a2, c1, b2]).map(ObjectIdentifier.init)
                == [a1, a2, b1, b2, c1].map(ObjectIdentifier.init))
        let grouped = [a1, a2, b1, b2, c1]
        #expect(LoadPipeline.groupedByFolder(grouped).map(ObjectIdentifier.init)
                == grouped.map(ObjectIdentifier.init))
    }

    @Test("Mono: a folder is stretched before the next one is read; the last one is left to the caller")
    func monoDuringLoad() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore()
        let first  = entries(try writeFolder("A", count: Self.framesPerFolder, in: root), in: store)
        let second = entries(try writeFolder("B", count: Self.framesPerFolder, level: 3000, in: root), in: store)

        let pending = await store.pipeline.processParallel(first + second, selectFirst: false,
                                                           maxDisplaySize: Self.displaySize,
                                                           metricsConfig: .off)
        #expect(ids(pending) == ids(second))
        try await expectFolderStretch(first)
        for entry in second {
            guard case .grey = entry.greyRecipe else {
                Issue.record("Expected Phase A's grey recipe before the caller's pass")
                continue
            }
        }
    }

    @Test("Mono load: every folder its own shared stretch, also when the scan mixes the folders")
    func monoLoad() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try writeFolder("A", count: Self.framesPerFolder, in: root)
        let b = try writeFolder("B", count: Self.framesPerFolder, level: 3000, in: root)
        // A's frames before and after B's, as a scan lists files and a subfolder by name.
        let half = a.count / 2
        let files = Array(a[..<half]) + b + Array(a[half...])

        let store = ImageStore()
        store.pipeline.openFiles(files, maxDisplaySize: Self.displaySize, metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.count == a.count + b.count)
        try await expectFolderStretch(store.entries.filter { $0.subfolderPath == "A" })
        try await expectFolderStretch(store.entries.filter { $0.subfolderPath == "B" })
    }

    @Test("Colour folders don't wait: all Bayer frames are left to the caller")
    func colourDoesNotWait() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ImageStore()
        let first  = entries(try writeFolder("A", count: Self.framesPerFolder, bayer: true, in: root), in: store)
        let second = entries(try writeFolder("B", count: Self.framesPerFolder, bayer: true, in: root), in: store)

        let pending = await store.pipeline.processParallel(first + second, selectFirst: false,
                                                           maxDisplaySize: Self.displaySize,
                                                           metricsConfig: .off, debayerColorImages: true)
        #expect(ids(pending) == ids(first + second))
        for entry in first + second {
            guard case .colour = entry.colourRecipe else {
                Issue.record("Expected the colour render, got \(String(describing: entry.colourRecipe))")
                continue
            }
        }
    }

    @Test("A display-size change: mono folders get their shared stretch again")
    func sizeChange() async throws {
        let root = try makeFolder()
        defer { try? FileManager.default.removeItem(at: root) }
        let files = try writeFolder("A", count: Self.framesPerFolder, in: root)
            + writeFolder("B", count: Self.framesPerFolder, level: 3000, in: root)
        let store = ImageStore()
        store.pipeline.openFiles(files, maxDisplaySize: 256, metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        store.pipeline.regenerateSizes(maxDisplaySize: Self.displaySize, maxThumbnailSize: 120,
                                       metricsConfig: .off, debayer: false)
        await store.pipeline.waitForProcessing()
        try await expectFolderStretch(store.entries.filter { $0.subfolderPath == "A" })
        try await expectFolderStretch(store.entries.filter { $0.subfolderPath == "B" })
    }
}
