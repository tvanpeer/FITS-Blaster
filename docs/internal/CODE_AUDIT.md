# FITS Blaster Code Audit

Generated 2026-10-17 on branch `colour-fix` (head `9780ac9`). Scope: 85 Swift files (~15,500 lines) and 1 Metal file across the app, the two Quick Look extensions (`FITSBlasterQL`, `FITSBlasterQLThumb`), the test target and `scripts/`. Excluded: `build/`, `bin/`, `site/`, test result folders.

Method: the `ios-code-audit` skill, adapted to a macOS + Metal + FITS app. A clean Debug build captured compiler warnings (0 Swift warnings; 4 more with `SWIFT_STRICT_CONCURRENCY=complete`). Three read-only agents covered concurrency/API, dead code/duplication, and bugs/security/performance; SwiftUI Pro did the SwiftUI pass. Every High finding was checked against the code by hand. Four were also reproduced: Quick Look on the `fb-15` VM (macOS 15.8.1), and three malformed FITS files run through the Debug CLI. Two agent claims were disproved and dropped (see §12).

Findings cite `path:line`, relative to the repo root. No code was changed. "Plan step N" refers to the master plan, [architecture-plan.md](architecture-plan.md), which assigns every finding here to exactly one step (table "Finding → step"); [concurrency-fixes-plan.md](concurrency-fixes-plan.md) holds the detailed design for plan steps 6 and 7.

---

## 1. Executive summary

1. **[High] Quick Look doesn't work on macOS 15.6–26.1** — §5.1 — `FITS Blaster.xcodeproj/project.pbxproj` (extensions inherit `MACOSX_DEPLOYMENT_TARGET = 26.2`). Reproduced on `fb-15`.
2. **[High] A malformed FITS header crashes the app and the Quick Look extensions** — §5.2 — `FITS Blaster/FITSReader.swift:203-237`. Reproduced (negative and huge NAXIS).
3. **[High] Frames with no detected stars get no metrics, so Auto-Flag and the CLI filters never reject them** — §5.4 — `FITS Blaster/MetricsCalculator.swift:188, 429`.
4. **[High] Keyboard shortcuts act on the main window while you type in Settings** — §5.5 — `FITS Blaster/ContentView.swift:154-203`.
5. **[High] Overlapping batches and stale colour renders** (already planned) — §3.1, §3.2 — `FITS Blaster/ImageStorePipeline.swift:50, 163, 211, 284, 528`.
6. **[High] Four warnings that become errors in Swift 6 mode** (already planned) — §3.3.
7. **[Medium] Undo of a rejection can delete hidden files in REJECTED** — §5.6 — `FITS Blaster/ImageStoreFileOperations.swift:238-244`.
8. **[Medium] Session chart cuts off frames and maps taps to the wrong frame** — §5.9 — `FITS Blaster/SessionChartView.swift:301`.
9. **[Medium] CLI treats `-o /path` as the folder** — §5.10 — `FITS Blaster/CLIRunner.swift:34-45`. Reproduced.
10. **[Medium] About 400 lines of dead code**, including a whole unused star pipeline — §9.1.

---

## 2. Quick wins (≤30 min each)

- **Set `MACOSX_DEPLOYMENT_TARGET = 15.6` on both Quick Look targets** (all configurations), then check `LSMinimumSystemVersion` in the built `.appex` — §5.1.
- **Use `chartEntries.count` for the chart's x-domain** — `FITS Blaster/SessionChartView.swift:301` — §5.9.
- **Check for an empty REJECTED folder without skipping hidden files** — `FITS Blaster/ImageStoreFileOperations.swift:239-240` — §5.6.
- **Show export write errors** instead of `try?` — `FITS Blaster/ImageStoreFileOperations.swift:278` — §5.7.
- **Only handle key events from the main window** in the key monitor — `FITS Blaster/ContentView.swift:155-160` — §5.5.
- **Register the tooltip delay as a default** instead of writing it on every launch — `FITS Blaster/FitsBlasterApp.swift:58-62` — §4.7.
- **Delete verified dead code** — §9.1 (no behaviour change).
- **Replace `Binding(get:set:)` with `$settings.exportHeaderKeys`** — `FITS Blaster/ExportSettingsTab.swift:54-57` — §8.4.
- **Fix the 17 stale comments** — §9.13.

---

## 3. Concurrency

### 3.1 New batch replaces `processingTask` without waiting or cancelling; Reset doesn't cancel
- **Location:** `FITS Blaster/ImageStorePipeline.swift:50, 163, 211, 284`; `FITS Blaster/ImageStore.swift:473-505`; `FITS Blaster/FITSToolbar.swift:51-54`
- **What:** Opening or dropping a second folder, changing sizes in Settings, or pressing Reset during a load starts or clears work without stopping the running batch. The first batch to finish clears the busy state.
- **Why:** The progress bars disappear and Cancel greys out while work is still running. After Reset during Phase 0, the old load can add its entries to the "empty" session.
- **Action:** Plan step 6 (`LoadPipeline.enqueueBatch`), with `reset()` calling `cancelProcessing()`.
- **Severity:** High

### 3.2 Colour and grey re-renders are untracked and can overwrite a newer view
- **Location:** `FITS Blaster/ImageStorePipeline.swift:453-458, 528-666, 747-811`
- **What:** `recolorImages` starts an unstored `Task`, and per-folder colour renders are unstructured `Task`s. Turning colour on during a load misses frames whose headers aren't loaded yet.
- **Why:** The screen can stay in colour while the setting is grey, and some frames can stay grey after turning colour on.
- **Action:** Plan step 6 (design in the concurrency plan, steps 1–2) (render generation, re-renders as queued batches).
- **Severity:** High

### 3.3 Four strict-concurrency warnings (errors in Swift 6 mode)
- **Location:** `FITS Blaster/ImageStorePipeline.swift:423`; `FITS Blaster/ContentSplitLayout.swift:47`; `FITS Blaster/MetricsCalculator.swift:474, 545`
- **What:** `FastLoadResult` (holds a non-Sendable `MTLBuffer`) is sent to the main actor and also used by Phase B; `NSItemProvider` is captured by task-group children; an `UnsafeBufferPointer` is captured by child tasks.
- **Why:** These block a move to Swift 6 mode. The first two are theoretical races today.
- **Action:** Plan step 7 (concurrency plan step 3).
- **Severity:** High

### 3.4 `AsyncSemaphore.wait` ignores cancellation; Phase B starts after Cancel
- **Location:** `FITS Blaster/ImageStorePipeline.swift:466-487, 976-998`
- **What:** Waiters are never resumed on cancellation, and nothing checks `Task.isCancelled` after a slot is acquired.
- **Why:** After Cancel, waiting frames still run full GPU detection and Moffat fitting one by one, keeping MTLBuffers alive.
- **Action:** Make the semaphore cancellation-aware and check cancellation before starting Phase B. Plan step 6.
- **Severity:** Medium

