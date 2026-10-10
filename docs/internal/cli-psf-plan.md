# CLI Mode + PSF Autoflag — Implementation Plan

**Date**: 2026-10-10  
**Status**: Planned — not started

---

## Overview

Two features shipped together:

- **PSF autoflag** — adds PSF signal weight as a rejection criterion to the existing auto-flag sheet (app-wide). Spotted as a gap while designing the CLI flags.
- **CLI batch mode** — the same app binary, called from a terminal with a folder path, processes all FITS files headlessly and writes a CSV export. No windows, no dock icon.

They are independent but scheduled together because the CLI needs a complete `AutoRejectConfig` to be useful.

---

## Part A — PSF Autoflag

Three files change. PSF signal weight is higher = better (like SNR), so it follows the SNR pattern: reject if value falls below a threshold.

### A1. `AutoRejectSheet.swift` — extend `AutoRejectConfig`

Add after the sky background block:

```swift
// PSF signal weight (higher = better)
var usePSF: Bool = false
var psfMultiplier: Double = 0.5        // relative: reject if PSF < multiplier × group median
var absolutePSFFloor: Double = 1.0     // absolute: reject if PSF < floor — calibrate before shipping
```

`usePSF` defaults off (opt-in, same as sky background). The absolute floor of 1.0 is a placeholder — needs calibration against real session data (see Risks).

### A2. `AutoRejectSheet.swift` — add `PSFSection` view

New private struct following the `SNRSection` pattern exactly:
- Relative mode: slider for multiplier in 0.1–0.9, step 0.05
- Absolute mode: slider for floor value in 0.1–10.0, step 0.1

Insert `PSFSection(config: $config)` between `SkyBackgroundSection` and the `if config.mode == .absolute` score guard in `AutoRejectSheet.body`.

### A3. `ImageStoreFileOperations.swift` — extend `previewAutoReject`

In the `.relative` branch, after the sky background check:

```swift
if config.usePSF, let psf = m.psfSignalWeight, let medPSF = gs?.medianPSFSignalWeight,
   Double(psf) < Double(medPSF) * config.psfMultiplier { return true }
```

In the `.absolute` branch, after the sky background check:

```swift
if config.usePSF, let psf = m.psfSignalWeight,
   Double(psf) < config.absolutePSFFloor { return true }
```

`FrameMetrics.psfSignalWeight` (`Float?`) and `GroupStats.medianPSFSignalWeight` (`Float?`) both already exist — no model changes needed.

---

## Part B — CLI Mode

### Architecture decision: `main.swift` + remove `@main`

**The problem:** `FitsBlasterApp` is `@main`. Overriding `static func main()` and calling `NSApplicationMain` in the non-CLI branch is unsafe — `NSApplicationMain` alone does not replicate SwiftUI's lifecycle (which uses internal `_AppDelegate` machinery).

**The solution:** Remove `@main` from `FitsBlasterApp` and add `main.swift`. When Xcode sees `main.swift` it uses it as the program entry point. The non-CLI branch calls `FitsBlasterApp.main()` — the `App` protocol extension method, which correctly bootstraps the full SwiftUI lifecycle with no private API.

### B1. `FitsBlasterApp.swift`

Remove the `@main` attribute. No other changes.

### B2. `main.swift` (new file)

```swift
//  main.swift
//  FITS Blaster

import Foundation
import AppKit

// CLI mode is triggered when any argument starts with /, ~ or --.
// Single-dash system args (-NSDocumentRevisionsDebugMode, etc.) are never matched.
private func isCLIArg(_ s: String) -> Bool {
    s.hasPrefix("/") || s.hasPrefix("~") || s.hasPrefix("--")
}

let headless = CommandLine.arguments.dropFirst().contains(where: isCLIArg)

if headless {
    Task { @MainActor in
        await CLIRunner.run()
        exit(0)
    }
    RunLoop.main.run()   // blocks; exit(0) inside the task terminates the process
} else {
    FitsBlasterApp.main()
}
```

### B3. `ImageStore.swift` — add `waitForProcessing() async`

`processingTask` (line 251) is internal. Add near its declaration:

```swift
func waitForProcessing() async {
    await processingTask?.value
}
```

The CLI calls this immediately after `openFiles` to block until all metrics are computed.

### B4. `CLIRunner.swift` (new file)

Headless orchestrator. Key design decisions:

- All autoflag criteria default **off**; passing any threshold implicitly enables that criterion.
- Two-pass argument parsing: resolve `--mode` first, then assign metric values to the correct field for that mode.
- Default header keys come from `AppSettings().exportHeaderKeys` — UserDefaults-backed, so a user who has customised their columns in the app gets the same defaults in the CLI.
- Progress → stderr. Final CSV path → stdout (enables scripting: `path=$(app /folder)`).
- Exit codes: 0 success, 1 usage/no-files error, 2 write error.
- `collectFITSURLs` is `nonisolated static` — called directly.
- Replicate the `rejectedURLs` Set-building logic from `openFolderPanel` (lines 686–691 of `ImageStoreFileOperations.swift`) to identify files in a `REJECTED` subfolder.

