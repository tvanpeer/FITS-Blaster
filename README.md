# FITS Blaster

A fast, native macOS app for culling FITS astronomical image files. Open a folder, navigate with the keyboard, reject bad frames, export a list of keepers.

## What makes it different

**Everything is GPU-accelerated.** Images are stretched on the GPU (Metal compute shader) — a single pass that normalises, gamma-corrects, and flips each frame. First image appears in under a second; 88 × 26 MP files load fully in ~11 s on an M1 Air.

**Colour (OSC/Bayer) support.** One-shot colour cameras produce raw Bayer-pattern FITS files. The app detects the pattern from the FITS header, shows a greyscale preview instantly, then re-renders the batch in colour once all frames are loaded — using per-channel median clip bounds across the folder so every frame has a consistent stretch.

**Relative quality badges.** Each thumbnail shows a red/amber/green badge based on FWHM, eccentricity, SNR, and star count — measured against the *group median*, not hardcoded thresholds. The app adapts automatically to your setup and sky conditions.

**Session chart.** A resizable strip plots any metric across the session. Drag across a range to batch-reject frames. Y-axis scales to the data, not to zero.

**Filter-aware grouping.** Frames are grouped by filter type (L, R, G, B, Hα, OIII, SII…) in both the sidebar and chart, with per-group median lines and colour coding.

**Subfolder support.** Recursively scans subfolders; calibration folders (FLAT, DARK, BIAS, CALIB) are skipped automatically. Each subfolder appears as a collapsible sidebar section.

## Other highlights

- Fully keyboard-driven; all keys configurable in Settings
- Auto-reject sheet: set thresholds relative to the group median, preview the count, then commit
- Simple mode (⌘⇧M) hides metrics for a fast visual cull
- No third-party dependencies — Metal, Accelerate, SwiftUI, Swift Charts only
- Sandboxed, read-only (rejection moves files to a `REJECTED/` subfolder)
- Supports BITPIX 8, 16, 32; requires macOS 15.7+

## Build

Open `FITS Blaster.xcodeproj` in Xcode and press ⌘R.

## Support

FITS Blaster is free. If it saves you time, [buy me a coffee on Ko-fi](https://ko-fi.com/tomvp) ☕
