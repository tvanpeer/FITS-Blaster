# Changelog

All notable changes to FITS Blaster are recorded here.

---

## 2026-10-31 — Star counts are the same on every run, also on dense frames

### Fixed
- **A frame with more than 50,000 star candidates gives the same metrics on every run.** The star detection on the GPU kept a list of at most 50,000 candidates (local maxima above the noise threshold); on a frame with more, which ones fitted depended on the GPU's thread order, so the star count varied slightly between identical runs. In the test data only one frame had that many (m31-night `#0026`, 50,455 candidates: 3371–3373 stars, in 1.23.1 too); dense or noisy frames of other sessions can as well. Now such a frame gets a second pass with room for all of them, and every candidate is used: `#0026` gives 3389 stars on every run. Other frames are unchanged and cost nothing extra; across all 10 baseline sets this is the only value that changes.

### Internal
- `detectLocalMaxima` takes its list's capacity from `DetectParams.capacity` instead of a compile-time constant; `MetricsCalculator.findLocalMaximaGPU` runs `detectionPass` with room for 50,000, and again with room for exactly the number counted when that was more (`capacity` is a parameter for the tests).
- New `DetectionCapacityTests` (2): a synthetic frame with 10,000 maxima and room for 1,000 gives all 10,000, the same on every run, the same set as the CPU scan (fails without the second pass); exactly enough room gives the same candidates as more room.
- `testing.md` corrected ("results are reproducible", with this exception and its fix); the baselines script's tolerance note updated. The m31-night baseline for `#0026` is updated (3373 → 3389 stars); the PixInsight comparison on M31 (FWHM, eccentricity, SNR) is unchanged.
- The search for a regression since 1.23.1 found none: v1.23.1 varies on this frame as well.
- Unit tests (362), render tests (`--full`) and the 10 metric baselines pass; 0 compiler warnings. 10 CLI runs of m31-night are identical.

---

## 2026-10-31 — Colour folders are read once (step 9f, part 2b)

### Changed
- **A colour load reads each file once instead of twice.** While a frame is still in memory from its first read, the first half of its colour render (the averaged colours at display size, before the stretch) is kept; when the folder's shared stretch is known, the colour image is made from that instead of reading the file again. The images are byte for byte the same. Before, the second read found most files gone from the file cache: a 7 GB night doesn't stay in it. M81 (355 colour frames, 17.6 GB) from the SSD, alternated with the previous build, sleep blocked: 16.9–17.1 s instead of 24.0–24.7 s, 1.00× instead of 1.86× the files read. From the share over a wired network: 159.3/162.7 s instead of 286.6/286.5 s, 1.06× instead of 1.91× the files downloaded — about as long as a plain read of the files (157 s).
- These kept averages use at most a quarter of the Mac's memory (4 GB on 16 GB; 8.4 MB per frame at a display size of 1024, so a 140-frame night takes 1.2 GB). A frame whose averages don't fit is read again, as before; at very large display sizes that happens for part of a folder. Memory during a load rises by up to that amount (M81 at 1024: peak 3.5 GB instead of 2.6 GB); after the load it is the same as before (1.3 GB at 1024, 11 GB at 4096). Turning Colour on later still reads the files.

### Internal
- New `ColourProxies` actor (owned by `LoadPipeline`, budget `physicalMemory / 4`): `reserve`, `store`, `take`, `discardAll`. Phase A of a Bayer frame with Colour on reserves room and keeps `ImageStretcher.averageBayer`'s `ColourProxy`; `renderFolderInColour` takes it (`FrameLoading.recolorBayerEntry(…, proxy:)`) and stretches it with `createBayerImage(from:clips:)`, or reads the file when there is none. `processParallel` discards the proxies left when the load ends (Cancel, a colour change meanwhile).
- `ColourProxy` keeps the averages in `Data` over memory of its own (`mmap`, given back with `munmap`), so it is `Sendable` and its memory goes back to the system with it. Kept as a Swift array, the allocator kept the freed blocks after the load (M81 at 1024: 514 MB in 64 empty blocks; at 4096: 2.2 GB), and `malloc_zone_pressure_relief` didn't give them back.
- Unit tests (361, with the Reset fix), render tests (`--full`, full output kept), the 10 metric baselines and `ColourProxyIdentityTests` pass; 0 compiler warnings. Tried by Tom in the app with a test build: colour loads, 4096, Cancel, Reset (memory back to 160 MB after M81, 201 MB after Rosette mixed), Colour off and on, mono and mixed folders.
- New `ColourProxyPipelineTests` (5): all frames from proxies give the same bytes as reading every file again; a budget for two proxies uses two and reads the rest, same bytes; two folders; a grey load keeps none; none is left after Cancel. `ColourProxyIdentityTests` still finds all 640 renders identical.

---

## 2026-10-31 — A Reset lets go of the old session's images

### Fixed
- **After a Reset the memory of the frames is given back.** The stored lists behind the sidebar and the chart (since step 9b, not in a release) weren't emptied by a Reset and kept every frame alive with its display images; the sidebar itself was empty. M81 (355 colour frames) at a display size of 4096: 11 GB after a Reset before, 111 MB now.

### Internal
- `ImageStore.reset()` rebuilds the lists from the emptied inputs (`updateVisibilityFilteredEntries()`, which also raises `listRevision` for the chart). Found with `heap` and `leaks -traceTree` on Tom's test build: all 355 `ImageEntry` objects were still alive, held by `ImageStore.visibleFolderSections`.
- New `ResetReleasesFramesTests` (fails without the fix: the sections stay filled and the frames alive). Unit tests (355), render tests (`--full`) and the 10 metric baselines pass on the fix alone; 0 compiler warnings.

---

## 2026-10-31 — The colour render in two passes gives the same bytes (step 9f, part 2b-0)

### Internal
- Two new kernels in `FITSStretch.metal`, the halves of `bayerDebayerAndStretch` (which is unchanged): `bayerAverage` writes the per-channel averages at display size as float32 (12 bytes per pixel), `bayerStretchFromAverage` stretches them with a frame's or folder's clips. Swift: `ImageStretcher.averageBayer(inputBuffer:…)` gives a `ColourProxy`, `ImageStretcher.createBayerImage(from:clips:)` the image; the display size comes from one shared `bayerDisplaySize` for both paths. Nothing in the app uses them yet: part 2b keeps the proxies from the first read so the folder's colour render needs no second one.
- New `ColourProxyIdentityTests` (with `FB_TEST_DATA` and `FB_TEST_DATA_FULL=1`): every frame of the three render-test colour folders rendered in one pass and in two, at 1024, 2048 and 4096 with the folder's median clips and at 1024 with its own clips. All 640 renders (160 frames) are byte-identical, although the shaders are compiled with fast math.
- Unit tests (355; the new suite is skipped without the test data), render tests (`--full`, full output kept) and the 10 metric baselines pass; 0 compiler warnings.

---

## 2026-10-31 — Mono folders get their shared stretch as soon as they are read (step 9f, part 2a)