### 3.5 Concurrency limits multiply, so live full-frame buffers are not bounded
- **Location:** `FITS Blaster/ImageStorePipeline.swift:688-700` with `708-737` (grey normalisation); `453-458`, `555-617` with `776-810` (colour)
- **What:** Each (folder, filter) group and each folder colour render gets its own `cores - 2` limit, and they overlap Phase A and Phase B.
- **Why:** With many folders or filters, groups × (cores − 2) full-resolution float buffers can be in flight at once. That is a memory spike on 8–16 GB Macs.
- **Action:** Use one shared limiter for all re-read and render work (plan step 6).
- **Severity:** Medium

### 3.6 Security-scoped access is stopped before late work finishes
- **Location:** `FITS Blaster/ImageStorePipeline.swift:163-176, 211-233, 284-330` (early `guard let self else { return }` at 164, 212, 285)
- **What:** Directory scopes are stopped when `processParallel` returns. On Cancel, colour tasks and CPU-fallback reads still run. The `guard let self` early returns skip the stop.
- **Why:** In the sandboxed App Store build, late renders fail silently. Scopes can leak.
- **Action:** Stop in a `defer` placed before any return, after all spawned work has ended.
- **Severity:** Low

### 3.7 Blocking file reads on the cooperative thread pool
- **Location:** `FITS Blaster/FITSReader.swift:85-101, 253-258, 371, 466`; called from `FITS Blaster/ImageStorePipeline.swift:390, 586-596, 636-641, 715-720, 819-823, 841-849`
- **What:** `Data(contentsOf:)` and `FileHandle.read` run synchronously in up to `max(8, cores)` concurrent tasks.
- **Why:** On slow or network disks, every pool thread can sit blocked in `read()`, starving Phase B and other async work.
- **Action:** Keep blocking reads below the pool width, or read on a dedicated thread.
- **Severity:** Low

### 3.8 Thousands of tiny child tasks per frame for star counting
- **Location:** `FITS Blaster/MetricsCalculator.swift:537-555` (and the dead copy at `367-385`)
- **What:** Up to 6,000 `addTask` calls per frame, each a microsecond-scale FWHM check, 4 at a time.
- **Why:** Task overhead is larger than the work and adds contention when several frames run Phase B together.
- **Action:** Split into 4 chunked tasks that each loop over a slice. Check the effect with `BenchmarkTests`.
- **Severity:** Low

### 3.9 Rejecting a frame while its re-renders are queued
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:84-97`; `FITS Blaster/ImageStorePipeline.swift:414, 583, 635, 713, 789`
- **What:** Pipeline tasks capture `entry.url` when queued; rejecting moves the file and changes `entry.url`.
- **Why:** Queued renders for that frame fail silently (`try?`), leaving a stale or missing render.
- **Action:** Read `entry.url` on the main actor right before the file read, or disable reject while a frame is processing.
- **Severity:** Low

### 3.10 Pointer used after `withUnsafeBufferPointer` returns
- **Location:** `FITS Blaster/MetricsCalculator.swift:209-212`
- **What:** `baseAddress` escapes the closure and is used across suspension points (CPU fallback only).
- **Why:** Undefined behaviour by Swift's rules. It works today.
- **Action:** Plan step 7 (concurrency plan step 4).
- **Severity:** Low

### 3.11 Project compiles in Swift 5 language mode
- **Location:** `FITS Blaster.xcodeproj/project.pbxproj` (`SWIFT_VERSION = 5.0` in all configurations)
- **What:** CLAUDE.md asks for Swift 6.2 with strict concurrency, but the project uses Swift 5 mode with minimal checking.
- **Why:** Data-race checks that Swift 6 makes errors are silent.
- **Action:** After §3.3, switch to Swift 6 mode (plan step 7, question 3).
- **Severity:** Medium

---

## 4. API modernity

### 4.1 Drop handler uses `NSItemProvider` and continuations
- **Location:** `FITS Blaster/ContentSplitLayout.swift:42-63`
- **What:** `.onDrop(of: [.fileURL])` + `loadObject(ofClass: NSURL.self)` inside a task group; URLs arrive in completion order.
- **Why:** Source of a §3.3 warning, and the dropped-URL order (which picks the bookmark and root name) is not deterministic.
- **Action:** `.dropDestination(for: URL.self)`, after checking sandboxed folder access still works.
- **Severity:** Low

### 4.2 Modal panels with a sleep-based workaround
- **Location:** `FITS Blaster/FITSToolbar.swift:33-41`; `FITS Blaster/ImageStoreFileOperations.swift:261-279, 576-619, 695-708`
- **What:** `runModal()` for open, save and alert, with an unexplained 300 ms `Task.sleep` before the open panel.
- **Why:** Timing-dependent, and the model can't be tested. Plan step 4 moves these out.
- **Action:** Async `begin`/sheet-modal panels, or `.fileImporter`/`.fileExporter`, called from the view.
- **Severity:** Low

### 4.3 FITS `UTType` built from extensions with an any-data fallback
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:700-704`
- **What:** `.init(filenameExtension: "fits") ?? .data`, although Info.plist declares `gov.nasa.gsfc.fits`.
- **Why:** If the lookup fails, the panel accepts any file.
- **Action:** One static `UTType` for FITS, used by panels and drops.
- **Severity:** Low

### 4.4 Path-string and `NSString` APIs; deprecated `lockFocus` in a script
- **Location:** `FITS Blaster/CLIRunner.swift:47-53, 245, 281`; `FITS Blaster/ImageStoreFileOperations.swift:90, 645-646, 681`; `scripts/make-dmg-background.swift:15-19, 90, 97`
- **What:** `expandingTildeInPath`, `fileExists(atPath:isDirectory:)` with `ObjCBool`, `NSImage.lockFocus`.
- **Why:** Legacy APIs where URL-based ones exist; `lockFocus` is discouraged.
- **Action:** URL resource values, `URL.homeDirectory`, `NSImage(size:flipped:drawingHandler:)`.
- **Severity:** Low

### 4.5 Device-dependent colour spaces
- **Location:** `FITS Blaster/ImageStretcher.swift:309, 336, 433, 575, 661`; `FITS Blaster/RenderedPixels.swift:44`
- **What:** `CGColorSpaceCreateDeviceGray()` / `DeviceRGB()`.
- **Why:** Not colour-managed, so frames can look different on different displays. Changing this changes the rendered pixels, so the render tests and baselines would need a planned update.
- **Action:** Named sRGB / generic grey spaces, decided together with the render-test targets.
- **Severity:** Low

### 4.6 Sparkle delegate isolation implicit; update button ignores `canCheckForUpdates`
- **Location:** `FITS Blaster/UpdaterDelegate.swift:15-26`; `FITS Blaster/MenuCommands.swift:171-179`; key string also at `FITS Blaster/AppSettings.swift:143-147`
- **What:** The delegate is inferred `@MainActor` from Sparkle's header while its comment says otherwise; the `"useBetaUpdateChannel"` key is written out twice; the menu item stays enabled during a check.
- **Why:** A misleading comment and a duplicated key that can drift.
- **Action:** Mark `@MainActor` explicitly, share one key constant, bind the button to `canCheckForUpdates`.
- **Severity:** Low