**CLI interface:**

```
FITS Blaster.app/Contents/MacOS/FITS Blaster <folder> [options]

  --output <path>             CSV output  [default: <folder>/frames.csv]
  --subfolders                Include files from subfolders
  --include-rejected          Include REJECTED folder; mark those files as rejected

  --mode rel|abs              Autoflag threshold mode  [default: relative]
  --fwhm <n>                  FWHM multiplier (rel) or pixel ceiling (abs)
  --eccentricity <n>          Eccentricity ceiling  [same in both modes]
  --stars <n>                 Star count multiplier (rel) or floor (abs)
  --snr <n>                   SNR multiplier (rel) or floor (abs)
  --sky-bg <n>                Sky BG multiplier (rel) or ADU ceiling (abs)
  --psf <n>                   PSF signal weight multiplier (rel) or floor (abs)
  --score <n>                 Quality score floor  [absolute mode only]
  --no-flag                   Export without autoflagging

  --path-style rel|abs        Path format in CSV  [default: relative]
  --headers KEY1,KEY2,...     FITS header columns  [default: app defaults]
  --include-rejected-in-csv   Include rejected entries in the CSV

  --help                      Show this help
```

**What the pipeline does (no new code needed):** `openFiles` runs the full metrics pipeline — Metal star detection, FWHM, SNR, PSF — identical to the UI app. `displayImage` and `thumbnail` are set in memory but immediately garbage-collectable since the CLI never reads them. Peak memory for ~500 frames at 1024 px is ~500 MB — acceptable for a batch tool. A `headless: Bool` / `skipImages` optimisation can follow later if this proves a problem.

---

## Implementation Order

1. **PSF autoflag (A1–A3)** — self-contained; builds and tests independently. Add a `FlagVisibilityTests` PSF case while touching those files.
2. **`waitForProcessing()` (B3)** — one method, no risk; same commit as step 1 or its own.
3. **`CLIRunner.swift` (B4)** — new file, no changes to existing code; safe to iterate on.
4. **`main.swift` + remove `@main` (B1–B2)** — last, highest risk to the app launch path. Verify GUI launch works normally before committing.

---

## File Summary

| File | Change |
| --- | --- |
| `FITS Blaster/AutoRejectSheet.swift` | Add PSF fields to `AutoRejectConfig`; add `PSFSection`; insert in sheet body |
| `FITS Blaster/ImageStoreFileOperations.swift` | Add PSF checks to `previewAutoReject` (+2 lines) |
| `FITS Blaster/ImageStore.swift` | Add `waitForProcessing() async` |
| `FITS Blaster/FitsBlasterApp.swift` | Remove `@main` attribute |
| `FITS Blaster/main.swift` | New — dispatch CLI or normal launch |
| `FITS Blaster/CLIRunner.swift` | New — headless orchestration (~150 lines) |
| `FITS Blaster Tests/FlagVisibilityTests.swift` | Add PSF autoflag test |
| `CHANGELOG.md` | Two entries |

**Net new code:** ~280 lines.

---

## Risks and Open Questions

1. **`FitsBlasterApp.main()` without `@main` (highest risk)** — The `App` protocol extension's `main()` should correctly start the SwiftUI lifecycle, but this code path has never been exercised. Verify in a test build that the app launches, shows its window, and Sparkle updates work before the final commit. If it fails, fallback: set `LSUIElement = YES` in Info.plist when headless, keep `@main`, and use the init() + `.prohibited` activation policy approach instead.

2. **PSF absolute floor default (1.0)** — The right value depends on actual PSF signal weight magnitudes from real sessions. Check `MetricsCalculator+Scoring.swift` for the scale, and validate against the benchmark datasets before shipping. Mark the field with a `// calibrate` comment for now.

3. **UserDefaults-backed header key defaults** — The CLI reads `AppSettings().exportHeaderKeys` which goes to UserDefaults under the app's bundle ID. This should work when the binary is invoked directly. Verify that the defaults (`OBJECT, DATE-OBS, EXPTIME, FILTER, GAIN, OFFSET, CCD-TEMP, FOCUSPOS, AIRMASS, OBJCTALT, AMBTEMP, HUMIDITY`) appear correctly when UserDefaults has no saved value.

4. **`--score` in relative mode** — Score is an absolute value (0–100); it has no meaningful "× group median" interpretation. The UI already gates score to absolute mode only. The CLI should print a warning and ignore `--score` when `--mode rel` is active.
