# RAW File Support — v2.0 Planning Document

*March 2026 — for review before committing to implementation*

---

## Before we start: is this the right feature?

Most astrophotographers who own DSLRs or mirrorless cameras already convert their RAW files to FITS before stacking — via NINA, Sequence Generator Pro, BackyardEOS, or similar. That conversion step is what gives them FITS files in the first place. So a meaningful fraction of the target audience already has FITS files and may never need RAW support.

That said, there is a real segment that skips conversion:
- Imagers who shoot and cull in the field on a laptop before the laptop goes home
- Users of apps like N.I.N.A. that can save directly as FITS *or* RAW depending on settings
- Newcomers who shoot RAW without knowing there's a FITS step

**Recommendation before coding anything**: survey existing users (Ko-fi supporters, any forum mentions of FITS Blaster) to quantify actual demand. If the answer is "almost nobody needs it", a simpler path is a **drag-and-drop FITS converter** that converts RAW→FITS as a preprocessing step, keeping the core app focused.

If the survey answer is positive, proceed with the plan below.

---

## Scope of v2.0

RAW support for the three most common manufacturer formats in astrophotography:

| Priority | Format | Cameras | Notes |
|---|---|---|---|
| 1 | DNG | Any (conversion format) | TIFF-based, open spec, easiest |
| 2 | Canon CR2 | Rebel, EOS series | TIFF-based, well-documented |
| 3 | Nikon NEF | D-series, Z-series | TIFF-based, similar to CR2 |
| 4 | Canon CR3 | R-series (modern) | HEIF container — much harder |
| 5 | Fujifilm RAF | X-series | Proprietary binary + X-Trans pattern |

Fuji X-Trans is a 6×6 non-Bayer CFA. The star measurement pipeline assumes a 2×2 Bayer grid; handling X-Trans correctly would require a separate code path. Treat it as out of scope for v2.0.

CR3 uses a HEIF container (ISO 23008-12) rather than TIFF, which requires either a custom HEIF parser or a third-party library. Out of scope for v2.0.

**v2.0 target: DNG + CR2 + NEF** — covers the vast majority of astrophotography DSLRs.

---

## The big technical constraint

The CLAUDE.md rule says **no third-party frameworks**. This matters a lot for RAW support.

The gold-standard library for RAW decoding is **libraw** (open source, C++). It gives direct access to raw Bayer sensor data before any processing — exactly what you need for accurate star measurement. Without it, the options are:

### Option A — Apple CoreImage (`CIRAWFilter`)

macOS has built-in RAW decoding via CoreImage. It handles Canon, Nikon, Sony, Fuji, and ~800 other camera models natively using Apple-maintained decode tables.