### 4.7 Tooltip delay written to user defaults on every launch
- **Location:** `FITS Blaster/FitsBlasterApp.swift:58-62`
- **What:** `UserDefaults.standard.set(500, forKey: "NSInitialToolTipDelay")` in `App.init`.
- **Why:** Overwrites the value permanently every launch.
- **Action:** `UserDefaults.standard.register(defaults:)`.
- **Severity:** Low

---

## 5. Bugs / logic errors

### 5.1 Quick Look extensions don't register on macOS 15.6–26.1
- **Location:** `FITS Blaster.xcodeproj/project.pbxproj` — the extension configurations have no `MACOSX_DEPLOYMENT_TARGET` and inherit the project-level 26.2; the app target sets 15.6
- **What:** Both `.appex` bundles ship with `LSMinimumSystemVersion = 26.2` (checked in `build/beta` and `build/metric-baselines`).
- **Why:** On macOS 15 and on 26.0–26.1, Finder shows no FITS previews or thumbnails. Reproduced on `fb-15` (15.8.1): after opening the app, `pluginkit` lists neither extension. A copy with the minimum set to 15.6 (re-signed ad hoc) registered both by itself, and a manually registered extension produced a correct M31 thumbnail. So the code runs on 15; only the setting blocks it.
- **Action:** Set 15.6 on both extension targets. Add a smoke-test check that `pluginkit -m -i <id>` finds both extensions on every VM (today it only checks they are in the app).
- **Severity:** High

### 5.2 Malformed FITS sizes crash the app and the Quick Look extensions
- **Location:** `FITS Blaster/FITSReader.swift:203-237` (no range check on NAXIS1/NAXIS2; plain `Int` multiplication at 227-235, also 262, 386); crash sites `FITSReader.swift:290-291, 308-309`, `FITS Blaster/ImageStretcher.swift:399-400, 546`
- **What:** Negative sizes pass the length check (−64 × −64 = 4096) and crash later on a conversion to an unsigned type; huge sizes overflow the multiplication.
- **Why:** One corrupt or crafted file crashes the app and loses the session. In Finder, the Quick Look extensions parse files without any user action. Reproduced with the Debug CLI: NAXIS = −64 → `Fatal error: Negative value is not representable` (exit 133); NAXIS = 2^32 → trap (exit 133).
- **Action:** In the header parser, require 1 ≤ NAXIS1, NAXIS2 ≤ a sane maximum. Do the size math with overflow checks and throw `invalidFormat`. Add malformed-header tests (§5.20).
- **Severity:** High

### 5.3 Non-finite BSCALE/BZERO are not rejected
- **Location:** `FITS Blaster/FITSReader.swift:213-225, 326-344`; `FITS Blaster/MetricsCalculator+Scoring.swift:22-31`; `FITS Blaster/Metric.swift:184, 194`
- **What:** BSCALE/BZERO are applied without checking for overflow to ±Inf; several `Int(Float)` conversions don't check `isFinite`.
- **Why:** An agent reported a crash. Not reproduced: a BSCALE = 1E35 file loaded with exit 0. The values are still nonsense, and an `Int(NaN)` path may exist that this file didn't reach.
- **Action:** Reject non-finite scale values at parse time; guard `Int(...)` conversions of computed floats.
- **Severity:** Low

### 5.4 Frames with no detected stars get no metrics and can't be auto-rejected
- **Location:** `FITS Blaster/MetricsCalculator.swift:188, 429`; `FITS Blaster/ImageStorePipeline.swift:482-485`; `FITS Blaster/ImageStoreFileOperations.swift:167`
- **What:** When detection finds no candidates, `compute` returns `nil` instead of metrics with zero stars. Auto-Flag skips entries with `metrics == nil`.
- **Why:** The worst frames (cloud, dew, cap on) are exempt from Auto-Flag and the CLI filters, and the CLI exports them as kept. `cachedMetrics` stays nil, so every metric toggle re-reads those files. Related to the open "score ignores cloudy frames" item.
- **Action:** Return metrics with star count 0 and a score of 0 when nothing is found; keep `nil` for "not computed / read failed". Add a test with a star-less frame.
- **Severity:** High

### 5.5 Keyboard shortcuts act on the main window from the Settings window
- **Location:** `FITS Blaster/ContentView.swift:154-203`; `FITS Blaster/KeyRecorderView.swift:15-66`
- **What:** The local key monitor handles every keyDown in the app, in any window. Its only guard is "first responder is `NSText`", and the key recorder is a plain `NSView`.
- **Why:** In Settings, pressing a bound key (reject, remove, flag, arrows) acts on the main window's frames. Reject moves a file on disk. Rebinding a shortcut to an already-bound key triggers the action instead of recording it. Verified by reading: a local monitor runs before the view's `keyDown`.
- **Action:** Ignore events whose window isn't the main content window.
- **Severity:** High

### 5.6 Undo of a rejection deletes the REJECTED folder even when it holds hidden files
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:238-244`
- **What:** The empty check uses `.skipsHiddenFiles`, then `removeItem` deletes the folder recursively.
- **Why:** Hidden files the user put there (sidecars, dot-files) are permanently deleted.
- **Action:** Delete only when the folder is truly empty (allowing `.DS_Store`).
- **Severity:** Medium

### 5.7 Export failures are silent
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:278`
- **What:** `try? content.write(...)`.
- **Why:** The user thinks the export worked.
- **Action:** Show the error through `errorMessage` (plan step 4).
- **Severity:** Medium

### 5.8 A file rejected this session loads twice when the folder is reopened with REJECTED
- **Location:** `FITS Blaster/ImageStorePipeline.swift:43, 64-70, 134`
- **What:** Existing entries are matched by `originalURL`, but scanned files by their current path (`…/REJECTED/x.fits`).
- **Why:** Two entries point at one file; acting on one leaves the other pointing at a path that no longer exists.
- **Action:** Match against both `url` and `originalURL`.
- **Severity:** Medium

### 5.9 Session chart x-domain counts points with data, not frames
- **Location:** `FITS Blaster/SessionChartView.swift:42-47, 275-283, 301`
- **What:** Points are placed at their index in `chartEntries`, but the domain ends at `chartPoints.count + 1`.
- **Why:** When some frames have no value (still processing, no stars), the right-most frames fall off the chart and tap/drag maps to the wrong frames.
- **Action:** Use `chartEntries.count + 1`.
- **Severity:** Medium

### 5.10 CLI picks an option value as the folder; relative folders aren't accepted
- **Location:** `FITS Blaster/CLIRunner.swift:34-45`; `FITS Blaster/main.swift:17-22`
- **What:** The folder is "the first argument starting with / or ~"; only `--render` values are skipped.
- **Why:** `-o /tmp/out.csv /data/night1` fails with "is not a directory" (reproduced). A relative folder isn't recognised as CLI use, so the GUI starts.
- **Action:** Parse options in one pass, consume flag values, and treat the remaining argument as the folder.
- **Severity:** Medium

