//
//  MetricsCalculator+Bayer.swift
//  FITS Blaster
//
//  Star crops for raw Bayer (OSC) frames and their bilinear demosaic to luminance, the
//  input of the crop-based shape measurement.
//

import Foundation

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
}
