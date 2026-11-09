//
//  MetricsCalculator+Types.swift
//  FITS Blaster
//
//  Types shared by the MetricsCalculator files: the Metal detection structs, the tuning
//  constants and the star candidate.
//

import Foundation

extension MetricsCalculator {

    // MARK: - Metal state (detection kernel)

    /// CPU-side mirror of the Metal DetectParams struct in FITSStretch.metal.
    /// Field order and types must match exactly so setBytes() copies the right bytes.
    struct DetectParams {
        var width:      UInt32         // image width in pixels
        var height:     UInt32         // image height in pixels
        var capacity:   UInt32         // candidates the output list can hold
        var saturation: Float          // raw level of saturated pixels (∞: none); also keeps the
                                       // float4 fields 16-byte aligned, as in Metal
        var offsets:    SIMD4<Float>   // per 2×2 cell position: subtracted from each pixel
        var thresholds: SIMD4<Float>   // per position: pixel − offset must reach this
    }

    /// CPU-side mirror of the Metal DetectCandidate struct.
    /// Two UInt32 values → 8 bytes, naturally aligned, no padding.
    struct DetectCandidate {
        var x: UInt32
        var y: UInt32
    }

    // MARK: - Tuning constants

    /// Controls star detection and measurement limits.
    enum Constants {
        /// Room for this many candidates in the first detection pass; a frame with more gets a
        /// second pass with room for all of them.
        static let maxDetectionCandidates  = 50_000
        /// Number of stratified samples for background estimation.
        static let backgroundSampleCount   = 5_000
        /// The first N stars (brightest first) are fitted; SNR and PSF·S use all of them (step 13e).
        static let topCandidatesForShape   = 200
        /// Star count: a candidate's peak must stand this many local-noise units above the
        /// local sky (`localContrast`). 12 matched PixInsight's real stars best (step 13c).
        static let countContrast: Float     = 12
        /// FWHM and eccentricity use only the fitted stars at least this bright (local
        /// contrast): on fainter stars noise widens and elongates the fit (step 13f).
        static let shapeContrast: Float     = 40
        /// With fewer such stars, FWHM and eccentricity use this many fitted stars with the
        /// highest contrast instead (step 13f).
        static let shapeMinimumStars        = 20
        /// A frame with fewer stars than this has no stars for the metrics: FWHM,
        /// eccentricity, SNR and PSF·S stay empty and the score is 0, so every check can
        /// reject it (step 13g, CODE_AUDIT §5.4). Flats count 0–2 spurious "stars"; real
        /// frames in the test sets have 80 or more.
        static let minimumStars             = 10
        /// Eccentricity above which a frame counts as elongated: the red "trailing" badge
        /// and Auto-Flag's default limit. Normal frames measure about 0.5 on colour and 0.4
        /// on mono; elongated ones 0.65 and up, trails 0.9 and up (step 13h).
        static let trailingEccentricity     = 0.65
        /// FWHM above this many times the filter group's median counts as out of focus:
        /// the orange "focus fail" badge and Auto-Flag's default relative FWHM limit (step 15d).
        static let focusFailFWHMMultiplier  = 1.5
        /// Inner and outer radius (pixels) of the ring that gives the local sky and noise.
        static let contrastRingInner       = 6
        static let contrastRingOuter       = 10
        /// A star candidate is a local maximum this many sky sigmas above the background.
        static let detectionSigmas: Float  = 5
        /// The CPU detection scans at most this centre crop (pixels per side), which keeps
        /// it fast when Metal is unavailable; the GPU scans the whole frame.
        static let cpuDetectionCropSide    = 4096
        /// Colour frames: a candidate with a pixel at this fraction of the frame's highest
        /// value or more is saturated, counted as a star but not measured (step 13a).
        static let saturationFraction: Float = 0.98
        /// A frame counts as saturated only when at least this many pixels share exactly its
        /// highest value (clipping gives identical values; one bright star doesn't). Step 13d.
        static let saturatedPixelsAtMaximum = 3
    }

    /// Tunables of the per-star shape measurement (CODE_AUDIT §9.4).
    enum Shape {
        /// A measured FWHM outside this range (pixels) is not a usable star: too small is a
        /// hot pixel or noise, too large a galaxy, nebula knot or blend.
        static let acceptedFWHM: ClosedRange<Float> = 0.5...20
        /// Half-width of the centroid window (2·2+1 = 5×5 pixels).
        static let centroidHalfWidth = 2
        /// Steps on each side of the centre along which the Moffat profile is fitted.
        static let moffatHalfWidth = 10
        /// Profile samples below this fraction of the peak are left out of the fit.
        static let moffatMinimumFraction: Float = 0.02
        /// FWHM = α · 2·√(2^{1/β} − 1) for a Moffat profile with β = 4 (≈ 0.870).
        static let moffatFWHMFactor: Float = 2 * (pow(Float(2), Float(0.25)) - 1).squareRoot()
        /// Star-count pre-filter: each of the 4 neighbours must carry at least this
        /// fraction of the background-subtracted peak (see `measureFWHMOnly`).
        static let wingFraction: Float = 0.05
    }

    // MARK: - Internal types shared with extension files

    /// Intermediate star candidate used internally during detection and NMS.
    struct StarCandidate {
        let x: Int
        let y: Int
        let peak: Float

        /// Sort order for candidates: brightest peak first; equal peaks by row, then column.
        ///
        /// The tie-break makes the order deterministic. 16-bit data has many equal peaks
        /// (saturated stars above all), and the GPU returns candidates in a random order,
        /// so sorting on the peak alone let that order decide which stars were kept and
        /// measured — and the metrics varied between runs on the same file.
        static func brighterFirst(_ a: StarCandidate, _ b: StarCandidate) -> Bool {
            if a.peak != b.peak { return a.peak > b.peak }
            if a.y != b.y { return a.y < b.y }
            return a.x < b.x
        }
    }

    /// Return type for GPU detection.
    struct GPUDetectionResult {
        /// Candidates stored in the output buffer, sorted by peak brightness.
        let candidates: [StarCandidate]
    }
}
