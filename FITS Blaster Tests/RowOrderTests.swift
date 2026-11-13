//
//  RowOrderTests.swift
//  FITS Blaster Tests
//
//  Which way up a frame is drawn (issue #14): ROWORDER read from the header, and every
//  stretch path keeping the file's first row on top unless the file says BOTTOM-UP. The test
//  frame has a bright band in its first rows and dark sky elsewhere, so the band shows where
//  the first row ended up.
//

import AppKit
import Metal
import Testing
@testable import FITS_Blaster

// MARK: - Reading ROWORDER

struct RowOrderParseTests {

    @Test("ROWORDER is read without regard to case, spaces or quotes", arguments: [
        ("'TOP-DOWN'", RowOrder.topDown), ("'BOTTOM-UP'", .bottomUp),
        ("'bottom-up'", .bottomUp), ("'  BOTTOM-UP  '", .bottomUp), ("BOTTOM-UP", .bottomUp),
        ("'TOP-DOWN        '", .topDown), ("'UPSIDE'", .topDown), ("''", .topDown), ("42", .topDown),
    ])
    func parse(value: String, expected: RowOrder) {
        #expect(RowOrder.parse(from: ["ROWORDER": value]) == expected)
    }

    @Test("Without ROWORDER the rows are top-down, as other programs show them")
    func missing() {
        #expect(RowOrder.parse(from: [:]) == .topDown)
        #expect(RowOrder.parse(from: ["BAYERPAT": "'RGGB'"]) == .topDown)
    }

    @Test("Only bottom-up rows are flipped")
    func flipsRows() {
        #expect(RowOrder.bottomUp.flipsRows)
        #expect(!RowOrder.topDown.flipsRows)
    }
}

// MARK: - Where the first row ends up

/// The test frame and the checks on rendered images.
enum OrientationFrame {
    static let width = 64, height = 48
    /// The first rows of the file (the top for a top-down frame): bright.
    static let bandRows = 4

    /// Dark sky with deterministic noise and a bright band in the first `bandRows` rows.
    static func pixels() -> [Float] {
        var seed: UInt32 = 777
        return (0..<(width * height)).map { i in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            let noise = Float(seed >> 8) / Float(1 << 24) * 200
            return (i / width < bandRows ? 30_000 : 1_000) + noise
        }
    }

    /// The mean brightness (0–255) of the top and the bottom row of `image`, read from an
    /// RGBA copy, so grey and colour images are measured the same way.
    static func topAndBottom(_ image: NSImage) throws -> (top: Double, bottom: Double) {
        let cg = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let w = cg.width, h = cg.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let drawn = bytes.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                          bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        try #require(drawn)
        // Row 0 of the bitmap is the top of the picture.
        func mean(row: Int) -> Double {
            var sum = 0
            for x in 0..<w { let p = (row * w + x) * 4; sum += Int(bytes[p]) + Int(bytes[p + 1]) + Int(bytes[p + 2]) }
            return Double(sum) / Double(w * 3)
        }
        return (mean(row: 0), mean(row: h - 1))
    }

    /// Records whether the band is at the top (`flipRows` false) or the bottom (true).
    static func expectBand(_ image: NSImage?, flipRows: Bool, _ path: String) throws {
        let rows = try topAndBottom(try #require(image, "\(path) gave no image"))
        let (bright, dark) = flipRows ? (rows.bottom, rows.top) : (rows.top, rows.bottom)
        #expect(bright > 200 && dark < 100,
                "\(path), flipRows \(flipRows): top \(rows.top), bottom \(rows.bottom)")
    }
}

struct RowOrderCPUTests {

    @Test("CPU grey stretch: first row on top unless flipped", arguments: [false, true], [0, 32])
    func cpuGrey(flipRows: Bool, maxDisplaySize: Int) throws {
        var pixels = OrientationFrame.pixels()
        let image = ImageStretcher.createImage(from: &pixels, width: OrientationFrame.width,
                                               height: OrientationFrame.height, flipRows: flipRows,
                                               maxDisplaySize: maxDisplaySize)
        try OrientationFrame.expectBand(image, flipRows: flipRows, "CPU grey")
    }

    @Test("CPU RGB stretch (Quick Look colour): first row on top unless flipped", arguments: [false, true], [0, 32])
    func cpuRGB(flipRows: Bool, maxDisplaySize: Int) throws {
        var rgb = OrientationFrame.pixels().flatMap { [$0, $0 * 0.9, $0 * 0.8] }
        let image = ImageStretcher.createRGBImage(from: &rgb, width: OrientationFrame.width,
                                                  height: OrientationFrame.height, flipRows: flipRows,
                                                  maxDisplaySize: maxDisplaySize)
        try OrientationFrame.expectBand(image, flipRows: flipRows, "CPU RGB")
    }

