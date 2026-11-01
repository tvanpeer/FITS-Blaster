# FWHM Comparison: FITS Blaster vs Other Tools

## Why values differ between tools

FWHM is not a single standardised measurement. Every tool makes different choices about the PSF model, fitting method, pixel unit convention, and which stars to include. Agreement within ~10% is normal; larger differences almost always have a specific cause (see below).

---

## What FITS Blaster does

- **PSF model:** Moffat β=4 (same default as PixInsight SubframeSelector)
- **Fitting method:** 1D weighted regressions along four directions (0°, 45°, 90°, 135°), linearised for β=4; the four widths are combined into the two principal axes of the elliptical star
- **Result:** Geometric mean of the two principal-axis FWHMs, in raw sensor pixels
- **Star sample:** Median over the stars fitted among the 200 brightest GPU-detected candidates
- **SNR:** median over the same stars of the fitted Moffat flux (peak · π · α_major · α_minor / 3) ÷ sky σ, since step 13b (before: peak ÷ σ); **PSF·S:** mean peak above background ÷ sky σ

---

## Measured comparison (same camera: 3.76 µm pixel, 430 mm focal length = 1.81"/px)

### Image B — narrowband (Antlia ALP-T dual-band Ha/OIII), OSC camera

| Tool | FWHM | Notes |
|---|---|---|
| **FITS Blaster** | **5.3 px** | |
| PixInsight Moffat4 | 5.60 px | −5% vs FITS Blaster |
| PixInsight Gaussian | 5.91 px | −10% vs FITS Blaster |
| Siril Moffat (free β) | 3.94 px | Different model — see note |
| Siril Gaussian | 4.53 px | |
| AstroPixelProcessor | 6.21–6.97 px | Per-frame range |

### Image C — no filter (broadband), same OSC camera

| Tool | FWHM | Notes |
|---|---|---|
| **FITS Blaster** | **6.9 px** | |
| PixInsight Moffat4 | 6.3 px | +10% vs FITS Blaster |
| PixInsight Gaussian | 6.73 px | +2.5% vs FITS Blaster |
| Siril Moffat (free β) | 6.30 px | |
| Siril Gaussian | 6.71 px | |
| AstroPixelProcessor | 4.35–11.08 px | Wide range, unreliable here |

**Conclusion:** FITS Blaster agrees with PixInsight Moffat4 within ±10% across both images, with no systematic bias.

---

## Mono and OSC cameras vs PixInsight SubframeSelector (2026-10-21, 2026-10-23)

Two mono sets, both with small stars: ASI294MM SHO (narrowband) and Rosette R/G/B (broadband). Set 3 is an OSC set with two exposure times (10 s and 180 s).

### Set 1: ASI294MM SHO

Data: `Test Data/ASI294MM SHO` — SH2-72, ZWO ASI294MM Pro, bin 2 (4144 × 2822; 2.3 µm native pixels, 4.63 µm binned per the XPIXSZ header; 408 mm = 2.34"/px, against 1.81"/px for the IMX571 OSC images above), 300 s, 10 frames each H, O and S. FITS Blaster 1.23.1-beta.2 (206), command-line mode. SubframeSelector 1.9.3, PSF type Moffat β = 4, subframe scale 1.0 (values in pixels), other settings default. All 30 frames matched. Comparison per filter, because the absolute values differ between filters.

#### Ranking (Spearman r; +1 = both tools order the frames the same way)

| Metric | H | O | S | All 30 |
|---|---|---|---|---|
| FWHM | +1.00 | +1.00 | +0.98 | +0.99 |
| PSF Signal Weight | +0.77 | +0.96 | +0.77 | +0.96 |
| Eccentricity | +0.87 | +0.49 | +0.58 | +0.55 |
| Stars | +0.41 | −0.65 | +0.37 | +0.84 |
| SNR (FB) vs SNR (PI) | +0.02 | −0.54 | +0.48 | +0.84 |
| SNR (FB) vs PSF SNR (PI) | −0.04 | −0.73 | −0.15 | +0.79 |

#### Absolute values (median)

| Metric | Filter | FITS Blaster | PixInsight | FB / PI |
|---|---|---|---|---|
| FWHM (px) | H | 2.08 | 1.71 | 1.22 |
| | O | 1.87 | 1.53 | 1.22 |
| | S | 1.91 | 1.58 | 1.21 |
| Eccentricity | H | 0.39 | 0.51 | 0.79 |
| | O | 0.39 | 0.43 | 0.89 |
| | S | 0.40 | 0.49 | 0.81 |
| Stars | H | 5,567 | 3,502 | 1.59 |
| | O | 5,776 | 5,244 | 1.09 |
| | S | 5,938 | 8,367 | 0.71 |

PSF Signal Weight and SNR use different scales in the two tools; only their ranking is comparable.

#### Conclusions

