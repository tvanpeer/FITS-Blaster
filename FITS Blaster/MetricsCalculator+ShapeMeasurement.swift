//
//  MetricsCalculator+ShapeMeasurement.swift
//  FITS Blaster
//
//  Per-star PSF fitting: FWHM, eccentricity, SNR. Both full-frame and crop-based variants.
//

import Foundation
import Accelerate

extension MetricsCalculator {

    // MARK: - Crop extraction

    /// Extract a (2*cropHalf+1)² pixel crop centred on (cx, cy).
    /// Out-of-bounds pixels are filled with 0.
    static func extractCrop(from pixels: UnsafeBufferPointer<Float>,
                             width: Int, height: Int,
                             cx: Int, cy: Int, cropHalf: Int) -> [Float] {
        let side = 2 * cropHalf + 1
        var crop = [Float](repeating: 0, count: side * side)
        for dy in -cropHalf...cropHalf {
            for dx in -cropHalf...cropHalf {
                let sx = cx + dx, sy = cy + dy
                guard sx >= 0, sx < width, sy >= 0, sy < height else { continue }
                crop[(dy + cropHalf) * side + (dx + cropHalf)] = pixels[sy * width + sx]
            }
        }
        return crop
    }

    // MARK: - Full-frame shape measurement

    /// Lightweight FWHM check used for bulk star counting in Phase 2.
    ///
    /// Fits a 1D Moffat β=4 profile along the X axis at **integer** pixel
    /// coordinates (no bilinear centroid, no Y-axis fit, no eccentricity loop).
    /// Roughly 10× cheaper than the full `measureShape`, so it can be called on
    /// thousands of sampled candidates without noticeable latency.
    ///
    /// Returns the estimated FWHM in pixels, or 0 on fit failure.
    static func measureFWHMOnly(pixels: UnsafeBufferPointer<Float>,
                                width: Int, height: Int,
                                cx: Int, cy: Int,
                                background: Float) -> Float {
        let rowStart = cy * width
        guard cy >= 0 && cy < height,
              cx >= 0 && cx < width,
              rowStart + cx < pixels.count else { return 0 }

        let peak = pixels[rowStart + cx] - background
        guard peak > 0 else { return 0 }

        // PSF cross-section pre-filter: all four immediate neighbours (±1px in X and Y)
        // must carry at least 5% of the background-subtracted peak flux. Real stars pass
        // easily; isolated noise spikes or hot pixels have neighbours at sky level
        // (≈ 0 after background subtraction), so this check rejects most of them
        // without running the expensive 20-point Moffat loop.
        //
        // 5% threshold rationale: a Moffat β=4 PSF with FWHM ≥ 1.3 px has ≥ 8% flux in
        // each immediate neighbour even when the star is detected 0.5 px off-centre, so
        // real stars pass easily. An isolated noise spike at 5σ has P(single neighbour
        // > 0.25σ) ≈ 40%, giving P(all 4 pass) ≈ 2.6% — a large reduction at very low
        // cost. 15% was too aggressive: off-centre stars with FWHM ≈ 2 px had Y-neighbours
        // at ~10% of detected peak, causing ~38% of real stars to be incorrectly rejected.
        let minWing = peak * 0.05
        let l = cx > 0          ? pixels[rowStart + cx - 1]      - background : -1
        let r = cx + 1 < width  ? pixels[rowStart + cx + 1]      - background : -1
        let u = cy > 0          ? pixels[(cy - 1) * width + cx]  - background : -1
        let d = cy + 1 < height ? pixels[(cy + 1) * width + cx]  - background : -1
        guard l > minWing, r > minWing, u > minWing, d > minWing else { return 0 }

        let halfW    = 10
        let minFrac: Float = 0.02
        var num: Float = 0, den: Float = 0

        for offset in -halfW...halfW where offset != 0 {
            let px = cx + offset
            guard px >= 0, px < width else { continue }
            let val = pixels[rowStart + px] - background
            guard val > peak * minFrac, val < peak else { continue }
            // Linearised Moffat β=4: z = (A/I)^{1/4} − 1 = sqrt(sqrt(A/I)) − 1
            let ratio = peak / val
            let z  = ratio.squareRoot().squareRoot() - 1
            let x2 = Float(offset * offset)
            let w  = val
            num += w * z  * x2
            den += w * x2 * x2
        }

        guard den > 0, num > 0 else { return 0 }
        let alpha      = (den / num).squareRoot()
        // FWHM = 2α·√(2^{1/4}−1), β=4 → constant ≈ 0.870
        let fwhmFactor = 2 * (pow(Float(2), Float(0.25)) - 1).squareRoot()
        return alpha * fwhmFactor
    }