### 5.11 CLI writes every frame when no frame passes the filter
- **Location:** `FITS Blaster/CLIRunner.swift:169-182`
- **What:** If all frames fail the criteria, it warns on stderr and exports all frames, with exit code 0.
- **Why:** A script that uses the CSV as a keep-list stacks every bad frame. This may be intended; it is undocumented in `--help`.
- **Action:** Decide the intended behaviour; if it stays, document it and use a distinct exit code.
- **Severity:** Medium

### 5.12 CLI ignores unknown flags and per-file errors
- **Location:** `FITS Blaster/CLIRunner.swift:147-199, 242-289`
- **What:** Typos like `--fwmh` or non-numeric values silently disable a filter; files that failed to load aren't reported; exit code stays 0.
- **Why:** Automation gets a "successful" run with missing data.
- **Action:** Usage error on unknown flags or bad values; report failed files; non-zero exit when files failed.
- **Severity:** Low

### 5.13 Sandboxed build: reject fails for dropped single files and for later dropped folders
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:636-693`; `FITS Blaster/FitsBlasterApp.swift:32-38`
- **What:** For single files, the bookmark is made for the parent folder, which the sandbox never granted. With several dropped folders, every entry gets the first folder's bookmark.
- **Why:** In the App Store build, rejecting those frames fails ("folder access unavailable"). Found by reading, not run in the sandboxed build.
- **Action:** One bookmark per source folder; for single files, ask for folder access before rejecting. Check in the App Store build.
- **Severity:** Medium

### 5.14 Batch reject/undo shows only the last error and does slow work per frame
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:62-101, 213-220`; `FITS Blaster/ImageStore.swift:644-656`
- **What:** Per entry: bookmark resolution, file move on the main actor, visibility rebuild, and `errorMessage` overwritten on failure.
- **Why:** With partial failures the user can't tell which files moved; large auto-rejects on SMB freeze the UI.
- **Action:** Collect failures into one summary, rebuild visibility once, move files off the main actor.
- **Severity:** Medium

### 5.15 `removeSelected` leaves removed IDs in the selection sets
- **Location:** `FITS Blaster/ImageStore.swift:448-471`
- **What:** Removed IDs stay in `markedForRejectionIDs`, `rejectedEntryIDs` and the cursor maps.
- **Why:** A selection made only of removed IDs sends keys into the batch branch, which then does nothing for the cursor frame.
- **Action:** Subtract removed IDs from all sets and maps.
- **Severity:** Low

### 5.16 Relative thresholds in very small groups
- **Location:** `FITS Blaster/ImageStore.swift:374-397`; `FITS Blaster/ImageStoreFileOperations.swift:175-187`
- **What:** The median is `sorted[count / 2]` (upper middle for even counts); groups of 1–2 frames are compared with themselves.
- **Why:** In a 2-frame group a bad frame can never exceed 1.5 × its own value.
- **Action:** True median for even counts; skip or flag relative checks below about 3 frames.
- **Severity:** Low

### 5.17 GPU errors are not detected; detection threadgroup not clamped
- **Location:** `FITS Blaster/ImageStretcher.swift:425-428, 570-573`; `FITS Blaster/MetricsCalculator+StarDetection.swift:197-213`
- **What:** Completion handlers never check `commandBuffer.status`; detection uses a fixed 16×16 threadgroup while the stretch path clamps to the pipeline limit.
- **Why:** After a GPU error, detection reads a zero counter (no metrics, no CPU fallback) and stretches can return black images.
- **Action:** Check for `.completed` and fall back to the CPU path on error; clamp the threadgroup size.
- **Severity:** Medium

### 5.18 CPU detection traps on images under 3 pixels wide or high
- **Location:** `FITS Blaster/MetricsCalculator+StarDetection.swift:106-118`
- **What:** `vDSP_Length(cropW - 2)` and `1..<(cropH - 1)` trap for tiny sizes (CPU fallback only).
- **Why:** A tiny but valid file crashes metrics when Metal is unavailable.
- **Action:** Return no candidates below 3 × 3.
- **Severity:** Low

### 5.19 A missing END card makes the parser walk the whole file
- **Location:** `FITS Blaster/FITSReader.swift:134-169`
- **What:** Without END, every 80-byte card of the file is turned into a String before the error.
- **Why:** Large mislabelled files take seconds, which can hit Quick Look time limits.
- **Action:** Stop after a fixed number of header blocks or at the first non-ASCII block.
- **Severity:** Low

### 5.20 No tests for malformed FITS input
- **Location:** `FITS Blaster Tests/FITSReaderTests.swift`
- **What:** No tests for negative, zero or huge NAXIS, overflow, missing END, truncated data or non-finite scale.
- **Why:** §5.2 could come back unnoticed.
- **Action:** Parameterised malformed-header tests for `read`, `readIntoBuffer` and `readForPreview`, each expecting a thrown `FITSError`.
- **Severity:** Low

---

## 6. Security

### 6.1 Quick Look extensions parse untrusted files and hold an unneeded entitlement
- **Location:** `FITSBlasterQL/FITSBlasterQL.entitlements:5-10`; `FITSBlasterQLThumb/FITSBlasterQLThumb.entitlements:4-7`
- **What:** Both declare `files.user-selected.read-only`; Quick Look already grants access to the file being previewed. Their parser crashes on bad input (§5.2). The agents found no memory corruption: every `memcpy` is preceded by a length check.
- **Why:** The code that handles untrusted input should hold the least access.
- **Action:** Keep only `app-sandbox`; fix §5.2.
- **Severity:** Low

### 6.2 CSV/TSV export allows formula injection and stray carriage returns
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:348-351, 497-511`
- **What:** Header values (e.g. OBJECT) are written as-is; cells starting with `=`, `+`, `-`, `@` aren't neutralised; `\r` isn't quoted.
- **Why:** Opening an export of someone else's files in Excel or Numbers can run formulas.
- **Action:** Quote on `\r`; prefix formula-leading text cells (not numeric metric columns) with `'`.
- **Severity:** Low

### 6.3 Direct-build entitlements list sandbox-only keys
- **Location:** `FITS Blaster/FITS Blaster.entitlements:1-17`
- **What:** The non-sandboxed build declares user-selected files, bookmarks, network client and Sparkle mach-lookup exceptions, which only mean something in a sandbox.
- **Why:** They hide the real privilege model and would become broad exceptions if the sandbox were turned on.
- **Action:** Remove them from the direct build's entitlements.
- **Severity:** Low

### 6.4 App Store build ships Sparkle keys in Info.plist
- **Location:** `FITS Blaster/Info.plist:88-97`
- **What:** The App Store configuration uses the same Info.plist with `SUFeedURL`, `SUPublicEDKey` and update settings.
- **Why:** They do nothing there, but they describe a self-updater, which App Review can question (guideline 2.4.5). The direct build's feed is https with an EdDSA key, which is fine.
- **Action:** Strip the `SU*` keys from the App Store build.
- **Severity:** Low

