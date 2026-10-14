# Testing FITS Blaster

How FITS Blaster is tested, what each kind of test checks, and — most
importantly — **what the person running the tests has to do**. Automatic checks
can only catch what they were written to look for; several steps below rely on
a human looking at the app.

> **Rule of thumb:** a green test run means "nothing we thought of broke". It
> does not mean the release is good. The manual checks marked **👤 YOU** are
> part of the test, not optional extras.

---

## Overview

| Layer | What it checks | How to run | Status |
|---|---|---|---|
| Unit and integration tests | Metrics, scoring, FITS reading, stretch clips, GPU vs CPU — on synthetic data | Xcode ⌘U | Exists (223 tests) |
| Benchmarks | Load and measure speed on real data | `scripts/run-benchmark.sh` | Exists |
| PixInsight comparison | Our metrics vs PixInsight SubframeSelector | `scripts/compare.py` | Exists |
| **VM smoke test** | The real DMG on other macOS versions: install, signing, launch, CLI | `scripts/vm-smoke.sh` | **New** |
| **Rendering tests on real data** | Colour and brightness of rendered frames | `scripts/run-render-tests.sh` | **New** |
| **Metric baselines** | Metrics don't change between versions unless we mean them to | `scripts/metric-baselines.py` | **New** |
| **CLI `--render`** (beta builds only) | Rendering of the shipped binary in the VMs, without the GUI | Part of `scripts/vm-smoke.sh` | **New** |

---

## 1. Unit and integration tests

**Run:** in Xcode, ⌘U (scheme *FITS Blaster*). Or from Terminal:

```
xcodebuild test -project "FITS Blaster.xcodeproj" -scheme "FITS Blaster" -destination "platform=macOS"
```

**What they cover:** star detection, FWHM, eccentricity, SNR, scoring,
auto-flag, export, sorting, navigation, FITS reading, the GPU stretch and the
per-folder stretch clips (`ClipNormalisationTests`). They use synthetic images
(planted stars, noise, gradients), so they are fast and need no test data.

**What they do not cover:** what real frames look like on screen, and how the
app behaves on other macOS versions.

👤 **YOU:**
- Run them before every commit that touches app code. All must pass.
- If a test fails, find out why before changing the test. Change a test only
  when the behaviour change is intended, and say so in the commit message.

---

## 2. VM smoke test (`scripts/vm-smoke.sh`)

Tests a build the way a user gets it, on the macOS versions we can't run on
this Mac. It automates the steps done by hand on 2026-10-13 (which led to the
colour-cast bug). The launch crash in build 199 could only be reproduced in a
clean VM, not on this Mac.

### What it checks automatically

