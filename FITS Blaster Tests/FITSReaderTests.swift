//
//  FITSReaderTests.swift
//  FITS Blaster Tests
//
//  Unit tests for FITSReader: header parsing, byte-swap, BZERO application,
//  and peekBitpix. Each test that needs pixel data builds a minimal valid
//  FITS file in the system temp directory and removes it on teardown.
//

import XCTest
@testable import FITS_Blaster

final class FITSReaderTests: XCTestCase {

    // MARK: - cleanHeaderString

    func testCleanHeaderStringStripsLeadingAndTrailingQuotes() {
        XCTAssertEqual(FITSReader.cleanHeaderString("'Ha              '"), "Ha")
        XCTAssertEqual(FITSReader.cleanHeaderString("'  OIII  '"), "OIII")
        XCTAssertEqual(FITSReader.cleanHeaderString("'Lum'"), "Lum")
    }

    func testCleanHeaderStringPreservesUnquotedValues() {
        XCTAssertEqual(FITSReader.cleanHeaderString("Ha"), "Ha")
        XCTAssertEqual(FITSReader.cleanHeaderString("  trimmed  "), "trimmed")
    }

    func testCleanHeaderStringHandlesEmpty() {
        XCTAssertEqual(FITSReader.cleanHeaderString(""), "")
        XCTAssertEqual(FITSReader.cleanHeaderString("''"), "")
    }

    // MARK: - peekBitpix

