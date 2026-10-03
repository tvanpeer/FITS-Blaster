# How the Quality Score Is Calculated

The quality score is a single integer from **0 to 100** that summarises the optical quality of a FITS frame. It is a weighted average of up to four individual metrics: FWHM, eccentricity, SNR, and star count. Only the metrics that are enabled in Settings contribute; their weights are renormalised so they always sum to 1.0 regardless of which subset is active.

---

## Step 1 — Background Estimation

Before any star is detected or measured, the image background level and noise are estimated using **stratified sampling**:

1. 5 000 pixels are sampled at regular stride across the full frame.
2. The **median** of those samples is taken as the sky background level.
3. The **median absolute deviation (MAD)** of the samples is computed and converted to an equivalent Gaussian sigma:

   σ = MAD × 1.4826

   The factor 1.4826 makes MAD a consistent estimator of the standard deviation for normally-distributed noise. A floor equal to 0.01 % of the sampled data range (with an absolute minimum of the smallest representable float) is applied to avoid division by zero on pathological data.

The detection **threshold** is set at background + 5 σ, so only genuine stars (5-sigma detections) are considered.

---

## Step 2 — Star Detection

Stars are detected as **local maxima** above the 5 σ threshold.

### GPU path (default on Apple Silicon)
A Metal compute kernel (`detectLocalMaxima`) scans the **full frame** in parallel. Each thread checks whether its pixel is above the threshold and is strictly greater than all 8 neighbours. Candidates are written to a compact shared buffer (capped at 50 000 entries); an atomic counter records the true total even when the buffer overflows. The GPU step takes roughly 3–8 ms for a 16–50 MP image.

### CPU fallback
When Metal is unavailable, a vectorised scan covers a **4 096 × 4 096 centre crop**. Each row is pre-filtered with a single `vDSP_maxv` call; rows where no pixel exceeds the threshold are skipped entirely (~50× faster than a naïve full-scan for typical star fields where 95 %+ of pixels are below threshold).

The detected star count (before any culling for saturation) is what is reported as the **star-count metric**.

---

## Step 3 — Per-Star Shape Measurement

Up to 200 of the brightest candidates are selected for shape fitting. Because the median is used to summarise each metric across the candidates, occasional saturated stars at the top of the brightness ranking have negligible effect on the result. For each candidate the following quantities are computed:

### Sub-pixel centroid
A 5 × 5 intensity-weighted window gives a sub-pixel centroid (cx, cy) and a bilinearly-interpolated peak value.

### FWHM — 1D Moffat β = 4 fit
A **Moffat profile** with fixed β = 4 (the PixInsight standard) is fitted independently along the X and Y axes through the sub-pixel centroid, using a ±10-pixel window and a linearised weighted regression:

```
z = (A / I)^(1/4) − 1  =  x² / α²
```

Weighted regression through the origin gives α directly. FWHM per axis is then:

```
FWHM = 2α · √(2^(1/4) − 1)   ≈   α × 0.870 × 2
```

The **reported FWHM** is the geometric mean of the two axes, matching PixInsight's single-value summary:

```
FWHM = √(FWHM_x × FWHM_y)
```

Units are **pixels**. Hot pixels (FWHM < 0.5 px) and pathological blobs (FWHM > 20 px) are rejected.

### Eccentricity — four-direction principal-axis reconstruction
Eccentricity is derived from the true principal axes of the PSF ellipse, reconstructed analytically from Moffat fits along four directions: 0°, 45°, 90°, and 135°.

For an elliptical Moffat with semi-axes `a` (major) and `b` (minor) at rotation angle `θ`, the directional α satisfies:

```
1/α(φ)²  =  cos²(φ−θ)/a²  +  sin²(φ−θ)/b²
```

The four measurements produce three independent combinations:

```
S   =  1/a² + 1/b²                 =  (1/α₀² + 1/α₉₀² + 1/α₄₅² + 1/α₁₃₅²) / 2
C   =  (1/a² − 1/b²)·cos(2θ)      =  1/α₀²  − 1/α₉₀²
S₂  =  (1/a² − 1/b²)·sin(2θ)      =  1/α₄₅² − 1/α₁₃₅²
```

Solving for the principal axes:

