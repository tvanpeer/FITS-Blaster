//
//  TestFITS.swift
//  FITS Blaster Tests
//
//  Builds small synthetic FITS files for tests: header cards, big-endian pixel
//  data and the 2880-byte block padding. Malformed-input tests use the same
//  helpers with deliberately wrong cards.
//

import Foundation

enum TestFITS {

    // MARK: - Header cards

    /// A `KEY = value` card padded to 80 characters. Pass `value` already laid out
    /// (the typed overloads right-align it in columns 11–30 like fixed-format FITS).
    static func card(_ key: String, value: String) -> String {
        let keyword = key.padding(toLength: 8, withPad: " ", startingAt: 0)
        return (keyword + "= " + value).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    static func card(_ key: String, bool value: Bool) -> String {
        card(key, value: String(repeating: " ", count: 19) + (value ? "T" : "F"))
    }

    static func card(_ key: String, int value: Int) -> String {
        card(key, value: rightAligned(String(value)))
    }

    static func card(_ key: String, float value: Double) -> String {
        card(key, value: rightAligned(String(value)))
    }

    /// A card without a value, e.g. COMMENT, padded to 80 characters.
    static func commentCard(_ text: String = "") -> String {
        ("COMMENT " + text).padding(toLength: 80, withPad: " ", startingAt: 0)
    }

    static let endCard = "END".padding(toLength: 80, withPad: " ", startingAt: 0)

    /// SIMPLE, BITPIX, NAXIS, NAXIS1, NAXIS2, optional BZERO/BSCALE, then `extraCards`.
    /// No END card: `fileData` adds it.
    static func imageCards(bitpix: Int, width: Int, height: Int,
                           bzero: Double? = nil, bscale: Double? = nil,
                           extraCards: [String] = []) -> [String] {
        var cards = [
            card("SIMPLE", bool: true),
            card("BITPIX", int: bitpix),
            card("NAXIS", int: 2),
            card("NAXIS1", int: width),
            card("NAXIS2", int: height),
        ]
        if let bzero { cards.append(card("BZERO", float: bzero)) }
        if let bscale { cards.append(card("BSCALE", float: bscale)) }
        return cards + extraCards
    }

    private static func rightAligned(_ s: String) -> String {
        String(repeating: " ", count: max(0, 20 - s.count)) + s
    }

    // MARK: - Pixel data (big-endian, as FITS requires)

    static func bigEndian(_ values: [Int16]) -> Data {
        var data = Data(capacity: values.count * 2)
        for v in values {
            let u = UInt16(bitPattern: v)
            data.append(UInt8(u >> 8))
            data.append(UInt8(u & 0xFF))
        }
        return data
    }

    static func bigEndian(_ values: [Float]) -> Data {
        var data = Data(capacity: values.count * 4)
        for v in values { withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    static func bigEndian(_ values: [Double]) -> Data {
        var data = Data(capacity: values.count * 8)
        for v in values { withUnsafeBytes(of: v.bitPattern.bigEndian) { data.append(contentsOf: $0) } }
        return data
    }

    // MARK: - Files

    /// Header cards plus END padded with spaces to whole blocks, then `pixels`
    /// padded with zeros. `withEnd: false` leaves out the END card.
    static func fileData(cards: [String], pixels: Data, withEnd: Bool = true) -> Data {
        var data = Data((cards + (withEnd ? [endCard] : [])).joined().utf8)
        while data.count % 2880 != 0 { data.append(0x20) }
        var pixelData = pixels
        while pixelData.count % 2880 != 0 { pixelData.append(0x00) }
        data.append(pixelData)
        return data
    }

    /// A 16-bit 256×256 FITS file with a flat background and ten round Gaussian stars (a
    /// frame needs at least `MetricsCalculator.Constants.minimumStars` to be measured,
    /// step 13g). `seed` varies the stars' brightness and size.
    static func starFieldData(seed: Int, extraCards: [String] = []) -> Data {
        let width = 256, height = 256
        var pixels = [Float](repeating: 1000, count: width * height)
        let stars = [(60, 70), (180, 60), (120, 150), (200, 200), (40, 210),
                     (30, 30), (220, 120), (90, 110), (150, 220), (230, 30)]
        for (i, (cx, cy)) in stars.enumerated() {
            let amplitude = Float(6000 + 900 * ((i + seed) % 4))
            let sigma: Float = 2.0 + 0.3 * Float((i + seed) % 3)
            for y in max(0, cy - 12)...min(height - 1, cy + 12) {
                for x in max(0, cx - 12)...min(width - 1, cx + 12) {
                    let d2 = Float((x - cx) * (x - cx) + (y - cy) * (y - cy))
                    pixels[y * width + x] += amplitude * exp(-d2 / (2 * sigma * sigma))
                }
            }
        }
        let stored = pixels.map { Int16(bitPattern: UInt16(min(65535, $0.rounded())) &- 32768) }
        let cards = imageCards(bitpix: 16, width: width, height: height, bzero: 32768, extraCards: extraCards)
        return fileData(cards: cards, pixels: bigEndian(stored))
    }

    /// Writes `data` to a new file in the temporary directory. The caller removes it.
    static func write(_ data: Data, fileName: String = "\(UUID().uuidString).fits",
                      in folder: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let url = folder.appending(component: fileName)
        try data.write(to: url)
        return url
    }
}
