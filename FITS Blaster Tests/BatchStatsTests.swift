//
//  BatchStatsTests.swift
//  FITS Blaster Tests
//
//  Tests that the info bar's load statistics (image count, megapixels) describe
//  the last batch only, not the whole session.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct BatchStatsTests {

    private static let width = 64
    private static let height = 32

    /// Writes `count` small 16-bit FITS files with a gradient into a new temporary folder.
    private func writeFiles(_ count: Int, prefix: String, in folder: URL) throws -> [(url: URL, subfolderPath: String)] {
        try (0..<count).map { i in
            let url = folder.appending(component: "\(prefix)-\(i).fits")
            try fitsData().write(to: url)
            return (url: url, subfolderPath: "")
        }
    }

    private func fitsData() -> Data {
        let cards = [
            card("SIMPLE", "T"), card("BITPIX", "16"), card("NAXIS", "2"),
            card("NAXIS1", String(Self.width)), card("NAXIS2", String(Self.height)),
            card("BZERO", "32768.0"),
            "END".padding(toLength: 80, withPad: " ", startingAt: 0)
        ]
        var data = Data(cards.joined().utf8)
        while data.count % 2880 != 0 { data.append(0x20) }
        for i in 0..<(Self.width * Self.height) {
            let value = UInt16(1000 + (i * 37) % 20000)
            let stored = UInt16(bitPattern: Int16(bitPattern: value &- 32768))
            data.append(UInt8(stored >> 8))
            data.append(UInt8(stored & 0xFF))
        }
        while data.count % 2880 != 0 { data.append(0x00) }
        return data
    }

    private func card(_ key: String, _ value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let padded = String(repeating: " ", count: max(0, 20 - value.count)) + value
        return (keyword + "= " + padded).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    @Test("A second batch reports only its own images and megapixels")
    func secondBatchCountsOnlyItself() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let store = ImageStore()
        store.openFiles(try writeFiles(3, prefix: "first", in: folder))
        await store.waitForProcessing()
        #expect(store.batchImageCount == 3)

        store.openFiles(try writeFiles(2, prefix: "second", in: folder))
        await store.waitForProcessing()
        #expect(store.entries.count == 5)
        #expect(store.batchImageCount == 2)
        let expected = 2.0 * Double(Self.width * Self.height) / 1_000_000
        #expect(abs((store.batchMegapixels ?? 0) - expected) < 1e-9)
    }
}
