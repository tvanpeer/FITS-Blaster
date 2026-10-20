# Metal review

2026-10-18, branch `colour-fix` (head `f8f6158`). Review only, no code changes. It covers the shader file `FITS Blaster/FITSStretch.metal` (3 compute kernels) and the Swift code that drives it (`ImageStretcher.swift`, `MetricsCalculator+StarDetection.swift`, `MetricsCalculator.swift`, `FITSReader.swift`), plus the CPU paths that should match it. It adds to [CODE_AUDIT.md](CODE_AUDIT.md), which left the kernels themselves out of scope (§11). Findings already there are referenced, not repeated. Fixes belong to [master-plan](architecture-plan.md) step 8 unless a finding says otherwise.

Two skills were looked at for this and not used: `metal-shader-expert` (graphics-oriented, with no review procedure; its main tip, `half` precision by default, would break our float data) and `piemonte/skills` `metal-graphics` (a snippet cookbook, mostly rendering).

## 1. Validation run

Debug build (Xcode 27.0, macOS 27.0.1, MacBook Air M1), with **Metal API validation** (`MTL_DEBUG_LAYER=1`) and **shader validation** (`MTL_SHADER_VALIDATION=1`, reports to stderr). Shader validation catches out-of-bounds reads and writes, and invalid resource use, inside the kernels.

| Run | What it exercised | Result |
| --- | --- | --- |
| All unit tests (223 tests, 21 suites), incl. `GPUTests` and `RenderingTests` on the sample set | all three kernels on synthetic and sample data | all passed; no validation reports |
| CLI, grey pipeline, 5 folders, 1,068 frames: M81 (355, colour camera), Rosette large mixed (464, mono, 8 × 3), M31 (39), California (87), Gamma Cygni (34) | `sqrtStretch` (incl. the 2×2 Bayer bin for colour cameras), `detectLocalMaxima` on every frame | exit 0; no validation reports |
| CLI with `--render --render-typical`, the 3 colour folders (476 frames) | `bayerDebayerAndStretch` on every frame | exit 0; no validation reports |

The log confirms validation was active in each process ("Metal API Validation Enabled", "Metal GPU Validation Enabled"). The large-folder render tests (`FB_TEST_DATA_FULL=1`) were not part of the unit-test run, but the CLI runs covered the same folders.

**Not covered:** other GPU generations (only M1 was used), Intel Macs, GPU timing (Metal System Trace), and malformed files (those are plan step 1).

## 2. Findings

### M1 The CPU stretch is a different algorithm from the GPU kernel
- **Location:** GPU `FITSStretch.metal:40-93` (`sqrtStretch`), `:128-213` (`bayerDebayerAndStretch`); CPU `ImageStretcher.swift:602-680` (`makeMTFLUT`, `cpuStretch`).
- **What:** For the same clips the two paths give different pixels, in four ways:
  - **Rounding.** The GPU truncates (`uchar(stretched * 255)`); the CPU rounds (`vImageConvert_PlanarFtoPlanar8`). Tested: 0.6/255 → 0 vs 1, 254.6/255 → 254 vs 255. On average the GPU is half a level darker.
  - **Order of downscale and stretch.** The GPU box-averages the raw pixels, then stretches. The CPU stretches every full-size pixel, then downscales the 8-bit result with `vImageScale` high-quality resampling (Lanczos). The MTF is non-linear, so averaging before and after give different values, mostly in stars and gradients.
  - **MTF.** The GPU computes the MTF exactly; the CPU uses a 4096-entry interpolated lookup table.
  - **Bayer.** The CPU grey path has no 2×2 Bayer bin (see M2).
- **Where it matters:**
  - Quick Look always uses the CPU path (`FITSBlasterQL/PreviewProvider.swift:22-30`, `FITSBlasterQLThumb/ThumbnailProvider.swift:44-52`), so Finder previews and thumbnails are not the image the app shows.
  - In the app the CPU path runs only when Metal fails, which today it never detects (CODE_AUDIT §5.17).
  - No test compares the two stretch paths; `GPUTests` compares only star counts (±1) and FWHM (within 20%).
- **Why it matters:**
  - The project rule "the CPU fallback gives the same result as the GPU path" (`CLAUDE.md`) is not met today.
  - Once §5.17 makes the app fall back to the CPU on GPU errors, a fallback image would look slightly different from its neighbours.
- **Action:**
  - First add a parity test: the same frame through both paths, reporting the maximum and mean difference per pixel.
  - Then decide: either make the CPU path follow the GPU order (box average, exact MTF, truncation), or accept a stated tolerance and write it into `CLAUDE.md`.
  - Changing the CPU path changes the Quick Look output, so that is a step 13 behaviour change; the test itself is step 8.
- **Severity:** Medium

