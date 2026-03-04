# Improvement Plan: From Viewer to Premium Culling App

## The core problem to solve

With 200–500 frames across multiple nights, filters, and camera setups, you need to identify bad frames **without looking at every single one**. The app currently requires you to navigate sequentially. That needs to change.

---

## Priority 1 — Session Overview Chart (killer feature)

A **resizable chart strip** beneath the main image showing FWHM, star count, and score plotted against frame index for the entire session. Each dot is a frame; clicking it selects it; drag-selecting a range lets you batch-reject.

- Dots coloured by **normalised filter type** (see Priority 2 for the full classification):
  - Broadband: L = white, R = red, G = green, B = blue
  - Narrowband mono: Ha = deep red, OIII = teal, SII = amber
  - Dual-narrowband OSC (HO / L-eXtreme / L-Ultimate): magenta
  - Tri-narrowband OSC (SHO / L-eNhance / Triad Ultra): purple
  - Quad-band OSC: gold
  - Unfiltered: grey
- Horizontal threshold lines drawn **per filter group** (not session-wide) — a good Ha frame and a good L frame have completely different star counts and SNR; mixing them into one threshold is meaningless
- Y-axis toggleable: FWHM / Eccentricity / SNR / Score / Star Count
- Hovering a dot shows the filename, filter, and metrics in a tooltip
- Drag-select a range of dots → batch-reject with a single keypress

This single feature turns "browse 400 frames one by one" into "select the FWHM spike cluster, hit X, done."

---

## Priority 2 — Filter-based grouping in sidebar

For LRGB + narrowband + OSC dual-narrowband across multiple nights, everything is currently one flat list. Instead:

### Filter normalisation

The FITS `FILTER` header can contain anything the capture software wrote. The app will normalise raw header values into canonical filter groups using fuzzy matching:

| Canonical group | Typical FITS header values matched |
|---|---|
| L | `Luminance`, `Lum`, `L`, `Clear`, `IR cut` |
| R | `Red`, `R` |
| G | `Green`, `G` |
| B | `Blue`, `B` |
| Ha | `Hα`, `Ha`, `H-Alpha`, `656nm` |
| OIII | `OIII`, `O3`, `O-III`, `500nm` |
| SII | `SII`, `S2`, `S-II`, `672nm` |
| Hβ | `Hβ`, `Hb`, `H-Beta`, `486nm` |
| HO *(dual NB)* | `HO`, `HOO`, `L-eXtreme`, `L-Ultimate`, `Antlia ALP-T`, `Dual Narrowband`, `Ha+OIII`, `Optolong Extreme` |
| SHO *(tri NB)* | `SHO`, `L-eNhance`, `LeNhance`, `Triad`, `Ha+OIII+SII`, `Tri-band` |
| Quad-NB | `Quad`, `Quad-band`, `Quad-NB`, `4-band`, `Antlia Quad` |
| Unfiltered | *(no FILTER header, or unrecognised value)* |

Matching is case-insensitive and substring-based so that values like `"Optolong L-eXtreme 7nm"` correctly map to HO. Unrecognised values are shown verbatim as their own group rather than silently discarded.

### Sidebar behaviour

- Sidebar grouped by normalised filter, then optionally by **night** (from `DATE-OBS`)
- Each group header shows: frame count, median FWHM, median score, and the filter's colour dot
- Collapse/expand individual groups
- Quick filter strip above sidebar: **All / L / R / G / B / Ha / OIII / SII / HO / SHO / Quad / Unfiltered** — only shows tabs for filters actually present in the loaded session
- Sort order (name, score, FWHM, etc.) applies within each group

### Important: per-group metric baselines

Narrowband and dual-narrowband filters suppress continuum light. An L frame in good conditions might show 400 stars; an HO frame of the same field might show 30. Star count thresholds and SNR baselines are always computed **within each filter group**, never across the whole session. This applies to P3 badges, P5 auto-reject, and P1 chart threshold lines.

---

## Priority 3 — Smarter thumbnail badges

The current badge is just a score number. Replace with a **two-tier system**:

- Score number stays, but badge colour encodes the *worst detected problem*:
  - **Red badge:** trailing (eccentricity > 0.5) or focus failure (FWHM > 1.5× *group* median)
  - **Amber badge:** clouds/haze — for broadband: star count < 40% of group median; for narrowband and dual-NB: star count < 30% of group median (lower floor because the absolute count is already small)
  - **Green badge:** frame is in the top third of its filter group
