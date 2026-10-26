//
//  ImageStretcher+Metal.swift
//  FITS Blaster
//
//  The GPU stretch: grey (with 2×2 Bayer binning) and Bayer colour, on frames in
//  Metal shared buffers. App only — the Quick Look extensions use the CPU stretch.
//

import Foundation
import AppKit
import Metal

extension ImageStretcher {

    /// Parameters struct matching the Metal shader's StretchParams (must stay in sync with FITSStretch.metal)
    private struct StretchParams {
        var shadowClip: Float   // STF shadow clipping point (replaces percentile lowClip)
        var highClip: Float
        var mtfMidtone: Float   // MTF midtone — background maps to this output level
        var srcWidth: UInt32    // physical buffer width
        var srcHeight: UInt32   // physical buffer height
        var dstWidth: UInt32
        var dstHeight: UInt32
        /// 1 = 2×2 Bayer binning (greyscale display of raw Bayer files), 0 = normal
        var bayerBin: UInt32
    }

    /// Parameters struct matching the Metal shader's BayerStretchParams (14 × 4 bytes = 56 bytes)
    private struct BayerStretchParams {
        var shadowClipR: Float
        var highClipR: Float
        var mtfMidtoneR: Float
        var shadowClipG: Float
        var highClipG: Float
        var mtfMidtoneG: Float
        var shadowClipB: Float
        var highClipB: Float
        var mtfMidtoneB: Float
        var srcWidth: UInt32
        var srcHeight: UInt32
        var dstWidth: UInt32
        var dstHeight: UInt32
        var rOffset: UInt32
    }

    // MARK: - Public

    /// Stretch using pixel data already in a Metal shared buffer.
    /// Pass `bayerPattern` when the file is a raw Bayer mosaic and should be displayed in
    /// greyscale — the kernel will apply 2×2 Bayer binning to eliminate the screen-door effect.
    @concurrent static func createImage(inputBuffer: MTLBuffer, width: Int, height: Int,
                                        maxDisplaySize: Int = 0,
                                        bayerPattern: BayerPattern? = nil) async -> NSImage? {
        let pixelCount = width * height
        let floatPtr = inputBuffer.contents().assumingMemoryBound(to: Float.self)
        let (shadowClip, highClip, midtone) = computeSTFClips(floatPtr, count: pixelCount)
        guard highClip > shadowClip else { return nil }

        if let result = await metalStretch(inputBuffer: inputBuffer, width: width, height: height,
                                           shadowClip: shadowClip, highClip: highClip, midtone: midtone,
                                           maxDisplaySize: maxDisplaySize,
                                           bayerPattern: bayerPattern) {
            return result
        }

        // CPU fallback — operate directly on Metal shared buffer (no copy)
        return cpuFallbackOnBuffer(inputBuffer.contents().assumingMemoryBound(to: Float.self),
                                   width: width, height: height,
                                   shadowClip: shadowClip, highClip: highClip, midtone: midtone,
                                   maxDisplaySize: maxDisplaySize)
    }

    // MARK: - Metal Path

    /// GPU-accelerated stretch. The kernel downsamples directly to the display size in a
    /// single pass — no post-GPU CPU scaling needed. Output Metal buffer is zero-copy into
    /// CGDataProvider.
    @concurrent private static func metalStretch(
        inputBuffer: MTLBuffer, width: Int, height: Int,
        shadowClip: Float, highClip: Float, midtone: Float,
        maxDisplaySize: Int = 0,
        bayerPattern: BayerPattern? = nil
    ) async -> NSImage? {
        // The input buffer must belong to the shared device the pipelines were built for (§7.9).
        guard let pipelineState = MetalContext.stretchPipeline,
              inputBuffer.device === MetalContext.device else { return nil }

        // When bayerBin=1, the kernel treats the source as half-resolution so each output
        // pixel covers aligned 2×2 Bayer cells. Use the effective (binned) dimensions
        // when computing the output size so the image isn't unnecessarily downscaled.
        let isBayerBin = bayerPattern != nil
        let effectiveW = isBayerBin ? width  / 2 : width
        let effectiveH = isBayerBin ? height / 2 : height

        // Compute output dimensions: the kernel writes directly at display size.
        let dstW: Int
        let dstH: Int
        if maxDisplaySize > 0 && max(effectiveW, effectiveH) > maxDisplaySize {
            let scale = Float(maxDisplaySize) / Float(max(effectiveW, effectiveH))
            dstW = max(1, Int(Float(effectiveW) * scale))
            dstH = max(1, Int(Float(effectiveH) * scale))
        } else {
            dstW = effectiveW
            dstH = effectiveH
        }

        let outputByteCount = dstW * dstH
        guard let outputBuffer = inputBuffer.device.makeBuffer(length: outputByteCount,
                                                               options: .storageModeShared) else {
            return nil
        }

        var params = StretchParams(
            shadowClip: shadowClip, highClip: highClip, mtfMidtone: midtone,
            srcWidth: UInt32(width), srcHeight: UInt32(height),
            dstWidth: UInt32(dstW), dstHeight: UInt32(dstH),
            bayerBin: isBayerBin ? 1 : 0
        )

        // Dispatch at output size — each thread writes exactly one output pixel.
        // A failed pass returns nil, so the caller renders on the CPU instead (§5.17).
        let completed = await MetalContext.runPass(pipelineState, width: dstW, height: dstH) { encoder in
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<StretchParams>.stride, index: 2)
        }
        guard completed else { return nil }

