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
        var width:     UInt32   // image width in pixels
        var height:    UInt32   // image height in pixels
        var threshold: Float    // background + 5σ detection threshold
        var capacity:  UInt32   // candidates the output list can hold
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
        /// Top N candidates used for full shape measurement (FWHM, ecc, SNR).
        static let topCandidatesForShape   = 200
        /// Additional candidates checked in the fast star-count pass (Phase 2).
        static let fallbackCandidateCount  = 6_000
        /// A star candidate is a local maximum this many sky sigmas above the background.
        static let detectionSigmas: Float  = 5
        /// The CPU detection scans at most this centre crop (pixels per side), which keeps
        /// it fast when Metal is unavailable; the GPU scans the whole frame.
        static let cpuDetectionCropSide    = 4096
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
