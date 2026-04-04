//
//  MetricsCalculator+StarDetection.swift
//  FITS Blaster
//
//  Background estimation, CPU/GPU local-maximum detection, and non-maximum suppression.
//

import Foundation
import Accelerate
import Metal

extension MetricsCalculator {

    // MARK: - Background estimation

    /// Robust background estimate using stratified sampling + median/MAD.
    static func estimateBackground(_ pixels: UnsafeBufferPointer<Float>, width: Int, height: Int) -> (median: Float, sigma: Float) {
        let n = pixels.count
        let sampleCount = min(n, Constants.backgroundSampleCount)
        let stride = max(1, n / sampleCount)

        var samples = [Float](repeating: 0, count: sampleCount)
        for i in 0..<sampleCount { samples[i] = pixels[i * stride] }
        vDSP.sort(&samples, sortOrder: .ascending)
        let med = samples[sampleCount / 2]

        // Relative floor: 0.01 % of the image's sampled dynamic range.
        // A fixed floor of 1.0 works for 16-bit ADU data but breaks for BITPIX=-32
        // float images whose values may be in the range 0.0–1.0 — the threshold
        // would overshoot all pixel values and no stars would ever be detected.
        let dataRange = samples[sampleCount - 1] - samples[0]
        let sigmaFloor = max(dataRange * 0.0001, Float.leastNormalMagnitude)

        var deviations = [Float](repeating: 0, count: sampleCount)
        var negMed = -med
        vDSP_vsadd(samples, 1, &negMed, &deviations, 1, vDSP_Length(sampleCount))
        vDSP_vabs(deviations, 1, &deviations, 1, vDSP_Length(sampleCount))
        vDSP.sort(&deviations, sortOrder: .ascending)
        let mad = deviations[sampleCount / 2]
        let sigma = max(mad * 1.4826, sigmaFloor)

        return (med, sigma)
    }

    // MARK: - Non-maximum suppression

    /// Non-maximum suppression: remove any candidate within `minSep` pixels of a
    /// brighter one, keeping only the dominant peak in each neighbourhood.
    ///
    /// This is especially important for BITPIX=-32 float images: unlike 16-bit
    /// integer data where adjacent pixels can tie (preventing multiple local
    /// maxima per star), IEEE 754 floats are almost always unique, so the same
    /// stellar PSF can generate several sub-pixel local maxima. With minSep = 3,
    /// candidates within 3 px of a brighter neighbour are suppressed.
    ///
    /// Uses an O(n) grid-based lookup (one hash-set entry per accepted candidate)
    /// so even 50 000 input candidates are processed in milliseconds.
    static func nonMaximumSuppression(_ candidates: [StarCandidate],
                                      imageWidth: Int,
                                      minSep: Int = 3) -> [StarCandidate] {
        guard minSep > 0, !candidates.isEmpty else { return candidates }
        let cellW = max(1, (imageWidth + minSep - 1) / minSep)
        var occupied = Set<Int>()
        occupied.reserveCapacity(candidates.count)
        var filtered: [StarCandidate] = []
        filtered.reserveCapacity(candidates.count / 2)

        for c in candidates {   // already sorted brightest-first
            let cellX = c.x / minSep
            let cellY = c.y / minSep
            // Check 3×3 grid neighbourhood — covers ±minSep pixels in both axes.
            var blocked = false
            outer: for dy in -1...1 {
                for dx in -1...1 {
                    let nx = cellX + dx
                    let ny = cellY + dy
                    guard nx >= 0 && ny >= 0 else { continue }
                    if occupied.contains(ny * cellW + nx) { blocked = true; break outer }
                }
            }
            if !blocked {
                filtered.append(c)
                occupied.insert(cellY * cellW + cellX)
            }
        }
        return filtered
    }

    // MARK: - CPU star detection

    /// Find local maxima above threshold within the centre crop.
    /// Returns candidates sorted by peak flux (brightest first).
    ///
    /// Vectorized pre-filter: uses vDSP_maxv on each crop row to skip rows
    /// that contain no above-threshold pixels entirely. For typical sky backgrounds
    /// (95%+ of pixels below threshold) this eliminates the vast majority of rows
    /// before the scalar 8-neighbour check is ever reached — ~50× faster than
    /// the naive full-scan loop.
    static func findLocalMaxima(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                cropX: Int, cropY: Int, cropW: Int, cropH: Int,
                                threshold: Float) -> [StarCandidate] {
        guard let base = pixels.baseAddress else { return [] }
        var candidates: [StarCandidate] = []
        candidates.reserveCapacity(200)

        let innerLen = vDSP_Length(cropW - 2)   // columns excluding the 1-pixel border

        for y in 1..<(cropH - 1) {
            let origY  = cropY + y
            let rowOff = origY * width + cropX

            // Vectorized row-max: skip the entire row if nothing exceeds the threshold.
            var rowMax: Float = 0
            vDSP_maxv(base + rowOff + 1, 1, &rowMax, innerLen)
            guard rowMax >= threshold else { continue }

            // At least one above-threshold pixel exists — check each for local maximum.
            for x in 1..<(cropW - 1) {
                let origX = cropX + x
                let idx   = origY * width + origX
                let val   = pixels[idx]
                guard val >= threshold else { continue }

                if val > pixels[idx - width - 1] &&
                   val > pixels[idx - width    ] &&
                   val > pixels[idx - width + 1] &&
                   val > pixels[idx         - 1] &&
                   val > pixels[idx         + 1] &&
                   val > pixels[idx + width - 1] &&
                   val > pixels[idx + width    ] &&
                   val > pixels[idx + width + 1] {
                    candidates.append(StarCandidate(x: origX, y: origY, peak: val))
                }
            }
        }

        candidates.sort { $0.peak > $1.peak }
        return candidates
    }