- Small problem **icon** overlaid on the badge:
  - `scope` (crosshair) = focus failure
  - `arrow.up.right` (diagonal) = trailing / elongated stars
  - `cloud.fill` = low star count (haze or cloud)
- For dual-narrowband OSC frames, the "low star count" threshold is calibrated to the group — so a perfectly good L-eXtreme frame with 25 stars is not falsely flagged as cloudy

---

## Priority 4 — Zoom controls + star overlay

**Zoom:**
- Toolbar zoom control: Fit / 50% / 100% / 200% (and pinch-to-zoom)
- At 100%, if the loaded image was downscaled, trigger a background reload at full resolution — critical for checking focus at the pixel level
- "Zoom to 100%" keyboard shortcut (`Z`)

**Star overlay:**
- Toggle button (`S`) shows detected star positions as circles on the image, scaled by measured FWHM
- Circle colour: green = measured and good, red = saturated/excluded, yellow = measured but borderline
- For dual-narrowband OSC frames the star count will be low — the overlay is still useful for checking trailing and focus, even with only 20–30 detected stars

---

## Priority 5 — Auto-reject threshold

One-click culling based on metrics:

- "Auto-flag" sheet: set thresholds for FWHM, eccentricity, SNR, star count
- Preview shows how many frames would be flagged *before* committing
- **Relative mode (recommended):** "FWHM > 1.5× group median" — adapts to your optics, seeing, and filter rather than requiring you to know absolute values
- **Absolute mode:** direct numeric thresholds per metric for advanced users
- Thresholds apply **per filter group** — narrowband and dual-NB groups are evaluated independently from broadband so that naturally lower star counts in HO / SHO frames do not trigger false cloud flags

---

## Priority 6 — Drag & drop

- Drag a folder from Finder onto the app window → opens it, same as Cmd+O
- Drag individual `.fits` / `.fit` / `.fts` files → adds them to current session
- Removes the biggest friction point for opening files

---

## Priority 7 — Pick/flag workflow

Add a proper three-state flag alongside the star rating:

- **P** = Picked (green flag) — definitely keeping
- **X** = Rejected (red, moves file)
- Space or **U** = Unflagged (neutral)
- Sidebar shows flag colour as a left-edge stripe on each thumbnail
- Final action: "Move all unflagged to REJECTED/" — lets you work positively (pick the good ones) rather than negatively

---

## Priority 8 — Richer stacking export

Given PixInsight, Siril, and APP workflows:

- **PixInsight:** Export a weighted image integration script (`.txt` with `WeightedBatchPreProcessing` format) — weight = quality score / 100; frames grouped by filter so each filter channel gets its own integration group
- **Siril:** Export a `.ssf` sequence file referencing picked/rated frames; one sequence file per filter group
- **APP:** Export a plain file list, one path per line (APP accepts these directly); optionally one file per filter group
- **All:** Option to include/exclude rejected frames, filter by minimum rating, filter by flag
- For dual-narrowband OSC frames exported to PixInsight: groups them under their canonical filter name (HO, SHO, Quad-NB) so the integration script is ready for a Starless + NBAccel workflow

---

## Priority 9 — Minor UI improvements

- **Tooltip on quality badge:** hover shows "FWHM 3.2px · Ecc 0.41 · SNR 87 · 312 stars" — read the score without navigating to the frame
- **Focus trend line** overlaid on session chart: smoothed FWHM moving average to separate seeing variation from slow focus drift
- **Session summary** in toolbar: "312 frames · 89 picked · 47 rejected · 4 filters"
- **Keyboard shortcut `F`** → flag as pick
- **Drag filename** out of toolbar into Finder or terminal

---

## What's out of scope

- Plate solving integration — heavy dependency, limited culling benefit
- Planetary/lucky imaging (video/SER files) — fundamentally different pipeline
- Folder watching / live capture integration — lower priority than core workflow improvements

---

## Suggested implementation order

**6 → 1 → 3 → 2 → 4 → 5 → 7 → 8 → 9**

Priority 6 (drag & drop) is quick and removes immediate friction. Priority 1 (session chart) is the largest but most distinctive feature. Priorities 2 and 3 build on the filter normalisation engine introduced in P2 — implement the normalisation table first, then badges and chart colours follow naturally.
