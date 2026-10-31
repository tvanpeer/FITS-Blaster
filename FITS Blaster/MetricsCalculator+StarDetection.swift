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
        // A local maximum needs a neighbour on every side, so crops under 3 × 3 have none.
        guard let base = pixels.baseAddress, cropW >= 3, cropH >= 3 else { return [] }
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

        candidates.sort(by: StarCandidate.brighterFirst)
        return candidates
    }

    // MARK: - GPU star detection

    /// GPU-accelerated full-frame local-maximum detection.
    ///
    /// Dispatches the `detectLocalMaxima` Metal kernel across a grid that covers
    /// every pixel of the image. Each thread that finds a local maximum above the
    /// threshold appends its position to a compact candidate list through an atomic
    /// counter.
    ///
    /// Pipeline:
    ///   1. A pass with room for `capacity` candidates (`maxDetectionCandidates`).
    ///   2. If the counter found more, a second pass with room for all of them: which ones
    ///      fit in the first list depends on the GPU's thread order, so the metrics varied
    ///      between runs on the same file (m31-night #0026: 50,455 maxima). The same data and
    ///      threshold find the same number, so the second list holds every one of them.
    ///   3. Read back the stored candidates, look up their peak values and sort
    ///      them brightest first.
    ///
    /// Returns nil if Metal is unavailable or a GPU pass failed, letting the caller fall
    /// back to CPU. `capacity` is a parameter for the tests.
    @concurrent static func findLocalMaximaGPU(metalBuffer: MTLBuffer,
                                               width: Int, height: Int,
                                               threshold: Float,
                                               capacity: Int = maxDetectionCandidates) async -> GPUDetectionResult? {
        // The frame's buffer must belong to the shared device the pipeline was built for;
        // the result buffers are made on that same device (§7.9).
        guard let pipeline = MetalContext.detectionPipeline,
              metalBuffer.device === MetalContext.device else { return nil }

        guard var pass = await detectionPass(pipeline, metalBuffer: metalBuffer, width: width, height: height,
                                             threshold: threshold, capacity: capacity) else { return nil }
        if pass.found > capacity {
            guard let all = await detectionPass(pipeline, metalBuffer: metalBuffer, width: width, height: height,
                                                threshold: threshold, capacity: pass.found) else { return nil }
            pass = all
        }
        let storedCount = min(pass.found, pass.capacity)
        guard storedCount > 0 else { return GPUDetectionResult(candidates: []) }
        let candidatesBuffer = pass.candidates

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

        candidates.sort(by: StarCandidate.brighterFirst)
        return GPUDetectionResult(candidates: candidates)
    }

    /// One `detectLocalMaxima` pass with room for `capacity` candidates: the list, and how many
    /// local maxima the counter found (more than `capacity` when the list was too small).
    private static func detectionPass(_ pipeline: MTLComputePipelineState, metalBuffer: MTLBuffer,
                                      width: Int, height: Int, threshold: Float,
                                      capacity: Int) async -> (candidates: MTLBuffer, found: Int, capacity: Int)? {
        let device = metalBuffer.device
        // Compact candidate list: capacity × 8 bytes (400 KB for the first pass).
        // Far smaller than the old width×height flag buffer (up to 200 MB for 50 MP),
        // and the CPU reads only the slots actually written — no full-frame scan.
        guard capacity > 0,
              let candidatesBuffer = device.makeBuffer(length: capacity * MemoryLayout<DetectCandidate>.stride,
                                                       options: .storageModeShared),
              // Single UInt32 atomic counter, zeroed so the kernel starts counting from 0.
              let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.size,
                                                  options: .storageModeShared) else { return nil }
        countBuffer.contents().storeBytes(of: UInt32(0), as: UInt32.self)

        var params = DetectParams(width:     UInt32(width),
                                  height:    UInt32(height),
                                  threshold: threshold,
                                  capacity:  UInt32(capacity))

        // One thread per pixel, in the shared 16×16 threadgroup clamped to the pipeline's
        // limit. A failed pass returns nil, so the caller detects on the CPU instead of
        // reading an unset counter as "no stars" (§5.17).
        let completed = await MetalContext.runPass(pipeline, width: width, height: height) { encoder in
            encoder.setBuffer(metalBuffer,      offset: 0, index: 0)  // input: float pixels
            encoder.setBuffer(candidatesBuffer, offset: 0, index: 1)  // output: compact list
            encoder.setBuffer(countBuffer,      offset: 0, index: 2)  // output: atomic counter
            encoder.setBytes(&params, length: MemoryLayout<DetectParams>.stride, index: 3)
        }
        guard completed else { return nil }
        // The counter holds the number of local maxima found, which may exceed the capacity.
        return (candidatesBuffer, Int(countBuffer.contents().load(as: UInt32.self)), capacity)
    }
}