    /// Compute FWHM, eccentricity, and aperture SNR for a single star.
    ///
    /// **FWHM:** 1D Moffat β=4 fits along four directions (0°, 45°, 90°, 135°).
    /// The four α values are combined analytically to recover the true principal-axis
    /// semi-widths of the elliptical PSF at any orientation; the geometric mean gives
    /// a single representative FWHM matching PixInsight's summary value.
    ///
    /// **Eccentricity:** Derived from the reconstructed principal-axis FWHM values.
    /// Orientation-invariant: correctly detects elongation at any angle, including diagonal.
    ///
    /// **SNR:** Peak signal above background in units of sky sigma.
    ///
    /// **peakVal:** Background-subtracted sub-pixel peak, returned so callers can
    /// compute PSF Signal Weight without re-deriving it from the fit coefficients.
    static func measureShape(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                             cx: Int, cy: Int, background: Float,
                             sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float, peakVal: Float) {
        let peakIndex = cy * width + cx
        guard peakIndex >= 0 && peakIndex < pixels.count else { return (0, 0, 0, 0) }
        guard pixels[peakIndex] > background else { return (0, 0, 0, 0) }

        // Sub-pixel centroid via intensity-weighted 5×5 window.
        let centHalf = 2
        var sumI: Float = 0, sumXI: Float = 0, sumYI: Float = 0
        for dy in -centHalf...centHalf {
            for dx in -centHalf...centHalf {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let val = max(0, pixels[py * width + px] - background)
                sumI  += val
                sumXI += Float(dx) * val
                sumYI += Float(dy) * val
            }
        }
        guard sumI > 0 else { return (0, 0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        // True peak via bilinear interpolation at the sub-pixel centroid.
        let peakVal = bilinear(pixels: pixels, width: width, height: height,
                               x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0, 0) }

        // Fit Moffat α along four directions: 0°, 90°, 45°, 135°.
        let rt2: Float = 1 / Float(2).squareRoot()
        guard let a0   = fitMoffatAlpha(pixels: pixels, width: width, height: height,
                                        centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: 1, dy: 0),
              let a90  = fitMoffatAlpha(pixels: pixels, width: width, height: height,
                                        centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: 0, dy: 1),
              let a45  = fitMoffatAlpha(pixels: pixels, width: width, height: height,
                                        centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: rt2, dy: rt2),
              let a135 = fitMoffatAlpha(pixels: pixels, width: width, height: height,
                                        centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: -rt2, dy: rt2)
        else { return (0, 0, 0, 0) }

        // Reconstruct true principal-axis α values from four directional measurements.
        //
        // For an elliptical Moffat with semi-axes a (major), b (minor), rotation θ:
        //   1/α(φ)² = cos²(φ−θ)/a² + sin²(φ−θ)/b²
        //
        // This gives three independent combinations:
        //   S  = 1/a² + 1/b²                  = (inv0 + inv90 + inv45 + inv135) / 2
        //   C  = (1/a² − 1/b²)·cos(2θ)        = inv0  − inv90
        //   S2 = (1/a² − 1/b²)·sin(2θ)        = inv45 − inv135
        //
        // Solving: |1/a² − 1/b²| = D = √(C² + S2²)
        //   1/a_major² = (S − D) / 2  (smaller reciprocal → larger axis)
        //   1/a_minor² = (S + D) / 2
        let inv0   = 1 / (a0   * a0)
        let inv90  = 1 / (a90  * a90)
        let inv45  = 1 / (a45  * a45)
        let inv135 = 1 / (a135 * a135)
        let S  = (inv0 + inv90 + inv45 + inv135) / 2
        let C  = inv0  - inv90
        let S2 = inv45 - inv135
        let D  = (C * C + S2 * S2).squareRoot()
        let invMajor2 = (S - D) / 2
        let invMinor2 = (S + D) / 2
        guard invMajor2 > 0, invMinor2 > 0 else { return (0, 0, 0, 0) }

        let fwhmFactor = 2 * (pow(Float(2), Float(0.25)) - 1).squareRoot()
        let fwhmMajor  = fwhmFactor / invMajor2.squareRoot()
        let fwhmMinor  = fwhmFactor / invMinor2.squareRoot()
        let fwhm       = (fwhmMajor * fwhmMinor).squareRoot()

        let axisRatio    = fwhmMinor / fwhmMajor
        let eccentricity = max(0, 1 - axisRatio * axisRatio).squareRoot()

        let snr: Float = peakVal / sigma

        return (fwhm, eccentricity, snr, peakVal)
    }

    /// Fit a 1D Moffat β=4 profile through (centX, centY) along unit direction (dx, dy).
    ///
    /// Linearisation: z = (A/I)^{1/4} − 1 = t²/α², where t is the signed step distance.
    /// Weighted regression through origin gives α directly.
    /// Returns the Moffat α parameter in pixels, or nil on failure.
    private static func fitMoffatAlpha(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                       centX: Float, centY: Float, peakVal: Float,
                                       background: Float, dx: Float, dy: Float) -> Float? {
        let halfW    = 10
        let minFrac: Float = 0.02
        var num: Float = 0, den: Float = 0

        for step in -halfW...halfW where step != 0 {
            let fstep = Float(step)
            let val = bilinear(pixels: pixels, width: width, height: height,
                               x: centX + fstep * dx, y: centY + fstep * dy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let z  = (peakVal / val).squareRoot().squareRoot() - 1
            let t2 = fstep * fstep
            num += val * z  * t2
            den += val * t2 * t2
        }

        guard den > 0, num > 0 else { return nil }
        return (den / num).squareRoot()
    }

    /// Bilinear interpolation into a float pixel array.
    private static func bilinear(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                 x: Float, y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let x1 = x0 + 1, y1 = y0 + 1
        guard x0 >= 0 && x1 < width && y0 >= 0 && y1 < height else { return 0 }
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = pixels[y0 * width + x0]
        let p10 = pixels[y0 * width + x1]
        let p01 = pixels[y1 * width + x0]
        let p11 = pixels[y1 * width + x1]
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }

    // MARK: - Crop-based shape measurement

    /// FWHM, eccentricity, SNR, and peakVal from a pre-extracted crop.
    /// Mirrors `measureShape` exactly but reads from the local crop array
    /// instead of a full-frame UnsafeBufferPointer.
    static func measureShapeFromCrop(crop: [Float], cropHalf: Int,
                                     background: Float,
                                     sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float, peakVal: Float) {
        let side = 2 * cropHalf + 1
        let cx = cropHalf, cy = cropHalf
        let peakIndex = cy * side + cx
        guard peakIndex < crop.count, crop[peakIndex] > background else { return (0, 0, 0, 0) }

        let centHalf = 2
        var sumI: Float = 0, sumXI: Float = 0, sumYI: Float = 0
        for dy in -centHalf...centHalf {
            for dx in -centHalf...centHalf {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < side && py >= 0 && py < side else { continue }
                let val = max(0, crop[py * side + px] - background)
                sumI  += val
                sumXI += Float(dx) * val
                sumYI += Float(dy) * val
            }
        }
        guard sumI > 0 else { return (0, 0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        let peakVal = bilinearCrop(crop: crop, cropSide: side, x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0, 0) }

        let rt2: Float = 1 / Float(2).squareRoot()
        guard let a0   = fitMoffatAlphaCrop(crop: crop, cropSide: side,
                                            centX: centX, centY: centY, peakVal: peakVal,
                                            background: background, dx: 1, dy: 0),
              let a90  = fitMoffatAlphaCrop(crop: crop, cropSide: side,
                                            centX: centX, centY: centY, peakVal: peakVal,
                                            background: background, dx: 0, dy: 1),
              let a45  = fitMoffatAlphaCrop(crop: crop, cropSide: side,
                                            centX: centX, centY: centY, peakVal: peakVal,
                                            background: background, dx: rt2, dy: rt2),
              let a135 = fitMoffatAlphaCrop(crop: crop, cropSide: side,
                                            centX: centX, centY: centY, peakVal: peakVal,
                                            background: background, dx: -rt2, dy: rt2)
        else { return (0, 0, 0, 0) }

        let inv0   = 1 / (a0   * a0)
        let inv90  = 1 / (a90  * a90)
        let inv45  = 1 / (a45  * a45)
        let inv135 = 1 / (a135 * a135)
        let S  = (inv0 + inv90 + inv45 + inv135) / 2
        let C  = inv0  - inv90
        let S2 = inv45 - inv135
        let D  = (C * C + S2 * S2).squareRoot()
        let invMajor2 = (S - D) / 2
        let invMinor2 = (S + D) / 2
        guard invMajor2 > 0, invMinor2 > 0 else { return (0, 0, 0, 0) }

        let fwhmFactor = 2 * (pow(Float(2), Float(0.25)) - 1).squareRoot()
        let fwhmMajor  = fwhmFactor / invMajor2.squareRoot()
        let fwhmMinor  = fwhmFactor / invMinor2.squareRoot()
        let fwhm       = (fwhmMajor * fwhmMinor).squareRoot()

        let axisRatio    = fwhmMinor / fwhmMajor
        let eccentricity = max(0, 1 - axisRatio * axisRatio).squareRoot()

        let snr: Float = peakVal / sigma
        return (fwhm, eccentricity, snr, peakVal)
    }

    /// Lightweight FWHM check from a pre-extracted crop.
    /// Mirrors `measureFWHMOnly` but reads from the local crop array.
    static func measureFWHMOnlyFromCrop(crop: [Float], cropHalf: Int,
                                        background: Float) -> Float {
        let side = 2 * cropHalf + 1
        let cx = cropHalf, cy = cropHalf
        let rowStart = cy * side
        guard rowStart + cx < crop.count else { return 0 }
        let peak = crop[rowStart + cx] - background
        guard peak > 0 else { return 0 }

        let minWing = peak * 0.05
        let l = cx > 0        ? crop[rowStart + cx - 1]        - background : -1
        let r = cx + 1 < side ? crop[rowStart + cx + 1]        - background : -1
        let u = cy > 0        ? crop[(cy - 1) * side + cx]     - background : -1
        let d = cy + 1 < side ? crop[(cy + 1) * side + cx]     - background : -1
        guard l > minWing, r > minWing, u > minWing, d > minWing else { return 0 }

        let halfW    = 10
        let minFrac: Float = 0.02
        var num: Float = 0, den: Float = 0

        for offset in -halfW...halfW where offset != 0 {
            let px = cx + offset
            guard px >= 0, px < side else { continue }
            let val = crop[rowStart + px] - background
            guard val > peak * minFrac, val < peak else { continue }
            let ratio = peak / val
            let z  = ratio.squareRoot().squareRoot() - 1
            let x2 = Float(offset * offset)
            num += val * z  * x2
            den += val * x2 * x2
        }

        guard den > 0, num > 0 else { return 0 }
        let alpha      = (den / num).squareRoot()
        let fwhmFactor = 2 * (pow(Float(2), Float(0.25)) - 1).squareRoot()
        return alpha * fwhmFactor
    }

    /// 1D Moffat β=4 fit from a pre-extracted crop along unit direction (dx, dy).
    /// Returns the Moffat α parameter in pixels, or nil on failure.
    private static func fitMoffatAlphaCrop(crop: [Float], cropSide: Int,
                                           centX: Float, centY: Float, peakVal: Float,
                                           background: Float, dx: Float, dy: Float) -> Float? {
        let halfW    = 10
        let minFrac: Float = 0.02
        var num: Float = 0, den: Float = 0

        for step in -halfW...halfW where step != 0 {
            let fstep = Float(step)
            let val = bilinearCrop(crop: crop, cropSide: cropSide,
                                   x: centX + fstep * dx, y: centY + fstep * dy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let z  = (peakVal / val).squareRoot().squareRoot() - 1
            let t2 = fstep * fstep
            num += val * z  * t2
            den += val * t2 * t2
        }

        guard den > 0, num > 0 else { return nil }
        return (den / num).squareRoot()
    }

    /// 2×2-bins a star crop extracted from a Bayer mosaic image.
    ///
    /// Each output pixel averages the 2×2 native block centred on the same star position,
    /// eliminating the alternating R/G/B/G channel pattern that otherwise distorts 1D Moffat fits.
    /// The returned crop has `binnedHalf = cropHalf / 2`; its centre is at (binnedHalf, binnedHalf).
    /// All FWHM values measured on the binned crop must be multiplied by 2 to recover native pixels.
    static func binCrop2x2(_ crop: [Float], cropHalf: Int) -> (crop: [Float], cropHalf: Int) {
        let side       = 2 * cropHalf + 1
        let binnedHalf = cropHalf / 2
        let binnedSide = 2 * binnedHalf + 1
        var binned     = [Float](repeating: 0, count: binnedSide * binnedSide)
        for by in 0..<binnedSide {
            for bx in 0..<binnedSide {
                // Native origin for this 2×2 block, aligned so output centre → input centre.
                let nx = cropHalf + (bx - binnedHalf) * 2
                let ny = cropHalf + (by - binnedHalf) * 2
                var sum: Float = 0; var n: Float = 0
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        let px = nx + dx, py = ny + dy
                        if px >= 0, px < side, py >= 0, py < side {
                            sum += crop[py * side + px]; n += 1
                        }
                    }
                }
                binned[by * binnedSide + bx] = n > 0 ? sum / n : 0
            }
        }
        return (binned, binnedHalf)
    }

    // MARK: - Moment-based eccentricity

    /// Intensity-weighted second-moment eccentricity from a pre-binned crop.
    /// More robust than 1D Moffat projections on Bayer-mosaic data because it
    /// uses all pixels and is orientation-invariant by construction.
    static func eccentricityFromMoments(crop: [Float], cropHalf: Int, background: Float) -> Float {
        let side = 2 * cropHalf + 1
        var sumW: Float = 0, sumX: Float = 0, sumY: Float = 0
        for y in 0..<side {
            for x in 0..<side {
                let v = max(0, crop[y * side + x] - background)
                sumW += v; sumX += v * Float(x); sumY += v * Float(y)
            }
        }
        guard sumW > 0 else { return 0 }
        let cx = sumX / sumW, cy = sumY / sumW
        var m20: Float = 0, m02: Float = 0, m11: Float = 0
        for y in 0..<side {
            for x in 0..<side {
                let v = max(0, crop[y * side + x] - background)
                let dx = Float(x) - cx, dy = Float(y) - cy
                m20 += v * dx * dx; m02 += v * dy * dy; m11 += v * dx * dy
            }
        }
        m20 /= sumW; m02 /= sumW; m11 /= sumW
        let trace = m20 + m02
        let disc  = max(0, trace * trace / 4 - (m20 * m02 - m11 * m11)).squareRoot()
        let lambdaMax = trace / 2 + disc
        let lambdaMin = trace / 2 - disc
        guard lambdaMax > 0, lambdaMin > 0 else { return 0 }
        return max(0, 1 - lambdaMin / lambdaMax).squareRoot()
    }

    /// Bilinear interpolation into a crop array.
    private static func bilinearCrop(crop: [Float], cropSide: Int, x: Float, y: Float) -> Float {
        let x0 = Int(x), y0 = Int(y)
        let x1 = x0 + 1, y1 = y0 + 1
        guard x0 >= 0 && x1 < cropSide && y0 >= 0 && y1 < cropSide else { return 0 }
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = crop[y0 * cropSide + x0]
        let p10 = crop[y0 * cropSide + x1]
        let p01 = crop[y1 * cropSide + x0]
        let p11 = crop[y1 * cropSide + x1]
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }
}
