# FWHM Comparison: FITS Blaster vs Other Tools

## Why values differ between tools

FWHM is not a single standardised measurement. Every tool makes different choices about the PSF model, fitting method, pixel unit convention, and which stars to include. Agreement within ~10% is normal; larger differences almost always have a specific cause (see below).

---

## What FITS Blaster does

- **PSF model:** Moffat β=4 (same default as PixInsight SubframeSelector)
- **Fitting method:** Two independent 1D weighted regressions (along X and Y axes), linearised for β=4
- **Result:** Geometric mean of FWHMx and FWHMy, in raw sensor pixels
- **Star sample:** Median over the top ~200 unsaturated candidate stars, GPU-detected

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

## Mono cameras vs PixInsight SubframeSelector (2026-10-21)

Two mono sets, both with small stars: ASI294MM SHO (narrowband) and Rosette R/G/B (broadband).

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

### Open questions (behaviour changes, master-plan step 13 at the earliest)

1. Why FWHM reads 18–22 % high on small stars (about 2 px), and whether that should be corrected.
2. Whether FITS Blaster's SNR should track image quality within a filter, as PixInsight's does, given its weight in the score. On both sets it doesn't.

---

## Known sources of difference

### 1. PSF model: Moffat β=4 vs free β vs Gaussian

The Moffat β parameter controls how quickly the star profile falls off in the wings.

- **Fixed β=4** (FITS Blaster, PixInsight): assumes a specific wing shape; fast to compute
- **Free β** (Siril): fits β as an additional free parameter; β=3.44 was measured for the test images above. When true β < 4, a free-β fit finds a tighter core and reports a *lower* FWHM than a forced β=4 fit — visible in the Siril Moffat values above (3.94 px vs 5.60 px for Image B)
- **Gaussian** (SasPro/SEP): uses `FWHM = 2.3548 × σ`; Gaussians have lighter tails than Moffat profiles, so they give slightly larger FWHM for the same star

### 2. 1D vs 2D fitting

FITS Blaster fits two separate 1D profiles (along X and Y) and takes the geometric mean. PixInsight and Siril fit a full 2D PSF simultaneously. For non-round stars or when axes are correlated, 2D fitting is more accurate.

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
| Rosette R/G/B, IMX585 mono | 1.56"/px | 1.8–2.2 px | 1.18–1.19 |
| SH2-72 H/O/S, ASI294MM bin 2 | 2.34"/px | 1.5–1.7 px | 1.21–1.22 |

A likely suspect is the 1D fit along X and Y on stars only a few pixels wide, against PixInsight's 2D fit, but this hasn't been measured; the two OSC images are also Bayer data, so they aren't a clean comparison. Until it is understood, absolute FWHM values of stars around 2 px or smaller should be read as relative only.

---

## Summary

For frame-quality ranking (the primary use case), the exact absolute value matters less than consistency. FITS Blaster is self-consistent across sessions and correlates well with actual image quality. Absolute values will be within ±10–15% of PixInsight Moffat4 under normal conditions. Larger differences are almost always explained by one of the factors above. The exception so far is undersampled data (stars under about 2 px), where FITS Blaster read 18–22% high on two mono sets but still ranked the frames the same (source 6).
