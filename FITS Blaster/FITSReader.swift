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
        guard let block = readFirstBlock(of: url), block.count >= 80 else { return nil }
        for i in stride(from: 0, to: block.count, by: 80) {
            let end = min(i + 80, block.count)
            guard let cardString = String(data: block[i..<end], encoding: .ascii) else { continue }
            let card = parseCard(cardString)
            guard card.keyword == "BITPIX" else { continue }
            return card.value.flatMap { Int($0) }
        }
        return nil
    }

    /// The first 2880-byte block of a file (less if the file is shorter), read with POSIX
    /// open/read: on an SMB share FileHandle took about 4 times as long per file (100 ms
    /// against 27 ms, measured 2026-10-25), and this runs for every file of a folder.
    private static func readFirstBlock(of url: URL) -> Data? {
        let fd = Darwin.open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var block = Data(count: 2880)
        var filled = 0
        while filled < 2880 {
            let n = block.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress?.advanced(by: filled), 2880 - filled) }
            if n <= 0 { break }   // end of file, or an error
            filled += n
        }
        return block.prefix(filled)
    }

    // MARK: - Header Parsing (shared between both read paths)

    /// Splits one 80-character header card into its keyword and, for `KEY = value / comment`
    /// cards, the value without the comment. Cards without `= ` in columns 9–10 have no value.
    private static func parseCard(_ card: String) -> (keyword: String, value: String?) {
        let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
        guard card.count > 10, card.dropFirst(8).prefix(2) == "= " else { return (keyword, nil) }
        let valueComment = card.dropFirst(10)
        let value = valueComment.firstIndex(of: "/").map { valueComment[..<$0] } ?? valueComment
        return (keyword, value.trimmingCharacters(in: .whitespaces))
    }

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

    /// Largest NAXIS1 or NAXIS2 accepted. Far above any camera sensor; larger images
    /// (big mosaics) are made after culling and stacking.
    static let maxAxisLength = 65_536

    /// Header blocks (2880 bytes each) searched for the END card before giving up,
    /// so a file without END isn't parsed card by card to its end.
    static let maxHeaderBlocks = 100

    /// Every FITS file is untrusted input (Quick Look parses files from Finder without
    /// the user opening them), so every size and scale value is checked here before
    /// anything is allocated or indexed. Anything invalid throws, never traps.
    ///
    /// `data` holds the file from its start, at least up to the END card; `fileSize` is the
    /// whole file's size when `data` holds only the header (`readIntoBuffer`), so the size
    /// checks see the real file.
    private static func parseHeader(from data: Data, fileSize: Int? = nil,
                                    forPreview: Bool = false) throws -> HeaderInfo {
        let fileSize = fileSize ?? data.count
        guard fileSize >= 2880, data.count >= min(fileSize, 2880) else {
            throw FITSError.invalidFormat("File too small to be a valid FITS file.")
        }

        var headerCards: [(String, String)] = []
        var offset = 0
        var foundEnd = false
        var blockCount = 0

        while offset < data.count {
            guard blockCount < maxHeaderBlocks else {
                throw FITSError.invalidFormat("No END card in the first \(maxHeaderBlocks) header blocks.")
            }
            blockCount += 1
            let blockEnd = min(offset + 2880, data.count)
            let block = data[offset..<blockEnd]

            for cardStart in stride(from: block.startIndex, to: block.endIndex, by: 80) {
                let cardEnd = min(cardStart + 80, block.endIndex)
                guard cardEnd - cardStart == 80 else { break }
                let cardData = block[cardStart..<cardEnd]
                guard let cardString = String(data: cardData, encoding: .ascii) else { continue }

                let card = parseCard(cardString)

                if card.keyword == "END" {
                    foundEnd = true
                    break
                }

                if let value = card.value {
                    headerCards.append((card.keyword, value))
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
              let naxis = Int(naxisStr), (2...999).contains(naxis) else {
            throw FITSError.invalidFormat("Missing NAXIS, or NAXIS outside 2–999.")
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

        let axisRange = 1...maxAxisLength
        guard axisRange.contains(width), axisRange.contains(height) else {
            throw FITSError.invalidFormat(
                "Image size \(width) × \(height) is outside 1–\(maxAxisLength) pixels per side.")
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

        // The pixels are scaled in Float, so the values must also be finite as Float.
        guard bzero.isFinite, bscale.isFinite, Float(bzero).isFinite, Float(bscale).isFinite else {
            throw FITSError.invalidFormat("BSCALE or BZERO is not a finite number.")
        }

        let bytesPerPixel = abs(bitpix) / 8
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (totalValues, valuesOverflow) = pixelCount.multipliedReportingOverflow(by: channels)
        let (dataBytes, bytesOverflow) = totalValues.multipliedReportingOverflow(by: bytesPerPixel)
        let (dataEnd, endOverflow) = offset.addingReportingOverflow(dataBytes)
        guard !(pixelOverflow || valuesOverflow || bytesOverflow || endOverflow) else {
            throw FITSError.invalidFormat("Image size \(width) × \(height) is too large.")
        }

        guard offset < fileSize else {
            throw FITSError.noImageData
        }

        guard dataEnd <= fileSize else {
            throw FITSError.invalidFormat("Not enough data for \(totalValues) values at \(bytesPerPixel) bytes each.")
        }

        // Build a flat dictionary of all parsed header cards. String values are cleaned
        // here, once (quotes and padding removed), not by every reader (CODE_AUDIT §7.5).
        var headers: [String: String] = [:]
        for (key, value) in headerCards where !key.isEmpty {
            headers[key] = cleanHeaderString(value)
        }

        return HeaderInfo(width: width, height: height, bitpix: bitpix, channels: channels,
                          bzero: bzero, bscale: bscale, dataOffset: offset, headers: headers)
    }

    // MARK: - Pixel helpers (shared between the read paths)

    /// Swaps 16-bit values from big-endian in place. FITS Standard §4.4.1 mandates
    /// big-endian (MSB-first) pixel storage; Apple Silicon is little-endian.
    private static func byteSwap16(_ values: UnsafeMutablePointer<UInt16>, count: Int) {
        var buffer = vImage_Buffer(data: values, height: 1,
                                   width: vImagePixelCount(count), rowBytes: count * 2)
        vImageByteSwap_Planar16U(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
    }

    /// Swaps 32-bit values from big-endian in place. The ARGB permute [3,2,1,0] reverses
    /// the four bytes of each 32-bit word in one vectorised pass — cheaper than a scalar
    /// loop and avoids vImageByteSwap_Planar32 (unavailable for signed int).
    private static func byteSwap32(_ values: UnsafeMutablePointer<UInt32>, count: Int) {
        var buffer = vImage_Buffer(data: values, height: 1,
                                   width: vImagePixelCount(count), rowBytes: count * 4)
        var permuteMap: [UInt8] = [3, 2, 1, 0]
        vImagePermuteChannels_ARGB8888(&buffer, &buffer, &permuteMap, vImage_Flags(kvImageNoFlags))
    }

    /// Applies BSCALE/BZERO in place and returns the min and max of the result.
    /// Integer FITS files almost always have BSCALE=1, so the cheaper vsadd (add only)
    /// is used in that case rather than vsmsa (multiply+add). Min/max are computed
    /// while the buffer is still warm in cache, saving two passes in the histogram later.
    private static func applyScaleAndRange(_ values: UnsafeMutablePointer<Float>, count: Int,
                                           bscale: Double, bzero: Double) -> (min: Float, max: Float) {
        let bscaleF = Float(bscale)
        let bzeroF  = Float(bzero)
        let n = vDSP_Length(count)
        if bscaleF != 1.0 {
            var mult = bscaleF
            var add  = bzeroF
            vDSP_vsmsa(values, 1, &mult, &add, values, 1, n)
        } else if bzeroF != 0.0 {
            var add = bzeroF
            vDSP_vsadd(values, 1, &add, values, 1, n)
        }
        var minValue: Float = 0
        var maxValue: Float = 0
        vDSP_minv(values, 1, &minValue, n)
        vDSP_maxv(values, 1, &maxValue, n)
        return (minValue, maxValue)
    }

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

        let range = pixelValues.withUnsafeMutableBufferPointer { buf in
            applyScaleAndRange(buf.baseAddress!, count: buf.count,
                               bscale: header.bscale, bzero: header.bzero)
        }

        return FITSImage(
            width: dstW, height: dstH, bitpix: header.bitpix, channels: header.channels,
            pixelValues: pixelValues, minValue: range.min, maxValue: range.max,
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
                byteSwap16(temp, count: totalValues)
                let int16Ptr = UnsafeMutableRawPointer(temp).assumingMemoryBound(to: Int16.self)
                vDSP.convertElements(of: UnsafeBufferPointer(start: int16Ptr, count: totalValues),
                                     to: &floatBuf)
                count = totalValues
            }

        case 32:
            pixelValues = data.withUnsafeBytes { rawPtr -> [Float] in
                let base = rawPtr.baseAddress!.advanced(by: header.dataOffset)
                let temp = UnsafeMutablePointer<UInt32>.allocate(capacity: totalValues)
                defer { temp.deallocate() }
                memcpy(temp, base, totalValues * 4)
                byteSwap32(temp, count: totalValues)
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
                byteSwap32(temp, count: totalValues)
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

        // Min/max across all values (all channels).
        let range = pixelValues.withUnsafeMutableBufferPointer { buf in
            applyScaleAndRange(buf.baseAddress!, count: totalValues,
                               bscale: header.bscale, bzero: header.bzero)
        }

        return FITSImage(
            width: header.width,
            height: header.height,
            bitpix: header.bitpix,
            channels: header.channels,
            pixelValues: pixelValues,
            minValue: range.min,
            maxValue: range.max,
            headers: header.headers,
            bayerPattern: BayerPattern.parse(from: header.headers)
        )
    }
}