### 6.5 FITS type declared as exported instead of imported
- **Location:** `FITS Blaster/Info.plist:60-80`
- **What:** `gov.nasa.gsfc.fits` is under `UTExportedTypeDeclarations`, though the app doesn't own that type.
- **Why:** Can conflict with other astronomy apps that declare it, making Open With and Quick Look routing unpredictable.
- **Action:** Move it to `UTImportedTypeDeclarations`.
- **Severity:** Low

---

## 7. Performance

### 7.1 Display-size images kept for every frame, up to three per colour frame
- **Location:** `FITS Blaster/ImageEntry.swift:18-19, 51-54`; `FITS Blaster/ImageStorePipeline.swift:432-435, 769-772, 801-804`
- **What:** Every entry keeps `displayImage`; colour (Bayer) entries also keep cached grey and colour versions, all backed by non-purgeable MTLBuffers. Display size can go up to 8192.
- **Why:** Memory grows linearly with session size: a few MB per frame at the default 1024, hundreds of MB at 8192.
- **Action:** Keep display images only for the selected frame and its neighbours (LRU); keep thumbnails for the rest; re-render on demand.
- **Severity:** Medium

### 7.2 Every file is read two to three times per load
- **Location:** `FITS Blaster/ImageStorePipeline.swift:586-605, 636-641, 703-738, 747-834, 841-873`
- **What:** Phase A reads each file; grey normalisation reads grey frames again; colour rendering reads colour frames again, and a third time for clips when loaded with colour off.
- **Why:** Load time and disk or NAS traffic double or triple; the "pages still warm" assumption fails on large sessions.
- **Action:** Render the normalised image from the Phase A buffer before releasing it, or keep a display-size float proxy.
- **Severity:** Medium

### 7.3 Peak memory per read is 3–4× the file size
- **Location:** `FITS Blaster/ImageStorePipeline.swift:466-469`; `FITS Blaster/FITSReader.swift:258-289, 305-307`
- **What:** The whole file as `Data`, a temporary integer copy and the float buffer are alive together; Phase A holds its buffer while waiting for a Phase B slot.
- **Why:** With 50–60 MP frames, several GB of transient memory.
- **Action:** Read straight into the destination buffer and byte-swap in place; lower I/O concurrency for large frames.
- **Severity:** Medium

### 7.4 Folder scanning and file moves on the main thread
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:523-572` (called at 591-594, 655-657), `645-646`, `681`, `89-100`, `233-244`
- **What:** `collectFITSURLs` (recursive listing) runs synchronously in main-actor methods; so do `fileExists` and reject/undo moves.
- **Why:** Opening a deep folder tree on NAS, SMB or iCloud beachballs before loading starts.
- **Action:** Make discovery `@concurrent` and await it, as `filterItems` does.
- **Severity:** Medium

### 7.5 Header-derived values recomputed on every access
- **Location:** `FITS Blaster/ImageEntry.swift:35-43`; `FITS Blaster/ImageStore.swift:293-303, 326-341`; `FITS Blaster/SidebarViews.swift:78, 87, 93-96`; `FITS Blaster/SessionChartView.swift:30-47, 83-90, 232-235`
- **What:** `filterGroup` (header lookup, quote stripping, ~30 string checks) and `isBayer` (header parse) are computed properties used in filters, groupings, statistics and view bodies; chart arrays are rebuilt several times per render.
- **Why:** Repeated O(n) string work per render and per metrics update during a batch.
- **Action:** Store `filterName`, `filterGroup` and `bayerPattern` once when headers are set; compute chart and sidebar arrays once per body.
- **Severity:** Medium

### 7.6 Bookmark resolved per entry on the main thread; start result ignored
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:22-58`; callers `FITS Blaster/ImageStorePipeline.swift:156, 204, 280, 526` and `ImageStoreFileOperations.swift:78-82, 223-227`
- **What:** Each call resolves a security-scoped bookmark and starts access, ignoring the returned Bool; callers always stop. Batch functions do this once per entry, not per folder.
- **Why:** N synchronous resolutions on the main thread for N frames sharing one folder; unbalanced start/stop.
- **Action:** Resolve once per distinct bookmark; stop only when start returned true.
- **Severity:** Medium

### 7.7 CLI runs the full display pipeline it doesn't use
- **Location:** `FITS Blaster/CLIRunner.swift:145-147`; `FITS Blaster/ImageStorePipeline.swift:97-105, 862-885`
- **What:** Without `--render`, the CLI still stretches, makes thumbnails and runs grey normalisation (a second read of every file).
- **Why:** About double the I/O and run time.
- **Action:** A metrics-only path for the CLI when nothing is rendered.
- **Severity:** Medium

### 7.8 Quick Look decodes at 2048 for a 1024 preview; thumbnails ignore Retina scale
- **Location:** `FITSBlasterQL/PreviewProvider.swift:19-30`; `FITS Blaster/FITSReader.swift:369-378`; `FITSBlasterQLThumb/ThumbnailProvider.swift:20-21, 59-65`
- **What:** `readForPreview` uses its 2048 default while the stretch uses 1024; thumbnail size ignores `request.scale`.
- **Why:** About 4× the needed memory in the preview extension; thumbnails look soft on Retina.
- **Action:** Pass 1024; multiply the thumbnail budget by `request.scale`.
- **Severity:** Low

### 7.9 Two separate Metal devices, queues and libraries; device argument ignored
- **Location:** `FITS Blaster/ImageStretcher.swift:99-113`; `FITS Blaster/MetricsCalculator.swift:63-83, 158`
- **What:** Two `MTLCreateSystemDefaultDevice()` statics; `compute(metalBuffer:device:)` ignores its `device` argument.
- **Why:** Correct only while both return the same device (15.6 still includes Intel Macs with two GPUs).
- **Action:** One shared Metal context; use the buffer's own `device`.
- **Severity:** Low

---

## 8. SwiftUI / UI

### 8.1 Every thumbnail cell re-renders on selection and flag changes
- **Location:** `FITS Blaster/ThumbnailCell.swift:14-20`
- **What:** Each cell reads `store.selectedEntry`, `flaggedEntryIDs`, `markedForRejectionIDs` and `groupStatistics`.
- **Why:** Moving the cursor or flagging one frame re-evaluates every visible cell; noticeable with large sessions and fast key repeat.
- **Action:** Pass `isCursor`, `isFlagged`, `isMarked` and the group stats in as plain values from the parent, or keep per-entry flags on `ImageEntry`. Measure with the `swiftui-performance-audit` skill.
- **Severity:** Medium