### M2 Quick Look grey previews of colour-camera raw frames are not Bayer-binned
- **Location:** `ImageStretcher.swift:184-195` (`createImage(from:)`, no `bayerPattern` parameter); `cpuStretch` has no binning; the GPU path bins (`metalStretch`, `bayerBin`).
- **What:** For a raw colour-camera (OSC) frame, the app's grey view averages each 2×2 Bayer cell first, to avoid the "screen-door" pattern. The Quick Look path stretches the raw mosaic as is. Its final downscale to 1024 px averages some of it away.
- **Why:** Finder previews and thumbnails of OSC frames may show a mosaic pattern, or slightly different brightness, compared with the app. Not checked visually: on this Mac several FITS Quick Look extensions are registered at once (an older FITS Blaster build, QuickFits), so it can't be shown which one `qlmanage` uses.
- **Action:** Check visually in a clean VM after plan step 1 (Quick Look on macOS 15). If it shows, either pass the Bayer pattern to the Quick Look path, or debayer in colour there too. Decide together with M1.
- **Severity:** Low (cosmetic, to be confirmed)

### M3 Saturated stars are never detected
- **Location:** `FITSStretch.metal:275-283` (GPU) and `MetricsCalculator+StarDetection.swift:124-131` (CPU): both use a strict `>` against all 8 neighbours.
- **What:** A star whose top is clipped at the sensor's maximum has a flat plateau of equal pixels. No pixel in the plateau is strictly greater than all its neighbours, so the star produces no candidate.
- **Evidence:** pixels at the maximum value per frame, and how many of them sit in a plateau:
  - M81 (6224 × 4168): 568 at the maximum (65535), 441 of them in plateaus;
  - Rosette R (3856 × 2180): 2,600 at 65520, 2,124 in plateaus;
  - M31 (6224 × 4168): 628 at 65535, 488 in plateaus.

  How many stars that is was not counted.
