//
//  MetricsCalculator+ShapeMeasurement.swift
//  FITS Blaster
//
//  Per-star PSF fitting: FWHM, eccentricity, SNR. One implementation for the whole frame
//  and for crops, through PixelGrid.
//

import Foundation
import Accelerate

extension MetricsCalculator {

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
        let minWing = peak * Shape.wingFraction
        let l = cx > 0          ? pixels[rowStart + cx - 1]      - background : -1
        let r = cx + 1 < width  ? pixels[rowStart + cx + 1]      - background : -1
        let u = cy > 0          ? pixels[(cy - 1) * width + cx]  - background : -1
        let d = cy + 1 < height ? pixels[(cy + 1) * width + cx]  - background : -1
        guard l > minWing, r > minWing, u > minWing, d > minWing else { return 0 }

        let halfW    = Shape.moffatHalfWidth
        let minFrac  = Shape.moffatMinimumFraction
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
        return alpha * Shape.moffatFWHMFactor
    }

    /// Compute FWHM, eccentricity, and aperture SNR for a single star in the whole frame.
    /// See `measureShape(in:cx:cy:background:sigma:)`.
    static func measureShape(pixels: UnsafeBufferPointer<Float>, width: Int, height: Int,
                             cx: Int, cy: Int, background: Float,
                             sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float, peakVal: Float) {
        measureShape(in: FramePixels(pixels: pixels, width: width, height: height),
                     cx: cx, cy: cy, background: background, sigma: sigma)
    }

    /// FWHM, eccentricity, SNR, and peakVal from a pre-extracted crop centred on the star.
    /// See `measureShape(in:cx:cy:background:sigma:)`.
    static func measureShapeFromCrop(crop: [Float], cropHalf: Int,
                                     background: Float,
                                     sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float, peakVal: Float) {
        measureShape(in: CropPixels(crop: crop, side: 2 * cropHalf + 1),
                     cx: cropHalf, cy: cropHalf, background: background, sigma: sigma)
    }

    /// Compute FWHM, eccentricity, and aperture SNR for the star at (cx, cy) in `grid`.
    /// One implementation for the whole frame and for crops (CODE_AUDIT §9.4).
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
    static func measureShape<Grid: PixelGrid>(in grid: Grid, cx: Int, cy: Int, background: Float,
                                              sigma: Float) -> (fwhm: Float, eccentricity: Float, snr: Float, peakVal: Float) {
        let width = grid.width, height = grid.height
        let peakIndex = cy * width + cx
        guard peakIndex >= 0 && peakIndex < grid.count else { return (0, 0, 0, 0) }
        guard grid[peakIndex] > background else { return (0, 0, 0, 0) }

        // Sub-pixel centroid via intensity-weighted (2·centroidHalfWidth+1)² window.
        let centHalf = Shape.centroidHalfWidth
        var sumI: Float = 0, sumXI: Float = 0, sumYI: Float = 0
        for dy in -centHalf...centHalf {
            for dx in -centHalf...centHalf {
                let px = cx + dx, py = cy + dy
                guard px >= 0 && px < width && py >= 0 && py < height else { continue }
                let val = max(0, grid[py * width + px] - background)
                sumI  += val
                sumXI += Float(dx) * val
                sumYI += Float(dy) * val
            }
        }
        guard sumI > 0 else { return (0, 0, 0, 0) }
        let centX = Float(cx) + sumXI / sumI
        let centY = Float(cy) + sumYI / sumI

        // True peak via bilinear interpolation at the sub-pixel centroid.
        let peakVal = bilinear(grid, x: centX, y: centY) - background
        guard peakVal > 0 else { return (0, 0, 0, 0) }

        // Fit Moffat α along four directions: 0°, 90°, 45°, 135°.
        let rt2: Float = 1 / Float(2).squareRoot()
        guard let a0   = fitMoffatAlpha(grid, centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: 1, dy: 0),
              let a90  = fitMoffatAlpha(grid, centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: 0, dy: 1),
              let a45  = fitMoffatAlpha(grid, centX: centX, centY: centY, peakVal: peakVal,
                                        background: background, dx: rt2, dy: rt2),
              let a135 = fitMoffatAlpha(grid, centX: centX, centY: centY, peakVal: peakVal,
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

        let fwhmFactor = Shape.moffatFWHMFactor
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
    private static func fitMoffatAlpha<Grid: PixelGrid>(_ grid: Grid, centX: Float, centY: Float,
                                                        peakVal: Float, background: Float,
                                                        dx: Float, dy: Float) -> Float? {
        let halfW    = Shape.moffatHalfWidth
        let minFrac  = Shape.moffatMinimumFraction
        var num: Float = 0, den: Float = 0

        for step in -halfW...halfW where step != 0 {
            let fstep = Float(step)
            let val = bilinear(grid, x: centX + fstep * dx, y: centY + fstep * dy) - background
            guard val > peakVal * minFrac, val < peakVal else { continue }
            let z  = (peakVal / val).squareRoot().squareRoot() - 1
            let t2 = fstep * fstep
            num += val * z  * t2
            den += val * t2 * t2
        }

        guard den > 0, num > 0 else { return nil }
        return (den / num).squareRoot()
    }

    /// Bilinear interpolation into `grid`; 0 when the 2×2 neighbourhood leaves the grid.
    private static func bilinear<Grid: PixelGrid>(_ grid: Grid, x: Float, y: Float) -> Float {
        let width = grid.width, height = grid.height
        let x0 = Int(x), y0 = Int(y)
        let x1 = x0 + 1, y1 = y0 + 1
        guard x0 >= 0 && x1 < width && y0 >= 0 && y1 < height else { return 0 }
        let fx = x - Float(x0), fy = y - Float(y0)
        let p00 = grid[y0 * width + x0]
        let p10 = grid[y0 * width + x1]
        let p01 = grid[y1 * width + x0]
        let p11 = grid[y1 * width + x1]
        return p00 * (1 - fx) * (1 - fy)
             + p10 * fx       * (1 - fy)
             + p01 * (1 - fx) * fy
             + p11 * fx       * fy
    }
}