### 8.2 Thumbnails and frames have no VoiceOver labels
- **Location:** `FITS Blaster/ThumbnailCell.swift:22-88`; `FITS Blaster/SidebarViews.swift` (thumbnail buttons); `FITS Blaster/ImageViewer.swift`
- **What:** The whole app has 6 accessibility modifiers; a thumbnail reads as an unlabelled image. Flag, rejected and quality state are only visual.
- **Why:** The core workflow can't be done with VoiceOver.
- **Action:** Label each thumbnail (file name, filter, score, flagged, rejected) and combine its children into one element.
- **Severity:** Medium

### 8.3 Fixed font sizes that bypass the app's `scaledFont`
- **Location:** `FITS Blaster/ThumbnailCell.swift:31, 40`; `FITS Blaster/SessionChartView.swift:296, 306, 400`
- **What:** `.font(.system(size:))` where the rest of the app uses `scaledFont`.
- **Why:** These ignore the app's text-size setting.
- **Action:** Use `scaledFont`.
- **Severity:** Low

### 8.4 `Binding(get:set:)` in view bodies
- **Location:** `FITS Blaster/ExportSettingsTab.swift:54-57`; `FITS Blaster/ContentView.swift:42-45`
- **What:** The first only mirrors `settings.exportHeaderKeys`; the second builds the error alert's binding.
- **Why:** Needless indirection.
- **Action:** `$settings.exportHeaderKeys`; for the alert, a small `isPresented` helper on the store.
- **Severity:** Low

### 8.5 Filtering inside `ForEach`
- **Location:** `FITS Blaster/SidebarViews.swift:87`
- **What:** `folderGroup.filterGroups.flatMap { $0.1 }.filter { store.isVisible($0) }` inline.
- **Why:** Recomputed on every body evaluation (see §7.5).
- **Action:** Compute once in the store with the other cached groupings.
- **Severity:** Low

### 8.6 `GeometryReader` for the zoom anchor where the size is known
- **Location:** `FITS Blaster/ImageViewer.swift:60-68`
- **What:** The overlay reads its size from `GeometryReader`, but the size is the image size × zoom already computed above.
- **Why:** Extra layout pass while zooming.
- **Action:** Position the indicator from the known size.
- **Severity:** Low

### 8.7 Deprecated `overlay(_:)` form
- **Location:** `FITS Blaster/SessionChartView.swift:362`
- **What:** `.overlay(Rectangle().stroke(...))`.
- **Action:** Trailing-closure `overlay { }`.
- **Severity:** Low

