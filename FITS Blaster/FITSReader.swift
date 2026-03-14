//
//  FITSReader.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

import Foundation
import Accelerate
import Metal

/// Errors that can occur when reading FITS files
enum FITSError: LocalizedError {
    case cannotOpenFile
    case invalidFormat(String)
    case unsupportedBitpix(Int)
    case noImageData
    case metalBufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile:
            return "Cannot open the FITS file."
        case .invalidFormat(let detail):
            return "Invalid FITS format: \(detail)"
        case .unsupportedBitpix(let value):
            if value < 0 {
                return "Unsupported image format: floating-point FITS files (BITPIX=\(value)) are not supported. Only integer formats (8, 16, 32-bit) are supported."
            }
            return "Unsupported BITPIX value: \(value). Supported values are 8, 16, and 32."
        case .noImageData:
            return "No image data found in the FITS file."
        case .metalBufferAllocationFailed:
            return "Failed to allocate Metal buffer for image data."
        }
    }
}

/// Lightweight metadata from a parsed FITS file (no pixel data)
struct FITSMetadata {
    let width: Int
    let height: Int
    let bitpix: Int
    let bzero: Double
    let bscale: Double
    let minValue: Float
    let maxValue: Float
    let headers: [String: String]
    /// Non-nil when the FITS headers declare a recognised Bayer CFA pattern.
    let bayerPattern: BayerPattern?
}

/// Result of reading FITS data directly into a Metal shared buffer
struct FITSBufferResult {
    let metadata: FITSMetadata
    let metalBuffer: MTLBuffer
}

/// Represents a parsed FITS image with its raw pixel data and metadata.
struct FITSImage {
    let width: Int
    let height: Int
    let bitpix: Int
    let bzero: Double
    let bscale: Double
    var pixelValues: [Float]
    let minValue: Float
    let maxValue: Float
    let headers: [String: String]
    /// Non-nil when the FITS headers declare a recognised Bayer CFA pattern.
    let bayerPattern: BayerPattern?
}

/// Reads and parses FITS (Flexible Image Transport System) files
struct FITSReader {

    // MARK: - BITPIX Peek (cheap format check)

