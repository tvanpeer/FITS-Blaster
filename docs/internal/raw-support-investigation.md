# RAW support (DSLR / mirrorless) — investigation for 2.0

Date: 2026-11-11. Status: **parked** (Tom). An experiment only: nothing in the app changed.

## Question

Could FITS Blaster open camera RAW files (CR2, CR3, NEF, ARW, …), now that Apple's
Core Image RAW 9 (WWDC 2026, macOS 27) improves RAW decoding? And can such frames be
measured like FITS frames, or only viewed?

## Core Image RAW 9

- The ninth version of Apple's RAW engine, in macOS 27: a machine-learning model on the
  Neural Engine that does demosaicing and noise reduction together. About 784 cameras.
- Apps opt in through `CIRAWFilter` (`decoderVersion`). On this Mac (macOS 27.0.1) the
  supported decoder versions are 7, 8 and 9; the default is 8.
- `CIRAWFilter` has no access to the raw sensor values (the Bayer mosaic): none of its 242
  properties and methods covers mosaic, CFA or sensor data. It always delivers a
  demosaiced image. It has a hook into the linear stage (`linearSpaceFilter`).
- Its defaults process the image: luminance noise reduction 0.61, colour noise reduction
  0.5, sharpening 0.81, tone curve ("boost") 1.0. All can be set to 0.

Sources: [Apple WWDC 2026 session 305](https://developer.apple.com/videos/play/wwdc2026/305/),
[Digital Camera World](https://www.digitalcameraworld.com/tech/iphones/iphone-photos-are-about-to-get-a-lot-less-noisy-even-if-youve-never-heard-of-core-image-raw-9-ios-27-and-macos-27-hide-a-key-editing-update),
[RedShark News](https://www.redsharknews.com/apple-raw-9-core-image-machine-learning-denoising?hs_amp=true).

## Test frames

Six light frames from Tom's 2022-02-25 Rosette session: Canon EOS 6D Mark II, ISO 800,
29.8 s, 6264 × 4180 visible pixels (raw 6384 × 4224, left margin 120, top margin 44),
RGGB, black level 2048, saturation 14 558, sensor 17 °C (all from LibRaw). Copies in a
scratch folder; the archive was only read.

## Test 1 — what Apple's processing does to the data

Middle of the six frames; noise = 1.4826 × MAD in a 1024² centre crop of the linear green
channel; decode time for a full frame, one at a time.

| Decoder | Settings | Decode time | Sky noise ÷ sky level | Brightest pixel above sky, in noise units |
|---|---|---|---|---|
| 8 | Apple's defaults | 0.42 s | 0.167 | 1 375 |
| 8 | everything off | 0.18 s | 0.359 | 533 |
| 9 | Apple's defaults | 2.75 s | 0.105 | 2 547 |
| 9 | everything off | 2.87 s | 0.071 | 2 809 |

RAW 9's noise reduction can't be switched off: with noise reduction, sharpening and tone
curve at 0 it still leaves about 5 × less noise than decoder 8. It is also about 15 × slower.

## Test 2 — FITS Blaster's metrics on three versions of the same frames

- **mosaic:** the raw sensor values via LibRaw (`unprocessed_raw`, cropped to the visible
  area), written as 16-bit colour FITS with `BAYERPAT = RGGB`, measured through the normal
  Bayer path — as frames from an astro camera.
- **Apple 8 / RAW 9:** `CIRAWFilter` with everything off, linear Rec. 709 luminance, scaled
  to 16 bit, measured as mono FITS.

Measured with the FITS Blaster 1.24-beta.5 command line. Middle of the six frames:

| | mosaic (LibRaw) | Apple 8 | RAW 9 |
|---|---|---|---|
| FWHM | 2.43 px | 2.46 px (+1 %) | 2.62 px (+8 %) |
| Eccentricity | 0.47 | 0.52 | 0.52 |
| SNR | 3 358 | 5 009 (× 1.5) | 10 995 (× 3.3) |
| Stars | 21 933 | 17 967 (−18 %) | 46 309 (× 2.1) |
| PSF·S | 420 | 593 (× 1.4) | 1 137 (× 2.7) |
| Score | 71.5 | 71 | 73 |

Per frame:

| Frame | FWHM m / A8 / R9 | Ecc m / A8 / R9 | Stars m / A8 / R9 |
|---|---|---|---|
| #0332 | 2.79 / 2.76 / 2.92 | 0.73 / 0.81 / 0.80 | 17 276 / 17 965 / 39 810 |
| #0333 | 3.46 / 3.33 / 3.45 | 0.86 / 0.91 / 0.90 | 14 654 / 15 805 / 34 845 |
| #0334 | 2.39 / 2.45 / 2.60 | 0.44 / 0.48 / 0.42 | 22 274 / 18 070 / 46 210 |
| #0335 | 2.47 / 2.46 / 2.65 | 0.51 / 0.54 / 0.58 | 21 591 / 18 599 / 46 407 |
| #0336 | 2.32 / 2.39 / 2.52 | 0.41 / 0.49 / 0.45 | 22 966 / 17 956 / 48 002 |
| #0337 | 2.33 / 2.32 / 2.48 | 0.37 / 0.47 / 0.39 | 23 250 / 17 969 / 47 740 |

Findings:

- **FWHM** survives Apple's decoder 8 within 1 % and in nearly the same frame order. RAW 9
  widens stars by 8 %.
- **Eccentricity** rises by 0.05–0.1 with Apple's demosaicing, most on round stars (#0337:
  0.37 → 0.47); relevant next to Auto-Flag's 0.65 limit.
- **Star count loses its warning power with Apple 8:** from the mosaic the worst frame (#0333)
  has 37 % fewer stars than the best; with Apple 8 only 15 % (all frames near 18 000). The
  star count is what catches thin cloud.
- **RAW 9 inflates SNR (× 3.3), stars (× 2.1) and PSF·S (× 2.7):** its noise reduction turns
  noise peaks into "stars" and calms the sky. Unusable for measuring.
- **The score hides all this:** its star and SNR parts are already (nearly) full at these values.

## Speed

LibRaw unpacks one CR2 (lossless JPEG) in 0.62 s on one core; Apple's decoder 8 decodes
and demosaics in 0.18 s. With 8 frames in parallel, LibRaw would need roughly 50 s for 592
frames, against 11–25 s for 592 FITS frames (FAQ speed table, MacBook Air M1).

## Directions

| | Viewing | Measuring | Cost |
|---|---|---|---|
| A. Apple only, decoder 8 "everything off" | fast, plain image | FWHM fine; eccentricity, star count and SNR differ from FITS and are weaker for cloud | no dependency |
| B. Apple for viewing, LibRaw for measuring | as A, optionally RAW 9 for the current frame | same raw mosaic and Bayer path as FITS: values comparable with FITS | LibRaw (LGPL-2.1 or CDDL-1.0) as a dependency; App Store: dynamic linking or CDDL |
| C. Viewing and culling only | as A | none (no chart, no Auto-Flag) | simplest |

Conclusion: to measure RAW frames like FITS frames, use the raw mosaic (B). RAW 9 fits at
most as an optional nice view of the current frame, never for thumbnails or measuring.

Open questions for later: RAW files carry EXIF (camera, ISO, exposure, sometimes sensor
temperature) but no FILTER or OBJECT — how filter groups and sessions would work; demand
among users (DSLR / mirrorless); CR3 and other formats; LibRaw licence handling; the FAQ's
"not on the roadmap" answer.
