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

    // MARK: - Bayer demosaicking

    /// Bilinearly demosaics a raw Bayer star crop to a single-channel luminance image.
    ///
    /// `originX`/`originY` are the absolute image coordinates of the crop's top-left corner,
    /// needed to determine the Bayer colour at each pixel position.
    ///
    /// `weights` controls how the R, G, B channels are combined:
    /// - `.rec709` gives the ITU-R BT.709 fixed blend that matches PixInsight's effective
    ///   OIII-channel weighting on dual-narrowband images; use this for FWHM measurement.
    /// - `.adaptive` (default) estimates weights from the outer-border sky brightness,
    ///   correctly normalising Ha vs OIII; use this for eccentricity measurement.
    static func debayerCropToLuminance(crop: [Float], cropHalf: Int,
                                        originX: Int, originY: Int,
                                        pattern: BayerPattern,
                                        weights: BayerLuminanceWeights = .adaptive) -> [Float] {
        let side = 2 * cropHalf + 1
        let rCol = Int(pattern.rOffset) & 1
        let rRow = (Int(pattern.rOffset) >> 1) & 1

        @inline(__always) func hAvg(_ x: Int, _ y: Int) -> Float {
            var s: Float = 0; var n: Float = 0
            if x > 0        { s += crop[y * side + x - 1]; n += 1 }
            if x < side - 1 { s += crop[y * side + x + 1]; n += 1 }
            return n > 0 ? s / n : 0
        }
        @inline(__always) func vAvg(_ x: Int, _ y: Int) -> Float {
            var s: Float = 0; var n: Float = 0
            if y > 0        { s += crop[(y - 1) * side + x]; n += 1 }
            if y < side - 1 { s += crop[(y + 1) * side + x]; n += 1 }
            return n > 0 ? s / n : 0
        }
        @inline(__always) func crossAvg(_ x: Int, _ y: Int) -> Float {
            var s: Float = 0; var n: Float = 0
            if x > 0        { s += crop[y * side + x - 1]; n += 1 }
            if x < side - 1 { s += crop[y * side + x + 1]; n += 1 }
            if y > 0        { s += crop[(y - 1) * side + x]; n += 1 }
            if y < side - 1 { s += crop[(y + 1) * side + x]; n += 1 }
            return n > 0 ? s / n : 0
        }
        @inline(__always) func diagAvg(_ x: Int, _ y: Int) -> Float {
            var s: Float = 0; var n: Float = 0
            if x > 0        && y > 0        { s += crop[(y-1)*side+(x-1)]; n += 1 }
            if x < side - 1 && y > 0        { s += crop[(y-1)*side+(x+1)]; n += 1 }
            if x > 0        && y < side - 1 { s += crop[(y+1)*side+(x-1)]; n += 1 }
            if x < side - 1 && y < side - 1 { s += crop[(y+1)*side+(x+1)]; n += 1 }
            return n > 0 ? s / n : 0
        }

        let wR: Float
        let wG: Float
        let wB: Float
        switch weights {
        case .rec709:
            wR = 0.2126; wG = 0.7152; wB = 0.0722
        case .adaptive:
            // Estimate per-channel sky brightness from the outer border of the crop
            // (purely background — no star flux at 8+ px from a sub-5-px FWHM star).
            // Using these as luminance weights normalises Ha vs OIII contributions in
            // narrowband images; broadband images get roughly equal weights.
            var skyR: Float = 0, skyG: Float = 0, skyB: Float = 0
            var nSR:  Float = 0, nSG:  Float = 0, nSB:  Float = 0
            let skyBorder = 4
            for by in 0..<side {
                for bx in 0..<side {
                    guard bx < skyBorder || bx >= side - skyBorder ||
                          by < skyBorder || by >= side - skyBorder else { continue }
                    let col = (originX + bx) & 1
                    let row = (originY + by) & 1
                    let v = max(0, crop[by * side + bx])
                    if      col == rCol && row == rRow { skyR += v; nSR += 1 }
                    else if col != rCol && row != rRow { skyB += v; nSB += 1 }
                    else                               { skyG += v; nSG += 1 }
                }
            }
            let meanR = nSR > 0 ? skyR / nSR : 1
            let meanG = nSG > 0 ? skyG / nSG : 1
            let meanB = nSB > 0 ? skyB / nSB : 1
            let totalSky = meanR + meanG + meanB
            wR = totalSky > 0 ? meanR / totalSky : Float(1)/3
            wG = totalSky > 0 ? meanG / totalSky : Float(1)/3
            wB = totalSky > 0 ? meanB / totalSky : Float(1)/3
        }

        var lum = [Float](repeating: 0, count: side * side)
        for y in 0..<side {
            for x in 0..<side {
                let col = (originX + x) & 1
                let row = (originY + y) & 1
                let isR = col == rCol && row == rRow
                let isB = col != rCol && row != rRow

                let r, g, b: Float
                if isR {
                    r = crop[y * side + x]
                    g = crossAvg(x, y)
                    b = diagAvg(x, y)
                } else if isB {
                    b = crop[y * side + x]
                    g = crossAvg(x, y)
                    r = diagAvg(x, y)
                } else if row == rRow {
                    // Gr pixel: R neighbours are horizontal, B neighbours are vertical
                    g = crop[y * side + x]
                    r = hAvg(x, y)
                    b = vAvg(x, y)
                } else {
                    // Gb pixel: R neighbours are vertical, B neighbours are horizontal
                    g = crop[y * side + x]
                    r = vAvg(x, y)
                    b = hAvg(x, y)
                }

                lum[y * side + x] = wR * r + wG * g + wB * b
            }
        }
        return lum
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
