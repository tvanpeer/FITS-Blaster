//
//  ImageStretcher+CPU.swift
//  FITS Blaster
//
//  The CPU stretch (grey and RGB images, the Quick Look path and the GPU fallback)
//  and thumbnails. No Metal: compiled into the Quick Look extensions too.
//

import Foundation
import AppKit
import Accelerate

extension ImageStretcher {

    /// Stretch from a plain Float array and return a pre-scaled display image.
    /// Scaling is done on the UInt8 buffer with vImageScale before creating the CGImage,
    /// avoiding an expensive full-res CGImage → CGContext round-trip.
    static func createImage(from pixels: inout [Float], width: Int, height: Int,
                            maxDisplaySize: Int = 1024) -> NSImage? {
        guard !pixels.isEmpty else { return nil }
        let (shadowClip, highClip, midtone) = pixels.withUnsafeBufferPointer { buf in
            computeSTFClips(buf.baseAddress!, count: buf.count)
        }
        guard highClip > shadowClip else { return nil }
        return cpuFallback(&pixels, width: width, height: height,
                           shadowClip: shadowClip, highClip: highClip, midtone: midtone,
                           maxDisplaySize: maxDisplaySize)
    }

    /// Stretch interleaved RGB float data (R,G,B,R,G,B,...) into a display image.
    /// Uses per-channel STF clip bounds and MTF stretch, the same method as the
    /// greyscale path. CPU-only; used by the Quick Look preview and thumbnail.
    static func createRGBImage(from pixels: inout [Float], width: Int, height: Int,
                                maxDisplaySize: Int = 1024) -> NSImage? {
        let pixelCount = width * height
        guard pixels.count == pixelCount * 3 else { return nil }

        // De-interleave into separate channel planes for vImage processing.
        let rPlane = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let gPlane = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let bPlane = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        defer { rPlane.deallocate(); gPlane.deallocate(); bPlane.deallocate() }

        for i in 0..<pixelCount {
            rPlane[i] = pixels[i * 3]
            gPlane[i] = pixels[i * 3 + 1]
            bPlane[i] = pixels[i * 3 + 2]
        }

        // Per-channel STF clip bounds and MTF midtones.
        let (loR, hiR, midR) = computeSTFClips(rPlane, count: pixelCount)
        let (loG, hiG, midG) = computeSTFClips(gPlane, count: pixelCount)
        let (loB, hiB, midB) = computeSTFClips(bPlane, count: pixelCount)

        // Per-channel MTF LUTs (built once per image; ~4096 floats each, negligible cost).
        var lutR = makeMTFLUT(midtone: midR)
        var lutG = makeMTFLUT(midtone: midG)
        var lutB = makeMTFLUT(midtone: midB)

        let rStretched = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let gStretched = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        let bStretched = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        defer { rStretched.deallocate(); gStretched.deallocate(); bStretched.deallocate() }

        var rSrc = vImage_Buffer(data: rPlane, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
        var gSrc = vImage_Buffer(data: gPlane, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
        var bSrc = vImage_Buffer(data: bPlane, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
        var rDst = vImage_Buffer(data: rStretched, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
        var gDst = vImage_Buffer(data: gStretched, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)
        var bDst = vImage_Buffer(data: bStretched, height: vImagePixelCount(height),
                                  width: vImagePixelCount(width), rowBytes: width * MemoryLayout<Float>.stride)

        let lutCount = vImagePixelCount(lutR.count)
        vImageInterpolatedLookupTable_PlanarF(&rSrc, &rDst, &lutR, lutCount, hiR, loR, vImage_Flags(kvImageNoFlags))
        vImageInterpolatedLookupTable_PlanarF(&gSrc, &gDst, &lutG, lutCount, hiG, loG, vImage_Flags(kvImageNoFlags))
        vImageInterpolatedLookupTable_PlanarF(&bSrc, &bDst, &lutB, lutCount, hiB, loB, vImage_Flags(kvImageNoFlags))

        // Convert each channel Float [0,1] → UInt8 [0,255]
        let r8 = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let g8 = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        let b8 = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        defer { r8.deallocate(); g8.deallocate(); b8.deallocate() }

        var rDst8 = vImage_Buffer(data: r8, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width)
        var gDst8 = vImage_Buffer(data: g8, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width)
        var bDst8 = vImage_Buffer(data: b8, height: vImagePixelCount(height),
                                   width: vImagePixelCount(width), rowBytes: width)
        vImageConvert_PlanarFtoPlanar8(&rDst, &rDst8, 1.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&gDst, &gDst8, 1.0, 0.0, vImage_Flags(kvImageNoFlags))
        vImageConvert_PlanarFtoPlanar8(&bDst, &bDst8, 1.0, 0.0, vImage_Flags(kvImageNoFlags))

        // Interleave R,G,B UInt8 planes + vertical flip into RGB byte buffer.
        let rgb = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount * 3)
        for y in 0..<height {
            let srcY = height - 1 - y   // FITS rows are bottom-to-top
            for x in 0..<width {
                let srcIdx = srcY * width + x
                let dstIdx = (y * width + x) * 3
                rgb[dstIdx]     = r8[srcIdx]
                rgb[dstIdx + 1] = g8[srcIdx]
                rgb[dstIdx + 2] = b8[srcIdx]
            }
        }

        // Optional downscale
        let finalData: UnsafeMutablePointer<UInt8>
        let finalW: Int, finalH: Int
        if maxDisplaySize > 0 && max(width, height) > maxDisplaySize {
            let scale = Float(maxDisplaySize) / Float(max(width, height))
            finalW = max(1, Int(Float(width) * scale))
            finalH = max(1, Int(Float(height) * scale))
            let scaled = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH * 3)
            for ch in 0..<3 {
                let srcPlanar = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
                let dstPlanar = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH)
                defer { srcPlanar.deallocate(); dstPlanar.deallocate() }
                for i in 0..<pixelCount { srcPlanar[i] = rgb[i * 3 + ch] }
                var sBuf = vImage_Buffer(data: srcPlanar, height: vImagePixelCount(height),
                                          width: vImagePixelCount(width), rowBytes: width)
                var dBuf = vImage_Buffer(data: dstPlanar, height: vImagePixelCount(finalH),
                                          width: vImagePixelCount(finalW), rowBytes: finalW)
                vImageScale_Planar8(&sBuf, &dBuf, nil, vImage_Flags(kvImageHighQualityResampling))
                for i in 0..<(finalW * finalH) { scaled[i * 3 + ch] = dstPlanar[i] }
            }
            rgb.deallocate()
            finalData = scaled
        } else {
            finalData = rgb
            finalW = width
            finalH = height
        }

        let totalBytes = finalW * finalH * 3
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let provider = CGDataProvider(dataInfo: finalData, data: finalData, size: totalBytes) { ptr, _, _ in
            ptr?.assumingMemoryBound(to: UInt8.self).deallocate()
        }
        guard let prov = provider else { finalData.deallocate(); return nil }
        guard let cgImage = CGImage(
            width: finalW, height: finalH,
            bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: finalW * 3,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: prov, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: finalW, height: finalH))
    }