### Changed
- **A mono folder gets its shared grey stretch while the next folder loads**, instead of every frame at the end of the load. The images are the same as before (the folder's median clips, the same kernel), but the files are read once instead of almost twice: the end-of-load pass found most of them gone from the file cache. Measured with a temporary switch on Rosette large (464 mono frames, 7.4 GB, cache flushed): from the share over a wired network 66.3/71.1 s instead of 111.7/109.7 s, with 0.97/1.05× instead of 1.71× the files downloaded; from the SSD the same time (10.6/9.7 s against 11.6/9.5 s), with 1.0× instead of 1.7× read. The same goes for a display-size change.
- Colour folders don't wait for each other: on M81 (355 colour frames, 17.6 GB) the same order saved hardly any reads (1.8× instead of 1.95×), because a 7 GB night doesn't stay in the file cache anyway. Colour is part 2b.

### Internal
- `LoadPipeline.processParallel` reads the frames folder by folder (`groupedByFolder`: a folder scan lists files and subfolders by name, so a folder's files could come before and after a subfolder's). At a folder boundary, a folder of at least two frames with a mono frame among those already read finishes its Phase A and runs `normalizeGreyStretch` before the next folder starts. It returns the frames whose grey pass is still due (the last folder, and folders not yet known to be mono), which `openFiles` and `regenerateSizes` normalise after the load as before.
- New `GreyPassPerFolderTests` (5): the grouping; a folder is stretched before the next is read and the last one is left to the caller; every folder gets its own median clips, byte for byte as its recipe makes them, also when the scan mixes the folders; colour folders don't wait; a display-size change.
- The real code measured from the SSD against the build before it, alternated, cache flushed: 9.2/9.2 s with 0.96/1.01× the files read, against 9.5/9.8 s with 1.60/1.57×.
  From the share over a wired network: 67.0/72.2 s with 0.98/1.06× the files downloaded, against 107.7/108.5 s with 1.69×.
- The part 2 plan with the experiment's numbers is in `docs/internal/architecture-plan.md`.
- Unit tests (354), render tests (`--full`, full output kept) and the 10 metric baselines pass; 0 compiler warnings. Tried by Tom in the app with a test build.

---

## 2026-10-30 — Thumbnails, colour toggle and playback with dropped frames (step 9f, part 1c)

### Changed
- **A new thumbnail size also reaches frames whose display images were dropped** (1b): such a frame is drawn once from its file for its new thumbnail, which the sidebar and the blurry stand-in in the viewer then use; the image itself isn't kept, so it pushes no other frame out. Below the memory limit nothing changes (the thumbnails are still made from the images in memory).
- **Turning Colour off draws a Bayer frame that has no grey image left the way the load does, binned 2×2.** Before, this path drew it without binning — with the "screen-door" pattern and up to twice the size of the load's grey image. It hardly ever ran (the load always keeps a grey image); with dropped frames it does. Turning Colour on already drew such frames as a colour load does.

### Internal
- `makeThumbnails` draws dropped frames with `FrameLoading.renderAgain` and `ImageEntry.replaceDroppedThumbnail` sets the thumbnail, the cached thumbnail of the render shown and the stand-in (`DroppedDisplay` now keeps the image's size); a frame drawn or dropped again meanwhile keeps its own. `renderBayerEntriesInGrey` renders with the binned grey recipe.
- The cursor's neighbours are now kept and drawn from `ImageStore.selectedEntry` itself (`didSet`) instead of from `MainContent`, so playback, arrow keys and clicks go the same way and can be tested; `ImageStore.navigationIsSimpleMode` follows the setting for the sidebar order. No behaviour change.
- 4 more `DisplayMemoryBudgetTests` (12): thumbnails of dropped frames are byte-identical to those of a store that kept its images, the frames stay dropped; Colour off gives the load's binned grey images byte for byte (the test fails with the old unbinned path); Colour on gives a colour load's images; playback reads ahead.
- Unit tests (349), render tests (`--full`, full output kept) and the 10 metric baselines pass; 0 compiler warnings. Tried by Tom in the app with a test build: thumbnail-size change, Colour off and on, and playback with dropped frames all work.

---

## 2026-10-30 — Display images within a memory limit (step 9f, part 1b)

### Added
- **Settings → Image Display → Memory → "Memory for display images":** a slider from 10 to 90 % of the Mac's memory in steps of 10, default 50 %, shown with the amount (for example "50 % — 8 GB of 16 GB"). Above it, the frames looked at least recently give up their display images; thumbnails, metrics and headers always stay. A change applies at once: lowering it drops images, raising it draws nothing. At the default display size this rarely matters (M81, 355 colour frames: 1.3 GB); at large display sizes it keeps FITS Blaster from taking most of the Mac's memory (M81 in colour at 4096: 11 GB without a limit).
- **A frame without its display image is drawn again from its file when you go to it**, exactly as before (same bytes). Until it is ready the viewer shows the frame's thumbnail at the image's size, so it looks blurry for a moment; zoom and position stay. While you move with the arrow keys or playback, the 8 frames ahead in the direction you move and the 2 behind are kept and drawn in advance, two at a time (on M81 at 4096 from the SSD about 32 frames per second, three times the key repeat). If a file can't be read (moved outside FITS Blaster, or a disconnected share), the thumbnail stays dimmed with "Couldn't read the file again" in the info bar; going to the frame again tries again.

### Internal
- New `DisplayMemoryBudget` (owned by `ImageStore`, no limit by default: the command line, `--render`, the render tests and the unit tests keep every image): counts each frame's display images (each image once), and when they exceed the limit drops the least recently viewed frames — a frame never viewed counts from when its first image came — never the cursor, the frames around it, or frames a batch is making. Trims are coalesced per main-actor turn.
- `ImageEntry.dropDisplayImages()` keeps a `DroppedDisplay` (the shown image's recipe, colour or grey, the thumbnail at the image's size, a token); `LoadPipeline.redrawDropped` draws dropped frames again with `FrameLoading.renderAgain`, the cursor first, `redrawConcurrency` (2) at a time; a result for a frame that was drawn or dropped again meanwhile is not used. `ImageStore.cursorMoved(from:isSimpleMode:)`, called by `MainContent` when the cursor moves, marks the cursor viewed and picks the frames around it in sidebar order.
- Redraw speed measured on M81 2025-04-04 at 4096 from the SSD with the file cache flushed (frames/s for 1, 2, 4, 8 at a time): colour 16.6, 32.4, 26.8, 17.5; grey 22.2, 32.4, 35.5, 35.3; one colour frame from the file cache takes about 50 ms, so at this size the drawing costs more than the reading.
- Measured on M81 (355 frames, colour, SSD, this 16 GB Mac): at 4096 with the 50 % limit the display images take 8.0 GB instead of 11 GB (91 frames dropped), the process 8.3 GB (peak 9.1 GB); load times alternated with and without the limit 38.2/29.9 s against 34.0/33.2 s, no consistent difference. At 1024 nothing is dropped and the load takes the same time (23.7/23.2 s against 23.7/23.1 s).
- Still to do in 1c: a thumbnail-size change, the colour toggle and the grey path of the toggle for frames whose images were dropped.
- New `DisplayMemoryBudgetTests` (8). Unit tests (345), render tests (`--full`) and the 10 metric baselines pass; 0 compiler warnings. One render-test run before the commit reported TEST FAILED after a single suite (23.8 s, no crash report, no fault in the log; only the last lines of its output were kept, so the cause is unknown); the two full runs after it passed all 3 tests. The render-test output is kept in full from now on.
- Tried by Tom in the app with a test build: the slider, jumping, arrow keys both ways, playback and a file moved away and back all work; the redraw delay is hardly noticeable.

---

## 2026-10-30 — Colour images follow a new display size

### Fixed
- **After changing the display size with Colour on, the colour images kept the old size**; only the grey ones were rendered at the new size. A display-size change now also drops the cached grey and colour renders, so every frame is rendered again at the new size, in colour too, and a later colour toggle renders at the new size as well. Found while preparing step 9f.

### Internal
- `regenerateSizes(maxDisplaySize:maxThumbnailSize:metricsConfig:debayer:)` takes the values directly (as `recolorImages` and `regenerateThumbnails` do), so tests don't change the app's saved settings; `regenerateSizes(settings:)` calls it.
- New `DisplaySizeChangeTests` (2): in colour mode the colour images, grey renders, thumbnails and recipes get the new size; in grey mode, colour turned on afterwards renders at the new size. Both fail without the fix.

---

## 2026-10-30 — Every display image records how it was made (step 9f, part 1a)

### Internal
- **Step 0 of 9f measured** (results in `docs/internal/architecture-plan.md`, step 9, "9f"). M81 (355 frames) takes 353 MB in grey and 1.3 GB in colour at the default display size 1024, and 2.3 GB / 11 GB at 4096; almost all of it is the display images in Metal memory. The earlier "3.15 GB at 4096" is not reproduced. A second read of every file during a load comes from the file cache for one night (≈ 7 GB), but for three nights (17.6 GB) nearly every file is read twice: 1.93× from the SSD (24 s instead of 9.4 s metrics only) and 1.88× over the network (283 s instead of 157 s), because a folder's colour render runs alongside the next folder's first pass. The 9f plan (memory budget with a slider, then fewer reads) is in the master plan with Tom's answers.
- **New `DisplayRecipe`:** each display image stores how it was made — Phase A's grey stretch (with or without 2×2 Bayer binning), the shared clips of a (folder, filter) group, the folder's shared colour clips, or the CPU stretch — with the display size. `FrameLoading.renderAgain(url:recipe:)` makes the image again from its file with the same kernel and values. Nothing uses it yet; in 1b it lets a display image be dropped to stay within a memory budget. No behaviour change, no Metal change.
- New `DisplayRecipeTests` (6): for mono on its own, mono in a group, Bayer in grey, Bayer in colour, and colour after a toggle, the image made again is byte-identical to the one the load made; an unreadable file gives no image.
- Unit tests (336), render tests (`--full`) and the 10 metric baselines pass; 0 compiler warnings. `--render` PNGs byte-identical before and after for Rosette R/G/B, ASI294MM SHO, M31 and California; the M31 CSV differs only in the star count of #0026 (3373 vs 3374), the known run-to-run variation (the build before gives 3371–3373 too).

---

## 2026-10-29 — The command line measures without making images (step 9e)

### Changed
- **The command line is faster when it renders nothing:** without `--render` it no longer makes display images, thumbnails, histograms or stretch clip bounds it never shows, and so no longer reads every mono frame a second time for the grey normalisation (CODE_AUDIT §7.7). The CSV is the same. On this Mac's SSD (warm cache, before and after alternated, best of 2): mono sets about twice as fast (Rosette R/G/B 0.35 → 0.18 s, ASI294MM SHO 0.66 → 0.34 s), colour sets 13–24 % faster (California 2.33 → 1.77 s, M81 345 frames 13.1 → 10.9 s). Over the 1 Gb/s network the time stays the same (M81 night, 142 frames: 63.7 vs 63.8 s; Rosette 9.0 vs 8.6 s), because there the load waits for the link (≈ 110 MB/s), and the second read of a mono file came from this Mac's memory anyway. `--render` and the app are unchanged.

### Internal
- `loadFast(…, rendersImages:)`, passed through `openFiles` and `processParallel`: with `false` Phase A keeps only the headers, image info and the pixel buffer for Phase B. Without grey clips the grey normalisation has nothing to re-read, without `--render` the CLI already passed no colour render. No Metal change: this only removes work.
- **CSVs byte-identical** between the builds before and after on all 10 baseline sets and M81 (unfiltered and filtered, 2 rounds each), with one exception that is not caused by this change: in m31-night the star count of frame #0026 is 3371, 3372 or 3373 from run to run, **with the build before this change as well** (6 runs each; the same three CSVs from both builds). That contradicts testing.md ("results are now reproducible" since 1.23.1); noted to find the cause later. The metric baselines allow it (stars ±3).
- `--render` output (8 PNGs and `backgrounds.csv` of the sample set) byte-identical before and after (beta builds).
- New `MetricsOnlyLoadTests`: without images the same headers, image info, filter group, metrics and group medians as a normal load, and no display image, thumbnail, histogram or clips; a normal load still makes them.
- Unit tests (328), render tests (`--full`) and the 10 metric baselines pass; 0 compiler warnings.

---

## 2026-10-28 — Test VMs on macOS 27.2, 26.7.2 and 15.8.2

### Internal
- **All four test VMs run the macOS versions released on 2026-10-26:** `fb-27` and `fb-27-beta` 27.2 (26B123), rebuilt from Apple's VM installer (no clicks); `fb-26` 26.7.2 (25G332) and `fb-15` 15.8.2 (24H232), upgraded with Apple's full installers. `fb-27-beta` stays on the 27.2 release until the first 27.3 beta (Tom's choice). The old VMs (27.0.1, 27.2 RC, 26.6.2, 15.8.1) were deleted after their replacements had passed the smoke test with 1.24-beta.2; all four pass, metric baselines included.
- **The App Store build 1.23.1 (208) passes on the new releases too** (`vm-test-all.sh --dev-build --appstore` with the archive submitted on 2026-10-22, signed for development as archives are): installs, sandboxed without Sparkle, launches and stays up without crashes, exceptions or faults, and both Quick Look extensions register and make a thumbnail on 15.8.2, 26.7.2 and 27.2. The command line, rendering and metric baselines don't apply to App Store builds. Checked because an App Store build has broken on a new macOS before (build 199 on 27.2 beta 1) while the direct build was fine.
- **New `scripts/tart-resize-base.sh`:** gives a copy of a base VM a larger disk in 1–2 minutes, keeping all its settings. It uses Packer with Cirrus Labs' Tart plugin (`scripts/tart-resize.pkr.hcl`), which moves the recovery partition to the end of the disk so the system can grow and macOS updates keep working. `fb-26` and `fb-15` went from 50 to 120 GB this way instead of being rebuilt with Setup Assistant. Packer is a tool on this Mac only; nothing changes in the app.
- **New `scripts/tart-upgrade-base.sh`:** upgrades a 15 or 26 base VM with Apple's full installer (`InstallAssistant.pkg`, shared read-only into the VM) through `startosinstall`, waits for the new version, removes the installer app, turns every automatic update off again (the 26.7.2 upgrade had removed `AutomaticCheckEnabled`), waits until macOS is quiet and shuts down properly.
- **Base VMs get 120 GB disks** (`tart-create-base.sh`, was 80): the full installer needs about 67 GB in the system container, and 26.6.2 → 26.7.2 refused on 80 GB ("An additional 10.06 GB of space is needed"). The disks are sparse, so the size costs nothing until macOS writes. The two 27 VMs stay at 80 GB, since 27 VMs are rebuilt from new IPSWs.
- The installers (27.2 IPSW, both full installers; ≈ 58 GB) are kept on the SSD in `Tart/ipsw/`, checked against the SHA-256 on ipsw.me and with `pkgutil --check-signature`. `docs/internal/testing.md` describes the new update and resize routes.

---

## 2026-10-27 — Frames start loading right after the folder scan (step 9d)

### Changed
- **The first frames appear right after the folder scan.** FITS Blaster no longer reads every file's header first to find unsupported (floating-point) files — that took up to 13 s over a network for a large folder ("Checking files"). A file FITS Blaster doesn't load now shows briefly as loading and is then left out; the message about them comes at the end of the load instead of before it (requested by Tom, option B). After Cancel it names the ones found so far; after Reset it is not shown.
- **Stacks with colour planes are left out too** (NAXIS3 > 1, e.g. a 16-bit RGB master in a POST folder). Before, a 16-bit one passed the old check and stayed in the list as an empty frame with an error; floating-point ones were already skipped. The message now reads "Skipped N files FITS Blaster doesn't load (floating-point or multi-channel stacks): …".

### Internal
- `openFiles` takes `FrameLoading.candidates` (FITS extension, not loaded yet; no file read) and starts Phase A at once. `loadFast` reports a file whose header has an unsupported BITPIX or colour planes (new `FITSError.multiChannel`, which was a generic `invalidFormat`) as `isUnsupported` (recognised from the header, before the pixels are read); Phase A then takes the frame out of the session (`leaveOut`: entries, selection, lists) and collects its name; it still counts as done for its folder's colour render and gets no Phase B. `filterItems`, `headerChecksAtOnce`, `peekBitpix`, `readFirstBlock` and the "Checking files" progress (`LoadPreparation.checking`) are gone.
- **Network measurements** (1 Gb/s wired to the Mac Studio share, M81 folders of ≈ 140 frames / 7 GB not read before, the CLI's full pipeline): loading runs at 85–93 MB/s, close to the link's limit, with little CPU and 0.35 GB peak memory — no Foundation overhead is left in `loadFast` since step 8d. Six instead of eight reads at once (CODE_AUDIT §3.7) made no difference on the network (85–93 vs 88–90 MB/s, alternated) nor on the SSD (step 8d), so §3.7 is closed and Phase A keeps max(8, cores). The header check cost 2.8 ms per file (0.4 s for 140 files), against ≈ 0.5 s per frame to load over the network.
- In the app over the cable the share was read at 984 Mb/s (Activity Monitor). A first app test over Wi-Fi had stalled at under 1 Mbit/s with the threads waiting in `pread` and almost no traffic arriving; after Wi-Fi was turned off and the share reconnected, the CLI read 7 GB through the cable at ≈ 110 MB/s and the app ran at full speed — the stall was the connection, not this change.
- Tests: `candidates` (extension and duplicates, no file read), Reset during a load shows no skipped-files message, a 16-bit stack with colour planes is left out, and a folder with floating-point files (first and third of four): they are left out, named in one message, the cursor ends on a loaded frame, the timing counts only the loaded frames. The tests of `filterItems` and `peekBitpix` are removed with them.
- Unit tests (325), render tests and the 10 metric baselines pass unchanged; 0 strict warnings. 👤 Checked in the app: the network folder starts loading right after the scan; a folder with normal and floating-point files (POST 5) loads the normal ones and names the others (the 16-bit RGB stack there led to the multi-channel change; after it only the one 2D 16-bit frame of POST 5 remains, no empty frames).

---

## 2026-10-27 — ⌘-click selects or deselects a single frame

### Changed
- **⌘-click on a thumbnail now adds that one frame to the orange selection or takes it out**, as in Finder, in the All, Flagged and Rejected views alike. Adding moves the cursor to the clicked frame; taking it out leaves the cursor where it is. Without a selection yet, ⌘-click starts one with the frame under the cursor and the clicked frame. Before, ⌘-click flagged the whole selection and cleared it (and in the Flagged view unflagged it), and didn't move the cursor.
- **Flagging is its own action:** the flag key (F) and the "(De)flag" button flag or unflag the whole selection (or the cursor frame without a selection), as before.

### Internal
- `ImageStore.toggleInSelection(_:)` holds the rule; the sidebar calls it and sets the ⇧-click anchor to the clicked frame. Tests: `CommandClickTests` (start a selection, take one frame out, add one, the Flagged view, flagging stays separate).
- The FAQ on the site still describes the old ⌘-click; it is updated with the stable 1.24 release, so stable users don't read about behaviour their version doesn't have yet.
- Unit tests (324) pass; 0 strict warnings. 👤 Checked in the app: taking one frame out of a range, adding one (the cursor follows), starting a selection, F flags the selection, and the same in the Flagged view.

---

## 2026-10-27 — Fewer sidebar redraws on clicks and while scrolling (step 9c)

### Improved
- **A click on a thumbnail no longer redraws the whole sidebar**, and the thumbnail cells are redrawn about 20 % less while switching and scrolling (M81, alternated cold-cache traces: cell updates 313–317 → 246–265, sidebar redraws on clicks 10 → 0). The stutter while loading is unchanged by this step (≈ 395 vs ≈ 402 hitches in 30 s); see below.
- The loading spinner on a thumbnail is the system's small spinner (16 points; it was a regular one scaled to about 19).

### Internal
- `ThumbnailCell` no longer has its own `@AppStorage` for the chart metric: the lazy list re-evaluated it whenever it placed a cell, which counted as a change and redrew the cell. `ThumbnailSidebar` reads the metric once and passes it through `ThumbnailRow` as a value.
- The ⇧-click anchor (`lastClickedID`, the sidebar's own state, changed on every click) is now `ImageStore.shiftClickAnchorID`, not observed.
- The spinner uses `.controlSize(.small)` instead of `.scaleEffect(0.6)`; no measurable effect (the scale animations during a load come mostly from the thumbnails' button style).
- **Measured** with four traces on 2026-10-27 (`09b2`/`09c2`/`09b3`/`09c3`), alternating 9b and 9c, each after `sudo purge` (cold disk cache) with the same window and layout. A trace of 9c on 2026-10-26 had shown only 22 hitches while loading, but it ran under different conditions (load 22 s instead of 31 s); the alternated cold-cache traces don't confirm it. What is left while loading (≈ 6.8 s of SwiftUI work in 30 s: the chart ≈ 1.3 s, the rest layout and text across the window as frames arrive) is measured again after steps 9d–9f, which change the loading itself.
- Unit tests (319), render tests and the 10 metric baselines pass unchanged; 0 strict warnings.

---

## 2026-10-26 — Sidebar and chart lists built once; the chart refreshes during a load (step 9b)

### Improved
- **Smoother while loading with the chart visible:** the chart no longer redraws for every frame that gets its metrics, but at most four times a second during a load, and once at the end (performance audit P3). Loading M81 (355 colour frames): chart redraws 278 → 118, chart mark collection 2.8 → 1.4 s, all view bodies 1.7 → 0.4 s, hitches 486 = 14.5 s → 417 = 10.3 s of 31 s. What is left is mostly the sidebar's thumbnail cells being redrawn as frames arrive (text layout ≈ 1.6 s, the loading spinners ≈ 0.6 s) — step 9c.

### Internal
- **Stored sidebar lists** (performance audit P2, CODE_AUDIT §7.5b, §8.5): `visibilityGroupedSortedEntries` and the new `visibleFolderSections` (each folder's visible frames per filter group) are stored and rebuilt with `visibilityFilteredEntries`, once per change; the sidebar no longer filters inside its `ForEach`, and keyboard navigation uses the stored sections. `listRevision` goes up with every rebuild.
- **Chart data snapshot** (`SessionChartData`): the chart's frames, points and medians are built outside its body — when `listRevision`, the metric or the folder selection change, every 250 ms during a batch, and at its end — so the chart no longer observes every frame's metrics.
- **One grouping and one median** (part of §9.11): `FilterGroup.grouped` (canonical order) replaces four copies; `upperMedian` (the middle value after sorting, as before) is used by the group statistics and the chart.
- Tests: `SessionListsTests` — grouping order, the median, the stored sections equal the sidebar's old filtering (All / Flagged / Rejected, with and without the filter strip), the revision, the chart data.
- Unit tests (319), render tests and the 10 metric baselines pass unchanged; 0 strict warnings. 👤 Checked in the app: the chart fills in during a load, sorting, filter strip, flagging and rejecting update sidebar and chart smoothly. Measured with trace `09b-load-and-switch.trace`.

---

## 2026-10-26 — Step 9 baseline measurements (9a)

### Internal
- Measured before step 9 (build `efb2ea1`, M81 355 colour frames, recorded in `PERFORMANCE_AUDIT.md`): loading with the chart visible gives 486 hitches = 14.5 s of 31 s, the chart redrawn 278× (performance audit finding 3); switching frames shows no image conversion on the main thread, so finding 6 (display images in the display's format) is not needed and leaves the plan; the app uses 1.4 GB at display size 1024 and 3.5 GB at 4096, almost all display images; CLI M81 grey 12.3–13.0 s, colour 28.2–28.6 s, Rosette large 9.7–9.9 s.
- Found: a click on a thumbnail redraws the whole sidebar body (its `lastClickedID` state); for step 9c.

---

## 2026-10-26 — The thumbnail size sets the shown size; the sidebar follows it

### Changed
- **"Max thumbnail size" is now the width the sidebar shows a thumbnail at** (Settings → Display → Sizes). Before, a thumbnail always filled the sidebar's width and the setting only changed its sharpness. Smaller thumbnails take less height, so more of them fit in the sidebar; larger ones show more detail.
- **The sidebar's width follows the setting:** thumbnail + padding (212 points at the default 180), never narrower than its controls need (170 points: the Sort row, the "Show" picker and the filter pills stay readable; smaller thumbnails are centred). After changing the setting the sidebar takes its new width. Its edge can be dragged up to 240 points wider (as far as the window allows), and the thumbnails then keep their size, centred; the extra width is kept between launches until the setting changes.
- **Range 80–400 points** (was 40–320 after the previous change): below 80 the file name and metric line become unreadable. A saved value outside the range is brought into it. At 400 points the thumbnails of 355 colour frames take about 600 MB on a Retina screen (125 MB at the default 180).
- The window widens when large thumbnails make the sidebar wider than the window allows, and its minimum width includes the sidebar.
- **The "Show" picker (All / Flagged / Rejected) adapts to the sidebar's width:** segments with the full words, in a narrower sidebar segments with short words (All / Flag / Rej), and only if even those don't fit a pop-up menu (also with a large text size). Before, it was cut off at both sides (seen by Tom).

### Internal
- **The app sets the sidebar's width itself**, with its own drag handle (`SidebarDivider`: the system divider line, an 8-point grab area, the column-resize pointer, and a VoiceOver adjustable action). Content and Inspector stay in an `HSplitView`. A first version kept the sidebar as a split-view pane and could not get it to its natural width: the split view gave it its maximum width at launch, made it jump after a size change and stopped it being dragged (seen by Tom, 2026-10-26).
- `RejectionVisibilityPicker`: full words, short words or a menu, whichever fits first (`ViewThatFits`); VoiceOver reads the full names.
- New `SidebarLayout` (cell padding, controls width, natural and maximum sidebar width) used by the layout, the window minimum and `ThumbnailCell` (content at most the set width, centred, with the highlight around it).
- Tests: the new range and the sidebar widths.
- Unit tests (314), render tests and the 10 metric baselines pass unchanged; 0 strict warnings. 👤 Checked in the app: the sidebar at its natural width at launch and after a size change (no jumps), dragging wider and back, kept between launches, Inspector and Simple mode, the Show picker with short words at 180 and full words from 220.

---

## 2026-10-26 — Sharp sidebar thumbnails on Retina screens

### Improved
- **Sidebar thumbnails are sharp on Retina screens.** They were rendered at the thumbnail setting in pixels (120) but shown across the sidebar's width (about 170 points at its usual width, up to 330), so on a Retina screen they were enlarged 2.5–5× and looked soft. They are now rendered at the setting × the screen's scale.

### Changed
- **Settings → Display → Sizes → "Max thumbnail size" is in points** (was pixels), with a short explanation under it. The default is **180 pt** instead of 120 px, sharp at the sidebar's usual width; a size you saved yourself is kept and now counts as points. The range is 40–320 pt instead of 40–400 px (320 is about the widest a thumbnail is ever shown); a saved larger value is brought down to 320.
- Thumbnail memory goes up accordingly: for 355 colour frames about 125 MB at 180 pt on a Retina screen (was about 14 MB at 120 px); grey frames take a quarter of that.
- **Changing only the thumbnail size no longer reloads every frame.** Apply re-read every file and rendered everything again (all progress bars) for any size change. Now a new thumbnail size makes new thumbnails from the images already in memory, within a second and without progress bars; only a new display size reloads the frames. The main window is also resized only when the display size changes (it was resized on every Apply).

### Internal
- `AppSettings.thumbnailRenderSize` (the setting × the largest scale of the connected screens) is what Open Folder, drag and drop, the size change and the colour toggle now pass to the pipeline. The CLI and the render tests keep their own 120 px.
- `LoadPipeline.regenerateThumbnails` makes the thumbnails of every frame (and of its cached grey and colour renders) from the display images, off the main thread with the shared render slots; a frame whose image changed meanwhile keeps the thumbnail that came with it. During a load it is queued behind the load; otherwise it runs at once without the batch UI, owned by the pipeline (Reset cancels it).
- Tests: `ThumbnailSizeTests` — points × scale at 1, 2 and 3 (and without screen information), the range for saved values, the default; new thumbnails from memory with the files deleted (same pixels as from the display image, no batch), and a new size during a load reaches the frames still loading.
- Unit tests (313), render tests and the 10 metric baselines pass unchanged; 0 strict warnings. 👤 Checked in the app: the thumbnail-only change is fast, without progress bars, and the thumbnails get sharper. The thumbnails' shown size still follows the sidebar width; the next step makes the setting the shown size.

---

## 2026-10-26 — Engine files split by what they need (step 8f)

### Internal
- **Engine files split** (engine part of CODE_AUDIT §9.12), code moved without changes:
  - `ImageStretcher` → `StretchClips.swift` (the `GreyClips` / `BayerClips` types), `ImageStretcher.swift` (statistics), `ImageStretcher+CPU.swift` (CPU stretch, RGB images, thumbnails) and `ImageStretcher+Metal.swift` (GPU stretch);
  - `FITSReader` → `FITSTypes.swift` (errors and result types), `FITSHeader.swift` (BITPIX check and header parser), `FITSReader.swift` (CPU reads) and `FITSReader+Metal.swift` (the buffer read);
  - `MetricsCalculator` → its shared types and constants in `MetricsCalculator+Types.swift`, the star crops and Bayer demosaic in `MetricsCalculator+Bayer.swift`.
- **The Quick Look extensions compile only what they use:** the header, the CPU reads, the statistics, the CPU stretch and `QuickLookRendering` — no Metal files, no `MetalContext`. (Their binaries had no Metal code before either: the linker dropped it as unused. The weak link to the system's `libswiftMetal` comes with Apple's frameworks and is unchanged.)
- **Engine tunables as named constants** (engine part of §9.14): `highClipPercentile` (99.99 %), `shadowClipMADs` (2.8), `mtfLUTSize` (4096), `Constants.detectionSigmas` (5) and `Constants.cpuDetectionCropSide` (4096). Same values.
- A few members became internal instead of private because another file now uses them (`parseHeader`, `parseCard`, `HeaderInfo`, the byte-swap and scale helpers, `cpuFallbackOnBuffer`).
- Unit tests (308), render tests and the 10 metric baselines pass unchanged; the strict build has 0 warnings; the website and App Store builds compile without warnings.
- **Step 8 checked in the VMs:** smoke test passed on macOS 15.8.1, 26.6.2, 27.0.1 and 27.2 (fb-15 needed a second run: the first one failed copying into the VM, "scp: Connection closed", before any test ran). 👤 Quick Look checked on fb-15 and fb-27: preview, icon view at several sizes, list and column view.

---

## 2026-10-26 — Sharper Quick Look thumbnails on Retina screens (step 8e)

### Improved
- **Quick Look thumbnails are sharp on Retina screens** (CODE_AUDIT §7.8). The thumbnail was rendered with as many pixels as the size Finder asked for in points, so on a Retina screen (2 pixels per point) it was enlarged and looked soft. It is now rendered at points × screen scale, still at most 512 pixels, so small and medium thumbnails (list and icon view up to 256 points) get twice the detail; the largest ones stay as they were, and so does the memory used. The size shown is unchanged.

### Internal
- New `QuickLookRendering`, shared by the preview and thumbnail extensions (Quick Look part of §9.11): reading a file for Quick Look and stretching it on the CPU (grey and RGB), and the thumbnail size rule (`thumbnailBudget`, `thumbnailContextSize`). Compiled into both extensions; in the app target only for the tests.
- The preview still reads at 2048 and shows at 1024 (decided 2026-10-26): the read takes every Nth pixel, and a read size of 1024 gives an odd N for typical sensors, which turns raw Bayer frames into a checkerboard.
- Tests: `QuickLookRenderingTests` — the thumbnail budget for list, icon and large sizes at scale 1, 2 and 3, the shown size (also for a FITS file smaller than the thumbnail), and the shared read-and-stretch gives the same image the extensions made before.
- Unit tests (308), render tests and the 10 metric baselines pass unchanged. 👤 Quick Look preview and thumbnails to be checked on fb-15 and fb-27 at the end of step 8.

---

## 2026-10-26 — Frames read straight into the GPU buffer (step 8d)

### Improved
- **Less memory while loading:** each frame is read straight into its GPU buffer and converted there, instead of holding the whole file, an integer copy and the float buffer at the same time (about 4× the file size per frame being loaded, CODE_AUDIT §7.3). Peak memory loading M81 (355 colour frames, 26 MP): 2.2 GB → 1.5–1.6 GB; Rosette large (464 mono frames): 0.85–0.94 GB → 0.61–0.76 GB. Loading M81 was also faster in every alternated pair (12.0 vs 14.7 s, 13.9 vs 21.2 s, 17.0 vs 22.1 s; the times varied with the disk cache).

### Internal
- `FITSReader.readIntoBuffer` reads with POSIX `open`/`pread`: the header block by block up to its END card (at most one block more than the 100-block limit), then the pixel bytes into the back part of the Metal buffer, converted front to back through a 256 KB scratch buffer (byte swap, then integer → Float — the same operations as before, so identical values). `parseHeader` checks the sizes against the file size from `fstat`. Open and read errors are the same Cocoa errors as with `Data(contentsOf:)` (no such file, no permission); a missing END or a truncated file gives the same `FITSError` as before. `read` (CPU fallback) and `readForPreview` (Quick Look) are unchanged.
- Tests: `BufferReadTests` — the buffer read equals the CPU read for BITPIX 8, 16 (with and without BZERO/BSCALE) and 32 over more than one conversion step; truncated file, header without END and missing file give the same errors as before. The malformed-input tests already cover `readIntoBuffer`.
- **Not changed: the number of reads at once** (§3.7, blocking reads below the thread-pool width). Tried with Phase A at cores − 2 (6 instead of 8 on this Mac): M81 12.7–13.4 s vs 10.2–13.9 s, 1.3 vs 1.5 GB — not clearly faster or slower on the internal SSD. The finding is about slow and network disks, so it moves to master-plan step 9, which measures loading over the network.
- Unit tests (305), render tests and the 10 metric baselines pass unchanged.

---

## 2026-10-26 — One star-shape measurement (step 8c)

### Internal
- **The shape measurement exists once** (CODE_AUDIT §9.4): centroid, the four-direction Moffat fits, the axis reconstruction, eccentricity and SNR were written out twice — once on the whole frame (mono) and once on a star crop (Bayer luminance), about 100 lines. Now one generic `measureShape(in:cx:cy:background:sigma:)` reads its pixels through a `PixelGrid`: `FramePixels` (the frame, in place) or `CropPixels` (a crop). Both had the same edge rule already (pixels outside the grid are skipped in the centroid and give 0 in the interpolation), so nothing changes. `measureShape(pixels:…)` and `measureShapeFromCrop(crop:…)` remain as thin wrappers.
- **Named constants** (`MetricsCalculator.Shape`): the accepted FWHM range 0.5–20 px (was written out in 3 places), the centroid window, the Moffat fit width and minimum fraction, the β = 4 FWHM factor (was computed in 2 places), and the star-count wing fraction.
- Unit tests (301), render tests and the 10 metric baselines pass unchanged (every star value byte-identical). `BenchmarkTests` alternated with 8b (3 rounds each): RGB 2.22–2.40 s vs 2.29–2.46 s, mono 0.50–0.56 s vs 0.47–0.55 s — the same.

---

## 2026-10-26 — One stretch-statistics function (step 8b)

### Internal
- **Grey and colour stretch statistics come from one function** (`ImageStretcher.stfStatistics`, CODE_AUDIT §9.6): high clip at the 99.99th percentile, background = median, shadow clip = median − 2.8 × MAD, and the midtone that puts the background at 25 % grey. Before, the colour path had its own copy inside `estimateBayerPerChannelPercentiles`. Their only differences stay, as explicit values: grey samples skip pixels ≤ 0 and need at least 11 samples (`greyMinimumSamples`), a Bayer channel needs 2 (`bayerMinimumSamples`); fewer give the same fallback (`stfFallback`, now also used by the clip medians). Making grey and colour the same would change renders (decision 10: not planned).
- **The kernels share one stretch helper** (`stretchByte` in `FITSStretch.metal`): the grey kernel had the MTF formula written out, the colour kernel a copy in `bayerStretchByte`. Same arithmetic.
- `GreyClips` is `Equatable`. Tests: the two minimum sample counts, and grey statistics from a buffer equal the shared function on its positive samples.
- Unit tests (301), render tests and the 10 metric baselines pass unchanged (renders byte-identical).

---

## 2026-10-26 — One Metal context; GPU errors fall back to the CPU (step 8a)

### Fixed
- **A failed GPU pass is no longer taken for a result** (CODE_AUDIT §5.17). The stretch and the star detection now check that the GPU finished without an error. Before, a failed stretch could show a black image, and a failed detection read "no stars" without trying the CPU. Now a failed grey stretch is rendered on the CPU, and a failed detection runs on the CPU. A failed colour render leaves the frame in grey (there is no CPU colour path for raw Bayer frames). In normal use the GPU doesn't fail, so nothing changes.

### Internal
- New `MetalContext`: the one Metal device, command queue and library, the three compute pipelines, one `runPass` helper (encode, dispatch, commit, wait without blocking a thread, check `commandBuffer.status`) and one zero-copy image wrap. `ImageStretcher` and `MetricsCalculator` no longer each create their own device, queue and library (§9.5, §7.9). Buffers are used on their own `device`, and a buffer from another device takes the CPU path instead of the shared pipelines. `ImageStretcher.metalDevice` is now `MetalContext.device`.
- The threadgroup is 16 × 16 clamped to the pipeline's limit for all three kernels; detection used a fixed 16 × 16 (§5.17). Same size on every Apple GPU, so results are unchanged. Kernels unchanged.
- The Quick Look extensions also compile `MetalContext.swift` (they have no Metal library, so they keep the CPU path), until the engine files are split in 8f.
- Tests: `MetalFallbackTests` — a forced GPU error renders the grey stretch on the CPU (identical to the CPU path), gives no colour image, and detects on the CPU with the same measurement as the CPU path; the threadgroup clamp; and the **CPU vs GPU stretch comparison** (METAL_REVIEW M1) on a synthetic star field, with today's difference as the limit: at full size at most 1 level (mean 0.50, rounding), scaled to 256 px at most 78 levels (mean 1.21, the order of downscale and stretch, mostly in stars). Whether the CPU path should follow the GPU is master-plan step 13. Failures are forced with a task-local switch, so other tests aren't affected.
- Unit tests (299), render tests and the 10 metric baselines pass unchanged; the website and App Store builds compile without warnings. Measured, alternating with 1.24-beta.2 (CLI, full pipeline): M81 grey 9.7–12.0 s instead of 11.7–13.1 s, M81 colour 23.8–24.3 s instead of 25.2–25.9 s, Rosette large 8.2–8.6 s instead of 8.3–8.5 s, same peak memory.

---

## 2026-10-26 — 1.24 beta 2: faster network folders, smoother browsing, safer loading

### Improved
- **Opening folders over the network is much faster:** listing the folder and checking the files went from over a minute to about 15 seconds for 1,147 files on a 1 Gb/s share. While FITS Blaster prepares a load you now see "Scanning…" and "Checking files" with a progress bar instead of an empty window.
- **Holding an arrow key is smooth again** in large sessions: the sidebar keeps up without stutter (5 short hitches in 5 seconds instead of 39–57 in a 355-frame session). Scrolling a zoomed frame redraws less too.
- **Much less memory with many folders or filters:** a session of 464 mono frames in 8 folders × 3 filters now peaks at 1 GB instead of 4.4 GB while loading.
- **Open Folder:** "Include files from subfolders" and "Include REJECTED folder" are back in the folder panel itself, and scanning a large folder no longer freezes the window. Dropped folders are scanned in the background too.
- **Export:** the header columns follow the order you chose in Settings → Export. Text that a spreadsheet could read as a formula is protected, and a failed export now shows an error.

### Fixed
- **A second folder during a load** (opened or dropped) now waits for the first one. Before, the progress bars disappeared and Cancel greyed out while the second folder was still loading.
- **Reset during a load** stops the load; it can no longer add frames to the emptied session.
- **Colour toggled during a load** now ends correctly: turned on, every frame ends in colour, also the frames that weren't loaded yet; turned off, every frame ends in grey. Toggling quickly ends on the last setting.
- **Cancel** also stops a colour re-render, and no longer measures the remaining frames one by one.
- **Several folders dropped at once** each get their own section in the sidebar, in the order you dropped them.
- The info bar above the chart no longer disappears when you select a frame that is still loading.

### Changed
- A colour toggle can be cancelled (Cancel is active while it runs), and a display-size change made during a load runs after the load.
- Files with Finder's "hidden" flag are no longer skipped when a folder is scanned (files whose name starts with a dot still are).

### Under the hood
- The loading pipeline was rebuilt so batches run one at a time, and the app now compiles in Swift 6 language mode, which turns data races the compiler can detect into errors. Measurements and image rendering are unchanged.

---

## 2026-10-26 — Swift 6 language mode (step 7c)

### Internal
- **All targets compile in Swift 6 language mode** (`SWIFT_VERSION = 6.0` in the 12 build configurations: the app, both Quick Look extensions and the tests, plus the project level), so data races the compiler can detect are now errors instead of silent (CODE_AUDIT §3.11). No code changes were needed: after 7a and 7b the strict build had no warnings left, and the tests compile as they are.
- `CLAUDE.md` project facts updated (Swift 6 mode; no concurrency warnings to keep).
- Unit tests (294), render tests and the 10 metric baselines pass unchanged; the website (beta) and App Store builds compile without warnings. VM smoke test passed on macOS 15.8.1, 26.6.2, 27.0.1 and 27.2 (0 failed, 0 warnings). 👤 Checked in the app: open, arrow keys, drag and drop, Cancel during a load, colour toggle, display-size change, reject, undo, flag, play, CSV export.

---

## 2026-10-26 — Drag and drop with `dropDestination` (step 7b)

### Changed
- **Dropped folders and files are taken in drop order.** Before, they arrived in the order the item providers happened to finish, so with several items the folder that set the session's root name and bookmark could differ from drop to drop (CODE_AUDIT §4.1).

### Internal
- The drop handler (`ContentSplitLayout`) uses `.dropDestination(for: URL.self)` instead of `onDrop` with `NSItemProvider`, a task group and continuations. This removes the last strict-concurrency warning (§3.3): `SWIFT_STRICT_CONCURRENCY=complete` now builds with 0 warnings.
- Unit tests (294), render tests and the 10 metric baselines pass unchanged. 👤 Checked in the App Store build (sandbox) on macOS 27.2 in the VM: one folder, two folders at once (a section each), single files, a folder plus a file, reject from a dropped folder (no question) and from a dropped file (access question for its folder, then moved; not asked again when that folder was granted earlier in the same run, also after Reset, as designed in 4c), undo, a non-FITS file (nothing happens). Also checked with the website build on the Mac.

---

## 2026-10-25 — Swift 6 readiness: three warnings and the pointer escape (step 7a)

### Internal
- **Phase A result** (`LoadPipeline.processParallel`): the values the screen needs are copied out before the hop to the main actor, so `FastLoadResult` with its Metal buffer only goes to Phase B (CODE_AUDIT §3.3, "sending 'fast'").
- **Star measurement** (`MetricsCalculator.measureCandidates`): the shape fits of the top 200 candidates and the star count over up to 6,000 more now run one after another in candidate order, without child tasks. The pixel pointer no longer crosses into other tasks (§3.3, two warnings), and the thousands of microsecond-sized tasks per frame are gone (§3.8, planned for step 8; its "4 chunked tasks" would have captured the pointer again). This is the main path for every frame, GPU and CPU, not only the CPU fallback as the concurrency plan assumed. Results unchanged: the shape values were already combined in candidate order, and the count is a sum. `IndexedShape` removed.
- **CPU fallback** (`compute(pixels:)`): the pixels are copied into a buffer the function owns and frees, instead of using a pointer from `withUnsafeBufferPointer` after the closure has returned (§3.10).
- The strict build (`SWIFT_STRICT_CONCURRENCY=complete`) has one warning left: the drop handler (step 7b).
- **Measured**, alternating with the step 6 build: `BenchmarkTests` (71 M81 colour frames, 30 ASI294MM mono frames, read + star measurement, several frames at once) RGB 1.72–1.74 s instead of 1.82–1.88 s, mono 0.40–0.45 s instead of 0.44–0.45 s; CLI full pipeline M81 grey 9.9–10.4 s instead of 10.2–10.4 s, Rosette large 7.6–7.65 s instead of 7.8 s, same peak memory. Unit tests (294), render tests and the 10 metric baselines pass unchanged.
- **`scripts/run-benchmark.sh` builds again:** its Release test build now sets `ENABLE_TESTABILITY=YES` (the tests use `@testable import`), the BETA condition (the test target also compiles the render tests, which use BETA-only code) and no coverage instrumentation.

---

## 2026-10-25 — One batch at a time; renders that can't go stale (step 6b)

### Fixed
- **A second folder during a load** (opened or dropped) is now queued and loads after the first. Before, both ran at once and the first to finish cleared "busy": the progress bars disappeared and Cancel greyed out while the second load was still running (CODE_AUDIT §3.1).
- **Reset during a load** stops it first. Before, the load kept the GPU busy and could still add its frames to the emptied session.
- **Turning colour on during a load** now runs after the load, so every frame ends in colour, including the ones that weren't loaded yet when colour was turned on (before, those stayed grey). **Turning it off during a colour load**, or on and off quickly, ends on the last setting: a render of an earlier setting no longer replaces a newer one (§3.2).
- **Cancel** now also stops a colour re-render, and starts no new star detection: frames still waiting for it are released at once instead of being measured one by one after Cancel (§3.4).
- **Folder access** (App Store build): kept until all of a batch's work has ended, also after Cancel, so late renders no longer fail silently (§3.6).
- **Rejecting a frame while it waits for a re-render**: the re-render reads the file at its new place in REJECTED instead of failing silently (§3.9).

### Changed
- A colour toggle is a batch: Cancel is active while it runs. The info bar still shows only its own Sampling / Restretching bars.
- A display-size change in Settings during a load waits for the load.
- The time on the info bar ("…s for n images") is the batch's own time from when it starts, not from when it was queued.

### Improved
- **Memory with many folders or filters:** all re-reads and re-renders (colour per folder, grey normalisation per folder and filter, colour sampling, grey re-render, metrics recompute) share one limit of max(4, cores − 2) at a time, instead of each folder or group having its own. Phase A and Phase B keep their own limits (§3.5).
- **Folder bookmarks** are resolved once per folder for a batch instead of once per frame, on the main thread; access is stopped only where it was started, also for reject and undo (§7.6).

### Internal
- `LoadPipeline.enqueueBatch`: each batch waits for the one before it (also for a cancelled one's work still in flight); only the newest clears "busy" (`processingBatchID`); cancelling a batch cancels the ones queued before it. `openFiles`, `regenerateSizes`, `recomputeMetrics` and `recolorImages` use it; the frames to work on, the duplicate check and "select the first frame" are taken when the batch starts.
- `renderGeneration`, raised by a colour toggle and by Reset: colour and grey re-renders of Bayer frames update the display only while their generation is current; the render caches are filled either way. A colour toggle that is already stale when its turn comes is skipped.
- `AsyncSemaphore.wait()` returns false, without a slot, when the task is cancelled before or while waiting.
- After Cancel the colour renders of a batch are cancelled and the batch waits for the work already running (`waitForSpawned`); `reset()` calls `pipeline.reset()` first. `accessFolders(for:)` replaces the per-frame `accessDirectory` calls of the batches; `accessDirectory` returns whether access was started.
- Helpers for the copied code (§9.9): `forEachWithRenderSlot`, `spawnColourRender`, `megapixels(of:)`; the caps are named constants (`phaseAConcurrency`, `phaseBConcurrency`, `renderConcurrency`, concurrency part of §9.14).
- Tests: `BatchQueueTests` (order, busy until the last batch, Cancel and Reset stop running and queued batches, a batch after Cancel waits for the cancelled one, the same folder twice, Reset during a load, a size change queued behind a load, a queued re-render after a reject), `AsyncSemaphoreTests` (cancelled waiters get no slot), `RenderGenerationTests` (on then off, off then on, colour on and off during a load, three quick toggles, Reset during a colour render, a toggle without Bayer frames), on synthetic RGGB frames. The new suites have a one-minute time limit.
- **Measured** (CLI, full pipeline, the step 5 build and this one alternated, 3 rounds): Rosette large (464 mono frames, 8 folders × 3 filters) **peak memory 4.3–4.5 GB → 1.0 GB**, time 11.6–14.4 s → 10.7–10.8 s; M81 grey (355 frames, 3 folders) 13.3–15.9 s → 13.2–14.5 s, 2.2–2.4 GB both; M81 in colour 36.5–37.8 s → 37.3–38.4 s (≈ 1.6 % slower on average, about the run-to-run spread), 2.8–2.9 GB both. Unit tests (294), render tests and the 10 metric baselines pass unchanged; the strict build has the four known warnings.
- VM smoke test passed on macOS 15.8.1, 26.6.2, 27.0.1 and 27.2 (0 failed, 0 warnings). 👤 Checked in the app: a second folder during a load, Reset during a load, colour off / on during a load, three quick toggles and Cancel during a re-render, a display-size change during a load, Cancel in Geek mode then the next folder, drag and drop of folders, files and a mix.
- Not changed: switching to Geek mode while a batch runs still doesn't recompute the missing metrics (`recomputeMetrics` skips during a batch, as before); because a colour toggle is now a batch, this also applies while a colour re-render runs.

---

## 2026-10-25 — Loading pipeline in its own type (step 6a)

### Internal
- New `LoadPipeline` (`@Observable @MainActor`), owned by `ImageStore` as `store.pipeline` with a weak reference back. It holds the batch state the progress UI shows (`isBatchProcessing`, `batchElapsed`, `batchMegapixels`, `batchImageCount`, the restretch and sampling counters, `restretchingMessage`, `preparation`), the tasks (`processingTask`, `dropScanTask`), `cancelProcessing`, `waitForProcessing`, and the load and re-render functions (`openFiles`, `regenerateSizes`, `recomputeMetrics`, `processParallel`, `recolorImages`, grey and colour normalisation). Reset clears the batch state through `clearBatchState()`, as before.
- The per-file work (`filterItems`, `loadFast`, `loadMetricsOnly`, `recolorBayerEntry`) and `FastLoadResult` are in `FrameLoading.swift`; `FolderTracker` and `AsyncSemaphore` have files of their own. `ImageStorePipeline.swift` is gone.
- Callers read `store.pipeline.…` (MainContent, FITSToolbar, SessionChartView, ContentView, SettingsView, CLIRunner, Open Folder and drag and drop, and the tests).
- Only code moved: no behaviour change. Unit tests, render tests and the 10 metric baselines pass unchanged; the strict build has the same four known warnings (CODE_AUDIT §3.3).
- **Pipeline benchmark** for step 6 (CLI, full pipeline, 3 runs each; before this commit): M81 355 colour frames grey 16.0–17.3 s, peak memory 2.2 GB; M81 in colour (`--render`) 35.9–38.3 s, 2.8–2.9 GB; Rosette large 464 mono frames 12.9–13.3 s, 4.2–4.5 GB. After this commit the same within noise when the two builds are run alternately (colour 34–36 s, mono 12.5–13.3 s for both); separate series drift by up to 10 %, so later comparisons alternate too. `BenchmarkTests` times only the per-frame read and measurement, not the pipeline, so step 6 is measured with the CLI.
- 👤 Checked in the app: Open Folder with progress and the timing line, colour toggle, Cancel during a load, Reset.

---

## 2026-10-25 — Narrower redraws on a cursor move (step 5c)

### Improved
- **Holding an arrow key** — the sidebar scrolls to the cursor without animation while the key is held down, so the animations no longer pile up; a single key press or a click still scrolls with animation (performance audit P5).
- **Fewer redraws per cursor move** — a thumbnail is redrawn only when its own cursor, flag, range or group-statistics state changes, instead of every visible thumbnail on every cursor move or flag (CODE_AUDIT §8.1); scrolling a zoomed frame redraws only the viewport box in the cursor's thumbnail. The sidebar's list no longer depends on the cursor (performance audit P1).

### Internal
- `ThumbnailRow` reads the per-frame state from the store and gives `ThumbnailCell` plain values (`isCursor`, `isFlagged`, `isMarkedForRejection`, `groupStats`); `GroupStats` is `Equatable`. `ViewportBox` reads the viewport itself.
- `SidebarCursorScroller`, an invisible view in the sidebar's scroll view, scrolls to the cursor and seeds the shift-click anchor; the key monitor records key repeats in `ViewerState.isKeyRepeat` (not observed), taken once per cursor move.
- The zoom-anchor marker is placed from the image size × zoom, without `GeometryReader` (CODE_AUDIT §8.6).
- The chart's cursor stays part of the chart for now: drawing it on top would change how the cursor looks with bars and on rejected frames. After the measurement below it isn't needed for smoothness; noted in master-plan step 9, with the thumbnail cells that still re-run on every move.
- **Measured** (after-trace `05-step5-after.trace`, M81 355 frames, Geek mode, chart visible, ↓ held 5 s; Release build): 5 hitches = 0.27 s instead of 39–57 = 1.7–3.6 s before step 5; per move ≈ 25 ms of SwiftUI work outside view bodies instead of 33–40 ms; the chart's mark collection 9.1 ms instead of 13.8 ms (5a); the sidebar's list body no longer runs. Details in `PERFORMANCE_AUDIT.md`, Metrics.
- 👤 Checked by hand: holding ↓ (smoother), thumbnail highlights, flags, ranges and badges, shift-click right after loading, the viewport box, the zoom anchor while zooming.
- Tests: `ViewerStateTests` checks that a key repeat is taken once.

---

## 2026-10-25 — Viewer state out of the image store (step 5b)

### Improved
- **Fewer redraws while scrolling a zoomed frame** — the viewport box in the cursor's thumbnail is updated only when it moves visibly (by 0.1 % of the frame or more, less than a pixel on any thumbnail), instead of on every scroll frame; the scroll position kept for the next frame is no longer observed by any view (performance audit P4).

### Internal
- New `ViewerState` (`@Observable @MainActor`, in the environment of the main and Settings windows) holds the display contrast, playback, the viewport fraction and centre, the zoom anchor and the Fit / centre-on-anchor triggers, which were in `ImageStore`. Views that only read the session no longer depend on scrolling and playback state. `startPlayback(store:settings:)` gets the store as a parameter; one playback step is `advancePlayback`. Reset in the toolbar resets both.
- Playback still stops when the filter strip or the rejection visibility changes; `ContentView` now does that (it was in the store's `didSet`s).
- Tests: `ViewerStateTests` (playback steps in sidebar order and ends after the last frame or without a cursor, start/stop, Reset restores the defaults, viewport fraction and centre from the scroll geometry, clamping, empty content ignored, a change below the tolerance isn't written or observed, a visible one is).
- 👤 Checked by hand: zoom (slider, pinch, 1:1, Fit, fit after Inspector / Simple mode), scroll and the viewport box, the scroll position kept on ↓, zoom anchor and centre on anchor, stretch and Defaults, playback (button, key, speed slider, stops on filter strip, visibility and ↓), Reset while playing, Settings.

---

## 2026-10-25 — Header facts computed once (step 5a)

### Internal
- **Header values are cleaned once**, when the file is read: `FITSReader` stores each value through `cleanHeaderString` (quotes and padding removed), so the Inspector, the export and the header pickers no longer clean them on every access.
- **`ImageEntry` stores the facts derived from its headers** — `filterName`, `filterGroup` and `bayerPattern` (with `isBayer`) are set when `headers` is set, instead of being parsed from the headers on every access (CODE_AUDIT §7.5). The loading pipeline uses the stored Bayer pattern (`FastLoadResult.bayerPattern`, `FITSImage.bayerPattern`, `entry.bayerPattern`); `BayerPattern.parse` is now only called by the reader and the entry.
- No visible change: a one-time check over all 296 frames of the baseline test sets gave the same filter names, filter groups and Bayer patterns as the old code, and the cleaned headers equal the old values after cleaning. Unit tests, render tests and the 10 metric baselines pass unchanged.
- Tests: `HeaderFactsTests` (facts stored, no or empty FILTER, facts follow a header change, the reader cleans string values and leaves numbers alone). `ExportTests` now gives its empty-key fixture the cleaned value `""`, as the reader would.
- 👤 Before-trace for step 5 recorded (`05-step5-before.trace`, build of 069105f: M81, 355 frames, Geek mode, chart visible, ↓ held 5 s).

---

## 2026-10-25 — Opening folders over the network: 5× faster, with progress

### Improved
- **Much faster on network folders** — before the frames appear, FITS Blaster lists the folder and reads each file's header to skip unsupported files. On an SMB share from another Mac (1 Gb/s, wired, the M81 folder with subfolders, 1147 files), that took 26 s for the listing and 50 s for the headers; now about 1 s and 13 s. The listing uses `readdir` instead of `FileManager` (about 35× faster on that share, measured 2026-10-25), the header is read with `open`/`read` instead of `FileHandle` (about 4×), and 8 headers are read at a time (about 6×).
- **Progress while preparing a load** — "Scanning <folder>…" with a spinner, then "Checking files" with a bar and a counter, in the empty window on a first load and in the info bar above the chart when frames are already loaded. Before, the window stayed blank, which over a network could last a minute.
- **Dropped folders are scanned off the main thread too**, like Open Folder, so dropping a large folder tree no longer freezes the window (CODE_AUDIT §7.4).

### Fixed
- **The info bar disappeared** when a frame that wasn't rendered yet was selected; it now stays, with its progress bars.

### Changed
- Files with the Finder "hidden" flag are no longer skipped when a folder is scanned (files whose name starts with a dot still are): checking the flag would cost a network request per file.

### Internal
- `collectFITSURLs` lists folders with `readdir` (`listDirectory`; `lstat` when the file system doesn't report the type) and resolves the folder path with `realpath`, as `FileManager` did; a test compares it with the old `FileManager` scan on a tree with hidden files, REJECTED at two levels, an excluded FLAT folder, accented names and numeric sorting: same files, same order, in all four subfolder/REJECTED combinations.
- `filterItems` checks headers in a bounded task group (`headerChecksAtOnce` = 8), keeps the input order, and reports progress through an `AsyncStream` that the loading task reads; the store's `preparation` holds the status. Drops scan in `dropScanTask`, owned by the store (cancelled with the load; a second drop waits for the first).
- Loading itself (`loadFast`, reading whole files) may have the same Foundation overhead on a network share; to be measured in master-plan step 9.
- `docs/internal/architecture-plan.md` step 9: start loading as soon as the first files are checked, instead of after all of them (requested).

---

## 2026-10-25 — Drag and drop: rejecting works in the App Store build, a section per folder (step 4c)

### Fixed
- **Rejecting dropped frames in the App Store version** — frames dragged in as single files couldn't be rejected ("folder access unavailable"): the sandbox only grants access to the dropped files, not to the folder where REJECTED goes. Rejecting one now asks once for access to its folder (an open panel pointed at it); after Allow, the frame moves into REJECTED, and the question isn't asked again for that folder while FITS Blaster runs, also not for files from it dropped later. Cancel moves nothing. The website version has no sandbox and never asks (CODE_AUDIT §5.13).
- **Several dropped folders** — every frame got the folder access of the first dropped folder, so in the App Store version frames from the other folders couldn't be rejected. Each folder now keeps its own access.
- **A sidebar section per dropped folder** — dragging in several folders at once put all frames in one list without headings; each folder now gets its own section, as when folders are opened one after the other. Dropped single files appear under the name of their folder.

### Internal
- The store keeps one security-scoped bookmark per opened, dropped or granted folder for the session (`sessionBookmarks`), and each new frame gets the bookmark of its own folder; `openFiles` no longer takes one bookmark for the whole batch. A missing permission becomes a `FolderAccessRequest` that `ContentView` answers with `FileDialogs.requestFolderAccess`; only in the sandboxed build (in the website build a permission error, e.g. on a read-only share, stays an error).
- Tests: `FolderAccessTests` (bookmarks per dropped folder, lookup, asking then rejecting, cancel, a different folder chosen, the website build, permission errors; a read-only folder stands in for the sandbox) and sidebar sections for dropped folders and files. 👤 Checked in the App Store build on macOS 27.2 RC: single files, the question once per folder, undo and reject again, cancel, two folders with headings, the Open Folder checkboxes in the sandbox.

---

## 2026-10-25 — Open Folder: options back in the panel, no frozen window (step 4b)

### Changed
- **Open Folder options in the panel again** — "Include files from subfolders" and "Include REJECTED folder" are checkboxes in the open panel itself, starting from the defaults in Settings → Files & Folders; the separate popover is gone. The checkboxes were moved out in October because they couldn't be clicked on macOS 27 with the panel opened the old way (`runModal`); the panel now opens with `begin`, and they work (checked on macOS 27.0.1).
- **"Folder Already Loaded"** appears as a sheet on the main window.

### Fixed
- **Opening a large folder no longer freezes the window** — the folder scan runs off the main thread, which matters for deep folder trees on a NAS, an SMB share or iCloud Drive (CODE_AUDIT §7.4).

### Internal
- The store's `openFolder(at:includeSubfolders:includeRejected:settings:)` has no panel or alert; `FileDialogs` shows the panel and the question, and the toolbar owns the running flow (⌘O asks the toolbar through `openFolderRequested`). The 300 ms sleep before the panel is gone (§4.2).
- One FITS extension list (`FITSFile`), used by the scan, drops and the pipeline (§9.11); `isDirectory` via URL resource values instead of `fileExists(atPath:isDirectory:)` with `ObjCBool`, and one rule for which frames count as rejected, shared with the command-line mode (§4.4).
- `docs/internal/testing.md`: the manual checks include the panel checkboxes on every macOS version and in the App Store build.
- Tests: `OpenFolderTests` (with and without REJECTED, already loaded, empty folder, the helpers).

---

## 2026-10-25 — Export: column order, safe CSV, errors shown (step 4a)

### Changed
- **Export column order** — the FITS header columns in an export now follow the order chosen in Settings → Export (the order in which keys were ticked), also from the Export sheet, which used to sort them alphabetically. Keys ticked in the sheet come last (decision 9 of the master plan).
- **Safer CSV and TSV** — a text value that starts with `=`, `+`, `-` or `@`, such as an OBJECT header from someone else's files, gets a leading `'`, so Excel and Numbers show it as text instead of running it as a formula. Numbers such as `-10.0` (CCD-TEMP) are left alone. CSV cells with a carriage return are quoted, and TSV replaces it with a space (CODE_AUDIT §6.2).

### Fixed
- **A failed export is reported** — when the file can't be written, an error now says so; before, the export failed silently (§5.7).

### Internal
- The export is built once as a table (`ExportTable`) and rendered as CSV, TSV or the aligned text report; the command-line mode and `CLIRenderer` use the same cell rules. The default header keys, the curated key list and key discovery live in `ExportHeaderKeys`; Settings and the Export sheet share one `HeaderKeyPicker` (§9.11, export part).
- The save panel moved out of the store into `FileDialogs` and opens with `begin` instead of `runModal`; the store's `export(to:…)` gets the chosen URL (master-plan step 4).
- The CSV output of the command-line mode is byte-identical to 1.24-beta.1 on M31, California, ASI294MM SHO and M42 (with and without REJECTED, absolute paths, filtered).
- Tests: column order, formula prefixes, quoting, TSV cells, `export(to:)`, a failed write, key discovery.

---

## 2026-10-24 — Testing: a cloned, checked copy of the test data

### Testing
- **Baseline copy of the test data** — the metric baselines and the rendering tests now read `/Volumes/FITS Blaster/Test Data (baselines)`, APFS clones (`cp -c`) of the eight sets in `Test Data`: separate files that share their data, so 11 GB of frames took about 1 MB. Rejecting or moving frames in `Test Data` no longer breaks the tests (on 2026-10-24 four M31 frames moved back from REJECTED and m31-night failed although no metric had changed).
- **Manifests** — `tests/baselines/<set>.sha256` lists the files each set's tests read, with SHA-256. `metric-baselines.py` (before the build) and `run-render-tests.sh` check them first and stop with "TEST DATA CHANGED" and the missing, extra or changed files (exit 2) instead of reporting metric differences. Checking all sets takes about 9 seconds.
- **M42 10 s and 180 s** added as baseline sets (`m42-10`, `m42-180`): one night, two exposure times. Their baselines record today's values, which are known to be wrong across exposure times (star count and SNR fall at 180 s); a fix in master-plan step 13 will change them on purpose.
- New `scripts/baseline-data.py` (`create`, `verify`, and `restore`, which clones frames missing from `Test Data` back from the baseline copy without overwriting anything) and `scripts/testdata.py` (the set list, shared by the scripts). `docs/internal/testing.md` explains the copy and how to change a set on purpose. `__pycache__/` added to `.gitignore`.
- `docs/internal/FWHM-comparison.md`: the M42 median SNR of FITS Blaster is 249 (10 s) and 127 (180 s), not 233 and 128 as written on 2026-10-23.

---

## 2026-10-24 — 1.24 beta 1: keyboard, REJECTED folder and chart fixes

### Fixed
- **Keyboard shortcuts only act in the main window.** Pressing a shortcut key in Settings, a sheet or a popover no longer flags, removes or rejects frames in the main window. Recording a shortcut on a key that's already in use works again.
- **Undoing a rejection never deletes hidden files.** The REJECTED folder is only removed when nothing but Finder's `.DS_Store` is left in it.
- **A frame rejected in this session no longer loads twice** when you reopen the folder with its REJECTED folder.
- **Session chart while loading:** dots appear at their final place, and clicking one selects the right frame.
- Removing frames no longer leaves them in the reject selection.

### Improved
- **Text size** (Settings → Interface → Appearance) now also applies to the chart's axis and hover labels and to the flag and flip badges on thumbnails.
- **VoiceOver** announces the image as a button that sets or clears the zoom anchor.
- The explanation under Settings → Display → Colour Images is corrected.

### Under the hood
- About 500 lines of unused code removed and many outdated comments corrected, in preparation for the next 1.24 steps. Measurements and image rendering are unchanged.

---

## 2026-10-24 — Stale comments and docs

### Changed
- **Settings → Display → Colour Images** — the explanation under "Debayer colour FITS images" no longer mentions bilinear debayering or "Reprocess All" (neither exists): images are debayered on the GPU, and loaded images are re-rendered when you change the setting.

### Internal
- Comments that named removed functions or described old behaviour rewritten (CODE_AUDIT §9.13, master-plan step 3d): `reprocessAll`, `normalizeBayerStretch` and crop extraction in the loading pipeline; "asinh stretch" and "gamma 2.2 LUT" (the stretch is STF clip + MTF); "bilinear" colour debayering (each displayed pixel averages whole 2×2 Bayer cells); PSF Signal Weight described as integrated flux (it is the mean star peak divided by the sky sigma); the GPU detection flow (a compact candidate list, 400 KB, not a full-frame flag buffer); `computeFWHM` as an example setting; the old open-folder panel in `ExportPanel`.
- The grey stretch kernel is renamed `sqrtStretch` → `mtfStretch`, with its Swift lookup string.
- `SwiftUI-Review.md` moved from the repo root to `docs/internal/` and marked historical (April 2026); `docs/internal/performance.md` notes that its root-cause analysis describes the v1.12.4 design.
- Renders and metrics are identical.

---

## 2026-10-24 — Refactor: metrics are all on or all off

### Internal
- `MetricsConfig` is now a single on/off switch (`computeMetrics`, with `MetricsConfig.off` for Simple mode) instead of four per-metric switches that the settings only ever set all on or all off (CODE_AUDIT §9.10, master-plan step 3c). `MetricsCalculator` always fills in all four metrics; `FrameMetrics.filtered(by:)` returns the metrics unchanged when on, and hides FWHM, eccentricity, SNR and star count (score 0, sky and PSF Signal Weight kept) when off, as before. `merging` and `covers` are gone, and `recomputeMetrics` measures a frame from disk only when it has no cached metrics.
- One difference with no visible effect: a frame whose cached metrics lack a value (e.g. stars counted but no FWHM fit) is no longer read from disk again on every switch to Geek mode; the calculation is deterministic, so that read always gave the same result.
- Tests: the partial-config tests in `FrameMetricsTests` became on/off tests; `IntegrationTests` and the GPU tests use `MetricsConfig()`. New `MetricsModeSwitchTests` switches a loaded folder off and on (from the cache) and loads in Simple mode then switches on (from disk); both give exactly the values of a normal load, on the old code as well as the new.

---

## 2026-10-24 — Refactor: never-read fields and unreachable branches

### Internal
- Fields nobody reads removed (CODE_AUDIT §9.2, master-plan step 3b): `bzero` and `bscale` on `FITSMetadata` and `FITSImage`, `FastLoadResult.metalDevice` and `.bitpix`, `GPUDetectionResult.totalFound`, the unused `device` parameter of `MetricsCalculator.compute(metalBuffer:)` (six test calls follow, and three tests drop a `device` they no longer use), and the unused `MetricsCalculator.cropSide`.
- Unreachable branches (§9.3): the plain-text case of CSV/TSV quoting and the sky-background case of the metric export now assert, since neither can be reached. The colour-camera stretch kernel (`bayerDebayerAndStretch`) loses its `bayerBin` parameter, which was always 1; the kernel keeps that path only, and the Swift and Metal parameter structs shrink from 60 to 56 bytes together.
- No behaviour change: renders and metrics are identical.

---

## 2026-10-24 — Refactor: dead code removed

### Internal
- About 450 lines with no callers removed (CODE_AUDIT §9.1, master-plan step 3a), each re-checked with a grep over all targets and tests first:
  - the crop-based star pipeline (`extractStarData`, `measureFromCrops`, `StarMeasurementCandidate`, `StarDetectionData`, `measureFWHMOnlyFromCrop`), a near-copy of the live one;
  - `reprocessAll`, `openFilesPanel` and the flat `openFiles(_: [URL])` overload only it called;
  - `rejectEntries` and `applyAutoReject`, `formatFraction`, `compute(ptr:)`, `makeSharedBuffer`, `estimatePercentiles`, `groupedSortedEntries`, `FolderGroup.totalCount`;
  - the 17 `*KeyEquivalent` properties in `AppSettings` and their mapper (the menu builds its own);
  - the empty `MainContentViews.swift` and the outdated `scripts/Create-installer.sh`.
- No behaviour change: renders and metrics are identical.

---

## 2026-10-24 — Text size, VoiceOver and small SwiftUI cleanups

### Improved
- **Text size** — the chart's axis labels and hover label, and the flip and flag badges on thumbnails, now follow the text-size setting (Settings → Interface → Appearance) like the rest of the app (CODE_AUDIT §8.3).
- **VoiceOver** — the image is announced as a button that sets or clears the zoom anchor (§8.8).

### Changed
- The tooltip delay (500 ms) is registered as a default instead of being written to the user's settings on every launch (§4.7).
- Code: direct binding for the export header keys, an `isShowingError` property for the error alert (§8.4), and the closure form of `overlay` (§8.7).

### Docs
- `docs/internal/architecture-plan.md` — release split: steps 2–15 are version 1.24, starting with 1.24-beta.1 (build 210) after steps 2–3.

---

## 2026-10-23 — Fixes: shortcuts in other windows, REJECTED folder, chart, removing frames

### Fixed
- **Keyboard shortcuts acted on the frames from other windows** — pressing a bound key in Settings, a sheet or a popover (reject, remove, flag, arrows) acted on the main window's frames; rejecting even moved a file. Recording a shortcut on a key that was already bound triggered the action instead. Shortcuts now only act on the frames when the main window has the focus (CODE_AUDIT §5.5).
- **Undo of a rejection could delete hidden files** — when the last frame left the REJECTED folder, the folder was deleted together with any hidden files in it. It's now only removed when nothing but a Finder `.DS_Store` is left (§5.6).
- **A frame rejected in this session loaded twice** when the folder was opened again with its REJECTED folder (§5.8).
- **Session chart** — while some frames had no value yet (still loading, or no stars), the last frames fell off the right edge and clicks selected the wrong frame (§5.9).
- **Removing frames** left their IDs in the reject and cursor state (§5.15).

### Testing
- New `RejectedFolderTests` (§5.6, §5.8) and a new case in `RemoveSelectedTests` (§5.15); each fails with the old code.

---

## 2026-10-23 — Docs: why star count and SNR fall on long OSC exposures

### Docs
- `docs/internal/FWHM-comparison.md` — set 3, star positions on a 10 s and a 180 s M42 frame against a reference star list. Two causes: the background σ of colour-camera frames is taken from the raw Bayer mosaic and includes the R/G/B sky spread (25 against a real 16–19 at 10 s, 320 against 59–72 at 180 s), which raises the detection threshold and lowers SNR and PSF Signal Weight (both divide by σ); and saturated stars are missed (16–18 % found, METAL_REVIEW M3). Open question 3 answered; new question 4 on extra detections in bright nebula.
- `docs/internal/METAL_REVIEW.md` M3 — the M42 measurement added.
- `docs/internal/architecture-plan.md` step 13 — both findings noted as input; no decision yet.

---

## 2026-10-23 — Docs: M42 OSC comparison with PixInsight, 10 s and 180 s

### Docs
- `docs/internal/FWHM-comparison.md` — set 3: M42 (IMX571 OSC, 10 s and 180 s) against SubframeSelector, run on the raw and on the debayered frames. Raw OSC frames give PixInsight wrong star counts, SNR and PSF Signal Weight, so OSC data are compared after debayering. Within one exposure time FWHM, eccentricity and the score rank the frames like PixInsight; across exposure times FITS Blaster's star count and SNR fall where PixInsight's rise although longer exposures should give more stars and a higher SNR (open question 3; saturated stars, METAL_REVIEW M3, suspected but not checked). FWHM reads 18 % high at about 3.4 px; added to source of difference 6.

---

## 2026-10-23 — Testing: quick-test VM on the internal volume, base VMs settle before shutdown

### Testing
- **Two Tart homes** — `fb-27-beta` now lives on the FITS Blaster volume for quick tests; `fb-15`, `fb-26` and `fb-27` stay on the external SSD, which is only connected for releases. Each VM is in one home only; `tart-lib.sh` finds it (`tart_home_of`, `tart_use`) and `vm-smoke.sh` makes the clone next to its base. Without the SSD: `vm-smoke.sh --tart fb-27-beta` works; `vm-test-all.sh` tests fb-27-beta, reports the others as SKIP and ends as failed with "NOT A FULL RELEASE TEST"; `tart-cleanup.sh` checks the volume that is there; the other scripts stop with a message about the drive. Nothing is written under `/Volumes` when the drive is missing (tested with the drive unplugged). New base VMs go on the SSD unless `TART_HOME` is set.
- **Base VMs settle before shutdown** — after a first boot or an update, macOS works for 10–15 minutes (Apple Intelligence, widgets, Shortcuts, XProtect). A base VM shut down earlier makes every clone redo that work: on `fb-27` the load in a clone went past 170, runs took over 10 minutes, scp lost its connection and Gatekeeper's online notarisation check failed. All four base VMs were started once and shut down after the load stayed under 1.5 for 5 minutes (13–16 minutes each); a full `vm-test-all.sh` run now takes 5 minutes, all PASS. `tart-create-base.sh` does this itself before its final shutdown (`tart_wait_quiet` in `tart-lib.sh`). `docs/internal/testing.md` covers both changes.

---

## 2026-10-23 — Quick Look on macOS 15 and 26, neutral colours, reproducible metrics

### Fixed
- **Finder thumbnails and Quick Look previews on macOS 15.6 to 26.1** — FITS files showed no thumbnail or Space-bar preview on these versions; the Quick Look extensions only worked from macOS 26.2. They now work on every macOS version FITS Blaster supports.
- **Colour cast in the colour view** — with Colour on, a folder could be shown with a strong colour cast (the M31 sample set looked magenta). The sky background now stays neutral.
- **Reproducible metrics** — opening the same folder twice always gives the same star counts, SNR, PSF Signal Weight and eccentricity. Values on affected frames change once, by no more than they already varied.
- **Damaged or unusual FITS files** no longer crash FITS Blaster or Quick Look; they're skipped with an "Invalid FITS format" message. Images larger than 65,536 pixels per side are not supported.
- **Full screen with the keyboard** — fn-F and ⌃⌘F now switch to full screen (fn-F used to flag the selected frame), and other 🌐 shortcuts such as 🌐E reach macOS.
- **Load speed** in the info bar is correct again after opening another folder.

---

## 2026-10-22 — Testing: Tart VMs on the external SSD

### Testing
- **Tart VMs moved** to the external SSD "FITS Blaster External": `scripts/tart-lib.sh` now uses `TART_HOME=/Volumes/FITS Blaster External/Tart` by default and stops with a clear message when the drive isn't connected (Tart would otherwise quietly start an empty `~/.tart`); nothing is written to the drive path before that check. `tart-create-base.sh` and `vm-test-all.sh` show their usage without the drive; `vm-smoke.sh --host` doesn't need it. All four VMs were copied with their disk images kept sparse and are byte-identical to the originals (SHA-256). `vm-test-all.sh --tag v1.23.1-beta.3` from the drive: fb-15, fb-26, fb-27 and fb-27-beta pass (fb-27 after a rerun; the first try couldn't reach api.github.com for the DMG). `docs/internal/testing.md` has the new location and notes on copying VMs between volumes.
- `scripts/tart-copy-vm.py` (new) — copies a VM folder to another volume with the disk image kept sparse, at drive speed (only the data regions; `cp -Rp` managed about 0.6 MB/s). Refuses an existing destination or a missing parent folder, so nothing is written under `/Volumes` when a drive isn't connected.
- **Instruments traces** moved to `/Volumes/FITS Blaster External/Traces` (archive); the paths in `docs/internal/PERFORMANCE_AUDIT.md` follow.

---

## 2026-10-22 — Testing: longer countdown in the screenshot script

### Testing
- `scripts/appstore-screenshots.sh` — the countdown before each capture is now 10 seconds (was 5), enough to switch back to FITS Blaster in full screen and open a popover. `DELAY=<seconds>` still overrides it.

---

## 2026-10-22 — Testing: smoke test for App Store builds

### Testing
- `vm-smoke.sh` / `vm-test-all.sh --appstore` — tests a local App Store build: Sparkle must be absent and the app sandboxed (a network entitlement warns); command-line checks, rendering and metric baselines are skipped, because App Store builds have no command-line mode. Install, signature, launch, crash and log checks and Quick Look run as usual. The App Store build 1.23.1 (208) passes on fb-15, fb-26, fb-27 and fb-27-beta (27.2 RC). `docs/internal/testing.md` has a section on it.

---

## 2026-10-22 — App Store build 1.23.1 (208)

### Changed
- **App Store configuration** — the app and both Quick Look extensions go from 1.23 (202) to 1.23.1 (208), for the App Store submission with everything since 1.23 (beta 1–3). Debug and Release stay at 1.23.1-beta.3 (207). A local App Store build was checked: all three bundles 1.23.1 (208) with minimum macOS 15.6, no Sparkle in the bundle (linked weak only), sandbox with user-selected read-write and app-scope bookmarks, no network entitlement, no command-line mode.

---

## 2026-10-22 — Testing: fb-27-beta now runs the macOS 27.2 RC

### Testing
- **fb-27-beta** rebuilt from the macOS 27.2 release candidate (26B118, installer checked against its published SHA-256) with the 80 GB disk; replaces the 27.2 beta 3 VM. The published 1.23.1-beta.3 passes the smoke test on it. `docs/internal/testing.md` updated.

---

## 2026-10-21 — Full screen with the keyboard

### Fixed
- **fn-F flagged a frame instead of switching to full screen** — fn-F (🌐F), the macOS shortcut for Enter Full Screen, was handled as a plain F and flagged the selected frame. It now switches to full screen, and other 🌐 shortcuts such as 🌐E (Emoji & Symbols) reach macOS as well.
- **⌃⌘F did nothing** — Control-Command-F now switches FITS Blaster to full screen and back, as in other Mac apps.

---

## 2026-10-21 — Testing: ASI294MM SHO in the metric baselines

### Testing
- **Eighth baseline set: ASI294MM SHO** — 30 mono narrowband frames (H, O, S; `.fit` files, single-letter filter names), the first real mono narrowband set in the baselines. 29 of 30 frames pass the standard filter (H #0002 drops out on eccentricity 0.507).
- `scripts/metric-baselines.py --only <name>` — check one dataset (repeatable); with `--update` only that dataset's baseline is written, so adding a set doesn't rewrite the others. `docs/internal/testing.md` updated.

---

## 2026-10-21 — Site: stable-only changelog, all betas of a round on the beta page

### Site
- **Changelog page = stable releases only** — the hand-added entries for 1.23 beta 2 to beta 9 are gone (the v1.23 entry covers them); a line under the title points to the Beta page for beta notes.
- **Beta page keeps every beta since the last stable release**, newest first, each with a link to its GitHub release (where its DMG stays available); the download button is for the newest beta. Filled with 1.23.1 beta 1 and beta 2.
- `scripts/update-site.py` — a beta tag adds its entry on top of the list (once) instead of replacing it; a stable tag also empties the list and greys out the download button ("No beta available", no link) until the next beta. `release.yml` commits `site/beta.html` on stable releases too.

---

## 2026-10-21 — Docs: FWHM comparison on mono data

### Docs
- `docs/internal/FWHM-comparison.md` — new section comparing FITS Blaster (1.23.1-beta.2) with PixInsight SubframeSelector (Moffat β = 4) on two mono sets with small stars: ASI294MM SHO (30 frames, H/O/S) and Rosette R/G/B (58 frames, IMX585). FWHM ranks the frames the same (r ≈ +0.98 to +1.00 per filter) but reads 18–22 % higher, more so for smaller stars; PSF Signal Weight ranks well; eccentricity well on Rosette, moderately on SHO; SNR doesn't track PixInsight within a filter. Two open questions for master-plan step 13 at the earliest; new source of difference 6 (small stars) with the offset per set.

---

## 2026-10-20 — Testing: App Store screenshots, fb-27 VM

### Testing
- **App Store screenshots** — `scripts/appstore-screenshots.sh` makes Mac App Store screenshots at an exact 16:10 size: window mode sets the FITS Blaster window to 1440 × 900 points and captures that area (2880 × 1800 on Retina, popovers and sheets included); `--fullscreen` captures the whole main screen and scales it to 2880 × 1800. A countdown after Enter leaves time to open a popover. `scripts/appstore-flatten.swift` removes the alpha channel (colour profile unchanged), which App Store Connect can refuse.
- **fb-27 VM** — base VM for the newest macOS 27 release (27.0.1, 80 GB disk) created with `tart-create-base.sh`; the beta 2 smoke test passes on it. `vm-test-all.sh` now tests all four VMs (fb-15, fb-26, fb-27, fb-27-beta). `docs/internal/testing.md` updated.

---

## 2026-10-20 — Fix: full screen with ⌃⌘F and fn-F

### Fixed
- **fn-F flagged a frame instead of entering full screen** — FITS Blaster's own key handling treated fn/🌐 + a letter as the plain letter, so fn-F (Enter Full Screen) flagged the selection, and other 🌐 shortcuts such as 🌐E (Emoji & Symbols) could trigger FITS Blaster keys. Letters pressed with fn now go to macOS; arrow, Home and End keys work as before.
- **⌃⌘F did nothing** — on macOS 27, SwiftUI windows don't respond to ⌃⌘F, although AppKit apps such as Safari do (measured with an empty SwiftUI app). FITS Blaster now toggles full screen on ⌃⌘F itself, the same way as View → Enter Full Screen.

### Testing
- `SystemKeyShortcutTests` — ⌃⌘F toggles full screen; fn + a letter goes to macOS; fn + arrow keys, plain keys and other F combinations stay with FITS Blaster.

---

## 2026-10-20 — Site: Mac App Store badge on the homepage

### Site
- **Mac App Store badge** — the homepage shows Apple's "Download on the Mac App Store" badge under the download button, with a line that the App Store version has no command-line mode or beta updates. The badge is Apple's artwork, unmodified (`site/mac-app-store-badge.svg`). The structured data links the App Store page (`sameAs`).
- **Deploy site workflow** — `.github/workflows/site.yml` uploads `site/` from main when started by hand (Actions → Deploy site → Run workflow), so site-only changes don't need a release. Releases still deploy the site themselves.

---

## 2026-10-20 — Quick Look on macOS 15 and 26, safer with damaged files

### Fixed
- **Finder thumbnails and previews on macOS 15.6 to 26.1** — FITS files showed no thumbnail or Space-bar preview on these versions; the Quick Look extensions only worked from macOS 26.2. They now work on every macOS version FITS Blaster supports.
- **Damaged or unusual FITS files** — a file with impossible image sizes, invalid scaling values, a missing end of header or cut-off data could crash FITS Blaster, or Quick Look in Finder. Such files are now skipped with an "Invalid FITS format" message. Images larger than 65,536 pixels per side are not supported.
- Very small images (under 3 × 3 pixels) no longer crash the star measurement on Macs without Metal.

---

## 2026-10-20 — Fix: Quick Look on macOS 15, no crash on malformed FITS files

### Fixed
- **Quick Look on macOS 15.6–26.1** — Finder showed no FITS thumbnails or previews on these versions, because both Quick Look extensions were built with macOS 26.2 as their minimum (inherited from the project). They now have 15.6, like the app (CODE_AUDIT §5.1).
- **Malformed FITS files** — negative, zero or huge image sizes, sizes whose product overflows, NAXIS outside 2–999, non-finite BSCALE or BZERO (also after conversion to Float), and truncated data now give an "Invalid FITS format" error instead of crashing the app or Quick Look. Images are limited to 65,536 pixels per side (§5.2, §5.3).
- **Header without END** — the parser gives up after 100 header blocks instead of reading the whole file card by card (§5.19).
- **Tiny images** — the CPU star detection returns no stars for images under 3 × 3 pixels instead of crashing (§5.18).
- The histogram and the sky background and star count texts no longer trap on NaN or infinite values (§5.3).

### Testing
- `FITSMalformedInputTests` — 12 kinds of malformed header, each on all three read paths (array, Metal buffer, Quick Look preview), must throw; an image at the size limit and END in the last allowed header block are still read; a 2 × 2 image on the CPU detection path.
- `TestFITS.swift` — one synthetic FITS writer for the tests, replacing the copies in `FITSReaderTests`, `IntegrationTests`, `GPUTests` and `BatchStatsTests`.
- **VM smoke test** — `vm-smoke-remote.sh` now checks that `pluginkit` lists both Quick Look extensions after the app was opened, and that `qlmanage -x -t` (through the Quick Look server, like Finder) makes a thumbnail of a sample frame (the PNG comes back in `out/quicklook/`).

---

## 2026-10-20 — Refactor: shared FITS parsing helpers

### Code quality
- **One card parser** — `peekBitpix` and the header parser in `FITSReader.swift` share one function that splits a header card into keyword and value.
- **One byte-swap per word size** — the 16-bit and 32-bit big-endian swaps are helpers, used by the Metal-buffer and the array read paths.
- **One scale-and-range step** — applying BSCALE/BZERO and finding the min and max was written three times; the three read paths now call one helper.
- No behaviour change: unit tests, render tests and metric baselines pass, and the metrics CSVs are byte-identical to the run before the change (apart from one star on one M31 frame, which also varies between runs of the unchanged code).

---

## 2026-10-20 — Docs: master plan decisions

### Docs
- `docs/internal/architecture-plan.md` — all open questions answered: step 1 ships early as 1.23.1-beta.2; a second folder is queued; Swift 6 mode in step 7; frames without stars get 0 stars and score 0; true median and no relative checks below 3 frames; the CLI writes a header-only CSV with its own exit code when no frame passes; a display-size proxy for fewer reads; sRGB / grey colour spaces; export columns in the Settings order; grey and colour statistics keep their differences; a beta after each group of steps. The plan is ready to start.

---

## 2026-10-20 — Testing: VirtualBuddy VM removed

### Testing
- The VirtualBuddy VM with macOS 27.2 beta 1, kept to reproduce App Review's build 199 crash, was removed after App Store build 202 was approved. `docs/internal/testing.md` and the comments in `scripts/vm-smoke.sh`, `vm-test-all.sh` and `tart-lib.sh` no longer refer to it; testing uses the Tart VMs only.

---

## 2026-10-20 — Testing: 16:10 window for manual VM checks

### Testing
- `scripts/vm-smoke.sh --keep` now starts the clone's display at 1440×900 as well as turning on display refit. With refit alone the window opened at the old 4:3 size, with black bars at the sides and hard-to-read controls until it was resized by hand.

---

## 2026-10-20 — Neutral colours, reproducible metrics, correct load speed

### Fixed
- **Colour cast in the colour view** — with Colour on, a folder could be shown with a strong colour cast; the M31 sample set looked magenta. The shared stretch for a folder now keeps the sky background neutral. Mono frames that share a stretch get the same correction.
- **Metrics varied between runs** — opening the same folder twice could give slightly different star counts, and on some data slightly different SNR, PSF Signal Weight and eccentricity. The same files now always give the same metrics. Values on affected frames change once, by no more than they already varied.
- **Wrong load speed after opening another folder** — the info bar counted every image in the session, not just the ones from the last load, so it could show thousands of MP/s. It now reports only the frames that were just loaded.

---

## 2026-10-20 — Command-line mode, new quality metrics, better colour-camera measurements

### Added
- **Command-line mode** — run the app's executable with a folder path to measure every frame without opening a window and write a CSV of the results. Add quality thresholds to export only the frames that pass. Run it with `--help` for all options, or see the FAQ. Not available in the Mac App Store version.
- **PSF Signal Weight (PSF·S)** — a new metric for transparency and seeing: star peak brightness relative to sky noise. Shown in the inspector, session chart, sort menu, and exports, and available as an Auto-Flag criterion.
- **Sky background** — the sky level of every frame, in the inspector, the session chart, and the sort menu. Auto-Flag can flag frames whose sky is too bright.
- **Export options** — choose FITS header columns (object, exposure, filter, temperature, focus position and more), export as TSV, include rejected frames with a status column, add the quality score, and pick absolute, relative, or filename-only paths. The plain text export is now an aligned, readable report.
- **Play mode** — press P to step through the frames automatically at an adjustable speed.
- **Flip 180°** — press V to rotate the current image, or the selection, for display. The FITS files aren't changed.
- **Session chart** can show bars instead of dots.
- **Zoom** — a fit button scales the image to the viewer, the zoom percentage jumps to 1:1, and clicking the image pins a point that stays centred while you zoom and step through frames.
- **Target Background** slider replaces the Brightness slider, matching PixInsight's convention.
- **Quick Look** previews and thumbnails for floating-point and RGB FITS files, such as stacked integrations.
- **Beta updates** — Settings → Interface → Software Updates can switch on beta releases. Not in the Mac App Store version.
- **Sample data** — an M31 sample set to try FITS Blaster without your own images (see the FAQ).

### Improved
- **Stretch** — a PixInsight-style screen transfer function: darker background, more contrast in faint nebulosity, no blown-out highlights. Mono frames in the same folder and filter share one stretch, so brightness no longer flickers while you step through them.
- **Colour (OSC) cameras** — FWHM and eccentricity are now measured on debayered, full-resolution star images. Rankings agree closely with PixInsight's SubframeSelector.
- **Eccentricity** detects elongated stars at any angle, not just horizontal or vertical.
- **Finder thumbnails** — FITS thumbnails no longer fall back to the app icon in Finder's icon view, and files in iCloud Drive that aren't downloaded no longer stall other thumbnails.
- **Navigation** — each filter group and each view (All, Flagged, Rejected) remembers its selected frame.
- **Sidebar** — filter pills wrap onto more rows, and the sidebar can be made wider.
- **Open Folder options** (subfolders, REJECTED folder) now appear in a popover on the Open Folder button and ⌘O.
- **VoiceOver** labels for the inspector, chart and filter controls.

### Changed
- The quality score always uses every metric that could be measured; the per-metric on/off settings are gone.
- The metric chips above the session chart are now optional (Settings → Display).
- The version downloaded from the website is no longer sandboxed, so command-line mode can read any folder you give it.

### Fixed
- Crash at launch on some macOS 27 versions.
- Filter codes H, O and S showed as "Unfiltered"; they now map to Hα, OIII and SII, and IR to Luminance.
- CSV numbers could lose their decimals with a comma-decimal region setting (Dutch, German, French).
- Dropping a folder on the app icon in the Dock didn't open it.
- In full screen, the window controls didn't appear at the top of the screen, and switching between Geek and Simple mode left an empty column.
- Filter buttons didn't work in sessions with more than one folder.
- The selected frame was lost when switching views or unflagging in the Flagged view.
- The session chart's cursor dot didn't follow navigation, and single-frame folders drew outside the chart.

---

## 2026-10-20 — Testing: readable window for manual VM checks

### Testing
- `scripts/vm-smoke.sh --keep` turns on Tart's display refit for the clone, so its desktop follows the window size instead of a fixed 1024×768 display shown scaled down.

---

## 2026-10-18 — Docs: measured findings in the code audit

### Docs
- `docs/internal/CODE_AUDIT.md` — §11 no longer says nothing in §7 was measured: §7.1 and §7.5 were measured on 2026-10-18; the rest of §7 is still unmeasured.

---

## 2026-10-18 — Fix: load statistics after opening more folders

### Fixed
- **Wrong load speed after opening another folder.** The info bar divided the whole session's images and megapixels by the time of the last load only. Opening a 34-frame folder after 442 others showed about 2,600 MP/s and 100 fps instead of about 190 MP/s and 7 fps. Each load, reprocess, size change and metrics recalculation now reports only the frames it processed.

### Tests
- `BatchStatsTests` — a second load reports only its own image count and megapixels.

---

## 2026-10-18 — Docs: memory, frame switching and scrolling measurements

### Docs
- `docs/internal/PERFORMANCE_AUDIT.md` — Instruments measurements of the last three interactions, on 476 colour frames:
  - Memory: 2.6 GB at display size 1024, but 16.3 GB at 4096, about as much as the Mac has.
  - Switching frames at 4096: about 155 ms of main-thread work per switch, almost all SwiftUI updates. Drawing the big image costs almost nothing there, but SwiftUI converts every new image on a background thread (about 40 ms).
  - Panning the zoomed image: the cursor thumbnail redraws on every scroll frame, as predicted, but costs under 0.5 ms per frame.
  - Loading at 4096 takes about 30–65% longer than at 1024.
- `docs/internal/CODE_AUDIT.md` — §7.1 gets the measured memory use.

---

## 2026-10-18 — Docs: Metal review

### Docs
- `docs/internal/METAL_REVIEW.md` — review of the three Metal kernels and the code that drives them. A run with Metal API and shader validation (223 unit tests, 1,068 real frames through the CLI) found no errors. Findings:
  - The CPU stretch, which Quick Look always uses, is a different algorithm from the GPU kernel, so Finder previews don't match the app (M1, M2).
  - Saturated stars are never detected, because their flat tops have no single brightest pixel. PixInsight and Siril both count them once by default (M3).
  - Three smaller points: fast math, the CPU detection crop and new buffers for every frame (M4–M6).
- `CLAUDE.md` — the rule that the CPU fallback matches the GPU now says it applies once steps 8 and 13 settle it; today it doesn't (M1).

---

## 2026-10-18 — Docs: performance measurements

### Docs
- `docs/internal/PERFORMANCE_AUDIT.md` — first Instruments measurements (Release build, MacBook Air M1), on 355 colour frames (M81) and on 464 mono frames in two folder layouts (Rosette, 24 folders × 1 filter and 8 folders × 3 filters):
  - Holding ↓ gives about 15 screen updates per second instead of 60. The session chart is the main cost: about 16 ms per cursor move, plus about 4 ms because it re-reads each frame's filter from the FITS header. Text layout adds about 6 ms; the sidebar costs only 0.1 ms.
  - During loading the chart is rebuilt about 150 times; each load starts with a pause of about 0.3 s.
- `docs/internal/architecture-plan.md` — storing the header facts (filter, filter group, Bayer pattern) once per frame moves from step 9 to step 5, next to the chart fix; the array work stays in step 9.
- `docs/internal/CODE_AUDIT.md` — §7.5 gets the measured cost and the new step split.

---

## 2026-10-18 — Docs: project guide for Claude

### Docs
- `CLAUDE.md` — project rules for Claude Code, taken from the code and performance audits: FITS files are untrusted input, every target sets the 15.6 minimum explicitly, renders and metrics stay byte-identical, concurrency and SwiftUI performance rules, and VM tests check what users see.

---

## 2026-10-18 — Docs: minimum macOS in the readiness checklist

### Docs
- `docs/internal/readiness.md` — minimum macOS updated from 15.0 to 15.6.

---

## 2026-10-17 — Docs: code audit, performance audit and master plan

### Docs
- `docs/internal/CODE_AUDIT.md` — a full code audit (76 numbered findings with file and line). Key findings:
  - the Quick Look extensions require macOS 26.2, so Finder previews and thumbnails don't work on macOS 15.6–26.1 (reproduced on the macOS 15 test VM);
  - malformed FITS sizes crash the app and the Quick Look extensions (reproduced);
  - frames with no detected stars can't be auto-flagged;
  - shortcuts act on the main window while typing in Settings.
- `docs/internal/PERFORMANCE_AUDIT.md` — a SwiftUI performance review from the code (no measurements yet). The main suspects are cursor movement re-rendering the sidebar, every thumbnail and the whole chart, and the chart rebuilding once per frame during loading.
- `docs/internal/architecture-plan.md` — the master plan: 15 steps that cover the architecture review (the app's structure fits; `ImageStore` gets split), the concurrency fixes and every finding of both audits, each in exactly one step, with the open questions. `docs/internal/concurrency-fixes-plan.md` holds the detailed design for its steps 6 and 7.
- No code changes; the fixes start after the App Store release of 1.23.

---

## 2026-10-15 — Testing: Tart VMs and support levels

### Testing
- **Test VMs moved to Tart** — the VM smoke test can now run unattended: `scripts/vm-smoke.sh --tart <base>` clones a base VM, starts it without a window, runs the checks, compares the metrics with the baselines and deletes the clone. `--keep` leaves the clone running with a window for the manual checks; `scripts/tart-cleanup.sh` removes test clones.
- **Support levels** — macOS 27 and the current 27 beta are fully tested (automatic and manual checks); the latest 15 and 26 releases are tested automatically. `scripts/vm-test-all.sh` runs the automatic level on every base VM, two at a time.
- **`scripts/tart-create-base.sh`** — creates a base VM from a macOS installer: fully scripted for macOS 27 releases (Apple's guest provisioning; beta installers need three clicks on the licence screens), guided with `--manual` for 15 and 26.
- First runs on macOS 15.8.1, 26.6.2, 27.0.1 and 27.2 beta 3: all checks pass, and the sample set renders and measures byte-identically on all four.
- `docs/public/Testing.md` — a one-page overview of the tests, when they run and which macOS versions they cover, for the website.

### Docs
- Minimum macOS stated as 15.6 everywhere (README said 15.7, the FAQ source 15.0), matching the build setting and the website.

---

## 2026-10-14 — Docs: restoring test VMs with VirtualBuddy

### Testing
- `docs/internal/testing.md` — test VMs are now restored with VirtualBuddy's Duplicate (checked to make an APFS clone, with a new VirtualBuddy ID), which needs no VirtualBuddy restart; the Terminal `cp -c` restore remains as an alternative.

---

## 2026-10-14 — Testing: CLI render check in the VM smoke test

### Testing
- **CLI `--render` (beta builds only)** — a test-only command-line option that writes every frame as the app renders it (colour frames with Colour on, mono in greyscale) as PNGs, plus each frame's background R, G, B to `backgrounds.csv`; `--render-typical` writes only each folder's typical frame. It is compiled in only with the `BETA` condition, which the release workflow now sets for beta tags and `scripts/build-beta.sh` sets for local builds; stable and App Store builds don't contain it, and it is not listed in `--help`.
- **VM smoke test** — for beta builds it now renders the sample set, checks the typical frame's background with the same limits as the rendering tests, checks the metrics are unchanged by `--render`, and copies the PNGs back for a visual check. Stable builds report SKIP.
- The pixel measurement used by the rendering tests moved into the app (`RenderedPixels.swift`) so both use the same code.

---

## 2026-10-13 — Testing: metric baselines

### Testing
- **Metric baselines** — `scripts/metric-baselines.py` runs command-line mode on the test datasets and compares every frame's FWHM, eccentricity, SNR, star count, PSF signal weight and score, and the frames kept by the standard filter, with stored baselines in `tests/baselines/`. `--update` writes new baselines after review. See `docs/internal/testing.md`.

---

## 2026-10-13 — Fix: metrics varied between runs on the same files

### Fixed
- **Reproducible metrics** — opening the same folder twice could give slightly different numbers: star counts varied by one or two, and on some data (such as a bright star field) SNR and PSF signal weight by a few percent and eccentricity in the third decimal. Stars with exactly the same peak brightness were ordered at random, so different stars were measured each time. Ties are now broken by position and parallel measurements are combined in a fixed order; the same files always give the same metrics. Values on affected frames change once, by no more than they already varied.

### Tests
- `MetricsDeterminismTests` — candidate order and star selection with equal peaks, and repeated GPU measurement of an image with 625 equally bright stars.

---

## 2026-10-13 — Testing: rendering tests on real data

### Testing
- **Rendering tests** — `RenderingTests` load real folders the way the app does and measure the sky background of every rendered frame; the typical frame of each folder must be neutral and at the 25% target. Run with `scripts/run-render-tests.sh` (sample set) or `--full` (M31, California, Gamma Cygni, Rosette, about 5 minutes); skipped in normal test runs. Results go to `tests/render-results/` (not committed).

---

## 2026-10-13 — Testing: VM smoke test and testing guide

### Testing
- **VM smoke test** — `scripts/vm-smoke.sh` installs a DMG, a local build or a GitHub release in a test VM over SSH and checks signing, notarisation, bundle contents, launch (no crash, exception or constraint loop) and command-line mode on the sample set. Results go to `tests/smoke-results/` (not committed).
- **Testing guide** — `docs/internal/testing.md` describes every kind of test, including the manual checks the person running them must do, and how to manage the test VMs. The release procedure now includes a smoke test before tagging and after publishing.

---

## 2026-10-13 — Fix: colour cast when frames in a folder differ

### Fixed
- **Colour cast in the colour view** — with Colour on, a folder could be shown with a strong colour cast; the 8-frame M31 sample set looked magenta. The shared per-folder stretch combined medians of each clip value separately, so one frame's highlight clip was paired with another frame's midtone. The midtone is now recomputed from the folder's median shadow clip, highlight clip and sky background, which keeps the background neutral. The same correction applies to the shared greyscale stretch of mono frames.

### Tests
- `ClipNormalisationTests` — shared clips for one frame, the sample-set green values, the midtone helper and STF statistics.

---

## 2026-10-13 — Command-line mode, PSF Signal Weight, better colour-camera metrics

### Added
- **Command-line mode** — run the app's executable with a folder path to measure every frame without opening a window and write a CSV of the results. Add quality thresholds to export only the frames that pass. Run it with `--help` for all options, or see the FAQ. Not available in the Mac App Store version.
- **PSF Signal Weight (PSF·S)** — a new metric for transparency and seeing: star peak brightness relative to sky noise. Shown in the inspector, session chart, sort menu, and exports, and available as an Auto-Flag criterion.
- **Zoom to fit** — a fit button next to the zoom percentage scales the image to fill the viewer.
- **Zoom anchor** — click the image to pin a point; zooming keeps it centred, and it stays in place as you step through frames.
- **Target Background** slider replaces the Brightness slider, matching PixInsight's convention.
- **Sample data** — an M31 sample set to try FITS Blaster without your own images (see the FAQ).

### Improved
- **Colour (OSC) cameras** — FWHM and eccentricity are now measured on debayered, full-resolution star images. Rankings agree closely with PixInsight's SubframeSelector.
- **Eccentricity** detects elongated stars at any angle, not just horizontal or vertical.
- **Finder thumbnails** — FITS thumbnails no longer fall back to the app icon in Finder's icon view, and files in iCloud Drive that aren't downloaded no longer stall other thumbnails.
- **Open Folder options** (subfolders, REJECTED folder) now appear in a popover on the Open Folder button and ⌘O.

### Changed
- The quality score always uses every metric that could be measured; the per-metric on/off settings are gone.
- The metric chips above the session chart are now optional (Settings → Display).
- The version downloaded from the website is no longer sandboxed, so command-line mode can read any folder you give it.

### Fixed
- Crash at launch on some macOS 27 versions.
- The selected frame was lost when switching between All, Flagged, and Rejected and back.
- The session chart's cursor dot didn't follow navigation, and single-frame folders drew outside the chart.

---

## 2026-10-13 — Fix: crash on launch (macOS 27, App Store build 202)

### Bug fixes
- **Crash on launch** — setting `window.toolbar` and `window.toolbarStyle = .unified` inside `viewDidMoveToWindow` caused AppKit constraint-update reentrancy during SwiftUI's initial layout pass on macOS 27. AppKit's `_postWindowNeedsUpdateConstraints` detected the re-entry and threw `NSGenericException`, converted by `NSApplication` to a fatal `SIGTRAP`. Fixed by moving toolbar configuration to `.windowToolbarStyle(.unified)` on the `WindowGroup` scene, which applies the style before any layout pass runs.
- **Verified** — App Review's crash (build 199) reproduced in a VM on macOS 27.2 26B5086k: "more Update Constraints in Window passes than there are views in the window". The fixed build launches cleanly on the same clean VM; full-screen traffic lights still work.

### Build
- App Store build number bumped from 199 to 202 (past the 201 beta builds) for resubmission.

---

## 2026-10-12 — Refactor: one type per file, fix Binding anti-patterns, Canvas over GeometryReader

### Code quality
- **One type per file** — extracted 23 types from large files into their own Swift source files.
- **`@Bindable` over `Binding(get:set:)`** — replaced manual binding construction with `@Bindable` where the source is an `@Observable` instance stored as `let`.
- **`Canvas` over `GeometryReader`** — `RejectionOverlay` and `ViewportBox` now use `Canvas { context, size in }` which provides the container size directly.
- **`Int` → `Double` in `AutoRejectConfig`** — `absoluteStarCountFloor` and `scoreFloor` are now `Double`, allowing direct `Slider` binding.
- **`Set<String>` for toggle binding** — `ExportPanel.selectedHeaderKeys` changed from `[String]` to `Set<String>` with a subscript extension, enabling direct `Toggle` binding.
- **`ContentFocusedValues` ViewModifier** — extracted all 20+ `focusedSceneValue` modifiers into a `ViewModifier` to avoid Swift type-checker timeout.

---

## 2026-10-10 — Feature: zoom to fit button

### New features
- **Zoom to fit** — added a small "fit" button (`↙↗` icon) in the image adjust controls strip, next to the zoom percentage. Tapping it scales the image to fill the available viewer area without scrolling.

---

## 2026-10-10 — Fix: CLI filter logic and Open Folder options popover

### Bug fixes
- **CLI filter exported wrong frames** — `applyAutoFlag` flags the *bad* frames (those failing quality thresholds); the CLI was exporting those flagged IDs, producing the inverse of the intended result. Replaced `applyAutoFlag` + `flaggedEntryIDs` with `previewAutoReject` + complement: frames *not* in the bad set are now exported.
- **CLI folder path detection** — a numeric flag value (e.g. `3.3` after `-f`) was incorrectly matched as the folder path when options appeared before the path. Fixed path detection to require the argument to start with `/` or `~`.
- **CLI terminology** — renamed "autoflag" to "filter" in all user-visible help text and messages.
- **CLI `-r`/`-R` flags merged** — removed the separate `--include-rejected-in-csv` (`-R`) flag; `-r`/`--include-rejected` now both scans the REJECTED folder and includes those frames in the CSV with `status=rejected`.
- **CLI `--no-flag` removed** — the flag was redundant; omitting filter criteria already exports all frames.
- **Open Folder options popover** — replaced the broken `NSOpenPanel` accessory view (non-interactive on macOS 27 without the app sandbox) with a SwiftUI `.popover` on the toolbar button. Options are now set in the popover, then a 300 ms async delay lets the popover dismiss before `NSOpenPanel.runModal()` takes over the main thread.
- **Deprecation warning** — removed `toolbar.showsBaselineSeparator = false` (deprecated in macOS 15, no replacement needed).

---

## 2026-10-10 — Fix: open folder options missing without app sandbox

### Bug fixes
- **Subfolders/Rejected options missing from Open Folder dialog** — sandbox removal (required for CLI) broke the old `NSOpenPanel` accessory view; `NSButton` checkboxes allocate space but do not render on macOS 27 without the sandbox. Fixed by using `NSHostingView` with a small SwiftUI view (`OpenFolderAccessoryView`) as the accessory view — SwiftUI rendering is reliable regardless of sandbox state.

---

## 2026-10-10 — Fix: selection lost when switching visibility mode

### Bug fixes
- **Selection lost on visibility switch** — switching to "Rejected" (or "Flagged") when empty, then back to "All", would show "Ready to blast…" instead of restoring the previous image. Added `cursorPerVisibility` to mirror the existing `cursorPerFilterGroup` pattern: the selected entry is now saved per visibility mode and restored when switching back.

---

## 2026-10-10 — CLI: short flag aliases

### Changes
- **Short flag aliases** — all CLI options now have single-letter shortcuts: `-h` help, `-o` output, `-S` subfolders, `-r` include-rejected, `-m` mode, `-f` fwhm, `-e` eccentricity, `-n` stars, `-s` snr, `-b` sky-bg, `-p` psf, `-q` score, `-P` path-style, `-H` headers.

---

## 2026-10-10 — CLI: autoflag now filters output

### Changes
- **CLI autoflag as filter** — when autoflag criteria are provided, the CSV now contains only the flagged (best) frames instead of all frames. If the criteria match nothing a warning is printed and all non-rejected frames are exported as fallback. Use `--no-flag` to export all frames regardless of quality.

---

## 2026-10-10 — Fix: GUI crash on macOS 27 without app sandbox

### Bug fixes
- **GUI crash on launch** — replaced `.inspector(isPresented:)` with a plain third `HSplitView` column. The `.inspector` modifier creates a nested `SplitViewChildController` layer that causes an infinite constraint-update loop (`NSGenericException`) on macOS 27 when the app sandbox is disabled. Using a regular split-view column removes that layer. The inspector panel still shows/hides via `showInspector` as before.

---

## 2026-10-10 — CLI batch mode + PSF autoflag

### Features
- **CLI batch mode** — the app binary can now be invoked from a terminal to process a folder of FITS files headlessly and write a CSV export. Pass a folder path as the first argument; run with `--help` for the full flag reference. Progress goes to stderr; the CSV path goes to stdout (supports scripting). Requires removing the app sandbox entitlement in the direct-distribution build for arbitrary path access.
- **PSF signal weight autoflag** — PSF signal weight is now a supported autoflag criterion in the Auto-Flag sheet, in both relative mode (reject if PSF < multiplier × group median) and absolute mode (reject if PSF < floor). Disabled by default.

### Internal
- `ImageStore.waitForProcessing() async` — suspends until any in-progress batch load completes; used by CLI mode.
- `main.swift` — new entry point that dispatches to CLI or normal SwiftUI app based on arguments; `@main` removed from `FitsBlasterApp`.

## 2026-10-09 — Tests: removeSelected and sidebarNavigationEntries coverage

### Tests
- **`RemoveSelectedTests`** — 8 new tests for `removeSelected`: cursor advancement after middle removal, end-of-list fallback, single-entry removal, flagged-batch removal from middle and end, flag-vs-cursor precedence, `flaggedEntryIDs` cleared after removal, and no-op guard.
- **`SidebarNavigationTests`** — 8 new tests for `sidebarNavigationEntries(isSimpleMode:)`: flat-list in simple mode, flat-list for single-filter sessions, filter-strip active, geek-mode filter grouping (contiguity), multi-folder section order, collapsed-folder exclusion, and multi-folder visibility filter.

---

## 2026-10-09 — Tests: higher-level integration coverage

### Tests
- **`GroupStatisticsTests`** — 8 new tests for `updateGroupStatistics`: `medianSkyBackground` and `medianPSFSignalWeight` computation (first coverage of these fields), per-filter-group isolation, nil-field exclusion, even-count median, and `topThirdScoreFloor` edge cases.
- **`SortOrderTests`** — 9 new tests for `updateCachedSort`: metric-based ascending/descending, nil-metrics trailing in both directions, load-order (filename) sort, and rejected-entry placement.
- **`FlagVisibilityTests`** — 6 new tests for the auto-flag + visibility pipeline: `applyAutoFlag` populates `flaggedEntryIDs`, additive (union) semantics, `.active` visibility mode, and `deflagAll`.

---

## 2026-10-09 — Tests: coverage for beta features

### Tests
- **`AutoRejectTests`** — three new tests for the sky background threshold introduced in beta 2: relative mode (rejects frames with sky BG > multiplier × group median), absolute mode (ceiling ADU value), and disabled-flag guard.
- **`MetricTests`** (new file) — covers the `Metric` enum introduced as single source of truth: `value(from:)` extraction for all seven metrics including `skyBackground` and `psfSignalWeight`, `median(from:)` from `GroupStats`, `isHigherBetter` for all cases, and `contexts` (verifies `skyBackground` is excluded from the export context).
- **`ExportTests`** (new file) — covers `ImageStore.exportContent`: CSV/TSV column layout, `sky_bg` exclusion from export columns, `status` column present/absent, POSIX decimal separator, all three path styles, FITS header key inclusion/omission, and `commonAncestorPath` edge cases.

---

## 2026-10-09 — Target Background display control; zoom anchor; chart and metric UI improvements

### Added
- **Target Background slider** replaces the old Brightness slider in the display controls bar. The value (0.05–0.50, default 0.25) sets the desired sky background brightness level in the displayed image, matching the PixInsight MAS convention. The STF stretch already targets ~0.25, so the default produces no visible change. The value persists across app restarts (moved from session-level `ImageStore` to `AppSettings`).
- **Zoom anchor** — click anywhere on the image to pin a point of interest. A crosshair marks the pinned point. All subsequent zoom changes (slider and pinch-to-zoom) keep that point centred in the viewport. The anchor persists across image navigation (same normalised coordinates = same sky position). Click the crosshair again to clear it. The lit scope icon in the zoom toolbar re-centres the viewport on the anchor after scrolling. The Defaults reset button also clears the anchor.
- **Quality Score** added to the inline metric chip row (shown when enabled in Settings → Quality Metrics).

### Fixed
- **Chart y-axis domain for single-image folders**: when only one frame was loaded (or all visible frames had the same metric value), the y-axis fell back to the hardcoded 0–1 range. Values outside that range (e.g. Sky BG = 1296 ADU, FWHM = 3.6 px) rendered as a bar or dot overflowing the chart area and drawing over the image preview. The domain now centres on the actual value with a ±20 % (min 0.5) margin.

### Changed
- **Metric chip row** is now opt-in via Settings → Quality Metrics (default off). The inspector remains the canonical metric display.
- **Per-metric compute toggles** (FWHM/Ecc/SNR/Stars on/off) removed; quality score always uses all available metrics.
- Internal: `Metric` enum introduced as single source of truth for all quality parameters. Each metric declares which UI locations it appears in via a `MetricContext` OptionSet (sort, chart, export, status chip), eliminating separate `ChartMetric` and related enums.

---

## 2026-10-08 — Throughput benchmark framework (BenchmarkTests, run-benchmark.sh)

## 2026-10-08 — Add scripts/compare.py for PI SubframeSelector correlation testing

## 2026-10-08 — Documentation: OSC/Bayer FWHM and eccentricity

### Changed
- Updated `docs/public/Score.md`, `site/score.html`, and `site/faq.html` to reflect the current bilinear-demosaicking implementation: two-pass luminance weighting (Rec. 709 for FWHM, adaptive sky weights for eccentricity), no 2×2 binning, no ×2 scale-back, and equivalent precision to mono cameras.

---

## 2026-10-08 — Bayer mosaic: separate luminance weights for FWHM and eccentricity

### Fixed
- **FWHM on OSC/Bayer files was strongly anti-correlated with PixInsight** (Spearman r = −0.919) after adaptive per-channel sky weights were introduced for eccentricity. Root cause: PI SubframeSelector effectively weights OIII-channel G pixels 2:1 over Ha-channel R pixels on a raw Bayer mosaic (50 % of pixels are G), while adaptive weights give R and G roughly equal weight on dual-narrowband images where OIII falls in the green bandpass. FWHM measurement now uses **ITU-R BT.709 luminance weights** (wG = 0.7152) so the debayered luminance matches PI's effective OIII-channel weighting.
- Eccentricity continues to use **adaptive sky-brightness weights** (estimated from the outer border of each star crop), which correctly normalise Ha and OIII signal for the axis-ratio measurement.
- PSF fitting for Bayer files now runs two debayering passes per star — Rec. 709 for FWHM, adaptive for eccentricity. The overhead is negligible (eight Moffat fits instead of four).
- Validated on three independent datasets: California Nebula (Antlia ALP-T dual narrowband, 60 frames) — FWHM r = +0.990, eccentricity r = +0.875; Gamma Cygni (Antlia ALP-T, 34 frames) — FWHM r = +0.948; M31 broadband (43 frames) — FWHM r = +0.973, eccentricity r = +0.740 (no regression).
- A new `BayerLuminanceWeights` enum (`.rec709` / `.adaptive`) is defined in `BayerPattern.swift`.

---

## 2026-10-06 — App Store: build 199, Sparkle weak-link, App Store entitlements

### Fixed
- App Store builds crashed at launch because `dyld` hard-linked Sparkle at load time. `OTHER_LDFLAGS` is now `-weak_framework Sparkle` so the framework is loaded on demand, matching the sandbox environment's expectations.
- Added `FITS Blaster App Store.entitlements` to the repository (app sandbox, user-selected read/write, app-scope bookmarks). The file was referenced in `project.pbxproj` but not tracked, so clean clones would fail to build for App Store distribution.
- Build number bumped to 199 for the resubmission.

---

## 2026-10-08 — Bayer mosaic: bilinear demosaicking for full-resolution PSF measurement

### Changed
- FWHM and eccentricity on OSC/Bayer files are now measured from a bilinearly debayered luminance crop rather than a 2×2-binned crop. The new path interpolates the missing R, G, B values at every pixel position (using the Bayer pattern from the FITS header), converts to luminance (Rec. 709 coefficients), and fits the PSF on the result at full native resolution. Eccentricity benefits most — the debayered crop has 4× more pixels and avoids the axis-ratio compression that 2×2 binning introduced. FWHM no longer requires a ×2 scale-back factor because the crop is already at native pixel scale. The `BayerPattern?` value is now threaded through the metrics pipeline in place of the previous `Bool`, giving the demosaicker the exact CFA pattern (RGGB, BGGR, GRBG, GBRG) at every call site.

---

## 2026-10-03 — Bayer mosaic: moment-based eccentricity on binned crops

### Fixed
- Eccentricity on OSC/Bayer files was unreliable with 1D Moffat projections on the raw Bayer mosaic: the alternating R/G/B/G channel pattern biases each directional fit differently, producing rankings that are essentially random across sessions (Spearman r as low as −0.15). Eccentricity for Bayer files is now computed as intensity-weighted second moments on the 2×2-binned crop. This uses all 169 crop pixels and is orientation-invariant by construction, compared to only ~20 usable samples across four 1D slices. Both FWHM (from the binned Moffat fit, ×2 scale-back) and eccentricity (from moments) now come from the same binned crop, so no additional crop measurement is needed.

---

## 2026-10-03 — Bayer mosaic: split FWHM/eccentricity measurement

### Fixed
- Eccentricity on OSC/Bayer files regressed after the 2×2-binning fix because the isotropic blur from binning compresses the PSF axis ratio toward 1, flattening all eccentricity values and destroying the ranking. FWHM and eccentricity are now measured from separate crops for Bayer files: FWHM comes from the 2×2-binned crop (eliminating the Bayer checkerboard artefact, ×2 scale-back applied), while eccentricity, SNR, and peakVal come from the raw unbinned crop where the four-direction axis-ratio signal is preserved.

---

## 2026-10-03 — Bayer mosaic: 2×2-bin crops before Moffat fitting

### Fixed
- FWHM and eccentricity were underestimated on colour OSC cameras because metrics were computed on the raw Bayer mosaic. The alternating R/G/B/G pixel pattern along any 1D cross-section looks like a narrower PSF than it really is, causing artificially low FWHM (e.g. 1.7 px where PixInsight measures 2.6 px) and weaker eccentricity correlation. FITS Blaster now detects the Bayer pattern from FITS headers (`BAYERPAT` keyword) and, for those files, bins each star crop 2×2 before fitting. Each 2×2 block averages one R + two G + one B pixel into a single luminance sample, eliminating the checkerboard artefact. FWHM from the binned crop is scaled ×2 to recover native-pixel values.

---

## 2026-10-03 — Eccentricity: orientation-invariant four-direction PSF fit

### Changed
- **Eccentricity** is now computed from a four-direction Moffat fit (0°, 45°, 90°, 135°) with analytic principal-axis reconstruction. The four directional α values satisfy a closed-form system that yields the true major/minor axes of the PSF ellipse at any rotation angle — not just axis-aligned elongation. Previously, only the 0° and 90° fits were used, so diagonal elongation (e.g. trailing at 45°) was missed entirely. The formula and the FWHM value are otherwise unchanged.
- Documentation updated in `Score.md`, `score.html`, and `faq.html`.

---

## 2026-10-03 — PSF Signal Weight formula revised

### Changed
- **PSF Signal Weight formula** revised from `mean(A × α²) / σ` to `mean(A) / σ` — peak amplitude per sky noise unit. The previous formula used the Moffat integrated flux (`A × α²`), which stayed roughly constant as seeing varied (because `A` and `α²` move in opposite directions). The new formula uses the peak amplitude directly, so PSF-SW now rewards both better transparency (more photons → higher `A`) and better seeing (sharper PSF → higher `A`), matching PixInsight SubframeSelector's PSF Signal Weight behaviour.
- Documentation updated accordingly in `Score.md`, `score.html`, and `faq.html`.

---

## 2026-10-03 — PSF Signal Weight metric

### Added
- New **PSF Signal Weight** metric (shown as "PSF·S" in the chart): mean peak star amplitude normalised by sky noise sigma. Rewards both transparency and seeing quality. Computed as a free by-product of the existing Moffat fit (no toggle needed).
- PSF Signal Weight appears in the inspector (below Sky BG), the session chart (new "PSF·S" button), the sort menu ("PSF Signal"), and thumbnail tooltips.

---

## 2026-10-03 — Chart cursor and progress bar label

### Fixed
- The chart cursor dot (white, larger) now moves correctly when navigating between images. The `selectedEntry` check was inside a `@ChartContentBuilder` closure that doesn't participate in SwiftUI's `@Observable` tracking, so the chart wasn't re-rendering on selection changes. Fixed by capturing the selected entry ID before the `Chart {}` block.

### Changed
- Renamed the "Colour" progress bar to "Restretching" — it tracks the full display-image restretch pass, which covers both Bayer→colour and greyscale re-renders (e.g. when toggling the debayer setting on a previously loaded session).

---

## 2026-10-03 — QuickLook thumbnail fixes and iCloud investigation

### Fixed
- Some FITS files in a folder showed the app icon instead of a thumbnail in Finder's icon view, while the same files had a tiny thumbnail in list view. Root cause: the thumbnail extension was always loading a 2048-pixel intermediate Float array (~24 MB) regardless of the requested thumbnail size. In icon view many thumbnails are requested simultaneously, exhausting the QuickLook extension process memory limit; the process was killed and macOS cached the failure as a permanent app icon. The extension now subsamples directly to the requested size — a 512-px icon-view thumbnail uses ~1.5 MB instead of ~24 MB; a 32-px list-view thumbnail uses ~5 KB.
- Added a clean early-exit for iCloud stubs (files with `ubiquitousItemDownloadingStatus == .notDownloaded`). Previously, calling `Data(contentsOf:)` on an undownloaded iCloud file blocked the QL extension indefinitely rather than throwing an error, causing the extension process to be killed by macOS and any other in-flight thumbnail requests in the same batch to fail.
- Added guard against empty pixel buffer in `createImage` to prevent a force-unwrap crash on pathological FITS files with zero-size image dimensions.

### Notes (iCloud thumbnails)
- For FITS files stored in iCloud Drive: thumbnails that survive `qlmanage -r cache` are stored in iCloud's own thumbnail metadata layer, not the local QuickLook cache. `qlmanage` commands have no effect on those. The QL extension generates thumbnails only for files with no iCloud-stored thumbnail and that are locally downloaded. Files that are iCloud stubs (not downloaded) will show the app icon; marking the folder "Keep Downloaded" in Finder is required for persistent thumbnails.

---

## 2026-10-02 — Folder drop and full-screen traffic lights

### Fixed
- Dropping a folder onto the app icon in the Dock or Applications folder now opens that folder in FITS Blaster. The app was missing `public.folder` in its document type registration, so macOS never forwarded folder drops to the app.
- In full-screen mode, moving the mouse to the top of the screen now reveals the traffic-light window controls (and the menu bar). A hidden `NSToolbar` is now attached to the window; without it, macOS has no hover zone to activate in full-screen mode.

---

## 2026-10-02 — STF auto-stretch (PixInsight-style)

### Improved
- Replaced gamma 2.2 stretch with a PixInsight-style Screen Transfer Function (STF). The new algorithm computes the image's median and MAD (Median Absolute Deviation) to set an intelligent black point, then applies a Midtone Transfer Function (MTF) that places the sky background at ~25% grey. The result: darker background, more contrast in faint nebulosity, no blown-out highlights. Applies to all paths — GPU (Metal), CPU fallback, colour (Bayer), QuickLook, and thumbnails.

---

## 2026-10-02 — Fix full-screen mode/inspector layout issues

### Fixed
- Switching between Geek and Simple mode in full screen no longer leaves a black dead column where the inspector panel used to be. The inspector now uses SwiftUI's `.inspector` modifier, which handles full screen correctly instead of relying on window resizing.
- The image now auto-fits to the newly available space when switching modes or showing/hiding the inspector.
- The inspector panel now correctly reappears when switching back to Geek mode after having been in Simple mode.

---

## 2026-10-02 — Sky BG sort and auto-flag, stable beta app name

### Added
- Sky BG sort option in the thumbnail sort menu.
- Sky background threshold in the Auto-Flag sheet: flag frames where sky brightness exceeds a multiple of the group median (relative mode) or a fixed ADU ceiling (absolute mode).

### Fixed
- Beta builds are now distributed as `FITS Blaster Beta.app` instead of a versioned name (e.g. `FITS Blaster 1.23-beta.6.app`). The versioned name prevented Sparkle from renaming the bundle on update, leaving users with a stale app name after every in-place upgrade.

---

## 2026-10-02 — Consistent stretch and sky background chart

### Improved
- Greyscale (mono) images in the same folder and filter group are now rendered with a consistent shared stretch, eliminating the brightness flickering when scrolling quickly through a session.
- Sky background value is now shown in the inline metrics row above the chart alongside FWHM, Ecc, SNR, and Stars.

### Added
- **Sky BG** chart metric: plot the sky background ADU level across the session, with per-filter-group median lines.

---

## 2026-10-01 — Filter pills, sky background, and 1:1 zoom

### Improved
- Filter pills in the thumbnail sidebar now wrap onto multiple rows when many filter groups are active, instead of overflowing into a single cramped line.
- The thumbnail sidebar can now be dragged up to 360 px wide (previously capped at 220 px).
- The zoom percentage label (e.g. "0.5×") is now a button — click it to jump instantly to 1:1 (100%) for pixel peeping. Tooltip reads "Click for 1:1 (100%)".

### Added
- **Sky background** metric in the inspector panel: the median ADU level of the sky background, estimated as a free side-effect of star detection. Useful as a relative sky-darkness indicator across a session.

---

## 2026-10-01 — Single-letter filter codes recognised

### Fixed
- Filter names consisting of a single letter — **H**, **O**, **S** — were shown as "Unfiltered" instead of being mapped to Hα, OIII, and SII respectively. Also added **IR** as an alias for Luminance. Affects users whose capture software writes short codes in the FITS FILTER header (common with N.I.N.A., SGP, and some ASIAIR configurations).

---

## 2026-04-29 — Beta update channel actually works now

### Fixed
- The "Beta updates" preference promised on the website was never actually wired up: every beta build was checking the stable appcast (`appcast.xml`) and reporting "you're up to date" by comparing the beta build number against the latest stable (1.22 / build 168). A new `BetaChannelUpdaterDelegate` now routes Sparkle's feed at `appcast-beta.xml` when the toggle is on. Beta builds default the toggle on; stable builds default it off.

### Added
- Settings → Interface → Software Updates section with a "Receive beta releases" toggle. Available in non-App-Store builds only (App Store builds don't ship Sparkle).

### Note
- This fix can only help users running this build forward; existing users on beta.3 (which has the bug) won't see this build via auto-update and will need to download once manually from the beta page.

---

## 2026-04-29 — Export path styles, padded text report, Simple-mode column tidy-up

### Added
- File path style option for exports: absolute path (current behaviour), relative to the longest folder shared by all exported frames, or filename only. Default is configurable in Settings → Export, with a per-export override in the export sheet. Relative mode collapses a single-folder session to bare filenames automatically.

### Changed
- The plain text (.txt) export is now a space-padded human-readable report rather than a bare list of file paths. It includes the same columns as CSV/TSV (path, optional status, metrics when available, selected FITS header columns) but every cell is padded so the file lines up cleanly in any text editor — numeric columns right-aligned, text columns left-aligned. Use CSV or TSV when you need a machine-parseable file.

### Fixed
- CSV/TSV exports left FWHM, eccentricity, SNR, stars, and score blank when a metric was disabled or the user had switched out of compute-everything mode after the first batch. The exporter now falls back to the cached metric values that are preserved for the lifetime of the session.

### Improved
- Simple-mode exports (and any session where no frame has any metrics data) now omit the `fwhm`, `eccentricity`, `snr`, `stars`, and `score` columns entirely instead of emitting empty cells, so the resulting CSV/TSV jumps straight from `path` to the selected FITS header columns.
- FITS header column picker (Settings → Export and the export sheet) now dims keys that aren't present in any currently-loaded file, so it's clear before exporting which keys will produce data and which won't. Selected-but-absent keys are dropped from the output, and the .txt report lists them in a `# Skipped columns with no data: …` footer so the omission is auditable when re-reading the file later.

---

## 2026-04-28 — FITS header export columns, export defaults, CSV decimal fix

### Added
- Configurable FITS header columns in CSV/TSV exports. Choose which header keys appear as columns in Settings → Export, or override per-export via the new export sheet. Defaults cover acquisition, focus, weather, and pointing fields (OBJECT, DATE-OBS, EXPTIME, FILTER, GAIN, OFFSET, CCD-TEMP, FOCUSPOS, AIRMASS, OBJCTALT, AMBTEMP, HUMIDITY).
- Tab-separated (.tsv) export format alongside CSV — handy for opening in plain text editors with aligned columns.
- Optional inclusion of rejected frames in exports. Plain text adds a `# REJECTED` suffix; CSV/TSV add a `status` column (`kept` / `rejected`).
- Quality score column in CSV/TSV exports.

### Fixed
- CSV exports could emit integer values for FWHM and eccentricity on systems with comma-decimal locales (Dutch/German/French), because the formatter used the user's region. Numbers now use a fixed `en_US_POSIX` locale and always have the configured decimal places.

### Improved
- Export sheet redesigned with format picker, rejected-frames toggle, and a FITS header column list. All values pre-populate from Settings → Export defaults; if you change anything, an orange notice signals "applies to this export only" (same pattern as the Open Folder panel).
- Export plain text retains its file-list-only output, but now includes a per-line marker for rejected frames when they are exported.

---

## 2026-04-12 — QuickLook previews and thumbnails for all FITS formats

### Added
- QuickLook preview and thumbnail support for floating-point FITS files (BITPIX -32 and -64). Previously these showed blank icons in Finder.
- QuickLook preview and thumbnail support for 3-channel RGB colour FITS files (NAXIS3=3), such as stacked integrations from Astro Pixel Processor.
- Asinh stretch (beta=50) for float FITS previews — compresses bright cores while revealing faint nebulosity in linear astrophotography data.
- Large-file subsampling: files over 2048px are stride-sampled during preview to stay within QuickLook's memory limit (~120 MB), enabling previews of 1+ GB stacked integrations.
- `FITSReader.readForPreview(from:)` — dedicated read path that accepts float BITPIX and multi-channel files without affecting the main app's integer-only pipeline.

### Improved
- Zero-pixel exclusion in percentile estimation prevents stacking artifacts (unfilled corners) from skewing the preview stretch.

---

## 2026-04-12 — SwiftUI review fixes, accessibility, tests, and rejected-view cursor fix

### Added
- 111 unit and integration tests covering FITSReader, quality scoring, filter group normalisation, frame metrics, Bayer pattern parsing, histogram computation, and star detection with synthetic images (single star FWHM accuracy, multi-star count, gradient background robustness, noise rejection, elongated star eccentricity, FITS round-trip pipeline, CPU image stretch).

### Fixed
- Undo-reject and reject actions now advance the cursor to the next visible entry, matching the flagged-view behaviour.
- VoiceOver: inspector toggle and chart style buttons now have accessible labels instead of empty strings.
- VoiceOver: session chart tap overlay now declares `.isButton` trait.
- VoiceOver: filter strip chips are individually focusable (replaced ScrollView with HStack) and announce selected state.
- VoiceOver: inspector panel exposes children to VoiceOver navigation.

### Improved
- Settings tabs migrated from deprecated `.tabItem()` to the `Tab` API.
- Filter group header uses cached `GroupStats` instead of recomputing O(n log n) median on every render.
- `.filter { }.count` replaced with `.count(where:)` in ExportPanel and BatchProgressBar.
- Drag handle uses semantic `.quinary`/`.quaternary` colours instead of manual opacity.
- `AppDelegate` annotated `@MainActor` for strict concurrency.
- Unnecessary explicit `return` removed from single-expression switch cases.
- Menu command views extracted from `FitsBlasterApp.swift` into `MenuCommands.swift`.

---

## 2026-04-09 — Session chart bars, filter fix, play mode, flip, and beta channel

### Added
- Session chart: optional bar chart mode as alternative to dots. Toggle via the chart header button. Preference is persisted.
- Play mode: press P to auto-advance through images at a configurable speed (0.2–5.0 seconds per frame). A speed slider appears in the toolbar during playback. Manual navigation stops playback automatically.
- Flip 180°: press V to rotate the current image (or batch selection) 180 degrees for display. A rotation indicator appears on the thumbnail. Does not modify FITS files.
- Cursor memory per filter group: switching between filter buttons (R, G, B, etc.) remembers and restores the selected image for each group.
- Beta release channel: tag a version as `v1.23-beta.1` to publish a test build without updating the homepage. Beta builds get their own page (`beta.html`), appcast feed (`appcast-beta.xml`), and are marked as pre-releases on GitHub.
- Beta page on the website with download link and release notes for the latest beta build.
- Release & issue workflow guide (`guide-releases.html`) documenting the tag-based release process and GitHub Issues workflow.

### Fixed
- Filter buttons above the thumbnail sidebar now work correctly in multi-folder sessions.
- Switching filter group or rejection visibility now auto-selects the first visible entry when the cursor is hidden.
- Unflagging an image in the Flagged view now advances the cursor to the next flagged image instead of losing the selection.
- Playback stops automatically when switching filter group or rejection visibility.
- Playback timer moved out of SwiftUI view modifier to prevent task cancellation during view rebuilds.

### Improved
- O(n²) search in image removal replaced with O(n) scan for selecting the next entry.
- GitHub Actions pipeline detects beta tags and adjusts behaviour: marks releases as pre-release, writes to separate appcast and site files.
- Site navigation now includes a Beta link on all pages.

---

## 2026-04-08 — Sparkle auto-update

### Added
- Automatic update checking via the Sparkle framework. FITS Blaster now checks for new versions once every 24 hours in the background.
- "Check for Updates..." menu item in the FITS Blaster menu for manual update checks.
- Updates are downloaded, installed, and relaunched automatically — no manual DMG drag required.

### Improved
- FAQ updated: "Does FITS Blaster require an internet connection?" now mentions the lightweight update check.

---

## 2026-04-08 — Image viewer controls

### Added
- Zoom slider (0.25×–4×) with live readout; trackpad pinch-to-zoom also supported.
- Brightness slider for quick exposure adjustment without re-rendering.
- Stretch slider to boost or reduce image contrast.
- "Defaults" button to reset all three adjustments in one click.
- Scrollbars appear automatically when the image is zoomed beyond the viewport.
- Viewport indicator: a yellow box on the sidebar thumbnail shows which part of the image is currently visible when zoomed in.

### Improved
- Scroll position is now preserved when navigating between frames at the same zoom level.
- Zooming via the slider keeps the viewport centre fixed instead of jumping to the top-left.
- Zoom level persists across app launches; brightness and stretch reset when opening a new folder.
- Swift 6 concurrency fixes: key-event monitor, `PanelAccessoryHelper`, `FolderTracker.init`, concurrent `self` capture, and unused weak-capture removals.
- QL extension `CFBundleVersion` now tracks the main app version automatically via `$(CURRENT_PROJECT_VERSION)`.

---

## 2026-04-08 — v1.20 QuickLook support and Bayer screen-door fix

### Added
- QuickLook preview: press Space on any FITS file in Finder to get a rendered preview without opening FITS Blaster. The preview uses the same percentile-clip + square-root stretch as the app.
- QuickLook thumbnails: Finder icon view now shows rendered FITS images as file icons, in colour for Bayer (e.g. Seestar, Dwarf) files.

### Fixed
- Screen-door grid pattern in colour (debayer) mode for raw Bayer FITS files. The `bayerDebayerAndStretch` Metal kernel now applies the same 2×2 Bayer cell alignment as the greyscale path: each output pixel's footprint is guaranteed to span at least one complete Bayer cell, so every pixel receives a proper R, G, B value. Colour Bayer images are displayed at half the sensor resolution (the true colour resolution). Confirmed fixed with test images from the **Seestar S30**, **Seestar S30 Pro**, **Seestar S50**, and **Dwarf 3**.

### Improved
- Release builds (local `build-release.sh` and CI) now produce a universal binary (arm64 + x86_64), so the same DMG runs natively on both Apple Silicon and Intel Macs.

---

## 2026-04-07 — Fix screen-door effect in colour mode for Bayer FITS files

### Fixed
- Colour (debayer) display of raw Bayer FITS files (e.g. ZWO Seestar S30/S50) no longer shows a screen-door grid pattern. The `bayerDebayerAndStretch` Metal kernel now uses the same 2×2 Bayer cell alignment that greyscale mode uses: each output pixel's footprint is guaranteed to cover at least one complete Bayer cell, so every pixel receives a proper R, G, B value rather than a single raw channel. Colour Bayer images are displayed at half the sensor resolution (the true colour resolution the sensor can produce).

---

## 2026-04-05 — Per-folder streaming colour rendering and progress bar improvements

### Improved
- Colour rendering now starts per-folder as soon as all entries in a folder are sampled, both during initial load and when switching from grey to colour mode. Previously the entire set had to be sampled before any rendering began.
- The Colour progress bar is now visible for the entire duration of colour rendering (no more flickering in/out between folders).
- All progress bars (Loaded, Metrics, Sampling, Colour) now stay on screen until the complete batch finishes, rather than disappearing individually as each pipeline completes.
- Progress bar count text now uses its natural width so 4-digit counts (1000+) are never clipped.
- Removed the now-redundant `normalizeBayerStretch` function; `renderFolderInColour` covers both the initial load and colour-toggle paths.

---

## 2026-04-04 — v1.19.5 switch CI to Xcode 26, restore @concurrent

### Improved
- CI now builds with Xcode 26.3 (previously Xcode 16.4). `@concurrent` pipeline annotations and `SWIFT_APPROACHABLE_CONCURRENCY` are fully effective under Xcode 26 and no longer cause the slowdown seen with the older compiler.

---

## 2026-04-04 — v1.19.4 concurrency revert

### Fixed
- Reverted all `@concurrent` annotations back to `nonisolated`. The `@concurrent` attribute causes a ~2× slowdown when compiled with Xcode 16 (Swift 6.0/6.1), regardless of whether `SWIFT_APPROACHABLE_CONCURRENCY` is enabled. Restores the pipeline throughput of 1.19.1.

---

## 2026-04-04 — v1.19.3 concurrency performance hotfix

### Fixed
- Disabled `SWIFT_APPROACHABLE_CONCURRENCY` (SE-0461) to restore full pipeline throughput when built with Xcode 16.4. The `@concurrent` annotations added in 1.19.2 are silently ignored by the Xcode 16 compiler, causing nonisolated async functions to inherit `@MainActor` and serialise metrics computation. The `@concurrent` annotations are retained for forward-compatibility when the CI migrates to Xcode 26.

---

## 2026-04-04 — v1.19.2 concurrency performance fix

### Fixed
- Restored full parallel pipeline throughput when building with Xcode 26 (Swift 6.2). All async functions in the image loading, stretching, and metrics pipeline are now marked `@concurrent`, guaranteeing they always run on the cooperative thread pool rather than the main actor. This fixes a ~3× slowdown introduced by the Swift 6.2 SE-0461 concurrency model changes.

---

## 2026-04-04 — v1.19.1 progress bar and colour rendering fixes

### Improved
- Progress bars (Loaded, Metrics, Sampling, Colour) are now shown below the main image again, next to the elapsed-time indicator, instead of in the toolbar.
- The currently selected image now switches to colour immediately when colour rendering begins, rather than waiting for its turn in the batch queue.
- Release builds are now arm64-only, matching the GitHub-distributed binary and restoring native Apple Silicon performance for local builds.

---

## 2026-04-04 — v1.19.0 batch progress bars

### Added
- **Batch progress bars** in the toolbar during image loading: Loaded, Metrics, Sampling, and Colour bars show live progress for each pipeline phase and disappear automatically when complete.

### Fixed
- In Simple mode with a multi-folder session, folder sections now appear in the sidebar (previously only Geek mode showed folder groupings). Filter sub-headers within folders remain Geek-mode only.

---

## 2026-04-03 — v1.18.1 keyboard navigation follows sidebar order

### Fixed
- Keyboard navigation (↑/↓/Home/End/Shift+↑/Shift+↓) now steps through entries in the same order they appear in the thumbnail strip, not the flat sort order. In sessions with multiple filter types (Ha, OIII, SII), pressing ↓ now advances within the current filter group section before moving to the next, matching what you see on screen.
- In multi-folder mode, keyboard navigation skips entries inside collapsed folder sections, so the cursor can no longer land on a hidden thumbnail.

---

## 2026-04-02 — v1.18.0 flag/deflag keys, toolbar & chart improvements

### Added
- **F key**: toggle flag/unflag on the current entry or orange range selection (configurable in Settings → Keyboard).
- **D key**: deflag all — clears the entire flagged set in one keystroke (configurable).
- **(De)flag** toolbar button: toggles the flag state of the current entry or orange range, always visible next to the Cancel button.
- **(De)flag** and **Deflag All** items in the Select menu, separated from the range-selection commands by a divider.
- Session chart brightness sliders in Settings → Display: independently control the opacity of rejected dots and non-flagged dots when a flagged set is active.
- Tooltips on all toolbar buttons, session chart metric buttons, and sidebar sort button; tooltip delay reduced from ~1.5 s to 0.5 s.
- **Getting Started** guide page on the website (`guide.html`) — full workflow walkthrough, interface overview, key hints, and tips.
- **Keyboard Shortcuts** reference page on the website (`keys.html`) — all default bindings in one place.
- Top-level navigation bar on all website pages, replacing scattered footer links.

### Improved
- Mode toggle button now shows **Simple** or **Geek** (the current mode) instead of a blank label, matching the Colour/Grey button convention.
- Session chart brightness contrast: rejected dots now render at 15 % opacity and non-flagged dots at 50 %, making the three-level hierarchy (rejected → non-flagged → flagged/cursor) clearly readable.
- Conflict detection for key bindings in Settings now correctly separates plain keys from ⌘-modifier keys, preventing false conflicts (e.g. plain D vs ⌘D).

### Removed
- **File → Open File(s)… (⌘⇧O)** menu item removed (the open-files path has sandbox limitations that prevent it from working reliably).

---

## 2026-04-01 — v1.17.1

### Fixed
- ⌘A, ⌘D, and ⌘I now operate on the orange range selection (consistent with ⇧+click and ⇧+arrow) rather than the flag set.

### Improved
- FAQ: ⌘A / ⌘D / ⌘I documented in the Flagged view entry and the keyboard shortcuts entry.

---

## 2026-04-01 — v1.17.0 selection redesign

### Added
- SO (SII+OIII) dual-narrowband filter group with emerald colour — recognises Askar C2 and similar filters.

### Improved
- Selection model fully redesigned for consistency: **cursor** (blue, always one frame) and **range selection** (orange, built with ⇧+click or ⇧+arrow) are now independent concepts with no side effects between views.
- ⇧+click and ⇧+arrow build an orange range selection in any view (All or Selected).
- ⌘+click adds the range (or single frame) to the Flagged view from All; removes it from Flagged view.
- Reject acts on the orange range if one is active, otherwise on the cursor.
- In the Flagged view, rejected frames stay visible (orange) so the reject can be undone immediately by pressing Reject again.
- Session chart cursor dot is now white for instant position recognition; all other dots remain filter-group coloured.
- Session chart cursor dot is smaller (less dominant); rejected frames always shown at 30% opacity.
- Sidebar thumbnail shows a checkmark badge on flagged frames; orange border on range-selected frames.
- FAQ: updated session chart and Flagged view entries to reflect new selection model; added full filter-group colour table with swatches.

---

## 2026-03-31 — v1.16.3 improvements

### Added
- Help menu: new "Ask Support" item opens the GitHub bug report form directly.

### Improved
- FAQ: added "What do the colours and brightness levels in the session chart mean?" entry explaining filter-group dot colours, dashed median lines, and the spotlight brightness hierarchy.
- FAQ: corrected "What is the session chart?" — dot colour represents the filter group, not the quality badge.

---

## 2026-03-31 — v1.16.2 improvements

### Fixed
- Auto-Flag sheet: all "Reject if …" threshold labels corrected to "Select if …"; subtitle updated to "Flag frames below quality thresholds for review."
- Cmd+Click in the Flagged view with an active multi-selection (e.g. after Cmd+A) now removes all selected entries at once instead of only the clicked one.

### Improved
- Session chart spotlight: when a multi-selection is active, non-selected dots dim to 0.40 opacity and rejected dots dim further to 0.15, creating a clear three-level brightness hierarchy (rejected → non-selected → selected).
- Session chart drag-select now triggers the spotlight correctly (previously only sidebar Cmd/Shift-click selections activated it).
- Auto-Flag sheet: SNR threshold is now enabled by default.

---

## 2026-03-31 — v1.16.1 bug fixes

### Fixed
- Website feature list said "drag-to-reject" and "Auto-reject" instead of "drag-to-select" and "Auto-select".
- Folder count badge in the thumbnail sidebar showed the total file count regardless of the active view (All / Flagged / Rejected); it now reflects only the entries visible in the current view.
- Metric buttons above the session chart (Score, FWHM, Ecc, SNR, Stars) did not visually indicate the selected button; the active metric now uses a filled (prominent) button style.
- Cmd+Click in the Flagged view was toggling multi-selection instead of removing the entry from the selection; it now always unflag the clicked entry.
- Shift-click multi-select did not work at first open until the user clicked the first thumbnail explicitly; the shift-click anchor is now seeded when the first image is auto-selected on load.

---

## 2026-03-29 — Include REJECTED: undo and selection fixes

### Fixed
- Undo reject now correctly moves files back to their pre-rejection folder when they were loaded via "Include REJECTED". Previously `originalURL` was set to the REJECTED path itself, so the move was a no-op.
- Cmd+A (Select All) and other command-key shortcuts now work reliably across all keyboard layouts. The key monitor was using `event.characters` which can return a control character for Cmd+letter on some systems; switched to `event.charactersIgnoringModifiers`.
- Thumbnail selection highlight now updates instantly after Cmd+A and other multi-selection operations. `ThumbnailCell` now observes `selectedEntryIDs` directly rather than relying on a parameter passed from the parent view.

---

## 2026-03-29 — v1.16 bug fixes and features

### Fixed
- Reset now always switches back to "All frames" mode (was left in Flagged/Rejected if active).
- Cmd+click in "Flagged" mode with an active multi-selection now toggles the clicked entry instead of unflagging everything (unflag-on-cmd-click is still the default for single-entry actions).
- Shift+click range selection now works from the very first open; it no longer requires re-clicking the first image first.
- Session chart now enlarges dots for all multi-selected thumbnails, not just the focused entry.

### Added
- **Sort by Rejected** added to the thumbnail sort picker; rejected entries sort to the bottom (ascending) or top (descending), with alphabetical tie-breaking.
- **Cmd+R — Select All Rejected**: selects all rejected frames in one keystroke. Configurable in Settings → Keyboard.
- **Colour/Grey toolbar button** now shows a `camera.filters` icon (multicolour in colour mode, monochrome in grey mode) instead of plain text.
- **Ko-fi link** added to the About FITS Blaster panel.
- Opening a folder with the subfolders checkbox set differently from Settings now shows a one-time info alert pointing to Settings → Files & Folders.
- **Include REJECTED folder** checkbox added to the Open Folder dialog; when ticked, FITS files inside the `REJECTED/` subdirectory are loaded and automatically marked as rejected. A permanent toggle for this is in Settings → Files & Folders.
- **"How Scores Work"** page added to the website, explaining background estimation, star detection, shape measurement, the composite score formula, and badge-colour logic.

---

## 2026-03-28 — Repository housekeeping

### Improved
- Source assets (`Book of Galaxies.png/icns`, `installer-background.png`) moved to `resources/` and are now tracked.
- Installer scripts moved to `scripts/`.
- Screenshots tracked in `Screenshots/`.
- `.github/` added: bug report and feature request issue templates, and a `release.yml` workflow that builds, notarises, and uploads a DMG to GitHub Releases on version tags.
- Removed stray DMG binary and legacy `Simple Claude fits viewer.xcodeproj/` from disk.
- `.gitignore` cleaned up; only built artefacts (`bin/`, `site/Downloads/`, `*.dmg`) remain excluded.

---

## 2026-03-28 — Track all remaining docs in repository

### Improved
- `readiness.md` moved to `docs/internal/` and is now version-controlled. All markdown docs are now tracked.

---

## 2026-03-28 — Track public docs in repository

### Improved
- `privacy-policy.md` and `RAW-support.md` moved to `docs/public/` and are now version-controlled.

---

## 2026-03-28 — Reorganise documentation layout

### Improved
- Markdown docs split into `docs/public/` (user-facing) and `docs/internal/` (developer notes).
- Moved to `docs/public/`: `FAQ.md`.
- Moved to `docs/internal/`: `FWHM-comparison.md`, `Score.md`, `performance.md`.

---

## 2026-03-28 — Track website in repository

### Improved
- `site/` is now committed to the repository (Option A); `site/Downloads/` remains gitignored so DMG binaries are never stored in git.

---

## 2026-03-27 — Fix main-thread I/O hang on file open

### Fixed
- Opening a folder no longer blocks the main thread on slow I/O (iCloud Drive materialisation,
  SMB mounts, heavy disk pressure). The BITPIX pre-flight check (`peekBitpix`) is now performed
  in a `nonisolated` background function instead of synchronously on the main actor, eliminating
  the spinning beach ball that occurred when files were stored in iCloud Drive.

---

## 2026-03-27 — Website updates

### Added
- `site/changelog.html` — full changelog web page styled to match the site, with colour-coded
  section labels (Added / Fixed / Improved / Changed / Removed).
- Download button on homepage linking to `Downloads/FITS-Blaster-1.15.dmg`.
- Changelog link in homepage footer.

### Changed
- Replaced App Store badge with Ko-fi donation link (`https://ko-fi.com/tomvp`).
- FAQ "Subscription" section replaced with "Support & Donations" (free app, Ko-fi link).
- FAQ "Does FITS Blaster require an internet connection?" updated: no longer mentions subscription.
- FAQ "What data does FITS Blaster collect?" updated: no longer mentions App Store network requests.

---

## 2026-03-25 — Switch to donationware; remove StoreKit (v1.15)

### Removed
- `PurchaseManager`, `PaywallView`, and `Configuration.storekit` deleted entirely.
- 50-frame free-tier cap removed from `ImageStore.openFiles` — all images load without restriction.
- Subscription tab removed from Settings.
- Paywall sheet and `PurchaseManager` environment removed from `ContentView` and `FitsBlasterApp`.

### Fixed
- Sandbox permission error on rejection: `accessDirectory(for:)` now falls back to creating a fresh
  security-scoped bookmark from the entry's parent directory when the stored bookmark is missing or
  stale. `rejectEntry` and `undoRejectEntry` now fail fast with a clear error message if directory
  access cannot be established, instead of proceeding silently without sandbox scope.

---

## 2026-03-25 — Flagged view + selection overhaul (v1.14)

### Added
- **Flagged view** — a dedicated sidebar filter that shows only flagged frames. Frames enter the list via ⌘+click, ⇧+click, chart drag-select, or Auto-Flag; ⌘+click inside the view removes them. Flagged frames persist across filter switches and are only cleared on folder reset.
- **Flag-then-inspect workflow** — chart drag-select and Auto-Flag now add frames to the Flagged view instead of rejecting them immediately. Rejection happens explicitly inside the Flagged view after inspection.
- **Select menu** — top-level menu with Select All, Deselect All, and Invert Selection, each with configurable key bindings (defaults: ⌘A / ⌘D / ⌘I).
- **Shift+↑/↓ extend selection** — grows the multi-selection one step at a time using the configured navigation keys.
- **Configurable selection key modifiers** — Settings → UI lets you choose ⌘ or ⌘⇧ independently for each selection shortcut.
- **Drag tooltip** — while drag-selecting in the session chart, a floating label shows the metric value of the frame under the cursor.

### Fixed
- Arrow-key navigation (previous / next / first / last) now respects the active visibility filter, stopping at the boundary of the visible set rather than crossing into hidden frames.

### Improved
- Session chart left edge has breathing room before the first dot, making drag-select starting from frame 1 easier.

### Updated
- FAQ: new "What is the Flagged view?" entry; updated chart drag-select and Auto-Flag descriptions to reflect the new workflow.


---

## 2026-03-24 — v1.9–v1.12 series — pipeline, Bayer colour, and subfolder support

### Added
- **GPU downscale** in Metal stretch kernels — renders directly to display size (1024 px) in a single pass, eliminating post-GPU CPU scaling. Load time cut ~50%.
- **Bayer colour debayering** — colour FITS images rendered via single-pass Metal shader with bilinear demosaicing and per-channel percentile stretch; per-folder normalisation for consistent batch display.
- **Phase A/B pipeline** — I/O and GPU stretch (Phase A) fully decoupled from metrics computation (Phase B) so images appear immediately without waiting for Moffat fitting; MTLBuffer passed directly to Phase B.
- **Subfolder scanning** — recursive subfolder support with collapsible folder sections in the sidebar and folder filter pills in the session chart.
- **Text size picker** in Settings (xSmall → xxxLarge, Dynamic Type-based).
- **Resizable session chart** with a custom drag handle; dynamic y-axis starts near the data minimum.
- Cancel and Colour/Grey toggle buttons added to the toolbar.

### Fixed
- Keyboard shortcuts work after clicking a thumbnail (replaced `onKeyPress` with an `NSEvent` local monitor).
- Colour/grey toggle is instant on the second press (greyscale image cached on first load).
- Duplicate folder detection; subfolder name collision tracked by full path.
- Session chart: folder pills wrap instead of overflow; x-axis domain capped to actual frame count.
- Open Folder "Include subfolders" checkbox reads back reliably (AppKit `NSButton`).

### Improved
- Settings reorganised: **User Interface** and **Files & Folders** tabs; key conflict detection added.
- Phase B semaphore tuned to `max(4, cpuCount-2)`; star-measurement task group parallelised with 4 inner workers.

---

## 2026-03-04 — Early development and initial commit

### Added
- Simple/Geek mode, filter-group sidebar, quality badges, auto-reject sheet, session chart, dock-icon drag & drop.
- Multi-select in thumbnail sidebar (⌘+click, ⇧+click); batch reject and undo.
- SNR threshold in Auto-Flag panel; filename displayed above the main image.
- Configurable Remove-from-List key (R) and Simple/Geek mode toggle key (G).
- Full FITS file viewer for macOS 15.7+ built on Swift 6 / SwiftUI. **`FITSReader`** parses FITS headers and pixel data (BITPIX 8/16/32) with zero-copy GPU (`readIntoBuffer`) and CPU (`read`) paths. **`ImageStretcher`** renders via Metal compute shader (percentile clipping + sqrt gamma). **`MetricsCalculator`** detects stars via GPU Metal kernel and measures FWHM (1D Moffat β=4), eccentricity (2D moments), and SNR. **`ImageStore`** triple-buffered concurrent pipeline with sandbox security-scoped bookmarks and rejection to `REJECTED/` subdirectory.

### Fixed
- **Star count accuracy** — multiple rounds of fixes: wing pre-filter threshold (38% undercount), NMS bypass (3× inflation for BITPIX=16), Phase 2 extrapolation noise amplification (27× inflation), and over-aggressive saturation filter (missing FWHM/Ecc/SNR metrics).
- Float FITS files (BITPIX=−32/−64) silently skipped at scan time with a user alert.
- `vDSP_vsadd` instead of `vDSP_vsmsa` for BZERO-only path (BSCALE is always 1 for integer FITS).

### Improved
- Two-phase loading pipeline: display then metrics; single MainActor hop per image; `sortedEntries` and `activeFilterGroups` cached as stored properties.
- Moffat fitting: `pow(x, 0.25)` → two `squareRoot()` calls; uniform-sampled star count replaces per-candidate parallel extrapolation.
- BITPIX=−64 byte-swap vectorised with `vImage` SIMD.