    func testPeekBitpixReturns16ForInt16File() throws {
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FITSReader.peekBitpix(url: url), 16)
    }

    func testPeekBitpixReturns8ForInt8File() throws {
        let url = try makeFITSFile(bitpix: 8, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FITSReader.peekBitpix(url: url), 8)
    }

    func testPeekBitpixReturns32ForInt32File() throws {
        let url = try makeFITSFile(bitpix: 32, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FITSReader.peekBitpix(url: url), 32)
    }

    func testPeekBitpixReturnsMinusMinus32ForFloatFile() throws {
        let url = try makeFITSFile(bitpix: -32, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(FITSReader.peekBitpix(url: url), -32)
    }

    func testPeekBitpixReturnsNilForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).fits")
        XCTAssertNil(FITSReader.peekBitpix(url: url))
    }

    // MARK: - read(from:) — header parsing

    func testReadParsesWidthAndHeight() throws {
        let url = try makeFITSFile(bitpix: 16, width: 8, height: 6)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.width,  8)
        XCTAssertEqual(image.height, 6)
    }

    func testReadParsesBitpix() throws {
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.bitpix, 16)
    }

    func testReadPixelCountMatchesDimensions() throws {
        let url = try makeFITSFile(bitpix: 16, width: 5, height: 7)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.pixelValues.count, 5 * 7)
    }

    // MARK: - read(from:) — BZERO application

    func testReadZeroPixelsWithNoBZERO() throws {
        // All-zero pixel data with no BZERO → all floats should be 0.
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4, bzero: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.minValue, 0, accuracy: 0.5)
        XCTAssertEqual(image.maxValue, 0, accuracy: 0.5)
    }

    func testReadBZEROIsAppliedToAllZeroPixels() throws {
        // All-zero pixel data with BZERO = 32768 (standard unsigned-16 offset).
        // Each stored value is 0; after BZERO application every float = 32768.
        let url = try makeFITSFile(bitpix: 16, width: 4, height: 4, bzero: 32768)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.minValue, 32768, accuracy: 0.5)
        XCTAssertEqual(image.maxValue, 32768, accuracy: 0.5)
    }

    func testReadBZEROIsAppliedToNonZeroPixels() throws {
        // Pixel data containing one big-endian 16-bit value of 100.
        // With BZERO = 1000, the result float should be 1100.
        let url = try makeFITSFile(bitpix: 16, width: 1, height: 1,
                                   bzero: 1000, pixelBigEndian16: 100)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.pixelValues.first ?? 0, 1100, accuracy: 0.5)
    }

    // MARK: - read(from:) — byte-swap (FITS Standard §4.4.1)

    func testReadByteSwapsInt16BigEndian() throws {
        // The 16-bit big-endian value 0x01F4 = 500.
        // After byte swap and BZERO=0, the float should be 500.
        let url = try makeFITSFile(bitpix: 16, width: 1, height: 1,
                                   bzero: nil, pixelBigEndian16: 500)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try FITSReader.read(from: url)
        XCTAssertEqual(image.pixelValues.first ?? 0, 500, accuracy: 0.5)
    }

    // MARK: - read(from:) — error cases

    func testReadThrowsForFloatFITS() throws {
        let url = try makeFITSFile(bitpix: -32, width: 4, height: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FITSReader.read(from: url)) { error in
            guard case FITSError.unsupportedBitpix(-32) = error else {
                return XCTFail("Expected unsupportedBitpix(-32), got \(error)")
            }
        }
    }

    func testReadThrowsForDoubleFITS() throws {
        let url = try makeFITSFile(bitpix: -64, width: 2, height: 2)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try FITSReader.read(from: url))
    }

    func testReadThrowsForMissingFile() {
        let url = URL(fileURLWithPath: "/tmp/no-such-file-\(UUID().uuidString).fits")
        XCTAssertThrowsError(try FITSReader.read(from: url))
    }

    // MARK: - FITS file builder helpers

    /// Writes a minimal valid FITS file to a temp URL and returns that URL.
    private func makeFITSFile(bitpix: Int, width: Int, height: Int,
                               bzero: Double? = nil,
                               pixelBigEndian16: Int16? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(component: "\(UUID().uuidString).fits")

        // ── Header block ──────────────────────────────────────────────────────
        var cards: [String] = [
            card("SIMPLE", bool: true,  comment: "Standard FITS"),
            card("BITPIX", int: bitpix, comment: "Bits per data value"),
            card("NAXIS",  int: 2,      comment: "Number of axes"),
            card("NAXIS1", int: width,  comment: "Width"),
            card("NAXIS2", int: height, comment: "Height"),
        ]
        if let bz = bzero {
            cards.append(card("BZERO", float: bz, comment: "Offset"))
        }
        cards.append(endCard())

        // Pad to 2880-byte boundary with spaces.
        var headerData = Data(cards.joined().utf8)
        while headerData.count % 2880 != 0 { headerData.append(0x20) } // ASCII space

        // ── Pixel data block ──────────────────────────────────────────────────
        let bytesPerPixel = abs(bitpix) / 8
        let totalPixels   = width * height
        var pixelData = Data(count: totalPixels * bytesPerPixel)

        // If a specific 16-bit value is requested, write it big-endian.
        if let val = pixelBigEndian16, bitpix == 16, totalPixels >= 1 {
            pixelData[0] = UInt8((val >> 8) & 0xFF)
            pixelData[1] = UInt8(val & 0xFF)
        }

        // Pad pixel block to 2880-byte boundary.
        while pixelData.count % 2880 != 0 { pixelData.append(0x00) }

        var fileData = headerData
        fileData.append(pixelData)
        try fileData.write(to: url)
        return url
    }

    // MARK: - Card builders (FITS §4.1 — 80-character fixed-width records)

    /// Logical (T/F) card.
    private func card(_ key: String, bool value: Bool, comment: String = "") -> String {
        // Logical values are right-justified in column 30 (1-indexed).
        let v = String(repeating: " ", count: 19) + (value ? "T" : "F")
        return fitsCard(key, value: v, comment: comment)
    }

    /// Integer card — right-justified in the value field.
    private func card(_ key: String, int value: Int, comment: String = "") -> String {
        let s = String(value)
        let v = String(repeating: " ", count: max(0, 20 - s.count)) + s
        return fitsCard(key, value: v, comment: comment)
    }

    /// Floating-point card — formatted without exponent for simple values.
    private func card(_ key: String, float value: Double, comment: String = "") -> String {
        let s: String
        if value == value.rounded() && abs(value) < 1e15 {
            s = String(format: "%.1f", value)
        } else {
            s = String(format: "%E", value)
        }
        let v = String(repeating: " ", count: max(0, 20 - s.count)) + s
        return fitsCard(key, value: v, comment: comment)
    }

    /// Assembles a complete 80-character header card.
    /// Layout: keyword(8) + "= "(2) + value(20) + " / "(3) + comment, padded to 80.
    private func fitsCard(_ key: String, value: String, comment: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        var card = keyword + "= " + value
        if !comment.isEmpty { card += " / " + comment }
        if card.count > 80 { return String(card.prefix(80)) }
        return card.padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    /// The END card — keyword padded to 80 characters with spaces.
    private func endCard() -> String {
        "END".padding(toLength: 80, withPad: " ", startingAt: 0)
    }
}
