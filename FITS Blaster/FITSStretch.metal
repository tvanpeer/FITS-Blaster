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
    uint  width;
    uint  height;
};

/// Single-pass compute kernel that performs:
///   1. Percentile-clipped normalization: [lowClip, highClip] → [0, 1]
///   2. Square root stretch: sqrt(t) — hardware-accelerated single instruction
///   3. Float → UInt8 conversion (0.0–1.0 → 0–255)
///   4. Vertical flip (FITS stores rows bottom-to-top)
kernel void sqrtStretch(
    device const float*   inputPixels  [[ buffer(0) ]],
    device       uchar*   outputPixels [[ buffer(1) ]],
    constant StretchParams& params     [[ buffer(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    uint srcIndex = gid.y * params.width + gid.x;
    float raw = inputPixels[srcIndex];

    // Normalize to [0, 1] with clipping
    float range = params.highClip - params.lowClip;
    float t = clamp((raw - params.lowClip) / range, 0.0f, 1.0f);

    // Gamma stretch: pow(x, 1/2.2) — equivalent to sqrt + display gamma
    float stretched = pow(t, 1.0f / 2.2f);

    // Convert to UInt8
    uchar value = uchar(stretched * 255.0f);

    // Write to vertically flipped position
    uint dstY = params.height - 1 - gid.y;
    uint dstIndex = dstY * params.width + gid.x;
    outputPixels[dstIndex] = value;
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
    uint  width;
    uint  height;
    /// R-pixel position in the 2×2 Bayer cell, encoded as two bits:
    ///   bit 0 = column parity of R  (0 = even, 1 = odd)
    ///   bit 1 = row parity of R     (0 = even, 1 = odd)
    /// RGGB=0  GRBG=1  GBRG=2  BGGR=3
    uint  rOffset;
};

/// Clamp-read: return the float pixel at (x, y), clamping to image borders.
static inline float bayerRead(device const float* pixels,
                               uint width, uint height, int x, int y) {
    uint cx = (uint)clamp(x, 0, (int)width  - 1);
    uint cy = (uint)clamp(y, 0, (int)height - 1);
    return pixels[cy * width + cx];
}

/// Stretch a single channel value to UInt8 with percentile clip + gamma 2.2.
static inline uchar bayerStretchByte(float raw, float lo, float hi) {
    float range = hi - lo;
    float t = clamp((raw - lo) / range, 0.0f, 1.0f);
    return uchar(pow(t, 1.0f / 2.2f) * 255.0f);
}

/// Single-pass kernel:
///   1. Bilinear Bayer demosaic using rOffset to identify each pixel's colour
///   2. Per-channel percentile-clip + gamma-2.2 stretch
///   3. Vertical flip (FITS rows are stored bottom-to-top)
///
/// Output: RGBA UInt8, 4 bytes/pixel (A = 255), packed row-major.
kernel void bayerDebayerAndStretch(
    device const float*           inputPixels  [[ buffer(0) ]],
    device       uchar4*          outputPixels [[ buffer(1) ]],
    constant BayerStretchParams&  params       [[ buffer(2) ]],
    uint2 gid [[ thread_position_in_grid ]]
) {
    uint x = gid.x;
    uint y = gid.y;
    if (x >= params.width || y >= params.height) return;

    uint W  = params.width;
    uint H  = params.height;
    uint ro = params.rOffset;

    // Determine colour of this pixel using rOffset bit encoding.
    // XOR pixel parity with R-pixel parity:
    //   (0,0) → R,  (1,1) → B,  else → G
    uint rx = ro & 1u;
    uint ry = (ro >> 1u) & 1u;
    uint cx = (x & 1u) ^ rx;
    uint cy = (y & 1u) ^ ry;

    float R, G, B;

    if (cx == 0u && cy == 0u) {
        // R pixel — interpolate G (cross) and B (diagonal)
        R = bayerRead(inputPixels, W, H, (int)x, (int)y);
        G = (bayerRead(inputPixels, W, H, (int)x-1, (int)y) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y) +
             bayerRead(inputPixels, W, H, (int)x, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x, (int)y+1)) * 0.25f;
        B = (bayerRead(inputPixels, W, H, (int)x-1, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x-1, (int)y+1) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y+1)) * 0.25f;
    } else if (cx == 1u && cy == 1u) {
        // B pixel — mirror of R case
        B = bayerRead(inputPixels, W, H, (int)x, (int)y);
        G = (bayerRead(inputPixels, W, H, (int)x-1, (int)y) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y) +
             bayerRead(inputPixels, W, H, (int)x, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x, (int)y+1)) * 0.25f;
        R = (bayerRead(inputPixels, W, H, (int)x-1, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y-1) +
             bayerRead(inputPixels, W, H, (int)x-1, (int)y+1) +
             bayerRead(inputPixels, W, H, (int)x+1, (int)y+1)) * 0.25f;
    } else {
        // G pixel. Whether R or B is horizontal depends on which row the G sits in.
        // If this row has the same parity as the R row (ry), R is horizontal.
        G = bayerRead(inputPixels, W, H, (int)x, (int)y);
        bool gInRRow = ((y & 1u) == ry);
        if (gInRRow) {
            // G in R-row: R neighbours are horizontal, B neighbours are vertical
            R = (bayerRead(inputPixels, W, H, (int)x-1, (int)y) +
                 bayerRead(inputPixels, W, H, (int)x+1, (int)y)) * 0.5f;
            B = (bayerRead(inputPixels, W, H, (int)x, (int)y-1) +
                 bayerRead(inputPixels, W, H, (int)x, (int)y+1)) * 0.5f;
        } else {
            // G in B-row: B neighbours are horizontal, R neighbours are vertical
            B = (bayerRead(inputPixels, W, H, (int)x-1, (int)y) +
                 bayerRead(inputPixels, W, H, (int)x+1, (int)y)) * 0.5f;
            R = (bayerRead(inputPixels, W, H, (int)x, (int)y-1) +
                 bayerRead(inputPixels, W, H, (int)x, (int)y+1)) * 0.5f;
        }
    }

    uchar r8 = bayerStretchByte(R, params.lowClipR, params.highClipR);
    uchar g8 = bayerStretchByte(G, params.lowClipG, params.highClipG);
    uchar b8 = bayerStretchByte(B, params.lowClipB, params.highClipB);

    // Vertical flip: FITS stores rows bottom-to-top
    uint dstY = H - 1u - y;
    outputPixels[dstY * W + x] = uchar4(r8, g8, b8, 255);
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
