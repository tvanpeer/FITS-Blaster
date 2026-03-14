//
//  ImageStretcher.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

import Foundation
import AppKit
import Metal
import Accelerate

// MARK: - BayerClips

/// Per-channel percentile clip bounds for a Bayer image.
/// Stored on `ImageEntry` during the grey-pass so the post-batch normalisation
/// step can compute per-folder medians and re-render in colour with shared bounds.
struct BayerClips: Sendable {
    let loR, hiR: Float
    let loG, hiG: Float
    let loB, hiB: Float

    var isValid: Bool { hiR > loR && hiG > loG && hiB > loB }

    /// Compute per-channel medians from a collection of per-image clips.
    static func median(of clips: [BayerClips]) -> BayerClips {
        guard !clips.isEmpty else { return BayerClips(loR: 0, hiR: 1, loG: 0, hiG: 1, loB: 0, hiB: 1) }
        let mid = clips.count / 2
        func med(_ kp: KeyPath<BayerClips, Float>) -> Float {
            clips.map { $0[keyPath: kp] }.sorted()[mid]
        }
        return BayerClips(
            loR: med(\.loR), hiR: med(\.hiR),
            loG: med(\.loG), hiG: med(\.hiG),
            loB: med(\.loB), hiB: med(\.hiB)
        )
    }

}

/// Converts raw FITS pixel data into a displayable image using a Metal compute
/// shader that performs the entire stretch pipeline in a single GPU pass:
///   normalize → asinh stretch → float-to-byte → vertical flip
///
/// Optimized for GPU utilization:
///   - Input pixels can be written directly into a Metal shared buffer (no copy)
///   - Output Metal buffer is used directly by CGDataProvider (no memcpy)
///   - Async GPU completion allows overlapping GPU work with CPU post-processing
struct ImageStretcher {

    /// Number of random samples used to estimate percentile clip bounds
    private static let percentileSampleCount = 10_000

    // MARK: - Metal State (initialized once, reused for all images)

    static let metalDevice: MTLDevice? = MTLCreateSystemDefaultDevice()
    private static let commandQueue: MTLCommandQueue? = metalDevice?.makeCommandQueue()
    private static let pipelineState: MTLComputePipelineState? = {
        guard let device = metalDevice,
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "sqrtStretch") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    private static let bayerPipelineState: MTLComputePipelineState? = {
        guard let device = metalDevice,
              let library = device.makeDefaultLibrary(),
              let function = library.makeFunction(name: "bayerDebayerAndStretch") else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }()

    /// Parameters struct matching the Metal shader's StretchParams
    private struct StretchParams {
        var lowClip: Float
        var highClip: Float
        var width: UInt32
        var height: UInt32
    }

    /// Parameters struct matching the Metal shader's BayerStretchParams (9 × 4 bytes = 36 bytes)
    private struct BayerStretchParams {
        var lowClipR: Float
        var highClipR: Float
        var lowClipG: Float
        var highClipG: Float
        var lowClipB: Float
        var highClipB: Float
        var width: UInt32
        var height: UInt32
        var rOffset: UInt32
    }

    // MARK: - Shared Metal Buffer for FITS Reading

    /// Allocate a Metal shared buffer that FITSReader can write into directly,
    /// avoiding a copy when uploading to the GPU.
    static func makeSharedBuffer(byteCount: Int) -> MTLBuffer? {
        metalDevice?.makeBuffer(length: byteCount, options: .storageModeShared)
    }

    // MARK: - Public

