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

    private func starFieldData(seed: Int) -> Data {
        TestFITS.starFieldData(seed: seed, extraCards: [TestFITS.card("FILTER", value: "Ha")])
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

        #expect(full.entries.allSatisfy { $0.metrics?.starCount != nil && $0.metrics?.fwhm != nil },
                "The test frames must have stars")
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
