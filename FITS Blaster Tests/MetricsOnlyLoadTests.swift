//
//  MetricsOnlyLoadTests.swift
//  FITS Blaster Tests
//
//  The command line without --render loads with `rendersImages` false (CODE_AUDIT §7.7):
//  no display images, thumbnails, histograms or clip bounds, so no grey normalisation
//  re-read either — and exactly the same headers, image info and metrics as a normal load.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct MetricsOnlyLoadTests {

    private static let width = 256
    private static let height = 256

    /// A 16-bit FITS file with a flat background and a few round Gaussian stars.
    private func starFieldData(seed: Int) -> Data {
        var pixels = [Float](repeating: 1000, count: Self.width * Self.height)
        let stars = [(60, 70), (180, 60), (120, 150), (200, 200), (40, 210)]
        for (i, (cx, cy)) in stars.enumerated() {
            let amplitude = Float(6000 + 900 * ((i + seed) % 4))
            let sigma: Float = 2.0 + 0.3 * Float((i + seed) % 3)
            for y in max(0, cy - 12)...min(Self.height - 1, cy + 12) {
                for x in max(0, cx - 12)...min(Self.width - 1, cx + 12) {
                    let d2 = Float((x - cx) * (x - cx) + (y - cy) * (y - cy))
                    pixels[y * Self.width + x] += amplitude * exp(-d2 / (2 * sigma * sigma))
                }
            }
        }
        let stored = pixels.map { Int16(bitPattern: UInt16(min(65535, $0.rounded())) &- 32768) }
        let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height, bzero: 32768,
                                        extraCards: [TestFITS.card("FILTER", value: "Ha")])
        return TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
    }

    private func writeFiles(in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        try (0..<3).map { i in
            let url = folder.appending(component: "stars-\(i).fits")
            try starFieldData(seed: i).write(to: url)
            return (url: url, subfolderPath: "")
        }
    }

    private struct Loaded: Equatable {
        let fwhm: Float?, eccentricity: Float?, snr: Float?, starCount: Int?
        let score: Int, sky: Float?, psf: Float?
        let headers: [String: String], info: String?, filterGroup: FilterGroup
        @MainActor init(_ e: ImageEntry) {
            let m = e.metrics
            fwhm = m?.fwhm; eccentricity = m?.eccentricity; snr = m?.snr; starCount = m?.starCount
            score = m?.qualityScore ?? -1; sky = m?.skyBackground; psf = m?.psfSignalWeight
            headers = e.headers; info = e.imageInfo; filterGroup = e.filterGroup
        }
    }

    private func load(_ files: [(url: URL, subfolderPath: String)], rendersImages: Bool) async -> ImageStore {
        let store = ImageStore()
        store.pipeline.openFiles(files, rendersImages: rendersImages)
        await store.pipeline.waitForProcessing()
        return store
    }

    private func byName(_ store: ImageStore) -> [String: Loaded] {
        Dictionary(uniqueKeysWithValues: store.entries.map { ($0.fileName, Loaded($0)) })
    }

    @Test("Without images the load measures the same headers, info and metrics")
    func sameMetrics() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(in: folder)

        let full = await load(files, rendersImages: true)
        let metricsOnly = await load(files, rendersImages: false)

        #expect(full.entries.allSatisfy { $0.metrics?.starCount != nil }, "The test frames must have stars")
        #expect(byName(metricsOnly) == byName(full))
        #expect(metricsOnly.groupStatistics[.ha]?.medianFWHM == full.groupStatistics[.ha]?.medianFWHM)
    }

    @Test("Without images no display image, thumbnail, histogram or clip bounds are made")
    func noImages() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = await load(try writeFiles(in: folder), rendersImages: false)
        #expect(store.entries.count == 3)
        for entry in store.entries {
            #expect(entry.displayImage == nil)
            #expect(entry.thumbnail == nil)
            #expect(entry.histogram == nil)
            // No grey clips: the grey normalisation pass doesn't read the file again.
            #expect(entry.greyClips == nil)
            #expect(entry.bayerClips == nil)
            #expect(entry.errorMessage == nil)
            #expect(!entry.isProcessing)
        }
    }

    @Test("A normal load still makes the images (the app's path is unchanged)")
    func normalLoadRenders() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = await load(try writeFiles(in: folder), rendersImages: true)
        for entry in store.entries {
            #expect(entry.displayImage != nil)
            #expect(entry.thumbnail != nil)
            #expect(entry.histogram != nil)
            #expect(entry.greyClips != nil)
        }
    }
}