### 8.8 Tap gesture on the image without an accessibility trait
- **Location:** `FITS Blaster/ImageViewer.swift:71`
- **What:** `onTapGesture { location in }` sets the zoom anchor (location is needed, so a Button doesn't fit) but VoiceOver doesn't know it's tappable.
- **Action:** Add `.accessibilityAddTraits(.isButton)` and a label, as the chart overlay already does.
- **Severity:** Low

### 8.9 View logic that can't be unit-tested
- **Location:** `FITS Blaster/SessionChartView.swift:30-90, 232-235`; `FITS Blaster/ContentView.swift:59-145, 213-260`; `FITS Blaster/ExportPanel.swift:121-134`
- **What:** Chart data, key dispatch and header-key discovery live in views.
- **Action:** Plan step 10.
- **Severity:** Low

---

## 9. Dead code / duplication / refactor

### 9.1 Code to delete (each verified: no callers in any target, tests included)
- **Location:**
  - crop-based star pipeline: `FITS Blaster/MetricsCalculator.swift:118-147, 226-404` (`extractStarData`, `measureFromCrops`, `StarMeasurementCandidate`, `StarDetectionData`) and `FITS Blaster/MetricsCalculator+ShapeMeasurement.swift:310-348` (`measureFWHMOnlyFromCrop`), about 190 lines
  - `FITS Blaster/ImageStorePipeline.swift:145` `reprocessAll`; `17-31` flat `openFiles(_ urls: [URL])` (only called by the next item)
  - `FITS Blaster/ImageStoreFileOperations.swift:695-727` `openFilesPanel`; `70-73` `rejectEntries`; `206-209` `applyAutoReject`; `483-493` `formatFraction`
  - `FITS Blaster/MetricsCalculator.swift:215-224` `compute(ptr:)`
  - `FITS Blaster/ImageStretcher.swift:151-153` `makeSharedBuffer`; `837-853` `estimatePercentiles`
  - `FITS Blaster/ImageStore.swift:343-351` `groupedSortedEntries`; `FITS Blaster/FolderGroup.swift:18` `totalCount`
  - `FITS Blaster/AppSettings.swift:344-362, 386-399` — 17 `*KeyEquivalent` properties and their mapper, whose fallbacks contradict the live ones in MenuCommands
  - `FITS Blaster/MainContentViews.swift` (empty placeholder file)
  - `scripts/Create-installer.sh` (hard-codes 1.19.6 and a missing icon path; unreferenced)
- **What:** About 400 lines of unreachable code.
- **Why:** Kept in sync for nothing; the crop pipeline is a near-copy of the live one, and docs describe it as live.
- **Action:** Delete; update `docs/internal/performance.md:68-80` and `docs/internal/architecture-plan.md` (which lists `MainContentViews`).
- **Severity:** Medium

### 9.2 Fields that are never read
- **Location:** `FITS Blaster/FITSReader.swift:44-45, 66-67` (`bzero`, `bscale`); `FITS Blaster/ImageStorePipeline.swift:937, 940-941` (`FastLoadResult.metalDevice`, `.bitpix`); `FITS Blaster/MetricsCalculator.swift:110-116` (`GPUDetectionResult.totalFound`)
- **What:** Carried state with no consumer (`totalFound` only fed the dead pipeline).
- **Action:** Remove.
- **Severity:** Low

### 9.3 Unreachable branches
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:508-509`; `FITS Blaster/Metric.swift:206`; `FITS Blaster/FITSStretch.metal:120-124, 166-167, 186-189`
- **What:** Plain-text quoting that never runs, a sky-background export case with no export context, and a `bayerBin` parameter that is always 1.
- **Action:** Remove or assert.
- **Severity:** Low

### 9.4 Star measurement and PSF fitting duplicated
- **Location:** `FITS Blaster/MetricsCalculator.swift:293-404` vs `439-576`; `FITS Blaster/MetricsCalculator+ShapeMeasurement.swift:42-96` vs `312-348`, `112-193` vs `244-308`, `200-220` vs `352-372`, `223-237` vs `494-507`
- **What:** Aggregation and the Moffat fitters each have a near-copy; the FWHM acceptance range (0.5–20) appears 6 times.
- **Why:** About 250 lines that must be tuned twice. One side is dead (§9.1).
- **Action:** After §9.1, one implementation reading pixels through a small sampler; named constants.
- **Severity:** Medium

### 9.5 Metal setup and dispatch duplicated
- **Location:** `FITS Blaster/ImageStretcher.swift:99-113, 363-459, 510-595`; `FITS Blaster/MetricsCalculator.swift:63-83`; `FITS Blaster/MetricsCalculator+StarDetection.swift:186-205`
- **What:** Device, library, pipeline creation, dispatch, the async commit and the zero-copy CGImage wrap appear 2–3 times, with different threadgroup sizing.
- **Action:** One `MetalContext` with a shared dispatch helper (goes with §7.9 and §5.17).
- **Severity:** Medium

### 9.6 Stretch statistics duplicated, with silent differences
- **Location:** `FITS Blaster/ImageStretcher.swift:766-778` vs `812-835`; fallbacks at `30, 63-66, 767, 813`; MTF formula in `FITS Blaster/FITSStretch.metal:86-92, 127-135` and `FITS Blaster/ImageStretcher.swift:602-609`
- **What:** Grey and colour paths compute the same STF statistics separately; only the grey path drops values ≤ 0 and needs more than 10 samples.
- **Why:** Grey and colour stretches can drift apart.
- **Action:** One statistics function and one Metal `mtf()` helper. Run the render tests and baselines before and after.
- **Severity:** Medium

### 9.7 FITS parsing helpers duplicated
- **Location:** `FITS Blaster/FITSReader.swift:85-101` vs `134-166`; `324-344` vs `434-454` vs `573-597`; `282-317` vs `488-522`
- **What:** `peekBitpix` re-parses cards; BSCALE/BZERO apply plus min/max is written 3 times; byte-swaps twice.
- **Why:** The §5.2 fix would have to go into several places.
- **Action:** Extract card parsing, scale-and-range and byte-swap helpers before or with §5.2.
- **Severity:** Medium

### 9.8 REJECTED folder logic written separately in the app and CLI
- **Location:** `FITS Blaster/ImageStoreFileOperations.swift:86, 548, 596-602`; `FITS Blaster/CLIRunner.swift:129-135`; `FITS Blaster/ImageStorePipeline.swift:64-69`
- **What:** The folder name, the "parent is REJECTED" test and the original-URL derivation are each written several times.
- **Action:** One small `RejectedFolder` helper used by both.
- **Severity:** Medium

### 9.9 Repeated pipeline boilerplate
- **Location:** `FITS Blaster/ImageStorePipeline.swift:289-317, 402-495, 566-620, 631-658, 709-737, 778-810` (bounded task-group loop ×6); `453-458, 555-560, 573-578, 611-616` (colour spawn ×4); `108, 178, 236, 323` (megapixels ×4)
- **What:** The same loops and blocks copied.
- **Action:** Plan step 6.
- **Severity:** Medium

### 9.10 Per-metric configuration is vestigial
- **Location:** `FITS Blaster/FrameMetrics.swift:14-24, 88-122`; `FITS Blaster/AppSettings.swift:376-382`; `FITS Blaster/ImageStorePipeline.swift:217-220, 254-331`
- **What:** Settings only ever produce "all metrics on" or "all off", yet partial-config merging and filtering remain; `covers(_:)` is tested but the pipeline open-codes the same check.
- **Action:** Replace with a single on/off and simplify `recomputeMetrics`.
- **Severity:** Medium

### 9.11 Smaller duplicates
- **Location:**
  - FITS extension list ×5: `FITS Blaster/ImageStorePipeline.swift:133`, `FITS Blaster/ImageStoreFileOperations.swift:530, 637, 701-703, 711`
  - header cleaning at 9 call sites, e.g. `FITS Blaster/ImageEntry.swift:37`, `FITS Blaster/InspectorView.swift:142, 150`
  - `BayerPattern.parse` called 15 times, twice in `loadFast` although `meta.bayerPattern` holds it (`FITS Blaster/ImageStorePipeline.swift:865-878`)
  - default export header keys ×3: `FITS Blaster/AppSettings.swift:250-255`, `FITS Blaster/CLIRunner.swift:297-302`, `FITS Blaster/ExportSettingsTab.swift:64-69`
  - header-key discovery and picker ×2: `FITS Blaster/ExportPanel.swift:121-176`, `FITS Blaster/ExportSettingsTab.swift:79-141` (and the two order header columns differently)
  - export columns built twice and CSV quoting twice: `FITS Blaster/ImageStoreFileOperations.swift:316-397`, `FITS Blaster/CLIRenderer.swift:85-88`
  - key-symbol mapping ×3 and `KeyEquivalent` building ×8: `FITS Blaster/ContentView.swift:213-226`, `FITS Blaster/KeyRecorderView.swift:28-36`, `FITS Blaster/MenuCommands.swift:63-188`
  - visibility switch ×3, grouping ×5, median ×8: `FITS Blaster/ImageStore.swift:293-434`, `FITS Blaster/SessionChartView.swift:56-70`
  - Quick Look read-and-stretch ×2: `FITSBlasterQL/PreviewProvider.swift:19-31`, `FITSBlasterQLThumb/ThumbnailProvider.swift:39-53`
  - main-window lookup by identifier vs by title: `FITS Blaster/MenuCommands.swift:20-22`, `FITS Blaster/SettingsView.swift:290-296`
  - text-size steps ×3: `FITS Blaster/AppSettings.swift:153-177`, `FITS Blaster/SettingsView.swift:418-426`
  - badge thresholds vs Auto-Reject defaults: `FITS Blaster/FrameMetrics.swift:132-177`, `FITS Blaster/AutoRejectConfig.swift:17-26`
  - test fixtures (FITS writer ×3, `makeEntry` ×4, `makeStore` ×5): `FITS Blaster Tests/IntegrationTests.swift:83-125`, `GPUTests.swift:221-232`, `FITSReaderTests.swift:260-330`
  - release scripts: create-dmg block ×3 (`scripts/build-dmg.sh:32-55`, `scripts/build-release.sh:64-84`), Python helpers ×2 (`scripts/generate-appcast.py`, `scripts/update-site.py`)
- **What:** Each is small; together they are the main source of drift risk.
- **Action:** Fix when touching the area; the test fixtures go with the planned `TestFITS.swift` helper.
- **Severity:** Low

### 9.12 Oversized files outside ImageStore
- **Location:** `FITS Blaster/ImageStretcher.swift` (854 lines); `FITS Blaster/FITSReader.swift` (613); `FITS Blaster/MetricsCalculator.swift` (577); `FITS Blaster/MetricsCalculator+ShapeMeasurement.swift` (508)
- **What:** `ImageStretcher.swift` mixes clip types, Metal and CPU paths, and is compiled into both Quick Look extensions, which only use the CPU path. The MetricsCalculator files are large mostly because of §9.1 and §9.4.
- **Action:** Split ImageStretcher into statistics, Metal (app only) and CPU parts, and give the extensions only what they use; split FITSReader into parser and readers. Plan step 8 (engine splits) and step 15 (folders).
- **Severity:** Medium

### 9.13 Stale comments and docs
- **Location (comments, 17 sites):** `FITS Blaster/ImageStorePipeline.swift:250, 363-370, 814`; `FITS Blaster/FocusedAction.swift:29`; `FITS Blaster/MetricsCalculator+StarDetection.swift:146-156, 165`; `FITS Blaster/FITSStretch.metal:40, 234-236`; `FITS Blaster/ImageStretcher.swift:86, 198-199, 837`; `FITS Blaster/FrameMetrics.swift:81`; `FITS Blaster/MetricsCalculator.swift:137-139, 562`; `FITS Blaster/SettingsView.swift:227`; `FITS Blaster/AppSettings.swift:215`; `FITS Blaster/UserDefaultsHelpers.swift:21-23`; `FITS Blaster/ExportPanel.swift:16`
- **Location (docs):** `SwiftUI-Review.md` (repo root, April 2026, cites line numbers in the now-empty `MainContentViews.swift`); `docs/internal/performance.md:68-80`
- **What:** Comments name functions or behaviour that no longer exist (e.g. `normalizeBayerStretch`, "asinh stretch", "bilinear debayering", "Requires Reprocess All"); the Metal kernel `sqrtStretch` does an MTF stretch.
- **Action:** Rewrite or delete; mark `SwiftUI-Review.md` as historical or move it to `docs/internal/`.
- **Severity:** Low

### 9.14 Magic constants
- **Location:** concurrency caps `FITS Blaster/ImageStorePipeline.swift:287, 390, 391, 565, 630, 708, 776`; size defaults (1024 / 120 in 10+ places, e.g. `ImageStorePipeline.swift:20, 37, 377, 842-843`); tunables `FITS Blaster/MetricsCalculator.swift:170, 243, 416-422`, `FITS Blaster/ImageStretcher.swift:770-832`; timings `FITS Blaster/FITSToolbar.swift:38`, `FITS Blaster/MainContent.swift:151`; URLs `FITS Blaster/FitsBlasterApp.swift:117, 128, 133`, `FITS Blaster/UpdaterDelegate.swift:16-17`
- **What:** Policy and tuning values repeated as literals; the stable feed URL exists both in code and in Info.plist.
- **Action:** Named constants grouped by topic, with the reason for the 300 ms delay written down.
- **Severity:** Low

### 9.15 Naming and organisation
- **Location:** `FITS Blaster/AppSettings.swift:217` (`debayerColorImages`) vs `FITS Blaster/ImageStorePipeline.swift:747` (`renderFolderInColour`); `normalizeGreyStretch` vs `FilterGroup.normalise`; `FITS Blaster/ExportPanel.swift` declares `ExportSheet`; `FITS Blaster/FrameMetrics.swift` also holds `MetricsConfig`, `GroupStats`, `BadgeProblem`; `FITS Blaster/AutoRejectSheet.swift:94-251` (seven near-identical threshold sections)
- **What:** Mixed British/American spelling in identifiers, file names that don't match their types, copy-paste sections.
- **Action:** Pick one spelling for identifiers (keep UserDefaults key strings unchanged); plan step 15 (the Auto-Reject sections: step 10).
- **Severity:** Low

---

## 10. Cross-cutting recommendations

1. **Treat every FITS file as untrusted input.** The Quick Look extensions parse files from Finder without the user opening them. One validated header type (sizes in range, products checked for overflow, finite scale values, a block limit for the header) closes §5.2, §5.3 and §5.19 together, and needs the parsing helpers from §9.7 first so the fix lands in one place. Back it with the malformed-input tests of §5.20.
2. **One owner for batch work.** §3.1–§3.6 and §9.9 all disappear into the planned `LoadPipeline` (plan step 6): one queue, one shared limiter for file reads and renders, cancellation that reaches every spawned task, scopes released when the last task ends.
3. **Compute header-derived facts once.** Storing `filterName`, `filterGroup` and `bayerPattern` on the entry when headers arrive fixes §7.5 and most of §9.11's parse repetition, and makes §8.1 cheaper.
4. **A shared engine core.** One Metal context (§7.9, §9.5, §5.17) and one statistics module (§9.6) would also let the Quick Look extensions compile only the CPU code they use (§9.12).
5. **Let the VM tests check what users see.** §5.1 slipped through because the smoke test checks that the extensions are present, not registered. Add a `pluginkit` check and a `qlmanage -t` thumbnail on every support level.

---

## 11. What was NOT audited

- Correctness of the Metal kernels and of the metric and score algorithms themselves (the "score ignores cloudy frames" question is tracked separately; §5.4 is related).
- Build settings beyond the deployment target, Swift version and entitlements; schemes and the release workflow.
- Sparkle's internals (treated as a black box).
- The App Store (sandboxed) build was not run; §5.13 and §6.4 come from reading.
- UI behaviour was not exercised, except Quick Look on `fb-15` and the CLI with malformed files. §5.5 is verified by reading only.
- Tests: quick scan only, no coverage review.
- Website (`site/`) and most of `scripts/`, apart from dead or duplicated scripts.
- Localisation (the app is English-only).
- No Instruments profiling; §7 lists likely hot spots, not measured ones.

---

## 12. Verification

How each High finding was checked:

- **§5.1** — Built `.appex` Info.plists in `build/beta/Build/Products/Release/` show `LSMinimumSystemVersion = 26.2`. On a `fb-15` clone (macOS 15.8.1) with beta 10 (203): after opening the app, `pluginkit -mA -i com.astrophotoapp.FitsBlaster.FITSBlasterQL` (and `…QLThumb`) found nothing; after unregistering and reopening, still nothing; a copy with the minimum set to 15.6 registered both on opening. A manually registered extension produced a correct M31 thumbnail with `qlmanage -t`.
- **§5.2** — `FITS Blaster/FITSReader.swift:203-237` has no range check. Debug CLI on synthetic files: NAXIS1 = NAXIS2 = −64 → exit 133, `Fatal error: Negative value is not representable`; NAXIS = 4294967296 → exit 133.
- **§5.4** — `FITS Blaster/MetricsCalculator.swift:188` and `:429`: `guard !allCandidates.isEmpty else { return nil }`; `FITS Blaster/ImageStoreFileOperations.swift:167`: `guard !entry.isRejected, let m = entry.metrics else { return false }`.
- **§5.5** — `FITS Blaster/ContentView.swift:155-160`: the only guard is `firstResponder is NSText`; `FITS Blaster/KeyRecorderView.swift:15`: `KeyRecorderNSView: NSView`.
- **§3.1–§3.3** — reviewed in the concurrency review of 2026-10-17; the warnings come from a scratch build with `SWIFT_STRICT_CONCURRENCY=complete`.

Medium findings reproduced: **§5.10** (CLI with `-o <file>` before the folder → "is not a directory"), **§5.6**, **§5.9** (read at the cited lines).

Agent claims checked and dropped:
- "A fresh beta install uses the stable update feed, because `didSet` doesn't run in `init`" — wrong for `@Observable` classes: a test with the same pattern showed `didSet` runs during `init`, so the beta default is written to UserDefaults.
- "BSCALE = 1E35 crashes the app" — not reproduced (exit 0); kept as a Low hardening item (§5.3).

If any finding doesn't hold when you open the cited lines, give me its § number and I'll look again.
