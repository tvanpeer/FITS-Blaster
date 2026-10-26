//
//  FITSReader.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//
//  Reads FITS files into Float arrays (the CPU paths: the app's fallback and
//  Quick Look). The header parser is in FITSHeader.swift, the types in FITSTypes.swift,
//  and the Metal-buffer read in FITSReader+Metal.swift.
//

import Foundation
import Accelerate

/// Reads and parses FITS (Flexible Image Transport System) files
struct FITSReader {

    // MARK: - Pixel helpers (shared between the read paths)

    /// Swaps 16-bit values from big-endian in place. FITS Standard §4.4.1 mandates
    /// big-endian (MSB-first) pixel storage; Apple Silicon is little-endian.
    static func byteSwap16(_ values: UnsafeMutablePointer<UInt16>, count: Int) {
        var buffer = vImage_Buffer(data: values, height: 1,
                                   width: vImagePixelCount(count), rowBytes: count * 2)
        vImageByteSwap_Planar16U(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
    }

    /// Swaps 32-bit values from big-endian in place. The ARGB permute [3,2,1,0] reverses
    /// the four bytes of each 32-bit word in one vectorised pass — cheaper than a scalar
    /// loop and avoids vImageByteSwap_Planar32 (unavailable for signed int).
    static func byteSwap32(_ values: UnsafeMutablePointer<UInt32>, count: Int) {
        var buffer = vImage_Buffer(data: values, height: 1,
                                   width: vImagePixelCount(count), rowBytes: count * 4)
        var permuteMap: [UInt8] = [3, 2, 1, 0]
        vImagePermuteChannels_ARGB8888(&buffer, &buffer, &permuteMap, vImage_Flags(kvImageNoFlags))
    }

    /// Applies BSCALE/BZERO in place and returns the min and max of the result.
    /// Integer FITS files almost always have BSCALE=1, so the cheaper vsadd (add only)
    /// is used in that case rather than vsmsa (multiply+add). Min/max are computed
    /// while the buffer is still warm in cache, saving two passes in the histogram later.
    static func applyScaleAndRange(_ values: UnsafeMutablePointer<Float>, count: Int,
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