```
D          =  √(C² + S₂²)
1/a_major² =  (S − D) / 2
1/a_minor² =  (S + D) / 2

FWHM_major  =  fwhmFactor / √(1/a_major²)
FWHM_minor  =  fwhmFactor / √(1/a_minor²)

e  =  √(1 − (FWHM_minor / FWHM_major)²)
```

- **e = 0** — perfectly round star
- **e → 1** — strongly elongated / trailed star

Because the reconstruction uses four evenly-spaced directions spanning 180°, it is fully **orientation-invariant** — elongation at 0°, 45°, or any other angle is detected with equal sensitivity. This matches PixInsight SubframeSelector's approach of fitting a full 2D PSF ellipse.

### SNR — aperture photometry
A circular aperture of radius r = 2 × FWHM is placed at the centroid. The background-subtracted flux inside the aperture (I_net) and the pixel count (n_ap) are summed, then:

```
SNR = I_net / √(I_net + n_ap · σ²_sky)
```

This is the standard simplified CCD equation (Merline & Howell 1995): the two noise terms under the root represent Poisson shot noise from the star and accumulated background noise across the aperture. Without a known camera gain, the Poisson term is a proportional proxy; it correctly **ranks frames relative to each other** within a session on the same camera.

The **median** FWHM, eccentricity, and SNR across all accepted candidates are used as the frame values.

---

## PSF Signal Weight (PSF-SW)

PSF Signal Weight is computed as a by-product of the Moffat fit — no extra processing is needed. It measures **peak amplitude per unit of sky noise**, rewarding both good transparency and good seeing.

### Formula

For each of the up to 200 fitted stars, the background-subtracted sub-pixel peak amplitude `A` is accumulated:

```
PSF-SW  =  mean(A) / σ_sky
```

where `σ_sky` is the background sigma from Step 1.

### Why peak amplitude?

Good transparency delivers more photons, which raises the peak `A`. Good seeing concentrates those photons into a narrower PSF, also raising `A`. PSF-SW therefore rewards both factors simultaneously. This matches PixInsight SubframeSelector's PSF Signal Weight behaviour.

### What PSF-SW tells you

- **High PSF-SW** — good transparency and/or good seeing. Stars are bright and sharp relative to the sky noise.
- **Low PSF-SW** — haze, thin cloud, poor seeing, or high sky background. The frame was photon-starved or the PSF was bloated.
- **Unlike SNR**, PSF-SW is not diluted by a large aperture — it uses the star's peak, not its total aperture flux.

PSF-SW is available in the session chart (the **PSF·S** button), the inspector, and the sidebar sort menu. It does **not** contribute to the composite quality score — it is a supplemental transparency metric intended to inform integration decisions.

---

## Step 4 — Composite Score

Each metric is converted to a normalised sub-score **s ∈ [0, 1]** using a piecewise-linear mapping:

| Metric | Weight | Ideal | Bad at | Formula |
|--------|--------|-------|--------|---------|
| FWHM | 35 % | ≤ 2 px | ≥ 7 px | `s = clamp(1 − (FWHM − 2) / 5, 0, 1)` |
| Eccentricity | 35 % | 0 | ≥ 0.5 | `s = clamp(1 − e / 0.5, 0, 1)` |
| SNR | 20 % | ≥ 200 | ≤ 10 | `s = clamp((SNR − 10) / 190, 0, 1)` |
| Star count | 10 % | ≥ 500 | 0 | `s = clamp(log₁₀(n + 1) / log₁₀(501), 0, 1)` |

Star count uses a **log scale** so that a frame with 50 stars is not penalised as harshly as a frame with 0 stars.

The weighted average of active sub-scores is scaled to 0–100:

```
score = round( (Σ wᵢ · sᵢ) / (Σ wᵢ) × 100 )
```

If no metrics are enabled, the score is 0.

---

## Badge Colours

The quality badge on each thumbnail is coloured by the **worst detected problem**, independent of the score:

| Colour | Condition |
|--------|-----------|
| 🔴 Red | Eccentricity > 0.5 (trailing), or FWHM > 1.5 × group median (focus failure) |
| 🟡 Amber | Star count < 30–40 % of group median (low stars; threshold is 30 % for narrowband filters) |
| 🟢 Green | Score is in the top third of the filter group |
| ⚪ Grey | No problem detected, not in top third |

The group median thresholds are computed separately for each filter group (Ha, OIII, etc.) so that narrowband frames with naturally lower star counts are not unfairly penalised against broadband frames.
