//
//  FITSReader+Metal.swift
//  FITS Blaster
//
//  Reading a frame straight into a Metal shared buffer (the app's load path).
//  App only — the Quick Look extensions use the CPU reads in FITSReader.swift.
//

import Foundation
import Accelerate
import Metal

/// Result of reading FITS data directly into a Metal shared buffer
struct FITSBufferResult {
    let metadata: FITSMetadata
    let metalBuffer: MTLBuffer
}

extension FITSReader {

    // MARK: - Read into Metal Buffer (zero-copy GPU path)

    /// Parse a FITS file and write the float pixel data directly into a Metal shared buffer.
    ///
    /// The file is read with POSIX `pread` — the header block by block up to its END card,
    /// then the pixel bytes straight into the back part of the Metal buffer — and the
    /// pixels are converted to Float in place, front to back, through a small scratch
    /// buffer. Peak memory per frame is the float buffer itself; before, the whole file
    /// as `Data`, an integer copy and the float buffer were alive together, about 4× the
    /// file size (CODE_AUDIT §7.3). The conversion is the same as before (byte swap, then
    /// integer → Float), so the values are identical.
    static func readIntoBuffer(from url: URL, device: MTLDevice) throws -> FITSBufferResult {
        let file = try OpenFile(url)
        defer { file.close() }
        let header = try parseHeader(from: try file.readHeaderBlocks(), fileSize: file.size)

        let pixelCount = header.width * header.height
        let floatByteCount = pixelCount * MemoryLayout<Float>.stride

        guard let metalBuffer = device.makeBuffer(length: floatByteCount, options: .storageModeShared) else {
            throw FITSError.metalBufferAllocationFailed
        }
        let destPtr = metalBuffer.contents().assumingMemoryBound(to: Float.self)

        // The raw pixels go to the end of the buffer. Converting front to back, the Float
        // written for pixel i ends at byte 4(i+1), never past the raw bytes still to be
        // read (pixel j's raw bytes start at rawOffset + bpp·j ≥ 4j for j > i).
        let bytesPerPixel = header.bitpix / 8
        let rawByteCount = pixelCount * bytesPerPixel
        let rawOffset = floatByteCount - rawByteCount
        let raw = metalBuffer.contents().advanced(by: rawOffset)
        try file.read(into: raw, count: rawByteCount, at: header.dataOffset)

        let scratch = UnsafeMutableRawPointer.allocate(byteCount: conversionChunk * 4, alignment: 16)
        defer { scratch.deallocate() }
        var start = 0
        while start < pixelCount {
            let count = min(conversionChunk, pixelCount - start)
            memcpy(scratch, raw.advanced(by: start * bytesPerPixel), count * bytesPerPixel)
            var dest = UnsafeMutableBufferPointer(start: destPtr.advanced(by: start), count: count)
            switch header.bitpix {
            case 8:
                vDSP.convertElements(of: UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: UInt8.self),
                                                             count: count),
                                     to: &dest)
            case 16:
                // Vectorised byte swap + convert Int16→Float
                byteSwap16(scratch.assumingMemoryBound(to: UInt16.self), count: count)
                vDSP.convertElements(of: UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: Int16.self),
                                                             count: count),
                                     to: &dest)
            case 32:
                // Vectorised byte swap, then convert Int32→Float
                byteSwap32(scratch.assumingMemoryBound(to: UInt32.self), count: count)
                vDSP.convertElements(of: UnsafeBufferPointer(start: scratch.assumingMemoryBound(to: Int32.self),
                                                             count: count),
                                     to: &dest)
            default:
                break  // unreachable: parseHeader rejects unsupported bitpix values
            }
            start += count
        }

        let range = applyScaleAndRange(destPtr, count: pixelCount,
                                       bscale: header.bscale, bzero: header.bzero)

        let metadata = FITSMetadata(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            minValue: range.min,
            maxValue: range.max,
            headers: header.headers,
            bayerPattern: BayerPattern.parse(from: header.headers)
        )

        return FITSBufferResult(metadata: metadata, metalBuffer: metalBuffer)
    }

    /// Pixels converted per step in `readIntoBuffer` (at most 256 KB of scratch).
    private static let conversionChunk = 65_536

    /// A file opened for reading with POSIX calls, for `readIntoBuffer`. Open and read
    /// errors become the same Cocoa errors `Data(contentsOf:)` gave before.
    private struct OpenFile {
        let url: URL
        let descriptor: Int32
        let size: Int

        init(_ url: URL) throws {
            self.url = url
            let fd = Darwin.open(url.path(percentEncoded: false), O_RDONLY)
            guard fd >= 0 else { throw Self.error(errno, url) }
            var info = stat()
            guard fstat(fd, &info) == 0 else {
                let code = errno
                Darwin.close(fd)
                throw Self.error(code, url)
            }
            descriptor = fd
            size = Int(info.st_size)
        }

        func close() { Darwin.close(descriptor) }

        /// The header blocks from the start of the file up to and including the one with
        /// the END card. One block more than `maxHeaderBlocks` at most, so parseHeader
        /// reports a missing END with the same message as for a whole file.
        func readHeaderBlocks() throws -> Data {
            var data = Data()
            for _ in 0...maxHeaderBlocks {
                let blockStart = data.count
                let blockLength = min(2880, size - blockStart)
                guard blockLength > 0 else { break }
                data.append(Data(count: blockLength))
                try data.withUnsafeMutableBytes { bytes in
                    try read(into: bytes.baseAddress!.advanced(by: blockStart), count: blockLength, at: blockStart)
                }
                if Self.containsEndCard(data[blockStart...]) { break }
            }
            return data
        }

        /// Reads exactly `count` bytes at `offset`.
        func read(into destination: UnsafeMutableRawPointer, count: Int, at offset: Int) throws {
            var done = 0
            while done < count {
                let n = pread(descriptor, destination.advanced(by: done), min(count - done, 1 << 30),
                              off_t(offset + done))
                if n < 0 {
                    if errno == EINTR { continue }
                    throw Self.error(errno, url)
                }
                // The file got shorter after its size was checked.
                guard n > 0 else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSURLErrorKey: url]) }
                done += n
            }
        }

        private static func containsEndCard(_ block: Data) -> Bool {
            stride(from: block.startIndex, to: block.endIndex - 79, by: 80).contains { start in
                guard let card = String(data: block[start..<(start + 80)], encoding: .ascii) else { return false }
                return parseCard(card).keyword == "END"
            }
        }

        private static func error(_ code: Int32, _ url: URL) -> CocoaError {
            let kind: CocoaError.Code = switch code {
            case ENOENT, ENOTDIR: .fileReadNoSuchFile
            case EACCES, EPERM:   .fileReadNoPermission
            default:              .fileReadUnknown
            }
            return CocoaError(kind, userInfo: [NSURLErrorKey: url, NSFilePathErrorKey: url.path(percentEncoded: false),
                                               NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }
}
