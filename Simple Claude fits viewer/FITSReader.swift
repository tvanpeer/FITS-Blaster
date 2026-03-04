//
//  FITSReader.swift
//  Simple Claude fits viewer
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
            return "Unsupported BITPIX value: \(value)"
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
}

/// Reads and parses FITS (Flexible Image Transport System) files
struct FITSReader {

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
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
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
                temp16.deallocate()

            case 32:
                // Bulk memcpy + vectorized byte-swap via ARGB permute [3,2,1,0], then convert Int32→Float
                let temp32 = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
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
                temp32.deallocate()

            case -32:
                // Bulk memcpy then vectorized 32-bit byte swap via ARGB permute [3,2,1,0]
                memcpy(destPtr, base, pixelCount * 4)
                let rowBytes = header.width * 4
                var swapBuf = vImage_Buffer(data: destPtr, height: vImagePixelCount(header.height),
                                            width: vImagePixelCount(header.width), rowBytes: rowBytes)
                var permuteMap: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))

            case -64:
                let src = base.assumingMemoryBound(to: UInt64.self)
                let temp = UnsafeMutablePointer<Double>.allocate(capacity: pixelCount)
                for i in 0..<pixelCount {
                    temp[i] = Double(bitPattern: src[i].bigEndian)
                }
                var destBuf64 = UnsafeMutableBufferPointer(start: destPtr, count: pixelCount)
                vDSP.convertElements(
                    of: UnsafeBufferPointer(start: temp, count: pixelCount),
                    to: &destBuf64
                )
                temp.deallocate()

            default:
                break
            }
        }

        // Apply BSCALE/BZERO in a single pass using vDSP_vsmsa: out = in * bscale + bzero
        let bscaleF = Float(header.bscale)
        let bzeroF = Float(header.bzero)
        if bscaleF != 1.0 || bzeroF != 0.0 {
            var mult = bscaleF
            var add = bzeroF
            let n = vDSP_Length(pixelCount)
            vDSP_vsmsa(destPtr, 1, &mult, &add, destPtr, 1, n)
        }

        let metadata = FITSMetadata(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            bzero: header.bzero,
            bscale: header.bscale,
            minValue: 0,
            maxValue: 0,
            headers: header.headers
        )

        return FITSBufferResult(metadata: metadata, metalBuffer: metalBuffer)
    }

    // MARK: - Legacy Array-based Read (CPU fallback)

    /// Parse a FITS file and return image data as a Swift array (used when Metal is unavailable)
    static func read(from url: URL) throws -> FITSImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
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
                temp.deallocate()
                count = pixelCount
            }

        case 32:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt32>.allocate(capacity: pixelCount)
                memcpy(temp, base, pixelCount * 4)
                // Vectorized byte-swap via ARGB permute [3,2,1,0] — same trick as BITPIX=-32
                var swapBuf = vImage_Buffer(data: temp, height: vImagePixelCount(header.height),
                                            width: vImagePixelCount(header.width), rowBytes: header.width * 4)
                var permuteMap: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
                let intPtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int32.self)
                var result = [Float](repeating: 0, count: pixelCount)
                vDSP.convertElements(of: UnsafeBufferPointer(start: intPtr, count: pixelCount), to: &result)
                temp.deallocate()
                return result
            }

        case -32:
            pixelValues = [Float](unsafeUninitializedCapacity: pixelCount) { buf, count in
                data.withUnsafeBytes { rawPtr in
                    let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                    memcpy(buf.baseAddress!, base, pixelCount * 4)
                    // Vectorized 32-bit byte swap using vImagePermuteChannels_ARGB8888
                    // Treats each 4-byte float as an ARGB pixel, reverses byte order [3,2,1,0]
                    let rowBytes = header.width * 4
                    var srcBuf = vImage_Buffer(data: buf.baseAddress!, height: vImagePixelCount(header.height),
                                               width: vImagePixelCount(header.width), rowBytes: rowBytes)
                    var permuteMap: [UInt8] = [3, 2, 1, 0]
                    vImagePermuteChannels_ARGB8888(&srcBuf, &srcBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
                }
                count = pixelCount
            }

        case -64:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt64>.allocate(capacity: pixelCount)
                memcpy(temp, base, pixelCount * 8)
                for i in 0..<pixelCount { temp[i] = temp[i].byteSwapped }
                let dblPtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Double.self)
                var result = [Float](repeating: 0, count: pixelCount)
                vDSP.convertElements(of: UnsafeBufferPointer(start: dblPtr, count: pixelCount), to: &result)
                temp.deallocate()
                return result
            }

        default:
            throw FITSError.unsupportedBitpix(header.bitpix)
        }

        // Apply BSCALE/BZERO in a single pass
        let bscaleF = Float(header.bscale)
        let bzeroF = Float(header.bzero)
        if bscaleF != 1.0 || bzeroF != 0.0 {
            pixelValues.withUnsafeMutableBufferPointer { buf in
                var mult = bscaleF
                var add = bzeroF
                let n = vDSP_Length(pixelCount)
                vDSP_vsmsa(buf.baseAddress!, 1, &mult, &add, buf.baseAddress!, 1, n)
            }
        }

        return FITSImage(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            bzero: header.bzero,
            bscale: header.bscale,
            pixelValues: pixelValues,
            minValue: 0,
            maxValue: 0,
            headers: header.headers
        )
    }
}
