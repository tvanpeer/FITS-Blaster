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
    /// Number of colour channels: 1 for greyscale, 3 for RGB (NAXIS3=3).
    let channels: Int
    let bzero: Double
    let bscale: Double
    /// Pixel values. For `channels == 1`: `width × height` floats.
    /// For `channels == 3`: `width × height × 3` interleaved R,G,B floats.
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
        let channels: Int
        let bzero: Double
        let bscale: Double
        let dataOffset: Int
        let headers: [String: String]
    }

    private static func parseHeader(from data: Data, forPreview: Bool = false) throws -> HeaderInfo {
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
        let supported = forPreview ? [8, 16, 32, -32, -64] : [8, 16, 32]
        guard supported.contains(bitpix) else {
            throw FITSError.unsupportedBitpix(bitpix)
        }

        guard let naxisStr = headerCards.first(where: { $0.0 == "NAXIS" })?.1,
              let naxis = Int(naxisStr), naxis >= 2 else {
            throw FITSError.invalidFormat("Missing NAXIS or NAXIS < 2.")
        }

        // Multi-channel FITS (NAXIS=3, NAXIS3=3): allowed only in preview mode.
        let channels: Int
        if naxis > 2,
           let naxis3Str = headerCards.first(where: { $0.0 == "NAXIS3" })?.1,
           let naxis3 = Int(naxis3Str), naxis3 > 1 {
            if forPreview && naxis3 == 3 {
                channels = 3
            } else {
                throw FITSError.invalidFormat(
                    "Multi-channel FITS files (NAXIS=\(naxis), NAXIS3=\(naxis3)) are not supported. " +
                    "Load the raw single-frame sub-exposures instead."
                )
            }
        } else {
            channels = 1
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
        let totalValues = pixelCount * channels

        guard offset < data.count else {
            throw FITSError.noImageData
        }

        guard offset + totalValues * bytesPerPixel <= data.count else {
            throw FITSError.invalidFormat("Not enough data for \(totalValues) values at \(bytesPerPixel) bytes each.")
        }

        // Build a flat dictionary of all parsed header cards
        var headers: [String: String] = [:]
        for (key, value) in headerCards where !key.isEmpty {
            headers[key] = value
        }

        return HeaderInfo(width: width, height: height, bitpix: bitpix, channels: channels,
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
                // FITS Standard §4.4.1 mandates big-endian (MSB-first) pixel storage.
                // Apple Silicon is little-endian, so every multi-byte pixel format requires
                // a byte-swap before numeric conversion.
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
                // Big-endian to little-endian: the ARGB permute [3,2,1,0] reverses the
                // four bytes of each 32-bit word in one vectorised pass — cheaper than a
                // scalar loop and avoids vImageByteSwap_Planar32 (unavailable for signed int).
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

    /// Parse a FITS file including float formats (BITPIX -32, -64) and
    /// multi-channel RGB (NAXIS3=3). Intended for QuickLook preview and thumbnail
    /// extensions where only a display image is needed — no metrics pipeline.
    ///
    /// For very large files, subsamples to keep memory under the QuickLook process
    /// limit. The returned dimensions reflect the subsampled size.
    static func readForPreview(from url: URL, maxSize: Int = 2048) throws -> FITSImage {
        // Parse header only (cheap — reads first few KB)
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let header = try parseHeader(from: data, forPreview: true)

        // If the image fits comfortably, use the standard read path.
        let longestSide = max(header.width, header.height)
        if longestSide <= maxSize {
            return try readImpl(data: data, header: header)
        }

        // Subsample: pick every Nth row and column to bring the image under maxSize.
        let step = (longestSide + maxSize - 1) / maxSize  // ceil division
        let dstW = (header.width  + step - 1) / step
        let dstH = (header.height + step - 1) / step
        let dstPixelCount = dstW * dstH
        let bytesPerPixel = abs(header.bitpix) / 8
        let planeBytes = header.width * header.height * bytesPerPixel

        var pixelValues = [Float](repeating: 0, count: dstPixelCount * header.channels)

        data.withUnsafeBytes { rawPtr in
            for ch in 0..<header.channels {
                let planeBase = rawPtr.baseAddress!.advanced(by: header.dataOffset + ch * planeBytes)
                var dstIdx = header.channels == 3 ? ch : 0
                let dstStride = header.channels == 3 ? 3 : 1

                for dstY in 0..<dstH {
                    let srcY = dstY * step
                    for dstX in 0..<dstW {
                        let srcX = dstX * step
                        let srcOffset = (srcY * header.width + srcX) * bytesPerPixel
                        let value: Float

                        switch header.bitpix {
                        case 8:
                            value = Float(planeBase.advanced(by: srcOffset)
                                .assumingMemoryBound(to: UInt8.self).pointee)
                        case 16:
                            let raw = planeBase.advanced(by: srcOffset)
                                .assumingMemoryBound(to: UInt16.self).pointee
                            value = Float(Int16(bitPattern: raw.bigEndian))
                        case 32:
                            let raw = planeBase.advanced(by: srcOffset)
                                .assumingMemoryBound(to: UInt32.self).pointee
                            value = Float(Int32(bitPattern: raw.bigEndian))
                        case -32:
                            let raw = planeBase.advanced(by: srcOffset)
                                .assumingMemoryBound(to: UInt32.self).pointee
                            value = Float(bitPattern: raw.bigEndian)
                        case -64:
                            let raw = planeBase.advanced(by: srcOffset)
                                .assumingMemoryBound(to: UInt64.self).pointee
                            value = Float(Double(bitPattern: raw.bigEndian))
                        default:
                            value = 0
                        }

                        pixelValues[dstIdx] = value
                        dstIdx += dstStride
                    }
                }
            }
        }

        // Apply BSCALE/BZERO
        let bscaleF = Float(header.bscale)
        let bzeroF  = Float(header.bzero)
        let n = vDSP_Length(pixelValues.count)
        if bscaleF != 1.0 {
            var mult = bscaleF; var add = bzeroF
            pixelValues.withUnsafeMutableBufferPointer { buf in
                vDSP_vsmsa(buf.baseAddress!, 1, &mult, &add, buf.baseAddress!, 1, n)
            }
        } else if bzeroF != 0.0 {
            var add = bzeroF
            pixelValues.withUnsafeMutableBufferPointer { buf in
                vDSP_vsadd(buf.baseAddress!, 1, &add, buf.baseAddress!, 1, n)
            }
        }

        var minValue: Float = 0, maxValue: Float = 0
        pixelValues.withUnsafeBufferPointer { buf in
            vDSP_minv(buf.baseAddress!, 1, &minValue, n)
            vDSP_maxv(buf.baseAddress!, 1, &maxValue, n)
        }

        return FITSImage(
            width: dstW, height: dstH, bitpix: header.bitpix, channels: header.channels,
            bzero: header.bzero, bscale: header.bscale,
            pixelValues: pixelValues, minValue: minValue, maxValue: maxValue,
            headers: header.headers,
            bayerPattern: BayerPattern.parse(from: header.headers))
    }

    /// Parse a FITS file and return image data as a Swift array (used when Metal is unavailable)
    static func read(from url: URL) throws -> FITSImage {
        let data = try Data(contentsOf: url)
        let header = try parseHeader(from: data, forPreview: false)
        return try readImpl(data: data, header: header)
    }

    private static func readImpl(data: Data, header: HeaderInfo) throws -> FITSImage {

        let pixelCount = header.width * header.height
        let totalValues = pixelCount * header.channels
        var pixelValues: [Float]

        switch header.bitpix {
        case 8:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let bytePtr = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                    .assumingMemoryBound(to: UInt8.self)
                var result = [Float](repeating: 0, count: totalValues)
                vDSP.convertElements(of: UnsafeBufferPointer(start: bytePtr, count: totalValues),
                                     to: &result)
                return result
            }

        case 16:
            // FITS Standard §4.4.1 mandates big-endian pixel storage; swap before conversion.
            pixelValues = [Float](unsafeUninitializedCapacity: totalValues) { floatBuf, count in
                let temp = UnsafeMutablePointer<UInt16>.allocate(capacity: totalValues)
                defer { temp.deallocate() }
                data.withUnsafeBytes { rawPtr in
                    let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                    memcpy(temp, base, totalValues * 2)
                }
                // vImage vectorized 16-bit byte swap (treat as 1D row for multi-channel)
                var srcBuf = vImage_Buffer(data: temp, height: 1,
                                           width: vImagePixelCount(totalValues), rowBytes: totalValues * 2)
                vImageByteSwap_Planar16U(&srcBuf, &srcBuf, vImage_Flags(kvImageNoFlags))
                let int16Ptr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int16.self)
                vDSP.convertElements(of: UnsafeBufferPointer(start: int16Ptr, count: totalValues),
                                     to: &floatBuf)
                count = totalValues
            }

        case 32:
            // Big-endian to little-endian via ARGB permute [3,2,1,0].
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt32>.allocate(capacity: totalValues)
                defer { temp.deallocate() }
                memcpy(temp, base, totalValues * 4)
                var swapBuf = vImage_Buffer(data: temp, height: 1,
                                            width: vImagePixelCount(totalValues), rowBytes: totalValues * 4)
                var permuteMap: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
                let intPtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int32.self)
                var result = [Float](repeating: 0, count: totalValues)
                vDSP.convertElements(of: UnsafeBufferPointer(start: intPtr, count: totalValues), to: &result)
                return result
            }

        case -32:
            // IEEE 754 single-precision float, stored big-endian.
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt32>.allocate(capacity: totalValues)
                defer { temp.deallocate() }
                memcpy(temp, base, totalValues * 4)
                var swapBuf = vImage_Buffer(data: temp, height: 1,
                                            width: vImagePixelCount(totalValues), rowBytes: totalValues * 4)
                var permuteMap: [UInt8] = [3, 2, 1, 0]
                vImagePermuteChannels_ARGB8888(&swapBuf, &swapBuf, &permuteMap, vImage_Flags(kvImageNoFlags))
                let floatPtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Float.self)
                return Array(UnsafeBufferPointer(start: floatPtr, count: totalValues))
            }

        case -64:
            // IEEE 754 double-precision float, stored big-endian.
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt64>.allocate(capacity: totalValues)
                defer { temp.deallocate() }
                memcpy(temp, base, totalValues * 8)
                for i in 0..<totalValues { temp[i] = temp[i].byteSwapped }
                let doublePtr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Double.self)
                var result = [Float](repeating: 0, count: totalValues)
                vDSP.convertElements(of: UnsafeBufferPointer(start: doublePtr, count: totalValues),
                                     to: &result)
                return result
            }

        default:
            throw FITSError.unsupportedBitpix(header.bitpix)
        }

        // For 3-channel RGB: convert from plane-sequential (R...G...B...) to
        // interleaved (R,G,B,R,G,B,...) so the stretcher can render directly.
        if header.channels == 3 {
            var interleaved = [Float](repeating: 0, count: totalValues)
            let rPlane = pixelValues[0..<pixelCount]
            let gPlane = pixelValues[pixelCount..<2*pixelCount]
            let bPlane = pixelValues[2*pixelCount..<3*pixelCount]
            for i in 0..<pixelCount {
                interleaved[i * 3]     = rPlane[rPlane.startIndex + i]
                interleaved[i * 3 + 1] = gPlane[gPlane.startIndex + i]
                interleaved[i * 3 + 2] = bPlane[bPlane.startIndex + i]
            }
            pixelValues = interleaved
        }

        // Apply BSCALE/BZERO. Integer FITS files almost always have BSCALE=1, so
        // we use the cheaper vsadd (add only) in that case rather than vsmsa (multiply+add).
        let bscaleF = Float(header.bscale)
        let bzeroF  = Float(header.bzero)
        if bscaleF != 1.0 || bzeroF != 0.0 {
            pixelValues.withUnsafeMutableBufferPointer { buf in
                let n = vDSP_Length(totalValues)
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

        // Compute min/max across all values (all channels).
        var minValue: Float = 0
        var maxValue: Float = 0
        pixelValues.withUnsafeBufferPointer { buf in
            vDSP_minv(buf.baseAddress!, 1, &minValue, vDSP_Length(totalValues))
            vDSP_maxv(buf.baseAddress!, 1, &maxValue, vDSP_Length(totalValues))
        }

        return FITSImage(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            channels: header.channels,
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
