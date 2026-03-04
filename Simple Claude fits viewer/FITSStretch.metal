//
//  FITSStretch.metal
//  Simple Claude fits viewer
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