**What you get:**
- A fully demosaiced, white-balanced, linear `CIImage` (Apple's "raw" output with noise reduction disabled and boost at minimum)
- Pixel data suitable for display and approximate star measurement
- No parsing code to maintain

**What you don't get:**
- The actual Bayer sensor values before demosaicing
- Access to the camera's embedded preview JPEG for fast thumbnail generation
- Guaranteed pixel-accurate agreement with tools like PixInsight (which uses libraw)

**FWHM accuracy impact:** Apple's RAW pipeline applies at minimum: hot-pixel suppression, lens distortion correction (on some bodies), and linear demosaicing. These are subtle but they soften the PSF slightly. Empirical tests would be needed, but expect FWHM values to agree with PixInsight within ~15–20% rather than the current ~10%. For *relative* ranking within a session this is still fine. For absolute calibration against external tools, it's a documented caveat.

**Performance:** `CIRAWFilter` is GPU-accelerated and fast on M1. A 24 MP CR2 decodes in roughly 80–150 ms on M1 Air, which is comparable to the current FITS GPU path.

### Option B — libraw (third-party, violates constraint)

Provides Bayer-level access, accurate PSF, identical pixel values to PixInsight. But requires bundling a C++ library, handling build system changes (Swift Package Manager or XCFramework), and ongoing maintenance as libraw releases updates. This is the "right" answer for a serious quality tool, but it's a policy decision, not just an engineering one.

**Recommendation:** Start with Option A (CoreImage) for v2.0. Document the FWHM accuracy caveat clearly in the FAQ. Revisit Option B in v2.1 if users report meaningful metric discrepancies.

If the no-third-party rule is relaxed, libraw integration is well-understood: it ships as a Swift Package and the bridging is ~200 lines of C wrapper code.

---

## Architecture changes

The current pipeline is:

```
FITSReader → float buffer → ImageStretcher → CGImage → MetricsCalculator → FrameMetrics
```

For RAW the equivalent would be:

```
RAWReader → float buffer → ImageStretcher → CGImage → MetricsCalculator → FrameMetrics
```

The goal is to drop a `RAWReader` in at the front and reuse everything downstream unchanged.

### What changes and what stays the same

| Component | Change required |
|---|---|
| `FITSReader.swift` | None |
| `ImageStretcher.swift` | Likely none — already handles Bayer float data |
| `MetricsCalculator.swift` | Likely none — operates on float buffer; slight accuracy caveat |
| `ImageStore.processParallel()` | Small — call format detector, route to correct reader |
| `ImageStore.collectFITSURLs()` | Rename + extend to include RAW extensions |
| `ImageEntry.swift` | Add optional EXIF fields (ISO, exposure time, focal length) |
| `FilterGroup.swift` | Add filename-based heuristic for filter inference |
| `AppSettings.swift` | Optional toggle to show/hide RAW files |
| `FitsBlasterApp.swift` | Expand `CFBundleDocumentTypes` in Info.plist |

### New files

**`RAWReader.swift`** — mirrors `FITSReader` API:
```swift
enum RAWReadResult {
    case success(buffer: MTLBuffer, metadata: RAWMetadata)
    case fallback(pixels: [Float], metadata: RAWMetadata)  // CPU path
    case failure(Error)
}

struct RAWMetadata {
    let width: Int
    let height: Int
    let bayerPattern: BayerPattern
    let iso: Int?
    let exposureTime: Double?
    let focalLength: Double?
    let cameraModel: String?
    let captureDate: Date?
}

struct RAWReader {
    static func peekFormat(url: URL) -> ImageFormat?          // cheap pre-flight check
    static func readIntoBuffer(url: URL, device: MTLDevice) async -> RAWReadResult  // GPU path
    static func read(url: URL) async -> RAWReadResult         // CPU fallback
}
```

**`ImageFormatDetector.swift`** — routes files to the correct reader:
```swift
enum ImageFormat {
    case fits
    case raw(RawSubformat)
}

enum RawSubformat {
    case dng, cr2, nef  // v2.0
    // cr3, raf, arw, pef  // future
}

struct ImageFormatDetector {
    static func detect(url: URL) -> ImageFormat?
    static var supportedExtensions: Set<String>  // ["fits","fit","fts","dng","cr2","nef"]
}
```

### `ImageEntry` additions

```swift
// New optional fields — no breaking change
var exifISO: Int?          = nil
var exifExposure: Double?  = nil   // seconds
var exifFocalLength: Double? = nil
var cameraModel: String?   = nil
var imageFormat: ImageFormat = .fits  // for display in inspector
```

---

## Filter group handling for RAW files

FITS files carry a `FILTER` header (e.g., "Ha", "OIII", "L"). RAW files have no equivalent — the filter is physical and not recorded in EXIF.

Options, in order of preference:

1. **Filename heuristic** (zero friction): scan the filename for common filter abbreviations (`_Ha_`, `_L_`, `_R_`, `_G_`, `_B_`, `_OSC_`, etc.) and assign the group automatically. Works for structured capture software naming conventions.

2. **User assignment at open time**: when loading a folder that contains RAW files, show a one-line picker at the top of the open sheet: "Assign filter to RAW files: [dropdown]". Affects the entire folder load; stored in `AppSettings` per folder bookmark.

3. **Default to `.unfiltered`**: display all RAW files in an "Unfiltered" group with a neutral colour. Simple, never wrong, but loses the per-filter quality comparison.

Implement all three in priority order — 1 first, fall back to 3 if heuristic finds nothing.

---

## The naming question

The app is called **FITS Blaster**. If RAW support lands, the name becomes slightly misleading. Options:

- Keep "FITS Blaster" and describe it as "astrophotography image culling" (already the tagline). RAW support is a feature, not the identity.
- Rename to something format-agnostic like "Astrophoto Blaster" or "Frame Blaster" — costs App Store SEO.

Recommendation: keep the name, update the tagline on the website: *"Fast, focused image culling for astrophotographers on Mac — FITS, CR2, NEF, DNG."*

---

## Implementation order

### Phase 1 — DNG only (~2–3 sessions)

1. Write `ImageFormatDetector` (extension routing only, no TIFF parsing yet)
2. Write `RAWReader` using `CIRAWFilter` to produce a linear demosaiced float buffer
3. Wire into `ImageStore.processParallel()` with format detection before reader selection
4. Add EXIF fields to `ImageEntry` and display them in the inspector
5. Expand file open panel and drag-drop to accept `.dng`
6. Test with real DNG files from a Canon R-series, Nikon Z-series, and Sony A7-series (DNG from all three)
7. Document FWHM accuracy caveat in the FAQ

### Phase 2 — CR2 + NEF (~1–2 sessions)

1. Add `.cr2` and `.nef` to `ImageFormatDetector`
2. Validate that CoreImage handles both without format-specific code (it should)
3. Test FWHM agreement with PixInsight on same files
4. Add filter heuristic for filename-based filter group detection

### Phase 3 (future) — accuracy upgrade

If user feedback reveals metric discrepancies that matter:
- Evaluate libraw integration (requires relaxing the no-third-party rule)
- OR write a minimal CR2/NEF TIFF parser that extracts raw Bayer data without libraw

---

## Open questions before starting

1. **User demand**: Is there measurable demand, or is this a solution looking for a problem? Check Ko-fi comments, any user feedback channels.

2. **Third-party rule**: Is there appetite to include libraw as a Swift Package dependency for v2.0? It changes the accuracy story significantly. If yes, replace `CIRAWFilter` with libraw from the start rather than switching later.

3. **Scope of metrics in RAW mode**: Should the inspector show ISO/exposure/focal length for RAW files? These are useful for culling (e.g., "that frame had ISO 1600, not 800") but require inspector UI changes.

4. **Star count reliability on RAW**: DSLR sensors have more hot pixels and fixed-pattern noise than cooled astro cameras. The star detection thresholds may need per-format tuning to avoid false positives. Worth profiling before shipping.

5. **App Store implications**: If/when the app goes to the App Store, the DNG/RAW entitlement requirements should be verified — no special entitlements are needed to read RAW via CoreImage, but worth checking.