- **FWHM ranks the frames practically the same as PixInsight**, so culling on FWHM removes the same frames. But FITS Blaster reads a **constant 21–22 % higher** in all three filters, outside the ±10 % without bias seen on the OSC images above. These stars are very small (about 1.6 px in PixInsight, about 3.7"), because the binned 4.63 µm pixels at 408 mm sample 30 % coarser than the IMX571 setup; see source of difference 6 below.
- **PSF Signal Weight agrees well** (O +0.96, H and S +0.77).
- **Eccentricity agrees moderately within a filter**, and FITS Blaster reads lower. With stars of about 2 px eccentricity is hard to measure for any tool, and the spread within a filter is small (0.33–0.51).
- **SNR measures something different.** FITS Blaster's SNR is the aperture SNR of the stars; PixInsight's SNR and PSF SNR describe the whole image. Within a filter they don't correlate; across the set they do, because H, O and S differ a lot. SNR is 20 % of FITS Blaster's score (see the open question on cloudy frames).
- **Star counts depend on the detection threshold**: FITS Blaster finds more stars than PixInsight in H and fewer in S, and its counts vary little from frame to frame (5,200–5,960).

### Set 2: Rosette R/G/B

Data: `Test Data/NGC 2244-Rosette_Nebula original` — QHYminiCam8M (Sony IMX585, 2.9 µm, bin 1, 3856 × 2180), Askar V 80-Red at 384 mm = 1.56"/px, 30 s; 19 R, 19 G and 20 B frames. Same FITS Blaster build and SubframeSelector settings as set 1; all 58 frames matched. SubframeSelector warned that noise, PSF signal and noise-scaling estimates were missing from the image metadata and were calculated from possibly uncalibrated data. That concerns its weights (PSF Signal Weight, noise), not FWHM or eccentricity.

#### Ranking (Spearman r)

| Metric | R | G | B | All 58 |
|---|---|---|---|---|
| FWHM | +0.99 | +0.99 | +0.98 | +0.98 |
| PSF Signal Weight | +0.90 | +0.72 | +0.87 | +0.87 |
| Eccentricity | +0.88 | +0.92 | +0.88 | +0.91 |
| Stars | +0.92 | +0.79 | +0.85 | +0.98 |
| SNR (FB) vs SNR (PI) | −0.12 | −0.04 | +0.36 | +0.40 |
| SNR (FB) vs PSF SNR (PI) | −0.39 | −0.04 | +0.29 | +0.60 |

#### Absolute values (median)

| Metric | Filter | FITS Blaster | PixInsight | FB / PI |
|---|---|---|---|---|
| FWHM (px) | R | 2.31 | 1.96 | 1.19 |
| | G | 2.18 | 1.84 | 1.18 |
| | B | 2.56 | 2.17 | 1.18 |
| Eccentricity | R | 0.44 | 0.47 | 0.91 |
| | G | 0.42 | 0.47 | 0.87 |
| | B | 0.41 | 0.47 | 0.89 |
| Stars | R | 4,734 | 2,910 | 1.61 |
| | G | 3,630 | 2,358 | 1.54 |
| | B | 2,429 | 1,574 | 1.55 |

#### Conclusions

- **FWHM again ranks the same** (r ≈ +0.99) and reads a **constant 18–19 % high**: slightly less than on set 1, where the stars were smaller (about 2.0 px against 1.6 px in PixInsight). See source of difference 6.
- **Eccentricity agrees well** here (r ≈ +0.9 per filter; FITS Blaster about 10 % lower).
- **PSF Signal Weight and star count rank well**; FITS Blaster finds about 1.6 × as many stars, consistently.
- **SNR again doesn't track PixInsight within a filter.**

### Set 3: M42 OSC, 10 s and 180 s (2026-10-23)

Data: `Test Data/M42 RGB IMX571/2025-03-04_None/LIGHT` — ATR2600C (Sony IMX571, 3.76 µm, RGGB, bin 1, 6224 × 4168), WO Zenithstar 73 at 430 mm = 1.81"/px (the setup of images B and C above), no filter, gain 100. Two subfolders: `10` (39 kept + 7 in REJECTED, all trailed) and `180` (9 kept + 6 in REJECTED). FITS Blaster 1.23.1 (209), command-line mode, both folders together (`-S -r`); the scores are the same with each folder alone, because the score is computed per frame on fixed scales. SubframeSelector 1.9.3 with the settings of sets 1 and 2, on the 48 kept frames, twice: on the **raw frames** (PixInsight opens a raw OSC FITS as one grey image with the Bayer pattern still in it) and on frames **debayered** in PixInsight (Debayer, `_d.xisf`). All 48 frames matched in both runs.

The sky is about 5 × brighter in the 180 s frames (median about 1,260 against 265 ADU), and they have about 10 × as many saturated pixels (≥ 65,000: about 4,000 against 390 per frame; two frames of each checked).

#### PixInsight raw against debayered (median, kept frames)

| Metric | 10 s raw | 10 s debayered | 180 s raw | 180 s debayered |
|---|---|---|---|---|
| FWHM (px) | 3.42 | 3.38 | 3.70 | 3.63 |
| Eccentricity | 0.53 | 0.53 | 0.48 | 0.51 |
| Stars | 545 | 702 | 618 | 1,526 |
| SNR | 1.72 | 0.62 | 1.12 | 1.97 |
| PSF Signal Weight | 0.030 | 0.014 | 0.019 | 0.052 |

FWHM and eccentricity hardly change with debayering. Star detection, SNR and PSF Signal Weight do: on the raw mosaic each star carries the colour checkerboard of the Bayer pattern. **Compare OSC data with PixInsight only after debayering**; the rest of this section uses the debayered run.

#### Ranking against debayered PixInsight (Spearman r)

| Metric | 10 s (39) | 180 s (9) | All 48 |
|---|---|---|---|
| FWHM | +0.99 | +0.88 | +0.98 |
| Eccentricity | +0.86 | +0.57 | +0.82 |
| Stars | +0.54 | +0.16 | −0.17 |
| PSF Signal Weight | +0.30 | +0.45 | −0.29 |
| SNR (FB) vs SNR (PI) | +0.56 | +0.43 | −0.15 |
| SNR (FB) vs PSF SNR (PI) | +0.68 | +0.33 | −0.09 |
| Score (FB) vs PSF Signal Weight (PI) | +0.74 | +0.86 | −0.04 |

#### Absolute values (median, kept frames)

| Metric | Exposure | FITS Blaster | PixInsight | FB / PI |
|---|---|---|---|---|
| FWHM (px) | 10 s | 3.99 | 3.38 | 1.18 |
| | 180 s | 4.28 | 3.63 | 1.18 |
| Eccentricity | 10 s | 0.52 | 0.53 | 0.97 |
| | 180 s | 0.50 | 0.51 | 0.99 |
| Stars | 10 s | 2,769 | 702 | 3.94 |
| | 180 s | 1,312 | 1,526 | 0.86 |
| SNR | 10 s | 249 | 0.62 | — |
| | 180 s | 127 | 1.97 | — |
| Score | 10 s | 51 (44–53) | — | — |
| | 180 s | 41 (38–47) | — | — |

The trailed frames in REJECTED (FWHM 7.7–9.6, eccentricity 0.84–0.97) score 24–30.

#### Conclusions

- **Within one exposure time FITS Blaster culls like PixInsight**: FWHM and eccentricity rank the frames the same way, and the score follows PixInsight's PSF Signal Weight (+0.74 and +0.86).
- **What to expect:** for the same target and conditions, a longer exposure gives a higher SNR per frame (signal grows with t, noise with √t, so about √18 ≈ 4 × from 10 s to 180 s on unsaturated stars), more stars (fainter ones rise above the detection threshold) and a slightly larger FWHM (more seeing and tracking error averaged in). Exceptions are saturation and changing conditions. Here both sets were taken alternately on the same evening (19:47–20:59 local time) at about the same airmass (1.90–2.05 for the kept frames), so conditions don't explain a difference.
- **Across exposure times it goes the other way.** From 10 s to 180 s PixInsight's star count, SNR and PSF Signal Weight rise (702 → 1,526; 0.62 → 1.97; 0.014 → 0.052). FITS Blaster's star count halves (2,769 → 1,312) and its SNR falls (249 → 127), so the 180 s frames score lower (41 against 51). FITS Blaster loses stars on the long exposures where PixInsight finds more; the next section shows why. Scores of frames with different exposure times can't be compared.
- **FWHM reads 18 % high** with stars of about 3.4 px, between image C (1.10 at 6.3 px) and the mono sets (1.18–1.22 at 1.5–2.2 px); see source of difference 6.
- The 10 s REJECTED frames are all trailed and score 30, the best kept frames 53: the score spreads over a narrow band, because eccentricity of 0.5 or more adds nothing (fixed scale 0–0.5) and SNR above 200 and star counts above 500 are full marks.

#### Why the star count and SNR fall: star positions (2026-10-23)

Two frames taken a minute apart: 10 s #0000 (19:47) and 180 s #0000 (19:48). FITS Blaster's candidates and fit results were dumped with a temporary test that follows `MetricsCalculator.compute(metalBuffer:)` step by step (GPU detection, suppression, the top 200 for shape, the next 6,000 for the count); it reproduced the command-line star counts exactly (2,937 and 1,165). The reference star list was made separately: 2×2 superpixels (R+G+G+B), background per 32 × 32 superpixel block, noise from pixel-to-pixel differences, local maxima with `>=` so a saturated top counts as one star, peaks above 5 × the noise.

**1. The noise estimate includes the sky colour.** `estimateBackground` takes the median and MAD of 5,000 pixels of the raw Bayer mosaic. In broadband light R, G and B have different sky levels, and that spread counts as noise:

| | 10 s | 180 s |
|---|---|---|
| Sky R / G / B (ADU) | 250 / 278 / 256 | 1,019 / 1,430 / 1,051 |
| Real noise per channel (pixel to pixel) | 16–19 | 59–72 |
| σ used by FITS Blaster | 25 | 320 |
| Detection threshold (background + 5σ) | 390 | 2,888 |

The colour spread grows with the exposure time and the real noise with its square root, so at 180 s σ is about 4.5 × too high (at 10 s about 1.4 ×) and the threshold sits at about 20 × the real noise. The same σ divides the SNR (peak / σ, `MetricsCalculator+ShapeMeasurement.swift`) and PSF Signal Weight (mean peak / σ), so both fall with longer exposures although the stars are fine. PixInsight's run on the raw frames shows the same effect in its noise estimate (10 × higher at 180 s). Mono frames and narrowband filters have one sky level per frame, which fits the good agreement on sets 1 and 2. FWHM and eccentricity are measured on debayered stars and are not affected.

**2. Which stars FITS Blaster finds** (reference stars, matched within 2 superpixels):

| Reference stars | 10 s: number | FB found | 180 s: number | FB found |
|---|---|---|---|---|
| Unsaturated, peak 5–10 × noise | 1,090 | 33 % | 4,517 | 0 % |
| 10–20 × | 448 | 56 % | 1,664 | 4 % |
| 20–50 × | 316 | 76 % | 684 | 37 % |
| 50–200 × | 222 | 88 % | 495 | 80 % |
| over 200 × | 143 | 93 % | 249 | 90 % |
| Saturated | 25 | 16 % | 139 | 18 % |
| All | 2,244 | | 7,748 | |

- Faint stars: at 180 s practically all are lost to the inflated threshold. The reference finds 3.5 × as many stars at 180 s as at 10 s, the direction PixInsight shows.
- Saturated stars: more than 80 % are missed at both exposure times, as [METAL_REVIEW M3](METAL_REVIEW.md) predicted (the strict "brighter than all 8 neighbours" test fails on a flat top). Longer exposures have more of them.
- The other way round: at 10 s FITS Blaster accepts about 1,600 detections without a reference star nearby. 357 lie in the bright nebula core (12 % of the detections in 0.4 % of the frame, where the local sky alone is above the threshold); 23 are single-pixel spikes; the rest is not explained, and the simple reference may miss some real stars. They would explain part of the high 10 s count against PixInsight (2,937 against 702). At 180 s there are 145 such detections.

**What it means:** on OSC broadband frames, star count, SNR and PSF Signal Weight depend on the colour of the sky, so they can't be compared between exposure times, and probably not between nights or sites with different sky colours. Within one folder (same exposure and sky) the ranking is still usable (score against PixInsight's PSF Signal Weight +0.74 and +0.86). Possible fixes, both behaviour changes for master-plan step 13 and needing a decision: background and σ per Bayer channel (or on 2×2 superpixels) for colour cameras, which fixes threshold, SNR and PSF Signal Weight together; and counting a saturated top as one candidate (M3). Both change metrics and baselines.

