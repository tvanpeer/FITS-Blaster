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
    /// **FWHM:** 1D Moffat β=4 fits along X and Y axes (PixInsight default model).
    /// Geometric mean of the two axes gives a single representative value.
    ///
    /// **Eccentricity:** 2D intensity-weighted image moments over a ±10px window,
    /// giving eigenvalues λ₁ ≥ λ₂ of the moment matrix. e = √(1 − λ₂/λ₁).
    /// Orientation-invariant: correctly detects elongation at any angle, unlike
    /// the previous approach of comparing two axis-aligned 1D fits.
    ///
    /// **SNR:** Peak signal above background in units of sky sigma.
    /// Scale-invariant: works equally for raw ADU, calibrated e⁻/s, and 0–1 float data.
    static func measureShape(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                             cx: Int, cy: Int, background: Float,
                             sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float) {
        let peakIndex = cy * width + cx
        guard peakIndex >= 0 && peakIndex < pixels.count else { return (0, 0, 0) }
        guard pixels[peakIndex] > background else { return (0, 0, 0) }

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
        guard sumI > 0 else { return (0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        // True peak via bilinear interpolation at the sub-pixel centroid.
        let peakVal = bilinear(pixels: pixels, width: width, height: height,
                               x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0) }

        // 1D Moffat β=4 fits for FWHM along X and Y.
        guard let fwhmX = fitMoffat1D(pixels: pixels, width: width, height: height,
                                       centX: centX, centY: centY, peakVal: peakVal,
                                       background: background, horizontal: true),
              let fwhmY = fitMoffat1D(pixels: pixels, width: width, height: height,
                                       centX: centX, centY: centY, peakVal: peakVal,
                                       background: background, horizontal: false)
        else { return (0, 0, 0) }

        // Geometric-mean FWHM — matches PixInsight's single-value summary.
        let fwhm = sqrt(fwhmX * fwhmY)

        // --- Eccentricity via 2D intensity-weighted central moments ---
        //
        // We accumulate three second-order moments over the same ±10px window
        // used by the Moffat fits, measuring offsets from the sub-pixel centroid
        // so the result is independent of where the star lands on the pixel grid:
        //
        //   M_20 = Σ(dx²·I) / ΣI   — spread along X
        //   M_02 = Σ(dy²·I) / ΣI   — spread along Y
        //   M_11 = Σ(dx·dy·I) / ΣI — tilt / cross-axis correlation
        //
        // These form a 2×2 symmetric covariance matrix  [[M_20, M_11],
        //                                                [M_11, M_02]]
        // whose eigenvalues λ₁ ≥ λ₂ give the squared semi-axes of the best-fit
        // intensity ellipse. The closed-form eigenvalues are:
        //
        //   λ₁,₂ = (M_20 + M_02)/2  ±  √[ ((M_20−M_02)/2)² + M_11² ]
        //
        // Eccentricity follows the standard conic definition:
        //   e = √(1 − λ_min / λ_max)
        //
        // A perfectly round star → M_11=0 and M_20=M_02 → λ₁=λ₂ → e=0.
        // A star trailed at 45° → large M_11 → λ₁≫λ₂ → e→1.
        let halfW = 10
        var sumI2: Float = 0, sumXXI: Float = 0, sumYYI: Float = 0, sumXYI: Float = 0
        for dy in -halfW...halfW {
            for dx in -halfW...halfW {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let val = max(0, pixels[py * width + px] - background)
                let fdx = Float(px) - centX
                let fdy = Float(py) - centY
                sumI2  += val
                sumXXI += fdx * fdx * val     // M_20 numerator
                sumYYI += fdy * fdy * val     // M_02 numerator
                sumXYI += fdx * fdy * val     // M_11 numerator
            }
        }
        let eccentricity: Float
        if sumI2 > 0 {
            let m20  = sumXXI / sumI2
            let m02  = sumYYI / sumI2
            let m11  = sumXYI / sumI2
            let half = (m20 + m02) * 0.5
            let disc = (((m20 - m02) * 0.5) * ((m20 - m02) * 0.5) + m11 * m11).squareRoot()
            let lambdaMax = half + disc
            let lambdaMin = half - disc
            eccentricity = lambdaMax > 0 ? sqrt(max(0, 1 - lambdaMin / lambdaMax)) : 0
        } else {
            eccentricity = 0
        }

        // Peak SNR: peakVal / σ_sky — scale-invariant (works for ADU, e⁻/s, and 0–1 float).
        let snr: Float = peakVal / sigma

        return (fwhm, eccentricity, snr)
    }

    /// Fit a 1D Moffat (β=4) profile through (centX, centY) along x or y.
    ///
    /// Linearisation: let z = (A/I)^{1/4} − 1, then z = x²/α².
    /// Weighted regression through origin (w = I−B) gives α directly.
    /// Returns FWHM = 2α·√(2^{1/4}−1) in pixels, or nil on failure.
    private static func fitMoffat1D(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                                    centX: Float, centY: Float, peakVal: Float,
                                    background: Float, horizontal: Bool) -> Float? {
        let halfW    = 10
        let minFrac: Float = 0.02   // ignore pixels below 2 % of peak (noise dominated)
        var num: Float = 0, den: Float = 0

        for offset in -halfW...halfW where offset != 0 {
            let fx  = horizontal ? centX + Float(offset) : centX
            let fy  = horizontal ? centY                 : centY + Float(offset)
            let val = bilinear(pixels: pixels, width: width, height: height, x: fx, y: fy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let ratio = peakVal / val
            let z  = ratio.squareRoot().squareRoot() - 1  // equivalent to pow(ratio, 0.25), ~5× faster
            let x2 = Float(offset * offset)
            let w  = val                                    // intensity weight
            num += w * z  * x2   // Σ w·z·x²
            den += w * x2 * x2   // Σ w·x⁴
        }

        guard den > 0, num > 0 else { return nil }
        let alpha = sqrt(den / num)
        // FWHM = 2α·√(2^{1/β}−1), β=4 → factor ≈ 0.870
        let fwhmFactor = 2 * sqrt(pow(Float(2), Float(0.25)) - 1)
        return alpha * fwhmFactor
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

    /// FWHM, eccentricity, and SNR from a pre-extracted crop.
    /// Mirrors `measureShape` exactly but reads from the local crop array
    /// instead of a full-frame UnsafeBufferPointer.
    static func measureShapeFromCrop(crop: [Float], cropHalf: Int,
                                     background: Float,
                                     sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float) {
        let side = 2 * cropHalf + 1
        let cx = cropHalf, cy = cropHalf
        let peakIndex = cy * side + cx
        guard peakIndex < crop.count, crop[peakIndex] > background else { return (0, 0, 0) }

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
        guard sumI > 0 else { return (0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        let peakVal = bilinearCrop(crop: crop, cropSide: side, x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0) }

        guard let fwhmX = fitMoffat1DCrop(crop: crop, cropSide: side,
                                          centX: centX, centY: centY, peakVal: peakVal,
                                          background: background, horizontal: true),
              let fwhmY = fitMoffat1DCrop(crop: crop, cropSide: side,
                                          centX: centX, centY: centY, peakVal: peakVal,
                                          background: background, horizontal: false)
        else { return (0, 0, 0) }

        let fwhm = sqrt(fwhmX * fwhmY)

        let halfW = 10
        var sumI2: Float = 0, sumXXI: Float = 0, sumYYI: Float = 0, sumXYI: Float = 0
        for dy in -halfW...halfW {
            for dx in -halfW...halfW {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < side && py >= 0 && py < side else { continue }
                let val = max(0, crop[py * side + px] - background)
                let fdx = Float(px) - centX
                let fdy = Float(py) - centY
                sumI2  += val
                sumXXI += fdx * fdx * val
                sumYYI += fdy * fdy * val
                sumXYI += fdx * fdy * val
            }
        }
        let eccentricity: Float
        if sumI2 > 0 {
            let m20  = sumXXI / sumI2
            let m02  = sumYYI / sumI2
            let m11  = sumXYI / sumI2
            let half = (m20 + m02) * 0.5
            let disc = (((m20 - m02) * 0.5) * ((m20 - m02) * 0.5) + m11 * m11).squareRoot()
            let lambdaMax = half + disc
            let lambdaMin = half - disc
            eccentricity = lambdaMax > 0 ? sqrt(max(0, 1 - lambdaMin / lambdaMax)) : 0
        } else {
            eccentricity = 0
        }

        let snr: Float = peakVal / sigma
        return (fwhm, eccentricity, snr)
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

    /// 1D Moffat β=4 fit from a pre-extracted crop.
    private static func fitMoffat1DCrop(crop: [Float], cropSide: Int,
                                        centX: Float, centY: Float, peakVal: Float,
                                        background: Float, horizontal: Bool) -> Float? {
        let halfW    = 10
        let minFrac: Float = 0.02
        var num: Float = 0, den: Float = 0

        for offset in -halfW...halfW where offset != 0 {
            let fx  = horizontal ? centX + Float(offset) : centX
            let fy  = horizontal ? centY                 : centY + Float(offset)
            let val = bilinearCrop(crop: crop, cropSide: cropSide, x: fx, y: fy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let ratio = peakVal / val
            let z  = ratio.squareRoot().squareRoot() - 1
            let x2 = Float(offset * offset)
            let w  = val
            num += w * z  * x2
            den += w * x2 * x2
        }

        guard den > 0, num > 0 else { return nil }
        let alpha = sqrt(den / num)
        let fwhmFactor = 2 * sqrt(pow(Float(2), Float(0.25)) - 1)
        return alpha * fwhmFactor
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