| Check | Passes when |
|---|---|
| Checksum (with `--tag`) | The downloaded DMG matches the GitHub release |
| Desktop login | The VM user is logged in at the desktop (needed to launch the app) |
| Install | The DMG mounts and contains an app, which is copied to `/Applications` |
| Code signature | `codesign --verify --deep --strict` succeeds |
| Notarisation | Gatekeeper reports *Notarized Developer ID* (skipped with `--dev-build`) |
| Bundle contents | Sparkle and both Quick Look extensions are included |
| Launch | The app is still running 30 s after launch (`--wait` to change) |
| Crash reports | No new FITS Blaster crash report appeared |
| Log | No uncaught exception or constraint loop (the build 199 crash) |
| Log faults | Fault-level messages are reported as **WARN** for you to judge |
| CLI `--help` | Prints usage and exits 0 |
| CLI, no filter | Exits 0 and writes one CSV row per sample frame |
| CLI, filtered | `-f 1.5 -e 0.5 -p 0.5` exits 0 and keeps at least one frame |
| Render (beta builds) | `--render` writes a PNG and a background for every frame; **SKIP** for stable builds, which don't have it |
| Render: metrics | The metrics CSV with `--render` is identical to the one without |
| Render: colour | Every colour frame got a colour render |
| Render: typical frame | Background R, G, B within 4 of each other and each within 63 ± 6 — the same limits as the [rendering tests](#4-rendering-tests-on-real-data-scriptsrun-render-testssh) |

### What it cannot check

- **Anything you see in the app.** It cannot take screenshots in the VM (macOS
  blocks screen capture over SSH). Layout, missing controls, a blank window —
  all invisible to the script. For beta builds it does bring back the rendered
  frames as PNGs (see [section 6](#6-cli---render-beta-builds-only)), but
  someone has to look at them.
- **Interaction.** It doesn't open folders in the GUI, click, flag, reject or
  export.
- **Metric values.** It checks the CSV has the right shape, not that the
  numbers are right (that comes with metric baselines).
- **Updates.** It doesn't test Sparkle update checks.

### 👤 YOU: before running

1. **Start from a clean VM.** Shut the VM down in VirtualBuddy, then restore it
   from its clean copy (see [VMs](#vms)). A VM that ran earlier builds keeps
   their settings and caches, which can hide problems a new user would hit.
2. **Boot the VM and log in as `fitstester`** in the VM window. Wait until the
   desktop is fully up.
3. **Leave the VM window alone** while the script runs; clicking in it can
   affect the launch check.
4. **Pick what to test:**
   - *Before tagging* (recommended for every release): a local beta build —
     `scripts/vm-smoke.sh <vm> "$(scripts/build-beta.sh)" --dev-build`.
     `build-beta.sh` builds Release with the `BETA` flag, so the render check
     runs too. Remember that a pushed beta tag goes live to beta users
     immediately, so this is the only test that happens before users get the
     build.
   - *After the release workflow*: the published DMG —
     `scripts/vm-smoke.sh <vm> --tag <tag>`. This also checks notarisation.

### Running

```
scripts/vm-smoke.sh fitsvm-b3 --tag v1.23-beta.10
```

Each check prints `PASS`, `WARN`, `FAIL` or `SKIP`. The last lines give the
result and where the sample set was unpacked in the VM. Results are saved in
`tests/smoke-results/<time>-<vm>-<build>/` on this Mac (not committed):
`smoke.log` plus `out/` with the CSVs, the CLI's stderr, the filtered app log,
any crash reports and — for beta builds — `render/` with the rendered PNGs and
`backgrounds.csv`.

### 👤 YOU: after running

The app is left open in the VM (unless you passed `--quit`). In the VM window:

1. **Window:** the main window is there, toolbar and sidebar look normal,
   full-screen and the traffic lights work.
2. **Open the sample set:** Open Folder… → the folder printed at the end of the
   run (`~/fb-smoke/<time>/sample/FITS-Blaster-Sample-M31`). All 8 thumbnails
   appear and the metrics fill in.
3. **Colour:** switch Colour on. The sky background should look roughly
   neutral grey — **not** magenta, green or strongly tinted. Frames 0041 and
   0042 are brighter (cloud); 0024–0028 can look slightly blue. Compare with
   the same folder on this Mac if in doubt. For beta builds, also open the
   PNGs in `out/render/` on this Mac (see [section 6](#6-cli---render-beta-builds-only)).
4. **Step through frames** with the arrow keys; flag one, reject one, undo.
5. **Quick Look:** in Finder, select a `.fits` file and press Space; check the
   icon view shows thumbnails.
6. **WARN lines:** open `out/app-log.txt` and read the fault messages. Most
   come from macOS itself; anything mentioning FITS Blaster's own code or
   repeating many times needs a closer look.
7. **Decide.** Any FAIL, or anything odd in steps 1–5, blocks the release until
   it is understood. Write down what you found (a line in the session notes
   or the release commit is enough).

Then shut the VM down and restore it from the clean copy, so the next run
starts clean.

### Which VMs

Run on **every VM** for releases that touch launch, windows, rendering or the
CLI; at least on the newest macOS beta VM for small fixes. Also run on this
Mac's own macOS by installing the DMG normally.

---

## 3. Benchmarks and PixInsight comparison

**Benchmarks** measure load-and-measure speed on real data:

```
scripts/run-benchmark.sh v1.23 --rgb "<colour folder>" --mono "<mono folder>"
```

Results go to `tests/benchmarks/` (not committed). Test data lives in
`/Volumes/FITS Blaster/Test Data` (M31, California, Gamma Cygni, Rosette).

**PixInsight comparison:** run the CLI on a folder, then
`python3 scripts/compare.py <folder>` compares `frames.csv` with a
`SubframeSelector.csv` exported from PixInsight in the same folder (rank
correlation per metric).

👤 **YOU:**
- Run the benchmarks before and after any change that could affect speed, on
  a quiet Mac (no Xcode indexing, no other heavy apps), and compare.
- Run the PixInsight comparison after any change to FWHM, eccentricity, SNR or
  star detection. A drop in rank correlation needs an explanation.

---

## 4. Rendering tests on real data (`scripts/run-render-tests.sh`)

Checks what the app actually shows for real frames. Added after the colour-cast
bug (the M31 sample set rendered magenta with Colour on), which no test caught.

**Run:**

```
scripts/run-render-tests.sh           # sample set only, about 30 s including the build
scripts/run-render-tests.sh --full    # also the large folders, about 5 minutes
```

The tests (`RenderingTests` in the test target) are skipped in normal ⌘U runs;
the script switches them on by pointing `FB_TEST_DATA` at
`/Volumes/FITS Blaster/Test Data` (`--data` for another location).

### How they work

Each folder is loaded exactly as the app loads it (the same code the CLI
uses), with Colour on for colour cameras. For every frame the test reads the
image the viewer would show (1024 px), and measures the **sky background** of
each channel: the median pixel value, which stars and nebulae are too sparse
to move. 63 out of 255 is the 25% grey the stretch aims for.

The **typical frame** is the one with the median background in its folder.

| Folders | Must hold for the typical frame |
|---|---|
| Sample set (published zip, unpacked each run) | R, G and B within **4** levels of each other, each within **63 ± 6** |
| M31 night, California, Gamma Cygni 03-04 (`--full`) | Same |
| Rosette R, G, B — mono (`--full`) | Background within **63 ± 6** |

**Why these limits** (measured 2026-10-13, typical frame R/G/B):

| Folder | Before the colour fix | After the fix |
|---|---|---|
| Sample set | 58/29/61 | 62/61/63 |
| M31 night | 62/59/61 | 62/61/61 |
| California | 58/63/60 | 62/64/64 |
| Gamma Cygni | 60/65/62 | 63/64/64 |
| Rosette (mono) | 63 | 63 |

After the fix the channels differ by at most 2 and stay within 2 of 63. Before
it they differed by up to 32 (the magenta you saw). The limits leave a little
room for harmless changes and still fail on the casts we had: the old code
fails on the sample set, California and Gamma Cygni.

Every other frame is **only reported**, not tested: real frames differ
(clouds, twilight, a brightening sky), and a limit there would be arbitrary.

### Output

For each folder the run prints every frame's background (typical frame marked
`[*]`), and saves to `tests/render-results/<time>/<folder>/` (not committed):

- `typical-<frame>.png` — the typical frame exactly as rendered
- `backgrounds.csv` — every frame's R, G, B background

### What they cannot check

- **Quick Look previews** — they use their own rendering code, in the
  extensions.
- **The Target BG and Stretch sliders** — applied on screen after rendering.
- **The display** — how macOS converts the colours for your screen.
- **Whether the colours are *right*** — only that the background is neutral
  and at the target level. A wrongly coloured nebula on a neutral background
  passes.

### 👤 YOU

- **When to run:** the sample set before every release; `--full` whenever the
  change touches loading, the stretch, colour or debayering.
- **Look at the PNGs.** Open the typical frames in `tests/render-results/`
  and check they look right — neutral sky, no tint, stars and the target
  visible. The numbers only catch a tinted background.
- **Read the per-frame table.** Frames far from the rest should have a reason
  you recognise (cloud, twilight, moon). Frames that look odd without a reason
  need a closer look.
- **If a test fails,** find out whether it's a bug or an intended change.
  Change the limits only with a written reason in the commit, and update the
  table above.
- **The test data must stay as it is.** Adding or removing frames in these
  folders changes the medians; if you have to, rerun and update the table.

---

## 5. Metric baselines (`scripts/metric-baselines.py`)

Checks that FWHM, eccentricity, SNR, star count, PSF signal weight and score
stay the same from version to version, unless we change them on purpose. It
runs the command-line mode — the same code the app uses for its metrics — on
the test datasets and compares every frame with the CSVs in `tests/baselines/`.

**Run:**

```
scripts/metric-baselines.py            # builds the current checkout (Release), all datasets, about 30 s + build
scripts/metric-baselines.py --quick    # sample set only
scripts/metric-baselines.py --app "/Applications/FITS Blaster Beta.app"     # an installed or downloaded build
scripts/metric-baselines.py --smoke-results tests/smoke-results/<run>      # CSVs from a VM smoke test (sample set)
```

Datasets: the sample set (unpacked from the published zip), the M31 night,
California, Gamma Cygni 03-04, Rosette R, G and B. Each run's CLI output is
kept in `tests/baseline-results/<time>/` (not committed).

### What it checks

Per frame, the new value must be within this distance of the baseline:

| Metric | Allowed | Why |
|---|---|---|
| FWHM | ± 0.01 px | one step in the last digit the CSV writes (a value on a rounding edge can flip) |
| Eccentricity | ± 0.001 | same |
| SNR | ± 0.1 | same |
| Stars | ± 0.5%, at least 3 | margin for small differences between machines |
| PSF·S | ± 0.5% | same |
| Score | ± 1 | whole numbers, relative to the folder |

And with the standard filter (`-f 1.5 -e 0.5 -p 0.5`, as in the VM smoke test)
**exactly the same frames** must be kept. A frame that flips is shown with its
values next to the folder medians, so you can see how close to the limit it was.
Frames missing from or added to a folder also fail.

### Background: results are now reproducible

When this was built (2026-10-13), identical runs on the same Mac gave slightly
different numbers: star counts ±2 everywhere, and on Gamma Cygni SNR up to
2.8% and PSF·S up to 1.8%. The cause was the star detection: the GPU returns
candidates in a random order, and stars with exactly the same peak value
(common in 16-bit data, especially saturated stars) kept that random order, so
different stars were picked and measured. Fixed in 1.23.1 by breaking ties on
position and combining parallel measurements in a fixed order. Since then,
repeated runs — on this Mac and in the 27.2 beta 3 VM — give byte-identical
results. `MetricsDeterminismTests` guard this.

Builds before the fix (beta 10, App Store build 202) still vary, so they can
fail on Gamma Cygni against these baselines. That is expected.

### 👤 YOU

- **When to run:** before every release, and after any change to star
  detection, metrics, the score, the auto-flag filter or FITS reading.
- **If it fails, don't update the baselines to make it pass.** First decide:
  - *A bug?* Fix the code.
  - *An intended change?* Check that the size and direction make sense —
    the failure list shows old → new for every frame. Then run the
    PixInsight comparison on M31 (`scripts/compare.py "/Volumes/FITS Blaster/Test Data/M31/LIGHT"`
    after a CLI run there) and check the rank correlation didn't get worse.
- **Updating:** `scripts/metric-baselines.py --update` prints how every metric
  changed per dataset and writes the new baselines plus
  `tests/baselines/baselines.json` (which build, commit and macOS made them).
  Look at `git diff tests/baselines`, then commit with the reason in the message.
- **A change in which frames the filter keeps** is a change users see in
  Auto-Flag. Treat it as a behaviour change, not noise.
- **Keep the test data unchanged** — adding or removing frames changes every
  relative metric and the score.

---

## 6. CLI `--render` (beta builds only)

A test-only option of the command-line mode that writes what the app shows:

```
"FITS Blaster.app/Contents/MacOS/FITS Blaster" <folder> --render <dir> [--render-typical]
```

- `<dir>/<folder>/<frame>.png` — each frame's display image (at most 1024 px,
  about 1.5 MB). Colour frames are rendered as the app shows them with Colour
  on; mono frames in greyscale.
- `<dir>/backgrounds.csv` — every frame's background R, G, B (0–255), its view
  (`colour`, `mono`, or `grey` for a colour frame that didn't get a colour
  render — a bug) and which frame is the folder's typical one.
- `--render-typical` — write only each folder's typical frame as a PNG (the CSV
  still lists every frame). For large folders: a full night is hundreds of MB.
- The metrics CSV is written as usual and is identical with or without
  `--render`.

It measures with the same code as the rendering tests (`RenderedPixels.swift`).
It writes data only; the VM smoke test judges it (see section 2). Run by hand
on this Mac, it is a quick way to see how a folder renders without opening the
app.

### Beta builds only

Decided 2026-10-13: the option exists only in beta builds, not in stable or App
Store builds, and is not listed in `--help`. The code is compiled in only when
the `BETA` compilation condition is set (or in Debug builds):

- the release workflow sets `BETA` for tags containing `beta`;
- `scripts/build-beta.sh` sets it for local builds;
- a stable build doesn't contain the code. It ignores `--render` like any
  unknown option and writes no PNGs; the smoke test reports **SKIP**.

Cost: none in stable builds, and none in beta builds unless `--render` is
given. With it, the CLI does the extra colour pass the app does with Colour on,
plus the PNGs: on this Mac the M31 night (39 frames) took about 8 s instead of
about 2.5 s.

### 👤 YOU

- **Look at the PNGs** from every VM run of a beta build
  (`tests/smoke-results/<run>/out/render/`). The check only catches a tinted
  or wrongly levelled *typical* frame; a tint in one frame, a wrong-looking
  target, banding or artefacts need your eyes. Compare with this Mac
  (`scripts/run-render-tests.sh` or `--render` by hand) if in doubt.
- **A SKIP on a beta build is a failure** — it means the build lacks `BETA`
  (wrong build script or a workflow change).
- **Keep the limits in step:** they are in `RenderingTests.swift` and
  `scripts/vm-smoke-remote.sh`; change both together, with a reason.

---

## VMs

VirtualBuddy VMs live in `/Volumes/FITS Blaster/VMs` (the VirtualBuddy library
on this Mac).

| VM | macOS | SSH | Clean copy |
|---|---|---|---|
| `27.2B1.vbvm` | 27.2 beta 1 (26B5086k) — the build App Review used for build 199 | `ssh fitsvm` (192.168.64.2) | `27.2B1-clean.vbvm` |
| `27.2B3.vbvm` | 27.2 beta 3 (26B5101f) | `ssh fitsvm-b3` (192.168.64.3) | `27.2B3-clean.vbvm` |

User `fitstester`, key `~/.ssh/fitsvm_ed25519`, host entries in `~/.ssh/config`.

**Restore a VM** (shut it down in VirtualBuddy first — never while it runs):

```
cd "/Volumes/FITS Blaster/VMs"
rm -rf 27.2B3.vbvm && cp -cRp 27.2B3-clean.vbvm 27.2B3.vbvm
```

`cp -c` makes an APFS clone: instant, and it takes almost no extra space.
Keep VMs on this volume; copying one to another disk loses the sharing.

👤 **YOU:**
- **Never start a `-clean` VM.** It appears in VirtualBuddy's list next to the
  working VM; starting it (even without logging in) changes it, and every
  later restore inherits those changes.
- **Quit and reopen VirtualBuddy after a restore.** On 2026-10-13 a restored
  VM hung with a spinning wheel and never started until VirtualBuddy was
  restarted (another restore earlier that day started without a restart).

**Add a VM for a new macOS version:**
1. Create it in VirtualBuddy (name like `27.3B1`).
2. In the VM: create user `fitstester`, log in, turn on Remote Login
   (System Settings → General → Sharing), note the IP address.
3. On this Mac: add a `Host` entry to `~/.ssh/config` (copy an existing one,
   change name and IP), then install the key once with
   `ssh-copy-id -i ~/.ssh/fitsvm_ed25519.pub <host>` (asks for the password).
4. Shut the VM down and make the clean copy:
   `cp -cRp <name>.vbvm <name>-clean.vbvm`.
5. Add it to the table above.

VM settings (CPU, memory, shared folders) are stored in
`<name>.vbvm/.vbdata/Config.plist`. The clean copy has its own; change both or
the next restore undoes the change.
