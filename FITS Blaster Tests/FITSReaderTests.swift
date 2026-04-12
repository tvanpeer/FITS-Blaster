//
//  FITSReaderTests.swift
//  FITS Blaster Tests
//
//  Unit tests for FITSReader: header parsing, byte-swap, BZERO application,
//  and peekBitpix. Each test that needs pixel data builds a minimal valid
//  FITS file in the system temp directory and removes it on teardown.
//

import Foundation
import Testing
@testable import FITS_Blaster

struct FITSReaderTests {

    // MARK: - cleanHeaderString

    @Test("Strips FITS string quoting and whitespace", arguments: [
        ("'Ha              '", "Ha"),
        ("'  OIII  '",         "OIII"),
        ("'Lum'",              "Lum"),
    ])
    func cleanHeaderStringStripsQuotes(input: String, expected: String) {
        #expect(FITSReader.cleanHeaderString(input) == expected)
    }

    @Test("Preserves unquoted values", arguments: [
        ("Ha",          "Ha"),
        ("  trimmed  ", "trimmed"),
    ])
    func cleanHeaderStringPreservesUnquoted(input: String, expected: String) {
        #expect(FITSReader.cleanHeaderString(input) == expected)
    }

    @Test("Handles empty strings", arguments: [
        ("",   ""),
        ("''", ""),
    ])
    func cleanHeaderStringHandlesEmpty(input: String, expected: String) {
        #expect(FITSReader.cleanHeaderString(input) == expected)
    }

    // MARK: - peekBitpix

    @Test("peekBitpix returns correct value", arguments: [
        (8,   "Int8"),
        (16,  "Int16"),
        (32,  "Int32"),
        (-32, "Float32"),
    ])
    func peekBitpixReturnsCorrectValue(bitpix: Int, label: String) throws {
        let url = try makeFITSFile(bitpix: bitpix, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(FITSReader.peekBitpix(url: url) == bitpix, "Expected BITPIX \(bitpix) for \(label)")
    }

    @Test("peekBitpix returns nil for missing file")
    func peekBitpixReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).fits")
        #expect(FITSReader.peekBitpix(url: url) == nil)
    }

    // MARK: - read(from:) — header parsing

    @Test("read parses width and height")
    func readParsesWidthAndHeight() throws {
        let url = try makeFITSFile(bitpix: 16, width: 8, height: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        #expect(image.width == 8)
        #expect(image.height == 6)
    }

    @Test("read parses bitpix")
    func readParsesBitpix() throws {
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        #expect(image.bitpix == 16)
    }

    @Test("read pixel count matches dimensions")
    func readPixelCountMatchesDimensions() throws {
        let url = try makeFITSFile(bitpix: 16, width: 5, height: 7)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        #expect(image.pixelValues.count == 5 * 7)
    }

    // MARK: - read(from:) — BZERO application

    @Test("Zero pixels with no BZERO remain zero")
    func readZeroPixelsWithNoBZERO() throws {
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4, bzero: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        #expect(abs(image.minValue) < 0.5, "Min should be ~0")
        #expect(abs(image.maxValue) < 0.5, "Max should be ~0")
    }

    @Test("BZERO is applied to all-zero pixels")
    func readBZEROIsAppliedToAllZeroPixels() throws {
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4, bzero: 32768)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        #expect(abs(image.minValue - 32768) < 0.5)
        #expect(abs(image.maxValue - 32768) < 0.5)
    }

    @Test("BZERO is applied to non-zero pixels")
    func readBZEROIsAppliedToNonZeroPixels() throws {
        let url = try makeFITSFile(bitpix: 16, width: 1, height: 1,
                                   bzero: 1000, pixelBigEndian16: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        let value = try #require(image.pixelValues.first)
        #expect(abs(value - 1100) < 0.5)
    }

    // MARK: - read(from:) — byte-swap

    @Test("read byte-swaps Int16 big-endian correctly")
    func readByteSwapsInt16BigEndian() throws {
        let url = try makeFITSFile(bitpix: 16, width: 1, height: 1,
                                   bzero: nil, pixelBigEndian16: 500)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        let value = try #require(image.pixelValues.first)
        #expect(abs(value - 500) < 0.5)
    }

    // MARK: - read(from:) — error cases

    @Test("read throws unsupportedBitpix for float FITS")
    func readThrowsForFloatFITS() throws {
        let url = try makeFITSFile(bitpix: -32, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try FITSReader.read(from: url)
            Issue.record("Expected unsupportedBitpix(-32) to be thrown")
        } catch FITSError.unsupportedBitpix(-32) {
            // expected
        } catch {
            Issue.record("Wrong error thrown: \(error)")
        }
    }

    @Test("read throws for double FITS")
    func readThrowsForDoubleFITS() throws {
        let url = try makeFITSFile(bitpix: -64, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            _ = try FITSReader.read(from: url)
            Issue.record("Expected an error to be thrown")
        } catch {
            // expected
        }
    }

    @Test("read throws for missing file")
    func readThrowsForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).fits")
        do {
            _ = try FITSReader.read(from: url)
            Issue.record("Expected an error to be thrown")
        } catch {
            // expected
        }
    }

    // MARK: - FITS file builder helpers

    private func makeFITSFile(bitpix: Int, width: Int, height: Int,
                               bzero: Double? = nil,
                               pixelBigEndian16: Int16? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).fits")

        var cards: [String] = [
            card("SIMPLE", bool: true),
            card("BITPIX", int: bitpix),
            card("NAXIS",  int: 2),
            card("NAXIS1", int: width),
            card("NAXIS2", int: height),
        ]
        if let bz = bzero { cards.append(card("BZERO", float: bz)) }
        cards.append(endCard())

        var headerData = Data(cards.joined().utf8)
        while headerData.count % 2880 != 0 { headerData.append(0x20) }

        let bytesPerPixel = abs(bitpix) / 8
        var pixelData = Data(count: width * height * bytesPerPixel)
        if let val = pixelBigEndian16, bitpix == 16, width * height >= 1 {
            pixelData[0] = UInt8((val >> 8) & 0xFF)
            pixelData[1] = UInt8(val & 0xFF)
        }
        while pixelData.count % 2880 != 0 { pixelData.append(0x00) }

        var fileData = headerData
        fileData.append(pixelData)
        try fileData.write(to: url)
        return url
    }

    private func card(_ key: String, bool value: Bool) -> String {
        let v = String(repeating: " ", count: 19) + (value ? "T" : "F")
        return fitsCard(key, value: v)
    }

    private func card(_ key: String, int value: Int) -> String {
        let s = String(value)
        return fitsCard(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }

    private func card(_ key: String, float value: Double) -> String {
        let s = value == value.rounded() && abs(value) < 1e15
            ? String(format: "%.1f", value) : String(format: "%E", value)
        return fitsCard(key, value: String(repeating: " ", count: max(0, 20 - s.count)) + s)
    }

    private func fitsCard(_ key: String, value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        let card = keyword + "= " + value
        return card.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    private func endCard() -> String {
        "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
