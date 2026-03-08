# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Claude FITS Viewer** is a native macOS app for culling and inspecting FITS (Flexible Image Transport System) astronomical image files. It measures image quality metrics (FWHM, eccentricity, SNR, star count) and lets the user reject bad frames. UI responsiveness and throughput on large image sets are the primary design goals.

## Build & Run

Open `Claude FITS viewer.xcodeproj` in Xcode and build with `Cmd+B` or run with `Cmd+R`. There is no CLI build command. There are currently no unit tests.

## Hard constraints — read these before writing any code

### Images are read-only
Pixel data is **never modified**. `FITSReader` loads raw pixels into a buffer and hands them off; no code downstream should mutate pixel values in place (BSCALE/BZERO is applied once at load time into a separate float buffer). Do not add any write path to `FITSReader`.

### Integer FITS only (BITPIX 8, 16, 32)
Float formats (BITPIX −32, −64) are explicitly rejected with a user-visible error at parse time. Do not add support for them. All pixel arithmetic assumes integer source data; BSCALE is always 1.0 by FITS convention, so use `vDSP_vsadd` (not `vDSP_vsmsa`) for BZERO application.

### UI speed is the top priority
- The main thread must never block on I/O, pixel decoding, or metrics computation.
- Prefer pre-computed, cached values (e.g. `groupStatistics`, `cachedSortedEntries`) over computed properties that re-derive results on every SwiftUI render pass.
- Any O(n) or heavier operation triggered by a UI interaction must run off the main actor.
- Avoid allocations in hot paths (inner loops over pixels, per-frame metric calculations).

### Parallelism and concurrency
- The loading pipeline is intentionally concurrent: multiple images are decoded and stretched in parallel. Preserve this structure when making changes.
- Use `Task(priority: .utility)` for background metric work; use a semaphore or task group to cap concurrency at `max(2, CPU_cores/2)`.
- Never introduce `await` on the main actor inside a loop that processes all entries — batch the work first, then update the UI once.

### Use Metal for pixel-scale work
If an operation touches every pixel of a 16 MP+ image (stretching, local-maximum detection, histogram), it must use the GPU path via `FITSStretch.metal`. Fall back to Accelerate (vDSP/vImage) only when Metal is unavailable. Do not write scalar Swift loops over pixel arrays.

## Architecture

**`FITSReader`** — Parses FITS headers (80-character cards in 2880-byte blocks) and pixel data. Two read paths:
- `readIntoBuffer(url:device:)` — zero-copy: writes converted floats directly into a `MTLBuffer` (GPU path)
- `read(url:)` — returns a `[Float]` array (CPU fallback only)

**`ImageStretcher`** — Renders images using percentile clipping (0.1%/99.9%) + gamma stretch:
- GPU path: `sqrtStretch` Metal compute kernel; output buffer fed directly to `CGDataProvider` (zero-copy)
- CPU path: Accelerate LUT interpolation + vImage vertical flip + optional downscaling

**`MetricsCalculator`** — Measures star quality from raw pixel data. GPU-accelerates local-maximum detection (`detectLocalMaxima` Metal kernel). CPU measures FWHM, eccentricity, SNR, and star count via sequential Moffat fits on the top candidates.

**`ImageStore`** — `@Observable @MainActor` class managing the image collection. Triple-buffered concurrent pipeline: Stage 1 (FITS I/O) → Stage 2 (GPU stretch) → Stage 3 (CGImage). Stores `groupStatistics` as a **stored property** updated only at batch boundaries — never recompute it inline.

**`ContentView`** — `HSplitView`: thumbnail sidebar (left, ~160 px) + main image viewer + session chart + inspector (right). Key bindings are user-configurable via `AppSettings` and recorded in Settings → Keyboard.

## Key Details

- FITS rows are stored bottom-to-top; vertical flip is performed in the Metal shader / CPU path.
- Display images are downscaled to 1024 px max; thumbnails to 120 px max.
- The app is sandboxed — access to directories not directly opened by the user requires security-scoped bookmarks stored on `ImageEntry.directoryBookmark`.
- File rejection moves images to a `REJECTED/` subdirectory; undo moves them back and removes the directory if empty.
- Supported extensions: `.fits`, `.fit`, `.fts`
- No third-party dependencies — only Apple frameworks: SwiftUI, Metal, Accelerate, AppKit, Foundation, UniformTypeIdentifiers.

## Commit workflow

When the user asks to commit (or says "done", "wrap up", etc.), always do these steps in order:

1. **Update `CHANGELOG.md`** — prepend a new `## <date> — <short title>` section describing what changed (Added / Fixed / Improved / Removed). Commit the changelog together with the code changes, or as a follow-up commit in the same session.
2. **Commit** all meaningful source changes with a detailed message.
3. **Propose a version bump** — patch for fixes/perf, minor for new features — and apply it once the user confirms: update both `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` (= `git rev-list --count HEAD`) in `project.pbxproj`, commit `"Bump version to X.Y (build N)"`, and tag `vX.Y`.

Do NOT commit: `.claude/settings.local.json`, `Simple Claude fits viewer.xcodeproj/` (duplicate project folder).
