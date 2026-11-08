//
//  MetricsModeSwitchTests.swift
//  FITS Blaster Tests
//
//  Switching between Geek mode (metrics on) and Simple mode (metrics off) through
//  LoadPipeline.recomputeMetrics: off hides the star metrics, on brings back exactly
//  the values a normal load measures, whether they come from the cache or from disk.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct MetricsModeSwitchTests {

    private func starFieldData(seed: Int) -> Data {
        TestFITS.starFieldData(seed: seed)
    }

    private func writeFiles(in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        try (0..<3).map { i in
            let url = folder.appending(component: "stars-\(i).fits")
            try starFieldData(seed: i).write(to: url)
            return (url: url, subfolderPath: "")
        }
    }

    private struct Values: Equatable {
        let fwhm: Float?, eccentricity: Float?, snr: Float?, starCount: Int?
        let score: Int, sky: Float?, psf: Float?
        init(_ m: FrameMetrics?) {
            fwhm = m?.fwhm; eccentricity = m?.eccentricity; snr = m?.snr; starCount = m?.starCount
            score = m?.qualityScore ?? -1; sky = m?.skyBackground; psf = m?.psfSignalWeight
        }
    }

    private func values(_ store: ImageStore) -> [String: Values] {
        Dictionary(uniqueKeysWithValues: store.entries.map { ($0.fileName, Values($0.metrics)) })
    }

    private func makeTemporaryFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test("Off hides the star metrics; on restores the measured values from the cache")
    func offAndOnFromCache() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ImageStore()
        store.pipeline.openFiles(try writeFiles(in: folder), metricsConfig: MetricsConfig())
        await store.pipeline.waitForProcessing()
        let measured = values(store)
        #expect(measured.values.allSatisfy { $0.starCount != nil && $0.fwhm != nil },
                "The test frames must have stars")

        store.pipeline.recomputeMetrics(metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        for entry in store.entries {
            #expect(entry.metrics?.starCount == nil)
            #expect(entry.metrics?.fwhm == nil)
            #expect(entry.metrics?.qualityScore == 0)
        }

        store.pipeline.recomputeMetrics(metricsConfig: MetricsConfig())
        await store.pipeline.waitForProcessing()
        #expect(values(store) == measured)
    }

    @Test("Loaded with metrics off, switching on measures the same values as a normal load")
    func loadOffThenOnFromDisk() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(in: folder)

        let reference = ImageStore()
        reference.pipeline.openFiles(files, metricsConfig: MetricsConfig())
        await reference.pipeline.waitForProcessing()

        let store = ImageStore()
        store.pipeline.openFiles(files, metricsConfig: .off)
        await store.pipeline.waitForProcessing()
        #expect(store.entries.allSatisfy { $0.metrics == nil || $0.metrics?.starCount == nil })

        store.pipeline.recomputeMetrics(metricsConfig: MetricsConfig())
        await store.pipeline.waitForProcessing()
        #expect(values(store) == values(reference))
    }
}