    /// Stretch using pixel data already in a Metal shared buffer.
    /// The input buffer's contents are consumed (overwritten by percentile estimation is separate).
    /// Returns the NSImage and the retained output Metal buffer (caller doesn't need to manage it).
    static func createImage(inputBuffer: MTLBuffer, width: Int, height: Int,
                            maxDisplaySize: Int = 0) async -> NSImage? {
        let pixelCount = width * height

        // Read percentiles from the shared buffer without copying
        let floatPtr = inputBuffer.contents().assumingMemoryBound(to: Float.self)
        let (lowClip, highClip) = estimatePercentiles(floatPtr, count: pixelCount)
        let range = highClip - lowClip
        guard range > 0 else { return nil }

        if let result = await metalStretch(inputBuffer: inputBuffer, width: width, height: height,
                                           lowClip: lowClip, highClip: highClip,
                                           maxDisplaySize: maxDisplaySize) {
            return result
        }

        // CPU fallback — operate directly on Metal shared buffer (no copy)
        return cpuFallbackOnBuffer(inputBuffer.contents().assumingMemoryBound(to: Float.self),
                                   width: width, height: height,
                                   lowClip: lowClip, highClip: highClip,
                                   maxDisplaySize: maxDisplaySize)
    }

    /// Stretch from a plain Float array and return a pre-scaled display image.
    /// Scaling is done on the UInt8 buffer with vImageScale before creating the CGImage,
    /// avoiding an expensive full-res CGImage → CGContext round-trip.
    static func createImage(from pixels: inout [Float], width: Int, height: Int,
                            maxDisplaySize: Int = 1024) -> NSImage? {
        let (lowClip, highClip) = estimatePercentiles(pixels)
        let range = highClip - lowClip
        guard range > 0 else { return nil }

        return cpuFallback(&pixels, width: width, height: height,
                           lowClip: lowClip, highClip: highClip,
                           maxDisplaySize: maxDisplaySize)
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

    // MARK: - Metal Path

    /// GPU-accelerated stretch. For images within maxDisplaySize the output Metal buffer is used
    /// directly by CGDataProvider (zero-copy). For oversized images a post-GPU vImageScale_Planar8
    /// pass scales the output to maxDisplaySize before CGImage creation.
    private static func metalStretch(
        inputBuffer: MTLBuffer, width: Int, height: Int,
        lowClip: Float, highClip: Float, maxDisplaySize: Int = 0
    ) async -> NSImage? {
        guard let device = metalDevice,
              let commandQueue = commandQueue,
              let pipelineState = pipelineState else { return nil }

        let pixelCount = width * height
        let outputByteCount = pixelCount

        guard let outputBuffer = device.makeBuffer(length: outputByteCount, options: .storageModeShared) else {
            return nil
        }

        var params = StretchParams(
            lowClip: lowClip,
            highClip: highClip,
            width: UInt32(width),
            height: UInt32(height)
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<StretchParams>.stride, index: 2)

        let threadgroupSize = MTLSize(
            width: min(16, pipelineState.maxTotalThreadsPerThreadgroup),
            height: min(16, pipelineState.maxTotalThreadsPerThreadgroup / 16),
            depth: 1
        )
        let gridSize = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(gridSize, threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        // Non-blocking GPU wait: releases the cooperative thread while the GPU runs
        // so the thread pool can schedule other tasks (Moffat fitting, other images)
        // instead of blocking. This is the correct async pattern for Metal on Swift concurrency.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        let needsScale = maxDisplaySize > 0 && max(width, height) > maxDisplaySize

        if needsScale {
            // Post-GPU scale: copy GPU output → vImageScale_Planar8 → smaller CGImage.
            // This sacrifices zero-copy for large images to keep NSImage memory manageable.
            let scale = Float(maxDisplaySize) / Float(max(width, height))
            let finalW = max(1, Int(Float(width) * scale))
            let finalH = max(1, Int(Float(height) * scale))
            let scaledData = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH)
            var srcBuf = vImage_Buffer(data: outputBuffer.contents(),
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: width)
            var dstBuf = vImage_Buffer(data: scaledData,
                                       height: vImagePixelCount(finalH),
                                       width: vImagePixelCount(finalW),
                                       rowBytes: finalW)
            vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))

            let dataProvider = CGDataProvider(dataInfo: scaledData, data: scaledData,
                                              size: finalW * finalH) { rawPtr, _, _ in
                rawPtr?.assumingMemoryBound(to: UInt8.self).deallocate()
            }
            guard let provider = dataProvider else { scaledData.deallocate(); return nil }
            guard let cgImage = CGImage(
                width: finalW, height: finalH,
                bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: finalW,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            ) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: finalW, height: finalH))
        }

        // Zero-copy: CGDataProvider reads directly from the Metal shared buffer.
        // We pass the MTLBuffer as an Unmanaged retained reference so it stays alive
        // until the CGImage is deallocated.
        let retained = Unmanaged.passRetained(outputBuffer as AnyObject)
        let dataProvider = CGDataProvider(
            dataInfo: retained.toOpaque(),
            data: outputBuffer.contents(),
            size: outputByteCount
        ) { info, _, _ in
            // Release the MTLBuffer when the CGImage is done with it
            if let info {
                Unmanaged<AnyObject>.fromOpaque(info).release()
            }
        }

        guard let provider = dataProvider else {
            retained.release()
            return nil
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: width,
            space: colorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - Metal Bayer Path

    /// GPU-accelerated Bayer demosaic + stretch using pre-computed clip bounds.
    /// Call `computeBayerClips` first to obtain `clips`, then pass the median/shared
    /// clips here for consistent stretch across a folder of images.
    static func createBayerImage(inputBuffer: MTLBuffer, width: Int, height: Int,
                                 rOffset: UInt32, clips: BayerClips,
                                 maxDisplaySize: Int = 0) async -> NSImage? {
        guard clips.isValid else { return nil }
        return await metalBayerStretch(inputBuffer: inputBuffer, width: width, height: height,
                                       rOffset: rOffset, clips: clips, maxDisplaySize: maxDisplaySize)
    }

    /// Compute per-channel Bayer clip bounds from a Metal shared buffer without rendering.
    /// Store the result on `ImageEntry.bayerClips` during the grey-pass, then compute
    /// per-folder medians and call `createBayerImage(inputBuffer:clips:)` for the colour pass.
    static func computeBayerClips(_ buffer: MTLBuffer, width: Int, height: Int,
                                   rOffset: UInt32) -> BayerClips {
        let ptr = buffer.contents().assumingMemoryBound(to: Float.self)
        return estimateBayerPerChannelPercentiles(ptr, width: width, height: height, rOffset: rOffset)
    }

    private static func metalBayerStretch(
        inputBuffer: MTLBuffer, width: Int, height: Int,
        rOffset: UInt32, clips: BayerClips,
        maxDisplaySize: Int = 0
    ) async -> NSImage? {
        guard let device = metalDevice,
              let commandQueue = commandQueue,
              let pipelineState = bayerPipelineState else { return nil }

        // Output: RGBA UInt8, 4 bytes/pixel
        let outputByteCount = width * height * 4
        guard let outputBuffer = device.makeBuffer(length: outputByteCount, options: .storageModeShared) else {
            return nil
        }

        var params = BayerStretchParams(
            lowClipR: clips.loR, highClipR: clips.hiR,
            lowClipG: clips.loG, highClipG: clips.hiG,
            lowClipB: clips.loB, highClipB: clips.hiB,
            width: UInt32(width), height: UInt32(height),
            rOffset: rOffset
        )

        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipelineState)
        encoder.setBuffer(inputBuffer, offset: 0, index: 0)
        encoder.setBuffer(outputBuffer, offset: 0, index: 1)
        encoder.setBytes(&params, length: MemoryLayout<BayerStretchParams>.stride, index: 2)

        let threadgroupSize = MTLSize(
            width: min(16, pipelineState.maxTotalThreadsPerThreadgroup),
            height: min(16, pipelineState.maxTotalThreadsPerThreadgroup / 16),
            depth: 1
        )
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: threadgroupSize)
        encoder.endEncoding()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)
        let needsScale = maxDisplaySize > 0 && max(width, height) > maxDisplaySize

        if needsScale {
            let scale = Float(maxDisplaySize) / Float(max(width, height))
            let finalW = max(1, Int(Float(width) * scale))
            let finalH = max(1, Int(Float(height) * scale))
            let scaledData = UnsafeMutablePointer<UInt8>.allocate(capacity: finalW * finalH * 4)
            var srcBuf = vImage_Buffer(data: outputBuffer.contents(),
                                       height: vImagePixelCount(height),
                                       width: vImagePixelCount(width),
                                       rowBytes: width * 4)
            var dstBuf = vImage_Buffer(data: scaledData,
                                       height: vImagePixelCount(finalH),
                                       width: vImagePixelCount(finalW),
                                       rowBytes: finalW * 4)
            // vImageScale_ARGB8888 works on any 4-byte/pixel data (channel-independent)
            vImageScale_ARGB8888(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))

            let dataProvider = CGDataProvider(dataInfo: scaledData, data: scaledData,
                                              size: finalW * finalH * 4) { rawPtr, _, _ in
                rawPtr?.assumingMemoryBound(to: UInt8.self).deallocate()
            }
            guard let provider = dataProvider else { scaledData.deallocate(); return nil }
            guard let cgImage = CGImage(
                width: finalW, height: finalH,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: finalW * 4,
                space: colorSpace, bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
            ) else { return nil }
            return NSImage(cgImage: cgImage, size: NSSize(width: finalW, height: finalH))
        }

        // Zero-copy path: CGDataProvider reads directly from Metal shared buffer
        let retained = Unmanaged.passRetained(outputBuffer as AnyObject)
        let dataProvider = CGDataProvider(
            dataInfo: retained.toOpaque(),
            data: outputBuffer.contents(),
            size: outputByteCount
        ) { info, _, _ in
            if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
        }
        guard let provider = dataProvider else { retained.release(); return nil }
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }

    // MARK: - CPU Stretch

    /// 4096-entry interpolated LUT: maps [0,1] → pow(x, 1/2.2).
    /// vImageInterpolatedLookupTable_PlanarF linearly interpolates between entries,
    /// so 4096 entries gives smooth, artifact-free output.
    private static let stretchLUT: [Float] = {
        let n = 4096
        return (0..<n).map { i in
            let t = Float(i) / Float(n - 1)
            return pow(t, 1.0 / 2.2)
        }
    }()

    /// Shared implementation: interpolated LUT (normalize+clip+gamma) + convert + flip + scale.
    /// Scaling is done on the UInt8 buffer with vImageScale_Planar8, which is much faster
    /// than creating a full-res CGImage and scaling via CGContext.
    private static func cpuStretch(
        srcData: UnsafeMutablePointer<Float>, pixelCount: Int, width: Int, height: Int,
        lowClip: Float, highClip: Float, maxDisplaySize: Int = 0
    ) -> NSImage? {
        let floatRowBytes = width * MemoryLayout<Float>.stride

        // Pass 1: Interpolated LUT does normalize+clip+gamma in one vectorized pass.
        let stretchedPtr = UnsafeMutablePointer<Float>.allocate(capacity: pixelCount)
        var srcBuf = vImage_Buffer(data: srcData, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        var dstBufF = vImage_Buffer(data: stretchedPtr, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: floatRowBytes)
        vImageInterpolatedLookupTable_PlanarF(&srcBuf, &dstBufF, stretchLUT, vImagePixelCount(stretchLUT.count), highClip, lowClip, vImage_Flags(kvImageNoFlags))

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
        lowClip: Float, highClip: Float, maxDisplaySize: Int = 0
    ) -> NSImage? {
        let pixelCount = width * height
        return pixels.withUnsafeMutableBufferPointer { buf in
            cpuStretch(srcData: buf.baseAddress!, pixelCount: pixelCount, width: width, height: height,
                       lowClip: lowClip, highClip: highClip, maxDisplaySize: maxDisplaySize)
        }
    }

    /// CPU fallback operating directly on a raw float pointer (e.g. Metal shared buffer).
    private static func cpuFallbackOnBuffer(
        _ floatPtr: UnsafeMutablePointer<Float>, width: Int, height: Int,
        lowClip: Float, highClip: Float, maxDisplaySize: Int = 0
    ) -> NSImage? {
        let pixelCount = width * height
        return cpuStretch(srcData: floatPtr, pixelCount: pixelCount, width: width, height: height,
                          lowClip: lowClip, highClip: highClip, maxDisplaySize: maxDisplaySize)
    }

    // MARK: - Percentile Estimation

    /// Estimate percentile clip bounds separately for each Bayer channel (R, G, B).
    /// Each channel is sampled independently so per-channel stretch eliminates colour casts.
    /// R and B each occupy ~1/4 of pixels; G occupies ~1/2.
    static func estimateBayerPerChannelPercentiles(
        _ ptr: UnsafePointer<Float>, width: Int, height: Int, rOffset: UInt32
    ) -> BayerClips {
        let rx = Int(rOffset & 1)
        let ry = Int((rOffset >> 1) & 1)
        let bx = 1 - rx
        let by = 1 - ry

        // Channel pixel counts
        let rCount = (width / 2) * (height / 2)
        let gCount = width * height / 2
        let rSubstride = max(1, rCount / percentileSampleCount)
        let gSubstride = max(1, gCount / percentileSampleCount)

        var rSamples = [Float](); rSamples.reserveCapacity(percentileSampleCount)
        var gSamples = [Float](); gSamples.reserveCapacity(percentileSampleCount)
        var bSamples = [Float](); bSamples.reserveCapacity(percentileSampleCount)

        // R pixels: every (rx, ry) position in 2×2 cell
        var i = 0
        for row in stride(from: ry, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: rx, to: width, by: 2) {
                if i % rSubstride == 0 { rSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        // B pixels: every (bx, by) position in 2×2 cell
        i = 0
        for row in stride(from: by, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: bx, to: width, by: 2) {
                if i % rSubstride == 0 { bSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        // G pixels: the two remaining positions per 2×2 cell
        i = 0
        for row in stride(from: ry, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: bx, to: width, by: 2) { // (bx, ry) — G in R-row
                if i % gSubstride == 0 { gSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }
        for row in stride(from: by, to: height, by: 2) {
            let rowBase = row * width
            for col in stride(from: rx, to: width, by: 2) { // (rx, by) — G in B-row
                if i % gSubstride == 0 { gSamples.append(ptr[rowBase + col]) }
                i += 1
            }
        }

        func clips(_ s: inout [Float]) -> (Float, Float) {
            guard !s.isEmpty else { return (0, 1) }
            vDSP.sort(&s, sortOrder: .ascending)
            let lo = s[Int(Float(s.count) * 0.001)]
            let hi = s[Int(Float(s.count - 1) * 0.999)]
            return (lo, hi > lo ? hi : lo + 1)
        }

        let (loR, hiR) = clips(&rSamples)
        let (loG, hiG) = clips(&gSamples)
        let (loB, hiB) = clips(&bSamples)
        return BayerClips(loR: loR, hiR: hiR, loG: loG, hiG: hiG, loB: loB, hiB: hiB)
    }

    /// Estimate from a raw pointer (for Metal buffer path — no array copy needed).
    /// Always uses stride-sampling: avoids a full copy for small images while
    /// giving equivalent accuracy to sorting the entire array.
    static func estimatePercentiles(_ ptr: UnsafePointer<Float>, count: Int) -> (low: Float, high: Float) {
        guard count > 0 else { return (0, 1) }
        let sampleStride = max(1, count / percentileSampleCount)
        var sample = [Float]()
        sample.reserveCapacity(min(count, percentileSampleCount))
        var i = 0
        while i < count {
            sample.append(ptr[i])
            i += sampleStride
        }
        vDSP.sort(&sample, sortOrder: .ascending)
        let n = sample.count
        let lo = sample[Int(Float(n) * 0.001)]
        let hi = sample[Int(Float(n - 1) * 0.999)]
        return (lo, hi > lo ? hi : lo + 1)
    }

    /// Estimate from an array (for fallback path)
    private static func estimatePercentiles(_ pixels: [Float]) -> (low: Float, high: Float) {
        pixels.withUnsafeBufferPointer { buf in
            estimatePercentiles(buf.baseAddress!, count: buf.count)
        }
    }
}
