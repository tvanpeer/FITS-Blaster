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

---

## Summary

For frame-quality ranking (the primary use case), the exact absolute value matters less than consistency. FITS Blaster is self-consistent across sessions and correlates well with actual image quality. Absolute values will be within ±10–15% of PixInsight Moffat4 under normal conditions. Larger differences are almost always explained by one of the factors above.
