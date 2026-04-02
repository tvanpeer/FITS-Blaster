//
//  MetricsCalculator+Scoring.swift
//  FITS Blaster
//
//  Quality score, histogram computation, and the median helper.
//

import Foundation
import Accelerate

extension MetricsCalculator {

    // MARK: - Histogram computation

    /// Compute a 256-bin histogram using pre-computed min/max values.
    /// This is the fast path: skips the two full-buffer vDSP min/max passes
    /// because the caller (FITSReader.readIntoBuffer) already computed them
    /// while the buffer was hot in cache right after conversion.
    static func computeHistogram(ptr: UnsafePointer<Float>, count: Int,
                                 minVal: Float, maxVal: Float) -> [Int] {
        let binCount = 256
        guard count > 0, maxVal > minVal else { return [Int](repeating: 0, count: binCount) }

        let scale = Float(binCount - 1) / (maxVal - minVal)
        var histogram = [Int](repeating: 0, count: binCount)

        let stride = max(1, count / 60_000)
        var i = 0
        while i < count {
            let bin = Int((ptr[i] - minVal) * scale)
            histogram[min(bin, binCount - 1)] += 1
            i += stride
        }
        return histogram
    }

    /// Compute a 256-bin histogram from sampled raw pixel data via a raw pointer.
    /// Uses stride sampling to keep it fast on large images.
    /// Prefer the minVal/maxVal overload when those are already known.
    static func computeHistogram(ptr: UnsafePointer<Float>, count: Int) -> [Int] {
        let binCount = 256
        guard count > 0 else { return [Int](repeating: 0, count: binCount) }

        var minVal: Float = 0
        var maxVal: Float = 0
        vDSP_minv(ptr, 1, &minVal, vDSP_Length(count))
        vDSP_maxv(ptr, 1, &maxVal, vDSP_Length(count))
        return computeHistogram(ptr: ptr, count: count, minVal: minVal, maxVal: maxVal)
    }

    /// Compute a 256-bin histogram from a Float array using pre-computed min/max.
    /// Use this overload when bounds are already known (e.g. from FITSReader.read()).
    static func computeHistogram(pixels: [Float], minVal: Float, maxVal: Float) -> [Int] {
        pixels.withUnsafeBufferPointer { buf in
            computeHistogram(ptr: buf.baseAddress!, count: buf.count, minVal: minVal, maxVal: maxVal)
        }
    }

    /// Compute a 256-bin histogram from a Float array. Delegates to the pointer overload.
    static func computeHistogram(pixels: [Float], width: Int, height: Int) -> [Int] {
        pixels.withUnsafeBufferPointer { buf in
            computeHistogram(ptr: buf.baseAddress!, count: buf.count)
        }
    }

    // MARK: - Quality score

    /// Composite quality score 0–100 from whichever metrics are non-nil.
    /// Weights are renormalised so they always sum to 1.0 over the active set.
    static func qualityScore(fwhm: Float?, eccentricity: Float?,
                             snr: Float?, starCount: Int?) -> Int {
        var weightedSum: Float = 0
        var totalWeight: Float = 0

        if let v = fwhm {
            let w: Float = 0.35
            // Ideal ≤ 2 px, bad at 7 px+
            let s = max(0, min(1, 1 - (v - 2.0) / 5.0))
            weightedSum += s * w; totalWeight += w
        }
        if let v = eccentricity {
            let w: Float = 0.35
            // Ideal 0, bad at 0.5+
            let s = max(0, min(1, 1 - v / 0.5))
            weightedSum += s * w; totalWeight += w
        }
        if let v = snr {
            let w: Float = 0.20
            // Aperture SNR: bad below 10, ideal at 200+
            let s = max(0, min(1, (v - 10) / 190))
            weightedSum += s * w; totalWeight += w
        }
        if let v = starCount {
            let w: Float = 0.10
            // Ideal 500+, bad at 0; log scale so small counts aren't completely penalised
            let s = max(0, min(1, log10(Float(v) + 1) / log10(501)))
            weightedSum += s * w; totalWeight += w
        }

        guard totalWeight > 0 else { return 0 }
        return Int((weightedSum / totalWeight) * 100)
    }

    // MARK: - Helpers

    static func median(_ values: [Float]) -> Float? {
        guard !values.isEmpty else { return nil }
        var sorted = values
        vDSP.sort(&sorted, sortOrder: .ascending)
        return sorted[sorted.count / 2]
    }
}