    /// Reads only the first FITS header block (2880 bytes) and returns the BITPIX value.
    /// Used to skip unsupported formats before creating an entry. Returns nil on any error.
    static func peekBitpix(url: URL) -> Int? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let block = try? handle.read(upToCount: 2880), block.count >= 80 else { return nil }
        for i in stride(from: 0, to: block.count, by: 80) {
            let end = min(i + 80, block.count)
            guard let card = String(data: block[i..<end], encoding: .ascii) else { continue }
            let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
            guard keyword == "BITPIX" else { continue }
            guard card.count > 10, card.dropFirst(8).prefix(2) == "= " else { return nil }
            let valueField = card.dropFirst(10)
            let raw = (valueField.split(separator: "/").first ?? valueField[...])
                .trimmingCharacters(in: .whitespaces)
            return Int(raw)
        }
        return nil
    }

    // MARK: - Header Parsing (shared between both read paths)

    /// Removes FITS string quoting and trailing whitespace from a header value.
    static func cleanHeaderString(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("'") { result.removeFirst() }
        if result.hasSuffix("'") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Parsed header info needed before pixel reading
    private struct HeaderInfo {
        let width: Int
        let height: Int
        let bitpix: Int
        let bzero: Double
        let bscale: Double
        let dataOffset: Int
        let headers: [String: String]
    }

    private static func parseHeader(from data: Data) throws -> HeaderInfo {
        guard data.count >= 2880 else {
            throw FITSError.invalidFormat("File too small to be a valid FITS file.")
        }

        var headerCards: [(String, String)] = []
        var offset = 0
        var foundEnd = false

        while offset < data.count {
            let blockEnd = min(offset + 2880, data.count)
            let block = data[offset..<blockEnd]

            for cardStart in stride(from: block.startIndex, to: block.endIndex, by: 80) {
                let cardEnd = min(cardStart + 80, block.endIndex)
                guard cardEnd - cardStart == 80 else { break }
                let cardData = block[cardStart..<cardEnd]
                guard let cardString = String(data: cardData, encoding: .ascii) else { continue }

                let keyword = String(cardString.prefix(8)).trimmingCharacters(in: .whitespaces)

                if keyword == "END" {
                    foundEnd = true
                    break
                }

                if cardString.count > 10 && cardString.dropFirst(8).prefix(2) == "= " {
                    let valueComment = String(cardString.dropFirst(10))
                    let value: String
                    if let slashIndex = valueComment.firstIndex(of: "/") {
                        value = String(valueComment[valueComment.startIndex..<slashIndex])
                            .trimmingCharacters(in: .whitespaces)
                    } else {
                        value = valueComment.trimmingCharacters(in: .whitespaces)
                    }
                    headerCards.append((keyword, value))
                }
            }

            offset = blockEnd
            if foundEnd { break }
        }

        guard foundEnd else {
            throw FITSError.invalidFormat("No END card found in header.")
        }

        guard let bitpixStr = headerCards.first(where: { $0.0 == "BITPIX" })?.1,
              let bitpix = Int(bitpixStr) else {
            throw FITSError.invalidFormat("Missing or invalid BITPIX keyword.")
        }
        guard [8, 16, 32].contains(bitpix) else {
            throw FITSError.unsupportedBitpix(bitpix)
        }

        guard let naxisStr = headerCards.first(where: { $0.0 == "NAXIS" })?.1,
              let naxis = Int(naxisStr), naxis >= 2 else {
            throw FITSError.invalidFormat("Missing NAXIS or NAXIS < 2.")
        }

        guard let naxis1Str = headerCards.first(where: { $0.0 == "NAXIS1" })?.1,
              let width = Int(naxis1Str) else {
            throw FITSError.invalidFormat("Missing NAXIS1.")
        }

        guard let naxis2Str = headerCards.first(where: { $0.0 == "NAXIS2" })?.1,
              let height = Int(naxis2Str) else {
            throw FITSError.invalidFormat("Missing NAXIS2.")
        }

        let bzero: Double
        if let bzeroStr = headerCards.first(where: { $0.0 == "BZERO" })?.1 {
            bzero = Double(bzeroStr) ?? 0.0
        } else {
            bzero = 0.0
        }

        let bscale: Double
        if let bscaleStr = headerCards.first(where: { $0.0 == "BSCALE" })?.1 {
            bscale = Double(bscaleStr) ?? 1.0
        } else {
            bscale = 1.0
        }

        let pixelCount = width * height
        let bytesPerPixel = abs(bitpix) / 8

        guard offset < data.count else {
            throw FITSError.noImageData
        }

        guard offset + pixelCount * bytesPerPixel <= data.count else {
            throw FITSError.invalidFormat("Not enough data for \(pixelCount) pixels at \(bytesPerPixel) bytes each.")
        }

        // Build a flat dictionary of all parsed header cards
        var headers: [String: String] = [:]
        for (key, value) in headerCards where !key.isEmpty {
            headers[key] = value
        }

        return HeaderInfo(width: width, height: height, bitpix: bitpix,
                          bzero: bzero, bscale: bscale, dataOffset: offset, headers: headers)
    }

    // MARK: - Read into Metal Buffer (zero-copy GPU path)

    /// Parse a FITS file and write the float pixel data directly into a Metal shared buffer.
    /// This avoids allocating a Swift array that would later be copied into Metal.
    static func readIntoBuffer(from url: URL, device: MTLDevice) throws -> FITSBufferResult {
        // Use direct buffered read (no .mappedIfSafe) so the OS performs sequential
        // read() syscalls rather than lazy page faults. With multiple concurrent tasks
        // all reading different files, page-fault-based mmap serialises on the kernel's
        // fault handler and causes severe latency spikes. Buffered reads pipeline better.
        let data = try Data(contentsOf: url)
        let header = try parseHeader(from: data)

        let pixelCount = header.width * header.height
        let floatByteCount = pixelCount * MemoryLayout<Float>.stride

        guard let metalBuffer = device.makeBuffer(length: floatByteCount, options: .storageModeShared) else {
            throw FITSError.metalBufferAllocationFailed
        }

        let destPtr = metalBuffer.contents().assumingMemoryBound(to: Float.self)

        data.withUnsafeBytes { rawPtr in
            let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)

            switch header.bitpix {
            case 8:
                let src = base.assumingMemoryBound(to: UInt8.self)
                var destBuf = UnsafeMutableBufferPointer(start: destPtr, count: pixelCount)
                vDSP.convertElements(
                    of: UnsafeBufferPointer(start: src, count: pixelCount),
                    to: &destBuf
                )

            case 16:
                // memcpy + vectorized byte-swap + convert Int16→Float
                let temp16 = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount)
                defer { temp16.deallocate() }
                memcpy(temp16, base, pixelCount * 2)
                var swapBuf = vImage_Buffer(data: temp16, height: vImagePixelCount(header.height),
                                            width: vImagePixelCount(header.width), rowBytes: header.width * 2)
                vImageByteSwap_Planar16U(&swapBuf, &swapBuf, vImage_Flags(kvImageNoFlags))
                let int16Ptr = UnsafeMutableRawPointer(temp16).assumingMemoryBound(to: Int16.self)
                var destBuf16 = UnsafeMutableBufferPointer(start: destPtr, count: pixelCount)
                vDSP.convertElements(
                    of: UnsafeBufferPointer(start: int16Ptr, count: pixelCount),
                    to: &destBuf16
                )

            case 32:
                // Bulk memcpy + vectorized byte-swap via ARGB permute [3,2,1,0], then convert Int32→Float
                let temp32 = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
                defer { temp32.deallocate() }
                memcpy(temp32, base, pixelCount * 4)
                var swapBuf32 = vImage_Buffer(data: temp32, height: vImagePixelCount(header.height),
                                              width: vImagePixelCount(header.width), rowBytes: header.width * 4)
                var permuteMap32: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf32, &swapBuf32, &permuteMap32, vImage_Flags(kvImageNoFlags))
                let intPtr = UnsafeMutableRawPointer(temp32).assumingMemoryBound(to: Int32.self)
                var destBuf32 = UnsafeMutableBufferPointer(start: destPtr, count: pixelCount)
                vDSP.convertElements(
                    of: UnsafeBufferPointer(start: intPtr, count: pixelCount),
                    to: &destBuf32
                )

            default:
                break  // unreachable: parseHeader rejects unsupported bitpix values
            }
        }

        // Apply BSCALE/BZERO. Integer FITS files almost always have BSCALE=1, so
        // we use the cheaper vsadd (add only) in that case rather than vsmsa (multiply+add).
        let bscaleF = Float(header.bscale)
        let bzeroF  = Float(header.bzero)
        let n = vDSP_Length(pixelCount)
        if bscaleF != 1.0 {
            var mult = bscaleF
            var add  = bzeroF
            vDSP_vsmsa(destPtr, 1, &mult, &add, destPtr, 1, n)
        } else if bzeroF != 0.0 {
            var add = bzeroF
            vDSP_vsadd(destPtr, 1, &add, destPtr, 1, n)
        }

        // Compute min/max immediately after BZERO while the float buffer is
        // maximally warm in cache. Storing these in metadata eliminates two
        // separate full-buffer passes later in the histogram computation.
        var minValue: Float = 0
        var maxValue: Float = 0
        vDSP_minv(destPtr, 1, &minValue, n)
        vDSP_maxv(destPtr, 1, &maxValue, n)

        let metadata = FITSMetadata(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            bzero: header.bzero,
            bscale: header.bscale,
            minValue: minValue,
            maxValue: maxValue,
            headers: header.headers,
            bayerPattern: BayerPattern.parse(from: header.headers)
        )

        return FITSBufferResult(metadata: metadata, metalBuffer: metalBuffer)
    }

    // MARK: - Legacy Array-based Read (CPU fallback)

    /// Parse a FITS file and return image data as a Swift array (used when Metal is unavailable)
    static func read(from url: URL) throws -> FITSImage {
        let data = try Data(contentsOf: url)
        let header = try parseHeader(from: data)

        let pixelCount = header.width * header.height
        var pixelValues: [Float]

        switch header.bitpix {
        case 8:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let bytePtr = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                    .assumingMemoryBound(to: UInt8.self)
                var result = [Float](repeating: 0, count: pixelCount)
                vDSP.convertElements(of: UnsafeBufferPointer(start: bytePtr, count: pixelCount),
                                     to: &result)
                return result
            }

        case 16:
            pixelValues = [Float](unsafeUninitializedCapacity: pixelCount) { floatBuf, count in
                // Allocate temp buffer, memcpy, then vectorized byte-swap
                let temp = UnsafeMutablePointer<UInt16>.allocate(capacity: pixelCount)
                defer { temp.deallocate() }
                data.withUnsafeBytes { rawPtr in
                    let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                    memcpy(temp, base, pixelCount * 2)
                }
                // vImage vectorized 16-bit byte swap
                var srcBuf = vImage_Buffer(data: temp, height: vImagePixelCount(header.height),
                                           width: vImagePixelCount(header.width), rowBytes: header.width * 2)
                vImageByteSwap_Planar16U(&srcBuf, &srcBuf, vImage_Flags(kvImageNoFlags))
                // Reinterpret as Int16, convert to Float
                let int16Ptr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int16.self)
                vDSP.convertElements(of: UnsafeBufferPointer(start: int16Ptr, count: pixelCount),
                                     to: &floatBuf)
                count = pixelCount
            }

        case 32:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
                defer { temp.deallocate() }
                memcpy(temp, base, pixelCount * 4)
                // Vectorized byte-swap via ARGB permute [3,2,1,0] — same trick as BITPIX=-32
                var swapBuf = vImage_Buffer(data: temp, height: vImagePixelCount(header.height),
                                            width: vImagePixelCount(header.width), rowBytes: header.width * 4)
                var permuteMap: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
                let intPtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int32.self)
                var result = [Float](repeating: 0, count: pixelCount)
                vDSP.convertElements(of: UnsafeBufferPointer(start: intPtr, count: pixelCount), to: &result)
                return result
            }

        default:
            throw FITSError.unsupportedBitpix(header.bitpix)  // unreachable: parseHeader rejects these
        }

        // Apply BSCALE/BZERO. Integer FITS files almost always have BSCALE=1, so
        // we use the cheaper vsadd (add only) in that case rather than vsmsa (multiply+add).
        let bscaleF = Float(header.bscale)
        let bzeroF  = Float(header.bzero)
        if bscaleF != 1.0 || bzeroF != 0.0 {
            pixelValues.withUnsafeMutableBufferPointer { buf in
                let n = vDSP_Length(pixelCount)
                if bscaleF != 1.0 {
                    var mult = bscaleF
                    var add  = bzeroF
                    vDSP_vsmsa(buf.baseAddress!, 1, &mult, &add, buf.baseAddress!, 1, n)
                } else {
                    var add = bzeroF
                    vDSP_vsadd(buf.baseAddress!, 1, &add, buf.baseAddress!, 1, n)
                }
            }
        }

        // Compute min/max while the buffer is hot in cache, matching what
        // readIntoBuffer does. Enables the CPU-path histogram to skip its
        // own two full-buffer vDSP passes.
        var minValue: Float = 0
        var maxValue: Float = 0
        pixelValues.withUnsafeBufferPointer { buf in
            vDSP_minv(buf.baseAddress!, 1, &minValue, vDSP_Length(pixelCount))
            vDSP_maxv(buf.baseAddress!, 1, &maxValue, vDSP_Length(pixelCount))
        }

        return FITSImage(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            bzero: header.bzero,
            bscale: header.bscale,
            pixelValues: pixelValues,
            minValue: minValue,
            maxValue: maxValue,
            headers: header.headers,
            bayerPattern: BayerPattern.parse(from: header.headers)
        )
    }
}