    /// A 16-bit FITS file of the test frame, with `rowOrder` as its ROWORDER card (none when nil).
    static func writeFile(rowOrder: String?) throws -> URL {
        let stored = OrientationFrame.pixels().map { Int16(bitPattern: UInt16(min($0, 65_535)) &- 32768) }
        let extra = rowOrder.map { [TestFITS.card("ROWORDER", value: $0)] } ?? []
        let cards = TestFITS.imageCards(bitpix: 16, width: OrientationFrame.width, height: OrientationFrame.height,
                                        bzero: 32768, extraCards: extra)
        return try TestFITS.write(TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored)))
    }

    @Test("A file's ROWORDER reaches the reader and Quick Look", arguments: [
        ("'TOP-DOWN'", false), ("'BOTTOM-UP'", true), (nil, false),
    ] as [(String?, Bool)])
    func quickLookFile(rowOrder: String?, flipped: Bool) throws {
        let url = try Self.writeFile(rowOrder: rowOrder)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try FITSReader.read(from: url).rowOrder.flipsRows == flipped)
        #expect(try FITSReader.readForPreview(from: url, maxSize: 256).rowOrder.flipsRows == flipped)
        let image = try QuickLookRendering.image(of: url, readSize: 256, displaySize: 256)
        try OrientationFrame.expectBand(image, flipRows: flipped, "Quick Look, ROWORDER \(rowOrder ?? "none")")
    }
}

@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"))
struct RowOrderMetalTests {

    private static func buffer() throws -> MTLBuffer {
        let device = try #require(MetalContext.device)
        let pixels = OrientationFrame.pixels()
        return try #require(device.makeBuffer(bytes: pixels, length: pixels.count * MemoryLayout<Float>.stride,
                                              options: .storageModeShared))
    }

    @Test("Metal grey stretch, own and shared clips, mono and Bayer-binned", arguments: [false, true], [0, 16])
    func metalGrey(flipRows: Bool, maxDisplaySize: Int) async throws {
        let w = OrientationFrame.width, h = OrientationFrame.height
        for pattern in [nil, BayerPattern.rggb] as [BayerPattern?] {
            let own = await ImageStretcher.createImage(inputBuffer: try Self.buffer(), width: w, height: h,
                                                       flipRows: flipRows, maxDisplaySize: maxDisplaySize,
                                                       bayerPattern: pattern)
            try OrientationFrame.expectBand(own, flipRows: flipRows, "Metal grey, Bayer \(pattern != nil)")
            let clips = ImageStretcher.computeGreyClips(try Self.buffer(), pixelCount: w * h)
            let shared = await ImageStretcher.createImage(inputBuffer: try Self.buffer(), width: w, height: h,
                                                          flipRows: flipRows, clips: clips,
                                                          maxDisplaySize: maxDisplaySize, bayerPattern: pattern)
            try OrientationFrame.expectBand(shared, flipRows: flipRows, "Metal grey shared clips, Bayer \(pattern != nil)")
        }
    }

    @Test("Metal colour, in one pass and through the colour proxy", arguments: [false, true], [0, 16])
    func metalColour(flipRows: Bool, maxDisplaySize: Int) async throws {
        let w = OrientationFrame.width, h = OrientationFrame.height
        let clips = ImageStretcher.computeBayerClips(try Self.buffer(), width: w, height: h, rOffset: 0)
        try #require(clips.isValid)
        let onePass = await ImageStretcher.createBayerImage(inputBuffer: try Self.buffer(), width: w, height: h,
                                                            flipRows: flipRows, rOffset: 0, clips: clips,
                                                            maxDisplaySize: maxDisplaySize)
        try OrientationFrame.expectBand(onePass, flipRows: flipRows, "Metal colour")
        let proxy = try #require(await ImageStretcher.averageBayer(inputBuffer: try Self.buffer(), width: w, height: h,
                                                                   flipRows: flipRows, rOffset: 0,
                                                                   maxDisplaySize: maxDisplaySize))
        let twoPass = await ImageStretcher.createBayerImage(from: proxy, clips: clips)
        try OrientationFrame.expectBand(twoPass, flipRows: flipRows, "Metal colour proxy")
    }

    @Test("Loading a file draws it the way its ROWORDER says", arguments: [
        ("'TOP-DOWN'", false), ("'BOTTOM-UP'", true), (nil, false),
    ] as [(String?, Bool)])
    func loadFast(rowOrder: String?, flipped: Bool) async throws {
        let url = try RowOrderCPUTests.writeFile(rowOrder: rowOrder)
        defer { try? FileManager.default.removeItem(at: url) }
        let result = await FrameLoading.loadFast(url: url)
        #expect(result.rowOrder.flipsRows == flipped)
        try OrientationFrame.expectBand(result.display, flipRows: flipped, "loadFast, ROWORDER \(rowOrder ?? "none")")
    }
}
