//
//  StarFluxSNRTests.swift
//  FITS Blaster Tests
//
//  Master-plan step 13b: SNR is the total flux of the fitted star in units of sky σ, so it
//  measures signal strength and not the seeing (the old peak ÷ σ fell as 1/FWHM²), and it
//  enters the score on a log scale from 100 (0) to 20,000 (full marks).
//

import Foundation
import Testing
@testable import FITS_Blaster

struct StarFluxSNRTests {

    private static let side = 256

    /// A mono frame: sky 1000 with deterministic uniform noise (±20), plus 20 round Moffat
    /// β = 4 stars of the given FWHM, each with the same total flux.
    private static func frame(fwhm: Float, flux: Float) -> [Float] {
        let n = side
        var pixels = [Float](repeating: 0, count: n * n)
        var seed: UInt32 = 77
        for i in 0..<(n * n) {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            pixels[i] = 1000 + (Float(seed >> 8) / Float(1 << 24) - 0.5) * 40
        }
        let alpha = fwhm / MetricsCalculator.Shape.moffatFWHMFactor
        let peak = flux * 3 / (Float.pi * alpha * alpha)   // Moffat β = 4: flux = peak · π · α² / 3
        for s in 0..<20 {
            let cx = 24 + (s % 5) * 50, cy = 24 + (s / 5) * 60
            for dy in -16...16 {
                for dx in -16...16 {
                    let r2 = Float(dx * dx + dy * dy) / (alpha * alpha)
                    pixels[(cy + dy) * n + (cx + dx)] += peak * pow(1 + r2, -4)
                }
            }
        }
        return pixels
    }

    @Test("Stars of equal flux give about the same SNR whatever their FWHM")
    func independentOfSeeing() async throws {
        let n = Self.side
        let sharp = try #require(await MetricsCalculator.compute(pixels: Self.frame(fwhm: 2.5, flux: 60_000),
                                                                width: n, height: n, config: MetricsConfig()))
        let soft = try #require(await MetricsCalculator.compute(pixels: Self.frame(fwhm: 4.5, flux: 60_000),
                                                               width: n, height: n, config: MetricsConfig()))
        let sharpSNR = try #require(sharp.snr), softSNR = try #require(soft.snr)
        let sharpFWHM = try #require(sharp.fwhm), softFWHM = try #require(soft.fwhm)
        #expect(softFWHM > sharpFWHM * 1.5)
        // The peaks differ by (4.5 / 2.5)² ≈ 3.2; the flux SNR stays within 15 %.
        #expect(abs(softSNR / sharpSNR - 1) < 0.15)
    }

    @Test("Twice the star flux gives about twice the SNR")
    func proportionalToFlux() async throws {
        let n = Self.side
        let faint = try #require(await MetricsCalculator.compute(pixels: Self.frame(fwhm: 3, flux: 30_000),
                                                                width: n, height: n, config: MetricsConfig()))
        let bright = try #require(await MetricsCalculator.compute(pixels: Self.frame(fwhm: 3, flux: 60_000),
                                                                 width: n, height: n, config: MetricsConfig()))
        let ratio = try #require(bright.snr) / (try #require(faint.snr))
        #expect(ratio > 1.8 && ratio < 2.2)
    }

    @Test("The SNR sub-score is log-scaled from 100 (0) to 20,000 (full marks)")
    func scoreScale() {
        func score(_ snr: Float) -> Int {
            MetricsCalculator.qualityScore(fwhm: nil, eccentricity: nil, snr: snr, starCount: nil)
        }
        #expect(score(0) == 0)
        #expect(score(50) == 0)
        #expect(score(100) == 0)
        #expect(score(20_000) == 100)
        #expect(score(80_000) == 100)
        // log₁₀(20) / log₁₀(200) ≈ 0.565
        #expect(score(2_000) == 56)
        #expect(score(1_000) < score(2_000) && score(2_000) < score(10_000))
    }
}
