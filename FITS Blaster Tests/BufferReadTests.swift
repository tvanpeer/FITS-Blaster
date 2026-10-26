//
//  BufferReadTests.swift
//  FITS Blaster Tests
//
//  FITSReader.readIntoBuffer reads the pixels straight into the Metal buffer and converts
//  them in place (CODE_AUDIT §7.3). The values must equal the CPU read path for every
//  integer BITPIX, also across the conversion steps, and errors must stay as before.
//

import Foundation
import Metal
import Testing
@testable import FITS_Blaster

@Suite(.enabled(if: MetalContext.device != nil, "Requires Metal GPU"))
struct BufferReadTests {

    /// 301 × 233 = 70,133 pixels: more than one 65,536-pixel conversion step, not a multiple of it.
    private static let width = 301, height = 233

    private static func pixelData(bitpix: Int) -> Data {
        let n = width * height
        var data = Data(capacity: n * bitpix / 8)
        for i in 0..<n {
            switch bitpix {
            case 8:
                data.append(UInt8((i * 37) % 256))
            case 16:
                let v = UInt16((i * 7919) % 65_536)
                data.append(UInt8(v >> 8)); data.append(UInt8(v & 0xFF))
            default:
                let v = UInt32(truncatingIfNeeded: i &* 2_654_435_761)
                withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    private static func file(bitpix: Int, bzero: Double? = nil, bscale: Double? = nil,
                             truncateBy: Int = 0) throws -> URL {
        let cards = TestFITS.imageCards(bitpix: bitpix, width: width, height: height,
                                        bzero: bzero, bscale: bscale)
        var data = TestFITS.fileData(cards: cards, pixels: pixelData(bitpix: bitpix))
        if truncateBy > 0 { data = data.prefix(data.count - truncateBy) }
        return try TestFITS.write(data)
    }

    @Test("Buffer read equals the CPU read", arguments: [
        (8, nil, nil), (16, 32768.0, nil), (16, nil, nil), (32, nil, nil), (16, 100.0, 0.5),
    ] as [(Int, Double?, Double?)])
    func sameAsCPURead(bitpix: Int, bzero: Double?, bscale: Double?) throws {
        let url = try Self.file(bitpix: bitpix, bzero: bzero, bscale: bscale)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try #require(MetalContext.device)

        let buffer = try FITSReader.readIntoBuffer(from: url, device: device)
        let cpu = try FITSReader.read(from: url)
        let n = Self.width * Self.height
        let values = Array(UnsafeBufferPointer(
            start: buffer.metalBuffer.contents().assumingMemoryBound(to: Float.self), count: n))
        #expect(values == cpu.pixelValues)
        #expect(buffer.metadata.minValue == cpu.minValue)
        #expect(buffer.metadata.maxValue == cpu.maxValue)
        #expect(buffer.metadata.headers == cpu.headers)
    }

    @Test("A truncated file gives the same error as the CPU read")
    func truncatedFile() throws {
        let url = try Self.file(bitpix: 16, truncateBy: 3000)
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try #require(MetalContext.device)
        let bufferError = #expect(throws: FITSError.self) { try FITSReader.readIntoBuffer(from: url, device: device) }
        let cpuError = #expect(throws: FITSError.self) { try FITSReader.read(from: url) }
        #expect(bufferError?.localizedDescription == cpuError?.localizedDescription)
    }

    @Test("A header without END in the first blocks gives the same error as the CPU read")
    func noEndCard() throws {
        // 101 header blocks of comment cards, no END.
        let cards = TestFITS.imageCards(bitpix: 16, width: 4, height: 4)
            + Array(repeating: TestFITS.commentCard("filler"), count: 101 * 36)
        let url = try TestFITS.write(TestFITS.fileData(cards: cards, pixels: Data(count: 32), withEnd: false))
        defer { try? FileManager.default.removeItem(at: url) }
        let device = try #require(MetalContext.device)
        let bufferError = #expect(throws: FITSError.self) { try FITSReader.readIntoBuffer(from: url, device: device) }
        let cpuError = #expect(throws: FITSError.self) { try FITSReader.read(from: url) }
        #expect(bufferError?.localizedDescription == cpuError?.localizedDescription)
    }

    @Test("A missing file gives the same kind of error as before (no such file)")
    func missingFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).fits")
        let device = try #require(MetalContext.device)
        let error = #expect(throws: CocoaError.self) { try FITSReader.readIntoBuffer(from: url, device: device) }
        #expect(error?.code == .fileReadNoSuchFile)
    }
}