    // MARK: - GPU star detection

    /// GPU-accelerated full-frame local-maximum detection.
    ///
    /// Dispatches the `detectLocalMaxima` Metal kernel across a grid that covers
    /// every pixel of the image simultaneously. Each thread writes 1 or 0 into a
    /// flat UInt8 flag buffer, then the CPU scans that buffer to collect positions.
    ///
    /// Pipeline:
    ///   1. Allocate a `width × height` byte flag buffer in shared memory.
    ///   2. Encode and commit the compute pass (kernel runs fully on the GPU).
    ///   3. Wait for completion (`waitUntilCompleted` — synchronous, ~3–8 ms
    ///      for 16–50 MP on Apple Silicon).
    ///   4. Linear scan of the flag buffer to collect candidate (x, y, peak)
    ///      tuples (~1–2 ms at memory-bandwidth speed).
    ///
    /// Returns nil if Metal is unavailable, letting the caller fall back to CPU.
    @concurrent static func findLocalMaximaGPU(metalBuffer: MTLBuffer,
                                               width: Int, height: Int,
                                               threshold: Float) async -> GPUDetectionResult? {
        guard let queue    = detectionCommandQueue,
              let pipeline = detectionPipelineState,
              let device   = detectionDevice else { return nil }

        // Compact candidate list: at most maxDetectionCandidates × 8 bytes = 80 KB.
        // Far smaller than the old width×height flag buffer (up to 200 MB for 50 MP),
        // and the CPU reads only the slots actually written — no full-frame scan.
        let candidateBytes = maxDetectionCandidates * MemoryLayout<DetectCandidate>.stride
        guard let candidatesBuffer = device.makeBuffer(length: candidateBytes,
                                                       options: .storageModeShared) else {
            return nil
        }

        // Single UInt32 atomic counter. Must be zeroed before each dispatch so
        // the kernel starts counting from 0.
        guard let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                                  options: .storageModeShared) else {
            return nil
        }
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var params = DetectParams(width:     UInt32(width),
                                  height:    UInt32(height),
                                  threshold: threshold)

        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder       = commandBuffer.makeComputeCommandEncoder() else { return nil }

        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(metalBuffer,      offset: 0, index: 0)  // input: float pixels
        encoder.setBuffer(candidatesBuffer, offset: 0, index: 1)  // output: compact list
        encoder.setBuffer(countBuffer,      offset: 0, index: 2)  // output: atomic counter
        encoder.setBytes(&params, length: MemoryLayout<DetectParams>.stride, index: 3)

        // 16×16 threadgroup (256 threads) — standard sweet spot for memory-bound
        // 2D kernels on Apple Silicon. Non-uniform dispatch handles any image size.
        let tgSize = MTLSize(width: 16, height: 16, depth: 1)
        let grid   = MTLSize(width: width, height: height, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tgSize)
        encoder.endEncoding()

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            commandBuffer.addCompletedHandler { _ in continuation.resume() }
            commandBuffer.commit()
        }

        // The atomic counter holds the true number of qualifying pixels found,
        // which may exceed the buffer capacity. Preserve both values separately:
        //   totalFound → reported as star count (accurate even when capped)
        //   storedCount → how many candidates we can actually read back
        let totalFound  = Int(countBuffer.contents().load(as: UInt32.self))
        let storedCount = min(totalFound, maxDetectionCandidates)
        guard storedCount > 0 else { return GPUDetectionResult(candidates: [], totalFound: 0) }

        // Convert the compact DetectCandidate list to StarCandidates, looking up
        // peak values from the input buffer. This is O(storedCount) — typically
        // a few hundred to a few thousand reads, not O(width × height).
        let floatPtr   = metalBuffer.contents().assumingMemoryBound(to: Float.self)
        let gpuEntries = candidatesBuffer.contents()
                             .assumingMemoryBound(to: DetectCandidate.self)

        var candidates: [StarCandidate] = []
        candidates.reserveCapacity(storedCount)
        for i in 0..<storedCount {
            let e = gpuEntries[i]
            let x = Int(e.x), y = Int(e.y)
            candidates.append(StarCandidate(x: x, y: y, peak: floatPtr[y * width + x]))
        }

        candidates.sort { $0.peak > $1.peak }
        return GPUDetectionResult(candidates: candidates, totalFound: totalFound)
    }
}