### Set 4: M81 OSC vs PixInsight ImageAnalysis (2026-11-01)

PixInsight's new **ImageAnalysis** process replaces SubframeSelector. It measures the same kinds of properties, with some definitions changed (biweight mean and Qn spread instead of median and mean deviation; pixel values in [0,1]).

Data: `Test Data/M81 IMX571/2025-03-26_None/LIGHT` — the IMX571 OSC camera and 430 mm setup of set 3 (1.80"/px), no filter, gain 100, 180 s, 61 kept frames from 21:03 to 04:33 local time (the 10 in REJECTED were not measured). FITS Blaster at `e79bb50` (metrics as 1.24-beta.3), command-line mode, default options. ImageAnalysis with its default settings (PSF type Moffat β = 4, sensitivity 0.5, peak response 0.5, Maximum PSF fits 8000), three runs:

- **A, raw:** on the `.fits` files (60 frames; #0137 was missed when selecting files).
- **B, debayered:** on files from Debayer 1.12.1 (VNG, RGGB, signal and noise evaluation on: Moffat4 PSF signal, MRS noise), without calibration or registration (60 frames). With these estimates in the metadata, ImageAnalysis takes noise, SNR scaling and PSF signal from Debayer, computed on the raw data before interpolation, as its documentation recommends for colour cameras.
- **C, debayered, 200 fits:** as B with Maximum PSF fits = 200, so only the 200 brightest detected stars get a PSF fit, close to FITS Blaster's sample (all 61 frames).

#### ImageAnalysis definitions (from its documentation)

| Property | Definition |
|---|---|
| FWHM | 2D elliptical Moffat (or Gaussian) fit per star, σ = √(σx·σy), FWHM = 2σ√(2^(1/β) − 1); frame value = biweight mean over the fitted stars |
| Eccentricity | √(1 − σy²/σx²) per star; biweight mean |
| Stars | number of stars detected (multiscale detection), not the number fitted |
| SNR | ((σL + σH) / (2σn))², with σL, σH the spread of the pixels below and above the median and σn the noise: a whole-image statistic ("scaled inverse noise variance") |
| PSF Signal Weight | c₁·F·F̄ / (c₂·σn·M*), with F the sum of the PSF fluxes, F̄ the sum of the mean PSF fluxes (flux per area, higher for smaller stars), M* the mean background; c₁ = 5.326·10⁻⁶, c₂ = 9.0·10⁶ |
| PSF SNR | c₃·F² / (c₄·σn²), c₃ = 1.316·10⁻⁷, c₄ = 4.987·10⁶; insensitive to gradients and star size |
| Robust mean | Tukey biweight location, c = 6 MAD, iterated from the median |
| Robust σ | Qn of Rousseeuw and Croux (first quartile of the pairwise distances, × 2.2191 and a small-sample factor) |

For colour images stars and pixel statistics are measured on the HSI intensity; the per-channel noise and PSF estimates from the metadata are combined as the mid-range.

#### Medians

| Metric | A raw | B debayered | C debayered, 200 fits | FITS Blaster |
|---|---|---|---|---|
| FWHM (px) | 3.18 | 2.41 | **3.39** | 3.83 |
| Eccentricity | 0.58 | 0.53 | 0.54 | 0.53 |
| Stars | 1,218 | 3,492 | 3,492 | 1,863 |
| SNR | 0.320 (0.302–0.330) | 0.437 | 0.437 | 400 |
| PSF Signal Weight | 0.024 | 0.045 | 0.045 | 503 |
| PSF SNR | 0.206 | 0.080 | 0.080 | — |

Only the PSF fits differ between B and C: stars, SNR, PSF Signal Weight and PSF SNR are identical, because they come from the detection and from Debayer's metadata. On the raw frames PixInsight's SNR is almost flat (0.302–0.330), so the raw run can't rank the frames on it.

#### Ranking against FITS Blaster (Spearman r; 59 frames, without #0089, see below)

| FITS Blaster | ImageAnalysis | A raw | B debayered | C 200 fits |
|---|---|---|---|---|
| FWHM | FWHM | +0.94 | +0.93 | +0.93 |
| Eccentricity | Eccentricity | +0.73 | +0.69 | +0.67 |
| Stars | Stars | +0.54 | +0.58 | +0.58 |
| PSF·S | PSF Signal Weight | +0.61 | +0.68 | +0.68 |
| Score | PSF Signal Weight | +0.38 | +0.40 | +0.40 |
| SNR | SNR | +0.51 | +0.06 | +0.06 |
| SNR | PSF SNR | −0.08 | −0.11 | −0.11 |

(The raw column uses 60 frames.) Between runs B and C PixInsight orders the frames the same way on FWHM (+0.99) and eccentricity (+0.98).

Within each tool (run B, 59 frames): FITS Blaster's SNR follows its own FWHM (−0.76) and its score follows FWHM (−0.70) and SNR (+0.54) but hardly the star count (+0.13). PixInsight's SNR follows the sky background (Median, −0.82); its PSF Signal Weight follows the star count (+0.86) and FWHM (−0.48).

#### Which stars are measured: FWHM

With all stars fitted (run B), PixInsight's FWHM is 24 % *smaller* than on the raw frames (0.68–0.85 × per frame), and FITS Blaster reads 1.59 × PixInsight. Debayering adds many faint stars (1,218 → 3,492 detected), and in PixInsight's fits the faint stars come out much smaller than the bright ones. With only the 200 brightest stars fitted (run C) PixInsight's FWHM rises 40 % to 3.39 px, and **FITS Blaster reads 1.14 × PixInsight (1.08–1.23 per frame)**, with the same ranking (+0.93). The PSF model is the same in both tools (Moffat β = 4), so it doesn't explain the gap.

Frame **#0089** shows the same effect at its extreme: in run B PixInsight gives FWHM 1.28 px, the sharpest of the night; in run A 4.49 px with eccentricity 0.86 and only 738 stars; in run C 4.68 px and 0.85; FITS Blaster 5.10 px. It is the worst frame of the night, and the all-stars average was dominated by faint fits.

#### Conclusions

- **FWHM ranks the frames the same as PixInsight** in every run (+0.93 to +0.94), so culling on FWHM removes the same frames.
- **Most of FITS Blaster's higher FWHM is the star sample**: on comparable stars (the brightest 200) it reads 14 % above ImageAnalysis, against 59 % above its default. The remaining 14 % is about what set 3 showed with stars of the same size (1.18 at 3.4 px). Candidates for that rest: 1D fits along four directions against a 2D fit, and median against biweight mean; not measured. SubframeSelector (sets 1–3) also fits all detected stars by default; whether the same sample effect explains the 18–22 % there was not measured.
- **Which FWHM is "right" depends on the stars you ask about.** The brightest stars are the best measured (PixInsight's relative PSF residual is 10 × lower for them: 0.0056 against 0.055), and they are what FITS Blaster uses. The all-stars average can be pulled down by faint stars, as #0089 shows. No reason here to change FITS Blaster's sample.
- **FITS Blaster's SNR does not measure what PixInsight's SNR does.** It is the median peak ÷ sky σ of the brightest stars, so sharper stars give a higher value: it largely repeats the FWHM (−0.76). PixInsight's SNR is a whole-image statistic that falls as the sky gets brighter. They don't correlate (+0.06), nor with PSF SNR (−0.11). SNR is 20 % of FITS Blaster's score.
- **FITS Blaster finds about half PixInsight's stars** (1,863 against 3,492 debayered), which fits the colour-camera noise estimate of set 3 (the R/G/B sky spread counts as noise and raises the detection threshold).
- **PSF·S is FITS Blaster's best signal metric** against PixInsight's PSF Signal Weight (+0.68). The score follows PSF Signal Weight only weakly (+0.40), because it is driven by FWHM and SNR and hardly by the star count.
- **For comparisons with ImageAnalysis on OSC data:** debayer first (with signal and noise evaluation), and compare FWHM with Maximum PSF fits = 200.

### Set 5: California OSC dual-band vs ImageAnalysis, and step 13a (2026-11-01)

Data: `California Nebula IMX571/2026-02-25_Antlia ALP-T/LIGHT` — the IMX571 OSC camera of sets 3 and 4, Antlia ALP-T dual-band (Hα/OIII), 180 s, 87 frames, a field full of nebula. ImageAnalysis on frames debayered as in set 4 (VNG, signal and noise evaluation), Maximum PSF fits 200. PixInsight medians: FWHM 3.42 px, eccentricity 0.45, stars 2,993.

Master-plan step 13a measures the sky background and noise per Bayer channel on colour frames (detection, star count, σ of SNR and PSF·S) and leaves saturated stars out of the measurements. Ranking against ImageAnalysis (Spearman r), before → after 13a:

| FITS Blaster | ImageAnalysis | Set 5 California (87) | Set 4 M81 (59) |
|---|---|---|---|
| FWHM | FWHM (200 fits) | +0.65 → +0.52 | +0.94 → +0.95 |
| Eccentricity | Eccentricity (200 fits) | +0.84 → +0.82 | +0.68 → +0.68 |
| Stars | Stars | +0.97 → +0.98 | +0.58 → +0.75 |
| SNR | SNR | +0.88 → +0.89 | +0.06 → +0.44 |
| PSF·S | PSF Signal Weight | +0.97 → +0.99 | +0.68 → +0.94 |
| Score | PSF Signal Weight | +0.69 → +0.89 | +0.40 → +0.46 |

- On the dual-band set nearly everything already ranked like PixInsight; on the broadband M81 night 13a lifts stars, SNR and PSF·S clearly. The score follows PSF Signal Weight better on both.
- Subtracting the channel backgrounds under the star fits as well (planned, then dropped) made California's eccentricity rank the frames the opposite way (−0.47) and its FWHM worse (+0.43); the fits keep the frame's single background.
- California's FWHM ranks less well after 13a (+0.52), because a different set of 200 stars is measured. FITS Blaster's star count stays far below PixInsight's on both sets (429 against 2,993; 1,976 against 3,494), although it ranks the frames well.

### Set 6: what SNR should measure, against ImageAnalysis (2026-11-01)

New ImageAnalysis references (Maximum PSF fits 200, MRS noise; colour sets debayered with signal and noise evaluation): M31 night, Gamma Cygni 2026-03-04, ASI294MM SHO, Rosette R/G/B, M42 10 s including the 7 trailed frames in REJECTED; plus M81 (set 4) and California (set 5). M42 10 s and 180 s kept frames: SubframeSelector on debayered frames (set 3). FITS Blaster after step 13a, with six SNR candidates in a temporary build:

- **A** median peak ÷ σ (until 13b); **B** median aperture flux ÷ (σ · √pixels), aperture 2 × FWHM; **C** median aperture flux ÷ σ; **D** whole image ((σL + σH) / 2σn)², PixInsight's SNR; **E** median fitted Moffat flux (peak · π · α_major · α_minor / 3) ÷ σ; **F** fitted flux ÷ (σ · √aperture area).

Spearman r against PixInsight's PSF SNR, per group:

| Group (frames) | A | B | C | D | E | F |
|---|---|---|---|---|---|---|
| M81 (61) | +0.30 | +0.89 | +0.81 | +0.56 | +0.82 | +0.84 |
| California (87) | +0.98 | +0.98 | +0.96 | −0.47 | +0.97 | +0.98 |
| M42 10 s (39, SFS) | +0.59 | +0.82 | +0.49 | −0.16 | +0.54 | +0.72 |
| M42 180 s (9, SFS) | +0.63 | +0.90 | +0.53 | +0.40 | +0.45 | +0.80 |
| SHO H (10) | −0.04 | +0.30 | +0.87 | −0.07 | +0.93 | +0.36 |
| SHO O (10) | −0.79 | −0.81 | +0.67 | +0.20 | +0.43 | −0.84 |
| SHO S (10) | −0.15 | +0.15 | +0.78 | +0.52 | +0.73 | −0.07 |
| Rosette R (19) | −0.39 | +0.57 | +0.64 | −0.10 | +0.60 | +0.52 |
| Rosette G (19) | −0.03 | +0.12 | +0.50 | +0.12 | +0.53 | +0.17 |
| Rosette B (20) | +0.29 | +0.51 | +0.34 | +0.12 | +0.26 | +0.46 |
| M31 (39) | +0.61 | +0.82 | +0.88 | +0.66 | +0.89 | +0.81 |
| Gamma Cygni (34) | +0.90 | +0.95 | +0.97 | +0.88 | +0.92 | +0.92 |
| **Mean (lowest)** | +0.24 (−0.79) | +0.52 (−0.81) | +0.70 (+0.34) | +0.22 (−0.47) | +0.67 (+0.26) | +0.47 (−0.84) |

- A, the old SNR, follows FWHM (−0.25 to −0.96) and runs against PixInsight on several mono groups. B and F work on colour sets but fail on mono. D, the whole-image SNR, doesn't follow PixInsight's star SNR.
- C and E are level. On these sessions they also rise with FWHM (+0.3 to +0.96), as PixInsight's PSF SNR does on the mono sets and M31 (+0.53 to +0.79), so that is largely in the data.
- **Trailed frames** (M42 10 s REJECTED, eccentricity 0.97): E and C are 7 × the kept frames (A 1.5 ×). PixInsight's detection rejects elongated sources: 18 stars, PSF SNR ≈ 0, and eccentricity 0.40, below the kept frames' 0.51, so PixInsight's eccentricity misses the trailing that FITS Blaster's catches.
- Chosen (master-plan 13b): **E**, with a log score scale from 100 to 20,000. Trailed frames get full SNR points, as they did with A; eccentricity and FWHM give them a low score.

### Set 7: star count against PixInsight's star detector (2026-11-01)

PixInsight's `StarDetector` (the V8 object ImageAnalysis uses, default settings; colour frames on the debayered (R + G + B) / 3) exported every star's position for one frame per set. On uncalibrated colour frames a large part of its list is **hot pixels**, smeared into small blobs by the demosaic: exact integer position, centre more than 3 × the brightest neighbour above the sky (real stars: 1.1 ×). ImageAnalysis's "Stars" includes them.

| Frame | PixInsight list | of which hot pixels | PixInsight real stars | FITS Blaster before 13c | after 13c |
|---|---|---|---|---|---|
| M81 #0002 | 3,270 | 1,187 | 2,083 | 2,102 | 2,311 |
| California #0000 | 3,543 | 2,629 | 914 | ~500 | 875 |
| M42 10 s #0000 | 692 | 10 | 682 | 3,054 | 695 |
| M42 180 s #0000 | 1,672 | 224 | 1,448 | ~1,500 | 1,547 |
| SHO H #0001 (mono) | 3,947 | 10 | 3,937 | 5,516 | 4,539 |
| Rosette R #0000 (mono) | 2,868 | 0 | 2,868 | 4,739 | 2,641 |

Before 13c, FITS Blaster missed faint real stars (only the first 6,200 of up to 30,000 candidates were checked, hot pixels first) and counted noise peaks on nebula and faint peaks below PixInsight's sensitivity. Step 13c checks every candidate and requires the peak to stand ≥ 12 × the local noise above the local sky. Set 3's question why the star count fell at 180 s is answered: M42 180 s now has more stars than 10 s.

Step 13d (saturated stars on mono, METAL_REVIEW M3) after 13c: M81 2,304 (1.11), California 865 (0.95), M42 10 s 695 (1.02), M42 180 s 1,541 (1.06), SHO H 4,558 (1.16), **Rosette R 2,896 (1.01)**.

### Set 8: hot pixels and faint stars in the measured set (2026-11-01)

California's FWHM ranked the frames at only +0.52 against ImageAnalysis (after 13d). Per frame, #0000–#0089 rank at +0.99; the last 13 frames (#0090–#0102, target at 12° altitude, airmass 4.9) at −0.40.

- **PixInsight on those frames:** its FWHM drops to 1.35–1.37 px from #0095 on. StarDetector lists of #0098 and #0102: 1,440 and 1,322 entries, 95 % and 97 % hot pixels (exact integer position, centre > 3 × the brightest neighbour above the sky), 66 and 43 real stars, and 139 and 159 hot pixels among its 200 brightest. Its PSF fits there are on hot pixels. (#0000 for comparison: 74 % hot pixels, 15 among the 200 brightest.)
- **FITS Blaster on the same frames:** its 200 measured candidates were mostly hot pixels too (California #0000 87, #0066 154, #0102 193), and the shape fit accepts them, with FWHM 1–2.5 px or junk at 5–8 px. The median depended on the mix: #0102 read 3.69 px where its real stars give about 6. Other sets: Gamma Cygni 26 hot pixels per frame, SHO H/O/S 40/27/31, M42 10 s 9, M31 6, Rosette 1–2.
- **Faint stars:** without hot pixels (13e) the measured set reaches fainter stars, and noise widens and elongates their fits (synthetic round stars: eccentricity 0.16–0.21 bright, 0.5–0.75 faint; a 3 px star reads 4.5 px at peak SNR 40). California's eccentricity then ranked −0.11 and rose through the night where PixInsight's falls. Its old +0.80 came from the hot pixels: they are round and their share grew through the night.
- **Fix (master-plan 13e + 13f):** measure only stars (the count's check); FWHM and eccentricity from the stars at contrast ≥ 40 (or the 20 with the highest contrast). Ranking after: see the plan, 13f. California #0–#89 eccentricity +0.56, FWHM +0.99, PSF·S +0.99; M42 10 s PSF·S +0.03 → +0.55.

### Open questions (behaviour changes, master-plan step 13 at the earliest)

1. ~~Why FWHM reads 18–22 % high on small stars (about 2 px), and whether that should be corrected.~~ Largely answered (set 4): mostly which stars are measured. On the 200 brightest stars FITS Blaster reads 14 % above ImageAnalysis; the rest (1D against 2D fit, median against biweight) is not measured. No correction proposed.
2. Whether FITS Blaster's SNR should track image quality within a filter, as PixInsight's does, given its weight in the score. On both sets it doesn't. Set 4 shows why: it is peak ÷ sky σ of the brightest stars, so it mostly repeats the FWHM (−0.76), while PixInsight's SNR is a whole-image statistic that follows the sky background. After step 13a (σ per Bayer channel) SNR ranked M81 better against PixInsight's SNR (+0.06 → +0.44, set 5). **Answered in step 13b** (set 6): SNR is now the fitted star flux ÷ σ, which ranks frames like PixInsight's PSF SNR (mean +0.67 over 12 groups, against +0.24 before).
3. ~~Why FITS Blaster finds half as many stars, and a lower SNR, on 180 s frames than on 10 s frames~~ Answered (set 3, star positions): the background σ of OSC frames includes the R/G/B sky spread, and saturated stars aren't detected (M3). Decide on the fixes in step 13.
4. What the ~1,250 unexplained extra detections on the 10 s frame are (set 3), and whether candidates in bright nebula should be rejected.

---

## Known sources of difference

### 1. PSF model: Moffat β=4 vs free β vs Gaussian

The Moffat β parameter controls how quickly the star profile falls off in the wings.

- **Fixed β=4** (FITS Blaster, PixInsight): assumes a specific wing shape; fast to compute
- **Free β** (Siril): fits β as an additional free parameter; β=3.44 was measured for the test images above. When true β < 4, a free-β fit finds a tighter core and reports a *lower* FWHM than a forced β=4 fit — visible in the Siril Moffat values above (3.94 px vs 5.60 px for Image B)
- **Gaussian** (SasPro/SEP): uses `FWHM = 2.3548 × σ`; Gaussians have lighter tails than Moffat profiles, so they give slightly larger FWHM for the same star

### 2. 1D vs 2D fitting

FITS Blaster fits 1D profiles along four directions (0°, 45°, 90°, 135°), combines them into the two principal axes and takes the geometric mean. PixInsight and Siril fit a full 2D PSF simultaneously. For non-round stars or when axes are correlated, 2D fitting is more accurate.

### 3. Bayer (OSC) camera images

Through a **narrowband filter** (Ha, OIII, dual-band), all Bayer CFA channels (R, G, B) see nearly identical star flux — the filter bandwidth is far narrower than the Bayer channel separation. The Bayer pattern has no meaningful effect and no correction is needed.

For **broadband** images (no filter, or LRGB), different Bayer channels see different star flux. This can introduce noise into the PSF fit but does not require a scale-factor correction — tests show FITS Blaster still agrees with PixInsight within 10% for broadband OSC images.

> **Note:** An earlier version of FITS Blaster applied a ÷√2 scale factor to Bayer images, based on the assumption that tools report FWHM in "effective green-channel pixel" units. This was reverted after empirical testing showed it made results worse. No per-image correction is applied.

### 4. AstroPixelProcessor

APP's FWHM values tend to run slightly higher than PixInsight and FITS Blaster, and APP reports a min/max range across frames rather than a single value. The range can be wide when field quality varies across the frame. APP is useful as a sanity check but not as a precise reference.

### 5. Siril — arcsecond output

Siril's PSF report outputs FWHM in arcseconds by default. To convert to pixels:

```
FWHM (px) = FWHM (") / pixel_scale ("/px)
pixel_scale = 206.265 × pixel_size_µm / focal_length_mm
```

Example: 3.76 µm pixel, 430 mm focal → 1.805"/px → Siril's 7.56" = 4.19 px.

### 6. Small (undersampled) stars (not yet explained)

FITS Blaster's FWHM agrees with PixInsight's ranking on every set, but its offset grows as the stars get smaller:

| Set | Scale | PixInsight FWHM | FB / PI |
|---|---|---|---|
| Image C, IMX571 OSC broadband | 1.81"/px | 6.3 px | 1.10 |
| Image B, IMX571 OSC dual-band | 1.81"/px | 5.6 px | 0.95 |
| M42 10 s and 180 s, IMX571 OSC broadband (debayered in PixInsight) | 1.81"/px | 3.4–3.6 px | 1.18 |
| Rosette R/G/B, IMX585 mono | 1.56"/px | 1.8–2.2 px | 1.18–1.19 |
| SH2-72 H/O/S, ASI294MM bin 2 | 2.34"/px | 1.5–1.7 px | 1.21–1.22 |

Set 4 (2026-11-01) shows that most of such a gap can come from which stars are measured: PixInsight fits all detected stars, faint ones fit smaller, and with only the 200 brightest fitted the gap fell from 1.59 to 1.14. Whether this explains the sets in this table was not measured. Another suspect for the rest is the 1D fits on stars only a few pixels wide, against PixInsight's 2D fit; the two OSC images are also Bayer data, so they aren't a clean comparison. Until it is understood, absolute FWHM values of stars around 2 px or smaller should be read as relative only.

---

## Summary

For frame-quality ranking (the primary use case), the exact absolute value matters less than consistency. FITS Blaster is self-consistent across sessions and correlates well with actual image quality. Absolute values will be within ±10–15% of PixInsight Moffat4 under normal conditions. Larger differences are almost always explained by one of the factors above. The exceptions so far: small stars (about 3.5 px and less), where FITS Blaster read 18–22% high but still ranked the frames the same (source 6; set 4 shows that most of such a gap can be the choice of stars: on the 200 brightest it was 14 %), and star count, SNR and PSF Signal Weight on OSC broadband frames, which depend on the sky colour through the noise estimate and go the opposite way from PixInsight across exposure times (set 3).