- **Why:** The star count leaves out the brightest stars. For FWHM and eccentricity this is harmless, because the measurement wants unsaturated stars anyway ("top 50 unsaturated"). But the star count and the score built on it shift with seeing and focus: a sharper night saturates more stars and may report *fewer* stars. This may be related to [the cloudy-frames question](CODE_AUDIT.md) (§5.4, "score ignores cloudy frames").
- **How other tools do it** (checked 2026-10-18, from their documentation):
  - **PixInsight** (`StarDetector` in PCL, used by SubframeSelector and StarAlignment; [reference](https://pixinsight.com/developer/pcl/doc/html/classpcl_1_1StarDetector.html)):
    - A star is a connected patch of pixels above background plus noise, not a single pixel, so a saturated plateau is one star.
    - Local maxima are only used to split close pairs, and patches with pixels above the "local maxima detection limit" (default 0.75) are left out of that splitting.
    - Saturated stars are included by default: "Upper limit" ("Stars with peak values larger than this value won't be detected") defaults to 1.0, "which effectively disables this feature".
    - Lowering "peak response" "is useful to prevent detection of saturated stars". "Bright threshold" (default 3.0) overrides it: high-SNR stars "will always be detected, even if their profiles are too flat".
    - Not checked: whether SubframeSelector's window shows the same settings and defaults. Peak response is 0.8 in the 2022 header and 0.5 in the current docs.
  - **Siril** (Dynamic PSF / findstar; [docs](https://siril.readthedocs.io/en/1.2/_sources/Dynamic-PSF.rst.txt)) also uses local maxima, like us, but:
    - it smooths the image with a Gaussian first, which turns a plateau into one peak;
    - it then checks whether the core is "consistently close to the upper bound", and finds the edge of the saturated part;
    - saturated stars are kept and marked. Since 1.2 the saturated part is left out of the profile fit.
  - **Astro Pixel Processor:** no public description found. The forum says only that the quality score "is taking into account the star shape quite a bit", with no weights and nothing on saturation. Only APP support could answer this.

  So both documented tools count a saturated star once by default, and leave rejecting it as a user choice. Our kernel tests raw pixels (no smoothing) with a strict `>`, which is the one setup where a flat top gives no detection.
- **Action:** A behaviour decision (step 13). Options:
  - keep it, and document that the star count excludes saturated stars;
  - or count a plateau once, e.g. `>=` with a tie-break on position, or a separate saturated-star count. This matches PixInsight and Siril. Measurement would still use the top 50 *unsaturated* stars, as now.

  Either way, metrics and baselines change, so this is not for step 8.
- **Severity:** Medium (behaviour, needs a decision)

### M4 Fast math is on for the Metal library
- **Location:** `FITS Blaster.xcodeproj/project.pbxproj` (`MTL_FAST_MATH = YES` in all 3 configurations).
- **What:** With fast math, the Metal compiler may use approximate division and reciprocal, and may assume no NaN or infinity. The kernels divide (`/ range`, `/ float(n)`, the MTF denominator) and compare (`val > …`).
- **Why:** Today this is safe in practice:
  - the clips are checked (`highClip > shadowClip`, `BayerClips.isValid`);
  - the MTF denominator can't reach 0 (the midtone is clamped);
  - the reader only produces finite integer data (BITPIX 8/16/32).

  Two consequences remain:
  - the GPU and CPU paths can't be bit-identical even after M1, since only the GPU uses approximate maths;
  - GPU results may differ by a level between GPU generations or compiler versions. The render tests and baselines have only been proven on M1, including in the VMs, which run on the same GPU.
- **Action:** Keep fast math (it is the default and the kernels are bandwidth-bound, so turning it off would cost little but gain little). Note in the render-test docs that byte-identity is per GPU family. If a parity test (M1) shows ±1 level differences from fast math, that sets the tolerance.
- **Severity:** Low

### M5 The CPU star detection scans only a 4096 × 4096 centre crop
- **Location:** `MetricsCalculator.swift:408-417`.
- **What:** The GPU kernel scans the whole frame; the CPU fallback scans a centre crop of at most 4096 × 4096. The test data's 6224 × 4168 frames lose about a third of their area on the CPU path.
- **Why:** If the app ever falls back to the CPU (after §5.17), star counts and scores of large frames drop, and the frame would look worse than its neighbours. `GPUTests` doesn't see it because its test image is 256 × 256.
- **Action:** With §5.17 (step 8): either scan the full frame on the CPU too, or mark CPU-fallback metrics so they aren't compared with GPU ones. Add a parity test on a frame larger than 4096.
- **Severity:** Low (fallback only)

### M6 New Metal buffers for every frame
- **Location:** `ImageStretcher.swift:393, 538` (output buffers); `MetricsCalculator+StarDetection.swift:169-180` (a 400 KB candidate buffer and a counter, per frame).
- **What:** Every stretch and every detection allocates fresh shared buffers.
- **Why:** Small per-frame costs: allocation, and zero-filling 400 KB for each detection. Not measured; the load traces show the main cost elsewhere (PERFORMANCE_AUDIT.md).
- **Action:** Only with the `MetalContext` of step 8 (CODE_AUDIT §7.9, §9.5), and only if a measurement shows it: reuse the detection buffers per thread or from a small pool. The display-image output buffers must stay per image (they back the `CGImage`).
- **Severity:** Low

## 3. Already in CODE_AUDIT.md

- §5.17: command-buffer status is never checked; the detection threadgroup isn't clamped to the pipeline limit.
- §7.9, §9.5: two Metal devices, queues and libraries; duplicated setup and dispatch.
- §9.3: `bayerBin` in the Bayer kernel is always 1.
- §9.13: stale comments, including `FITSStretch.metal:40, 234-236` and `MetricsCalculator+StarDetection.swift:146-156, 165` (the "80 KB" and flag-buffer comments).

## 4. Checked and fine

- **Bounds:** every kernel returns early for threads outside the output (`dstWidth`/`dstHeight`) or on the border (detection). Source footprints are clamped to `width − 1` / `height − 1`. Shader validation found no out-of-bounds access on 1,068 real frames.
- **Struct layout:** `StretchParams`, `BayerStretchParams`, `DetectParams` and `DetectCandidate` match their Swift structs (only 4-byte fields, no padding); `setBytes` uses the Swift stride.
- **Maths:**
  - the MTF denominator `(2m−1)t − m` is negative for every t in (0, 1] when 0 < m < 1, and the midtone is clamped to that range;
  - float accumulation in the box average is precise enough (footprints up to about 40 × 40 pixels for thumbnails);
  - integer indices fit in 32 bits for frames under 4 G pixels (step 1 will bound NAXIS).
- **Detection:** the counter keeps the true total when the 50,000-candidate cap is hit. `memory_order_relaxed` is enough because the slots are disjoint. The output order is random, but the Swift side sorts with a full tie-break (`StarCandidate.brighterFirst`: peak, then y, then x), so the results are reproducible.
- **Dispatch:** `dispatchThreads` with non-uniform threadgroups (supported on all Apple-silicon Macs and the macOS 15 minimum); 16 × 16 threads.
- **Memory:** shared storage mode on unified memory; input buffers are written once by `FITSReader` and read by the kernels and the CPU, without copies.
- **Waiting:** command buffers are awaited with a continuation on the completion handler, not with `waitUntilCompleted` on the cooperative pool.

## 5. Suggested order

1. **Step 8:** a GPU-vs-CPU parity test for the stretch (M1) and for detection on a frame larger than 4096 (M5), together with the §5.17 error handling. This tells us the real size of M1 and M4.
2. **Step 13 (decisions):** saturated stars (M3); whether Quick Look should match the app (M1, M2).
3. **Step 8, only if measured:** buffer reuse (M6).
