//
//  MetricsModeSwitchTests.swift
//  FITS Blaster Tests
//
//  Switching between Geek mode (metrics on) and Simple mode (metrics off) through
//  ImageStore.recomputeMetrics: off hides the star metrics, on brings back exactly
//  the values a normal load measures, whether they come from the cache or from disk.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct MetricsModeSwitchTests {

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
        let cards = TestFITS.imageCards(bitpix: 16, width: Self.width, height: Self.height, bzero: 32768)
        return TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored))
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
        store.openFiles(try writeFiles(in: folder), metricsConfig: MetricsConfig())
        await store.waitForProcessing()
        let measured = values(store)
        #expect(measured.values.allSatisfy { $0.starCount != nil && $0.fwhm != nil },
                "The test frames must have stars")

        store.recomputeMetrics(metricsConfig: .off)
        await store.waitForProcessing()
        for entry in store.entries {
            #expect(entry.metrics?.starCount == nil)
            #expect(entry.metrics?.fwhm == nil)
            #expect(entry.metrics?.qualityScore == 0)
        }

        store.recomputeMetrics(metricsConfig: MetricsConfig())
        await store.waitForProcessing()
        #expect(values(store) == measured)
    }

    @Test("Loaded with metrics off, switching on measures the same values as a normal load")
    func loadOffThenOnFromDisk() async throws {
        let folder = try makeTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let files = try writeFiles(in: folder)

        let reference = ImageStore()
        reference.openFiles(files, metricsConfig: MetricsConfig())
        await reference.waitForProcessing()

        let store = ImageStore()
        store.openFiles(files, metricsConfig: .off)
        await store.waitForProcessing()
        #expect(store.entries.allSatisfy { $0.metrics == nil || $0.metrics?.starCount == nil })

        store.recomputeMetrics(metricsConfig: MetricsConfig())
        await store.waitForProcessing()
        #expect(values(store) == values(reference))
    }
}
