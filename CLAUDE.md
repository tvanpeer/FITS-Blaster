# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

**Simple Claude fits viewer** is a native macOS app for viewing FITS (Flexible Image Transport System) astronomical image files. It uses Metal for GPU-accelerated image stretching and the Accelerate framework for vectorized CPU fallback.

## Build & Run

Open `Simple Claude fits viewer.xcodeproj` in Xcode and build with `Cmd+B` or run with `Cmd+R`. There is no CLI build command. There are currently no unit tests.

## Architecture

The app has a clear data flow pipeline with four main components:

**`FITSReader`** — Parses FITS file headers (80-character cards in 2880-byte blocks) and pixel data. Supports BITPIX 8/16/32/-32/-64. Has two read paths:
- `readIntoBuffer(...)` — writes float pixels directly into a Metal shared buffer (zero-copy, used for GPU path)
- `read(...)` — returns a `[Float]` array (CPU fallback)

**`ImageStretcher`** — Renders images using percentile clipping (0.1%/99.9%) + power-law gamma stretch:
- GPU path: dispatches `FITSStretch.metal` compute shader, output `MTLBuffer` fed directly to `CGDataProvider` (zero-copy)
- CPU path: Accelerate-based vectorized LUT interpolation, byte-swap, vertical flip, and optional downscaling

**`ImageStore`** — `@Observable @MainActor` class managing the image collection. Runs a triple-buffered concurrent pipeline (Stage 1: FITS I/O → Stage 2: GPU stretch → Stage 3: CGImage creation) using a GCD `DispatchQueue` with a semaphore capped at `max(2, CPU_cores/2)`. Each `ImageEntry` keeps the full `CGImage` in memory for fast switching.

**`ContentView`** — `HSplitView` with a thumbnail sidebar (left, ~160px) and main image viewer (right). Navigation: ↑/↓ arrows, `Cmd+O` (open folder), `Cmd+Shift+O` (open files), `X` (reject), `U` (undo reject). File rejection moves files to a `REJECTED/` subdirectory using security-scoped bookmarks.

## Key Details

- FITS images are stored bottom-to-top; the reader/shader performs a vertical flip before display.
- Images are downscaled to 1024px max dimension for display; thumbnails are capped at 120px.
- The app is sandboxed — file access beyond the user's selection requires security-scoped bookmarks stored on `ImageEntry.directoryBookmark`.
- Supported extensions: `.fits`, `.fit`, `.fts`
- No third-party dependencies; only Apple frameworks (SwiftUI, Metal, Accelerate, AppKit, Foundation, UniformTypeIdentifiers).