    /// Create a small thumbnail using CGContext
    static func createThumbnail(from displayImage: NSImage, maxSize: Int = 120) -> NSImage? {
        guard let cgImage = displayImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return nil
        }
        let w = cgImage.width
        let h = cgImage.height
        let scale = min(CGFloat(maxSize) / CGFloat(w), CGFloat(maxSize) / CGFloat(h), 1.0)
        let thumbW = max(1, Int(CGFloat(w) * scale))
        let thumbH = max(1, Int(CGFloat(h) * scale))

        let colorSpace = cgImage.colorSpace ?? CGColorSpaceCreateDeviceGray()
        let isColor = colorSpace.numberOfComponents > 1
        let bitmapInfo = isColor
            ? CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
            : CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue)
        guard let ctx = CGContext(
            data: nil,
            width: thumbW,
            height: thumbH,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .medium
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))

        guard let thumbCG = ctx.makeImage() else { return nil }
        return NSImage(cgImage: thumbCG, size: NSSize(width: thumbW, height: thumbH))
    }

    // MARK: - CPU Stretch

    /// Entries of the CPU stretch's interpolated MTF table.
    static let mtfLUTSize = 4096

    /// Build a 4096-entry MTF (Midtone Transfer Function) LUT for a given midtone value.
    /// The MTF places the background at `midtone` output level: MTF(m, x) = (m−1)x / ((2m−1)x − m).
    /// Built per-image since midtone is derived from the image's own statistics (~microseconds).
    private static func makeMTFLUT(midtone m: Float) -> [Float] {
        let n = mtfLUTSize
        return (0..<n).map { i in
            let t = Float(i) / Float(n - 1)
            guard t > 0 else { return 0 }
            return max(0, min(1, (m - 1) * t / ((2 * m - 1) * t - m)))
        }
    }

    /// Shared implementation: STF-normalized MTF LUT + convert + flip + scale.
    /// Scaling is done on the UInt8 buffer with vImageScale_Planar8, which is much faster
    /// than creating a full-res CGImage and scaling via CGContext.
    private static func cpuStretch(
        srcData: UnsafeMutablePointer<Float>, pixelCount: Int, width: Int, height: Int,
        shadowClip: Float, highClip: Float, midtone: Float = 0.25,
        maxDisplaySize: Int = 0
    ) -> NSImage? {
        let floatRowBytes = width * MemoryLayout<Float>.stride

        // Pass 1: Interpolated LUT normalizes [shadowClip, highClip] → [0, 1] and applies MTF.
        var lut = makeMTFLUT(midtone: midtone)
        let stretchedPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        var srcBuf = vImage_Buffer(data: srcData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        var dstBufF = vImage_Buffer(data: stretchedPtr, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        vImageInterpolatedLookupTable_PlanarF(&srcBuf, &dstBufF, &lut, vImagePixelCount(lut.count), highClip, shadowClip, vImage_Flags(kvImageNoFlags))

        // Pass 2: Float [0,1] → UInt8 [0,255]
        let bytes8 = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        var dstBuf8 = vImage_Buffer(data: bytes8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        vImageConvert_PlanarFtoPlanar8(&dstBufF, &dstBuf8, 1.0, 0.0, vImage_Flags(kvImageNoFlags))
        stretchedPtr.deallocate()

        // Pass 3: Vertical flip
        let flipped8 = UnsafeMutablePointer<UInt8>.allocate(capacity: pixelCount)
        var flippedBuf = vImage_Buffer(data: flipped8, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width)
        vImageVerticalReflect_Planar8(&dstBuf8, &flippedBuf, vImage_Flags(kvImageNoFlags))
        bytes8.deallocate()

        // Pass 4 (optional): Scale down with vImageScale_Planar8
        let finalData: UnsafeMutablePointer<UInt8>
        let finalW: Int
        let finalH: Int

        if maxDisplaySize > 0 && max(width, height) > maxDisplaySize {
            let scale = Float(maxDisplaySize) / Float(max(width, height))
            finalW = max(1, Int(Float(width) * scale))
            finalH = max(1, Int(Float(height) * scale))
            let scaledData = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH)
            var scaledBuf = vImage_Buffer(data: scaledData, height: vImagePixelCount(finalH), width: vImagePixelCount(finalW), rowBytes: finalW)
            vImageScale_Planar8(&flippedBuf, &scaledBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            flipped8.deallocate()
            finalData = scaledData
        } else {
            finalData = flipped8
            finalW = width
            finalH = height
        }

        let finalPixelCount = finalW * finalH
        let colorSpace = CGColorSpaceCreateDeviceGray()

        let dataProvider = CGDataProvider(dataInfo: finalData, data: finalData, size: finalPixelCount) { rawPtr, _, _ in
            rawPtr?.assumingMemoryBound(to: UInt8.self).deallocate()
        }

        guard let provider = dataProvider else {
            finalData.deallocate()
            return nil
        }

        guard let cgImage = CGImage(
            width: finalW, height: finalH,
            bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: finalW,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: finalW, height: finalH))
    }

    private static func cpuFallback(
        _ pixels: inout [Float], width: Int, height: Int,
        shadowClip: Float, highClip: Float, midtone: Float = 0.25,
        maxDisplaySize: Int = 0
    ) -> NSImage? {
        let pixelCount = width * height
        return pixels.withUnsafeMutableBufferPointer { buf in
            cpuStretch(srcData: buf.baseAddress!, pixelCount: pixelCount, width: width, height: height,
                       shadowClip: shadowClip, highClip: highClip, midtone: midtone,
                       maxDisplaySize: maxDisplaySize)
        }
    }

    /// CPU fallback operating directly on a raw float pointer (e.g. Metal shared buffer).
    /// Used by the Metal path (ImageStretcher+Metal.swift) when the GPU pass fails.
    static func cpuFallbackOnBuffer(
        _ floatPtr: UnsafeMutablePointer<Float>, width: Int, height: Int,
        shadowClip: Float, highClip: Float, midtone: Float = 0.25,
        maxDisplaySize: Int = 0
    ) -> NSImage? {
        let pixelCount = width * height
        return cpuStretch(srcData: floatPtr, pixelCount: pixelCount, width: width, height: height,
                          shadowClip: shadowClip, highClip: highClip, midtone: midtone,
                          maxDisplaySize: maxDisplaySize)
    }
}
