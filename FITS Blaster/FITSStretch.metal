//
//  FITSStretch.metal
//  FITS Blaster
//
//  Created by Tom van Peer on 28/02/2026.
//

#include <metal_stdlib>
using namespace metal;

/// Parameters passed from the CPU to the GPU kernel
struct StretchParams {
    float lowClip;      // 0.1% percentile value
    float highClip;     // 99.9% percentile value
    uint  srcWidth;     // full-resolution input dimensions
    uint  srcHeight;
    uint  dstWidth;     // output (display) dimensions — may be downscaled
    uint  dstHeight;
};

/// Single-pass compute kernel that performs:
///   1. Box-filter downsample from full-resolution input to display size
///   2. Vertical flip (FITS stores rows bottom-to-top)
///   3. Percentile-clipped normalization: [lowClip, highClip] → [0, 1]
///   4. Gamma 2.2 stretch + Float → UInt8
///
/// Each thread averages all source pixels whose centres fall within the output
/// pixel's footprint, giving alias-free downsampling equivalent to vImageScale
/// kvImageHighQualityResampling. At 1:1 (dstWidth == srcWidth) the footprint
/// shrinks to exactly one source pixel and the result is identical to a direct
/// point-sample kernel.
kernel void sqrtStretch(
    device const float*   inputPixels  [[ buffer(0) ]],
    device       uchar*   outputPixels [[ buffer(1) ]],
    constant StretchParams& params     [[ buffer(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    if (gid.x >= params.dstWidth || gid.y >= params.dstHeight) return;

    float scaleX = float(params.srcWidth)  / float(params.dstWidth);
    float scaleY = float(params.srcHeight) / float(params.dstHeight);

    // Source column range for this output pixel [sxStart, sxEnd] (inclusive).
    uint sxStart   = uint(float(gid.x)        * scaleX);
    uint sxEndExcl = uint(float(gid.x + 1u)   * scaleX);
    uint sxEnd     = min(sxEndExcl > sxStart ? sxEndExcl - 1u : sxStart,
                         params.srcWidth - 1u);

    // Source row range with FITS vertical flip.
    // gid.y = 0 → top of display → highest source rows (sky top = last FITS rows).
    uint flippedY  = params.dstHeight - 1u - gid.y;
    uint syStart   = uint(float(flippedY)      * scaleY);
    uint syEndExcl = uint(float(flippedY + 1u) * scaleY);
    uint syEnd     = min(syEndExcl > syStart ? syEndExcl - 1u : syStart,
                         params.srcHeight - 1u);

    float sum = 0.0f;
    uint  n   = 0u;
    for (uint sy = syStart; sy <= syEnd; sy++) {
        uint rowBase = sy * params.srcWidth;
        for (uint sx = sxStart; sx <= sxEnd; sx++) {
            sum += inputPixels[rowBase + sx];
            n++;
        }
    }
    float raw = sum / float(max(n, 1u));

    // Normalize to [0, 1] with clipping, then gamma stretch
    float range = params.highClip - params.lowClip;
    float t = clamp((raw - params.lowClip) / range, 0.0f, 1.0f);
    outputPixels[gid.y * params.dstWidth + gid.x] = uchar(pow(t, 1.0f / 2.2f) * 255.0f);
}

// MARK: - Bayer debayer + stretch

/// Parameters for the Bayer demosaicing + stretch kernel. Must match the Swift
/// BayerStretchParams struct exactly (field order, types, no padding).
struct BayerStretchParams {
    /// Per-channel percentile clip bounds — computed separately for R, G, B pixels
    /// so each channel is stretched independently (eliminates green cast).
    float lowClipR;
    float highClipR;
    float lowClipG;
    float highClipG;
    float lowClipB;
    float highClipB;
    uint  srcWidth;     // full-resolution input dimensions
    uint  srcHeight;
    uint  dstWidth;     // output (display) dimensions — may be downscaled
    uint  dstHeight;
    /// R-pixel position in the 2×2 Bayer cell, encoded as two bits:
    ///   bit 0 = column parity of R  (0 = even, 1 = odd)
    ///   bit 1 = row parity of R     (0 = even, 1 = odd)
    /// RGGB=0  GRBG=1  GBRG=2  BGGR=3
    uint  rOffset;
};

/// Stretch a single channel value to UInt8 with percentile clip + gamma 2.2.
static inline uchar bayerStretchByte(float raw, float lo, float hi) {
    float range = hi - lo;
    float t = clamp((raw - lo) / range, 0.0f, 1.0f);
    return uchar(pow(t, 1.0f / 2.2f) * 255.0f);
}

/// Single-pass kernel:
///   1. Box-filter downsample from full-resolution input to display size
///   2. Vertical flip (FITS rows are stored bottom-to-top)
///   3. Per-channel (R/G/B) box average across the source footprint
///   4. Per-channel percentile-clip + gamma-2.2 stretch
///
/// Averaging the R, G, B Bayer pixels separately within each output footprint
/// gives alias-free demosaicing without any cross-channel contamination.
/// No neighbourhood interpolation is needed — the box average is the demosaic.
///
/// Output: RGBA UInt8, 4 bytes/pixel (A = 255), packed row-major.
kernel void bayerDebayerAndStretch(
    device const float*           inputPixels  [[ buffer(0) ]],
    device       uchar4*          outputPixels [[ buffer(1) ]],
    constant BayerStretchParams&  params       [[ buffer(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    uint outX = gid.x;
    uint outY = gid.y;
    if (outX >= params.dstWidth || outY >= params.dstHeight) return;

    uint W  = params.srcWidth;
    uint H  = params.srcHeight;
    uint ro = params.rOffset;
    uint rx = ro & 1u;
    uint ry = (ro >> 1u) & 1u;

    float scaleX = float(W) / float(params.dstWidth);
    float scaleY = float(H) / float(params.dstHeight);

    // Source column range for this output pixel (inclusive, with FITS vertical flip)
    uint sxStart   = uint(float(outX)        * scaleX);
    uint sxEndExcl = uint(float(outX + 1u)   * scaleX);
    uint sxEnd     = min(sxEndExcl > sxStart ? sxEndExcl - 1u : sxStart, W - 1u);

    uint flippedY  = params.dstHeight - 1u - outY;
    uint syStart   = uint(float(flippedY)      * scaleY);
    uint syEndExcl = uint(float(flippedY + 1u) * scaleY);
    uint syEnd     = min(syEndExcl > syStart ? syEndExcl - 1u : syStart, H - 1u);

    // Accumulate R, G, B channels separately across the source footprint.
    float sumR = 0.0f, sumG = 0.0f, sumB = 0.0f;
    uint  nR   = 0u,   nG   = 0u,   nB   = 0u;
    for (uint sy = syStart; sy <= syEnd; sy++) {
        for (uint sx = sxStart; sx <= sxEnd; sx++) {
            float v  = inputPixels[sy * W + sx];
            uint  cx = (sx & 1u) ^ rx;
            uint  cy = (sy & 1u) ^ ry;
            if      (cx == 0u && cy == 0u) { sumR += v; nR++; }
            else if (cx == 1u && cy == 1u) { sumB += v; nB++; }
            else                           { sumG += v; nG++; }
        }
    }
    float R = (nR > 0u) ? sumR / float(nR) : 0.0f;
    float G = (nG > 0u) ? sumG / float(nG) : 0.0f;
    float B = (nB > 0u) ? sumB / float(nB) : 0.0f;

    uchar r8 = bayerStretchByte(R, params.lowClipR, params.highClipR);
    uchar g8 = bayerStretchByte(G, params.lowClipG, params.highClipG);
    uchar b8 = bayerStretchByte(B, params.lowClipB, params.highClipB);

    outputPixels[outY * params.dstWidth + outX] = uchar4(r8, g8, b8, 255);
}

// MARK: - Local-maximum detection

/// CPU-side parameters for the detection kernel. Must match the Swift
/// DetectParams struct exactly (same field order, same types).
struct DetectParams {
    uint  width;      // image width in pixels
    uint  height;     // image height in pixels
    float threshold;  // background + 5σ — pixels below this level are sky
};

/// Output record written by the detection kernel for each candidate.
/// Must match the Swift DetectCandidate struct exactly.
struct DetectCandidate {
    uint x;     // pixel column
    uint y;     // pixel row
};

/// Maximum number of candidates the output buffer can hold.
/// 50 000 × 8 bytes = 400 KB — large enough for very dense star fields.
/// The atomic counter still records the true total even when this cap is hit,
/// so the reported star count remains accurate; only the measurement sample
/// (top 50 unsaturated stars) could be affected in extreme Milky Way fields.
#define MAX_DETECTION_CANDIDATES 50000

/// Detect strict 8-neighbour local maxima above a noise threshold.
///
/// Each GPU thread handles exactly one pixel of the full-resolution image,
/// so the entire frame is tested in a single dispatch — no row-by-row loop.
///
/// **Output format:** compact candidate list, not a flag-per-pixel buffer.
/// Qualifying pixels atomically claim a slot in `candidates[]` and write
/// their (x, y) coordinates there. The CPU then reads exactly `count`
/// candidates — typically a few hundred — rather than scanning the entire
/// image frame. This eliminates the O(width × height) CPU scan that would
/// otherwise take 20–50 ms for 16–50 MP images.
///
/// Thread safety: `atomic_fetch_add_explicit` on the counter is the only
/// shared-state write; candidate slots are disjoint so no further
/// synchronisation is needed.
kernel void detectLocalMaxima(
    device const float*       pixels     [[ buffer(0) ]],  // raw FITS float pixels
    device DetectCandidate*   candidates [[ buffer(1) ]],  // compact output list
    device atomic_uint*       count      [[ buffer(2) ]],  // running candidate count
    constant DetectParams&    p          [[ buffer(3) ]],  // width, height, threshold
    uint2 gid [[ thread_position_in_grid ]]
) {
    uint x = gid.x;
    uint y = gid.y;

    // Border pixels: the 8-neighbourhood would extend outside the image.
    if (x == 0 || x >= p.width - 1 || y == 0 || y >= p.height - 1) return;

    uint  idx = y * p.width + x;
    float val = pixels[idx];

    // Fast exit: below threshold → not a star candidate.
    if (val < p.threshold) return;

    // Strict 8-neighbour local-maximum test expressed as a single predicate so
    // the compiler can emit branchless, fully-vectorised instructions.
    bool isMax =
        val > pixels[idx - p.width - 1] &&   // top-left
        val > pixels[idx - p.width    ] &&   // top-centre
        val > pixels[idx - p.width + 1] &&   // top-right
        val > pixels[idx           - 1] &&   // left
        val > pixels[idx           + 1] &&   // right
        val > pixels[idx + p.width - 1] &&   // bottom-left
        val > pixels[idx + p.width    ] &&   // bottom-centre
        val > pixels[idx + p.width + 1];     // bottom-right

    if (!isMax) return;

    // Atomically reserve a slot in the output list.
    // memory_order_relaxed is sufficient: we only need atomicity of the counter
    // itself, not ordering relative to the candidate writes.
    uint slot = atomic_fetch_add_explicit(count, 1u, memory_order_relaxed);
    if (slot < MAX_DETECTION_CANDIDATES) {
        candidates[slot] = DetectCandidate{x, y};
    }
}
