//
//  FITSMalformedInputTests.swift
//  FITS Blaster Tests
//
//  Malformed FITS headers must throw a FITSError on every read path, never crash
//  (CODE_AUDIT §5.2, §5.3, §5.19, §5.20). Quick Look parses files from Finder
//  without the user opening them, so this input is untrusted.
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

struct FITSMalformedInputTests {

    /// The three ways the app and the Quick Look extensions read a file.
    enum ReadPath: String, CaseIterable, CustomTestStringConvertible {
        case array, metalBuffer, preview
        var testDescription: String { rawValue }

        func read(_ url: URL) throws {
            switch self {
            case .array:
                _ = try FITSReader.read(from: url)
            case .metalBuffer:
                let device = try #require(ImageStretcher.metalDevice)
                _ = try FITSReader.readIntoBuffer(from: url, device: device)
            case .preview:
                _ = try FITSReader.readForPreview(from: url)
            }
        }
    }

    /// A malformed file: its header cards and how many pixel bytes follow.
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let cards: [String]
        let pixelBytes: Int
        var withEnd = true
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        // Negative sizes multiply to a positive size and used to pass the length check.
        Case(name: "negative NAXIS1 and NAXIS2",
             cards: TestFITS.imageCards(bitpix: 16, width: -64, height: -64), pixelBytes: 64 * 64 * 2),
        Case(name: "zero NAXIS1",
             cards: TestFITS.imageCards(bitpix: 16, width: 0, height: 64), pixelBytes: 2880),
        Case(name: "NAXIS1 above the limit",
             cards: TestFITS.imageCards(bitpix: 8, width: FITSReader.maxAxisLength + 1, height: 1),
             pixelBytes: FITSReader.maxAxisLength + 1),
        Case(name: "huge sizes whose product overflows",
             cards: TestFITS.imageCards(bitpix: 32, width: 1 << 32, height: 1 << 32), pixelBytes: 2880),
        Case(name: "NAXIS above 999",
             cards: [TestFITS.card("SIMPLE", bool: true), TestFITS.card("BITPIX", int: 16),
                     TestFITS.card("NAXIS", int: 1000), TestFITS.card("NAXIS1", int: 4),
                     TestFITS.card("NAXIS2", int: 4)],
             pixelBytes: 32),
        Case(name: "missing END card",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4), pixelBytes: 32, withEnd: false),
        Case(name: "no END in the first 100 header blocks",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4,
                                        extraCards: [String](repeating: TestFITS.commentCard(),
                                                             count: FITSReader.maxHeaderBlocks * 36)),
             pixelBytes: 32),
        Case(name: "truncated pixel data",
             cards: TestFITS.imageCards(bitpix: 16, width: 100, height: 100), pixelBytes: 10),
        Case(name: "BSCALE is NaN",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4, bscale: .nan), pixelBytes: 32),
        Case(name: "BSCALE is infinite",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4, bscale: .infinity), pixelBytes: 32),
        Case(name: "BZERO is minus infinity",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4, bzero: -.infinity), pixelBytes: 32),
        // Finite as Double, infinite once converted to Float for scaling.
        Case(name: "BSCALE beyond the Float range",
             cards: TestFITS.imageCards(bitpix: 16, width: 4, height: 4, bscale: 1e39), pixelBytes: 32),
    ]

    @Test("Malformed headers throw instead of crashing", arguments: cases, ReadPath.allCases)
    func malformedHeaderThrows(testCase: Case, path: ReadPath) throws {
        let data = TestFITS.fileData(cards: testCase.cards, pixels: Data(count: testCase.pixelBytes),
                                     withEnd: testCase.withEnd)
        // Truncate exactly: fileData pads to whole blocks, which would hide the truncation.
        let url = try TestFITS.write(testCase.name == "truncated pixel data"
                                     ? data.prefix(2880 + testCase.pixelBytes) : data)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(throws: FITSError.self) { try path.read(url) }
    }

    // MARK: - Limits that must still be accepted

    @Test("An image exactly at the size limit is read", arguments: ReadPath.allCases)
    func imageAtSizeLimitIsRead(path: ReadPath) throws {
        let width = FITSReader.maxAxisLength
        let cards = TestFITS.imageCards(bitpix: 8, width: width, height: 1)
        let url = try TestFITS.write(TestFITS.fileData(cards: cards, pixels: Data(count: width)))
        defer { try? FileManager.default.removeItem(at: url) }
        try path.read(url)
    }

    @Test("END in the last allowed header block is found", arguments: ReadPath.allCases)
    func endInLastAllowedBlockIsFound(path: ReadPath) throws {
        // 5 image cards + 3594 comments + END = 3600 cards, exactly 100 blocks of 36,
        // so END is the last card of block 100.
        let comments = [String](repeating: TestFITS.commentCard(),
                                count: (FITSReader.maxHeaderBlocks - 1) * 36 - 5 + 35)
        let cards = TestFITS.imageCards(bitpix: 16, width: 4, height: 4, extraCards: comments)
        let data = TestFITS.fileData(cards: cards, pixels: Data(count: 32))
        #expect(data.count == FITSReader.maxHeaderBlocks * 2880 + 2880)
        let url = try TestFITS.write(data)
        defer { try? FileManager.default.removeItem(at: url) }
        try path.read(url)
    }

    // MARK: - Tiny images on the CPU detection path

    @Test("CPU star detection on a 2 × 2 image finds nothing and doesn't crash")
    func cpuDetectionOnTinyImage() async {
        let pixels: [Float] = [10, 20, 30, 40]
        let candidates = pixels.withUnsafeBufferPointer { buf in
            MetricsCalculator.findLocalMaxima(pixels: buf, width: 2, height: 2,
                                              cropX: 0, cropY: 0, cropW: 2, cropH: 2, threshold: 0)
        }
        #expect(candidates.isEmpty)
        let metrics = await MetricsCalculator.compute(pixels: pixels, width: 2, height: 2,
                                                      config: MetricsConfig())
        #expect(metrics == nil)
    }
}
