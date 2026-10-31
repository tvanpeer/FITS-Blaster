//
//  MetalContext.swift
//  FITS Blaster
//
//  The one Metal device, command queue and set of compute pipelines, shared by the stretch
//  (ImageStretcher) and star detection (MetricsCalculator), with one dispatch helper and
//  one zero-copy image wrap (CODE_AUDIT §9.5, §7.9). A nil member means Metal or a kernel
//  isn't available — the Quick Look extensions have no Metal library — and callers take
//  the CPU path.
//

import AppKit
import Metal

enum MetalContext {

    static let device: MTLDevice? = MTLCreateSystemDefaultDevice()
    static let commandQueue: MTLCommandQueue? = device?.makeCommandQueue()

    // makeDefaultLibrary() finds all kernels from all .metal files compiled into the
    // app bundle — no separate library file needed.
    private static let library: MTLLibrary? = device?.makeDefaultLibrary()

    /// Greyscale MTF stretch, with optional 2×2 Bayer binning (`mtfStretch`).
    static let stretchPipeline = makePipeline("mtfStretch")
    /// Bayer demosaic + per-channel stretch (`bayerDebayerAndStretch`).
    static let bayerStretchPipeline = makePipeline("bayerDebayerAndStretch")
    /// Its two halves: the per-channel averages only (`bayerAverage`), and the stretch of
    /// those averages (`bayerStretchFromAverage`), for a colour render from a kept proxy.
    static let bayerAveragePipeline = makePipeline("bayerAverage")
    static let bayerStretchFromAveragePipeline = makePipeline("bayerStretchFromAverage")
    /// Full-frame local-maximum star detection (`detectLocalMaxima`).
    static let detectionPipeline = makePipeline("detectLocalMaxima")

    private static func makePipeline(_ name: String) -> MTLComputePipelineState? {
        guard let device, let function = library?.makeFunction(name: name) else { return nil }
        return try? device.makeComputePipelineState(function: function)
    }

    /// For tests: while true, every command buffer is treated as failed, so the callers'
    /// CPU fallbacks can be checked. Task-local, so it only affects the work of the test
    /// that sets it (and its child tasks), not tests running alongside.
    @TaskLocal static var failsCommandBuffersForTesting = false

    // MARK: - Dispatch

    /// The 2-D threadgroup for `pipeline`: 16 × 16 (the usual sweet spot for memory-bound
    /// 2-D kernels on Apple GPUs), clamped to what the pipeline allows (CODE_AUDIT §5.17).
    static func threadgroupSize(for pipeline: MTLComputePipelineState) -> MTLSize {
        let width = min(16, pipeline.maxTotalThreadsPerThreadgroup)
        let height = max(1, min(16, pipeline.maxTotalThreadsPerThreadgroup / width))
        return MTLSize(width: width, height: height, depth: 1)
    }

    /// Encodes one 2-D compute pass over `width` × `height` threads, commits it and waits
    /// for the GPU without blocking a thread. `encode` sets the pipeline's buffers and bytes.
    ///
    /// Returns false when the pass couldn't be encoded or the command buffer ended with an
    /// error: the output is then not valid and the caller falls back to the CPU path
    /// (CODE_AUDIT §5.17). Before, a failed pass was read as if it had worked — a black
    /// image, or zero stars without a CPU retry.
    static func runPass(_ pipeline: MTLComputePipelineState, width: Int, height: Int,
                        encode: (MTLComputeCommandEncoder) -> Void) async -> Bool {
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return false }
        encoder.setComputePipelineState(pipeline)
        encode(encoder)
        // Non-uniform dispatch: each thread handles one output element, for any size.
        encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: threadgroupSize(for: pipeline))
        encoder.endEncoding()

        // Non-blocking GPU wait: releases the cooperative thread while the GPU runs
        // so the thread pool can schedule other tasks (Moffat fitting, other images).
        let completed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            commandBuffer.addCompletedHandler { buffer in
                continuation.resume(returning: buffer.status == .completed)
            }
            commandBuffer.commit()
        }
        return completed && !failsCommandBuffersForTesting
    }

    // MARK: - Zero-copy image

    /// Wraps an 8-bit-per-channel shared buffer in an image without copying: the image's
    /// data provider reads straight from the buffer and keeps it alive until the image is
    /// released.
    static func makeImage(from buffer: MTLBuffer, width: Int, height: Int,
                          bytesPerPixel: Int, colorSpace: CGColorSpace,
                          bitmapInfo: CGBitmapInfo) -> NSImage? {
        let byteCount = width * height * bytesPerPixel
        let retained = Unmanaged.passRetained(buffer as AnyObject)
        guard let provider = CGDataProvider(dataInfo: retained.toOpaque(),
                                            data: buffer.contents(),
                                            size: byteCount,
                                            releaseData: { info, _, _ in
                                                if let info { Unmanaged<AnyObject>.fromOpaque(info).release() }
                                            }) else {
            retained.release()
            return nil
        }
        guard let cgImage = CGImage(
            width: width, height: height,
            bitsPerComponent: 8, bitsPerPixel: 8 * bytesPerPixel, bytesPerRow: width * bytesPerPixel,
            space: colorSpace, bitmapInfo: bitmapInfo,
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
        ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