        // Zero-copy: the image reads straight from the Metal shared buffer.
        return MetalContext.makeImage(from: outputBuffer, width: dstW, height: dstH, bytesPerPixel: 1,
                                      colorSpace: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue))
    }

    // MARK: - Metal Bayer Path

    /// Stretch using pre-computed greyscale clip bounds, bypassing percentile estimation.
    /// Use the result of `computeGreyClips` (or a per-group median) to re-render an image
    /// with consistent stretch across a folder of same-filter frames.
    @concurrent static func createImage(inputBuffer: MTLBuffer, width: Int, height: Int,
                                        clips: GreyClips, maxDisplaySize: Int = 0,
                                        bayerPattern: BayerPattern? = nil) async -> NSImage? {
        guard clips.isValid else { return nil }
        if let result = await metalStretch(inputBuffer: inputBuffer, width: width, height: height,
                                           shadowClip: clips.low, highClip: clips.high, midtone: clips.midtone,
                                           maxDisplaySize: maxDisplaySize,
                                           bayerPattern: bayerPattern) {
            return result
        }
        return cpuFallbackOnBuffer(inputBuffer.contents().assumingMemoryBound(to: Float.self),
                                   width: width, height: height,
                                   shadowClip: clips.low, highClip: clips.high, midtone: clips.midtone,
                                   maxDisplaySize: maxDisplaySize)
    }

    /// Compute greyscale percentile clip bounds from a Metal shared buffer without rendering.
    /// Store the result on `ImageEntry.greyClips` during Phase A, then compute per-(folder, filter)
    /// medians and call `createImage(inputBuffer:clips:)` for the normalisation pass.
    static func computeGreyClips(_ buffer: MTLBuffer, pixelCount: Int) -> GreyClips {
        let ptr = buffer.contents().assumingMemoryBound(to: Float.self)
        return computeSTFStatistics(ptr, count: pixelCount)
    }

    /// GPU-accelerated Bayer demosaic + stretch using pre-computed clip bounds.
    /// Call `computeBayerClips` first to obtain `clips`, then pass the median/shared
    /// clips here for consistent stretch across a folder of images.
    @concurrent static func createBayerImage(inputBuffer: MTLBuffer, width: Int, height: Int,
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

    @concurrent private static func metalBayerStretch(
        inputBuffer: MTLBuffer, width: Int, height: Int,
        rOffset: UInt32, clips: BayerClips,
        maxDisplaySize: Int = 0
    ) async -> NSImage? {
        // The input buffer must belong to the shared device the pipelines were built for (§7.9).
        guard let pipelineState = MetalContext.bayerStretchPipeline,
              inputBuffer.device === MetalContext.device else { return nil }

        // Bayer images are always binned 2×2 so each output pixel's footprint covers
        // at least one complete Bayer cell — eliminating the screen-door pattern.
        let effectiveW = width  / 2
        let effectiveH = height / 2

        // Compute output dimensions from the effective (binned) source size.
        let dstW: Int
        let dstH: Int
        if maxDisplaySize > 0 && max(effectiveW, effectiveH) > maxDisplaySize {
            let scale = Float(maxDisplaySize) / Float(max(effectiveW, effectiveH))
            dstW = max(1, Int(Float(effectiveW) * scale))
            dstH = max(1, Int(Float(effectiveH) * scale))
        } else {
            dstW = effectiveW
            dstH = effectiveH
        }

        // Output: RGBA UInt8, 4 bytes/pixel, at display size
        let outputByteCount = dstW * dstH * 4
        guard let outputBuffer = inputBuffer.device.makeBuffer(length: outputByteCount,
                                                               options: .storageModeShared) else {
            return nil
        }

        var params = BayerStretchParams(
            shadowClipR: clips.loR, highClipR: clips.hiR, mtfMidtoneR: clips.midR,
            shadowClipG: clips.loG, highClipG: clips.hiG, mtfMidtoneG: clips.midG,
            shadowClipB: clips.loB, highClipB: clips.hiB, mtfMidtoneB: clips.midB,
            srcWidth: UInt32(width), srcHeight: UInt32(height),
            dstWidth: UInt32(dstW), dstHeight: UInt32(dstH),
            rOffset: rOffset
        )

        // Dispatch at output size — each thread writes exactly one output pixel. There is no
        // CPU colour path: after a failed pass the frame keeps its grey render (§5.17).
        let completed = await MetalContext.runPass(pipelineState, width: dstW, height: dstH) { encoder in
            encoder.setBuffer(inputBuffer, offset: 0, index: 0)
            encoder.setBuffer(outputBuffer, offset: 0, index: 1)
            encoder.setBytes(&params, length: MemoryLayout<BayerStretchParams>.stride, index: 2)
        }
        guard completed else { return nil }

        // Zero-copy: the image reads straight from the Metal shared buffer.
        return MetalContext.makeImage(from: outputBuffer, width: dstW, height: dstH, bytesPerPixel: 4,
                                      colorSpace: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue))
    }
}
