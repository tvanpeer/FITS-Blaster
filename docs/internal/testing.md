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
| **VM smoke test** | The real DMG on macOS 15, 26, 27 and the 27 beta: install, signing, launch, CLI, rendering, metrics | `scripts/vm-test-all.sh`, `scripts/vm-smoke.sh` | **New** |
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
| Quick Look registered | After the app was opened, `pluginkit -m -i` finds both extensions (preview and thumbnail). Being in the bundle isn't enough: with a too-high minimum macOS they are ignored (CODE_AUDIT §5.1) |
| Quick Look thumbnail | `qlmanage -x -t` (through the Quick Look server, like Finder) makes a thumbnail of the first sample frame; the PNG comes back in `out/quicklook/` |
| Metric baselines (with `--tart`) | The sample set's metrics and filter result match `tests/baselines/` (section 5) — also on macOS 15 and 26 |

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

### Support levels

Which macOS versions get which tests (decided 2026-10-14). Each level has a
Tart base VM (see [VMs](#vms)); every test runs on a fresh clone of it.

| Level | macOS | Base VM | Tests |
|---|---|---|---|
| **Fully tested** | Newest 27 release (27.0.1 on 2026-10-15) | `fb-27` | Automatic smoke test, metric baselines, render check **and** 👤 the manual checks below |
| **Fully tested** | Current 27 beta or RC (27.2 RC) | `fb-27-beta` | Same |
| **Automatically tested** | Latest 26 release | `fb-26` | Automatic smoke test, metric baselines, render check — no person needed |
| **Automatically tested** | Latest 15 release | `fb-15` | Same |
| Supported, not tested | Everything else from 15.6 (the app's minimum) | — | — |

The base VMs run the *latest* release of each major; the app's minimum stays
macOS 15.6. Base VMs that don't exist yet are skipped (since 2026-10-20 all four
exist: `fb-15`, `fb-26`, `fb-27` and `fb-27-beta`).

### Running

All base VMs, automatic level (two VMs at a time, about 3 minutes per pair):

```
scripts/vm-test-all.sh "$(scripts/build-beta.sh)" --dev-build     # before tagging
scripts/vm-test-all.sh --tag v1.23.1-beta.1                        # the published DMG
```

One base VM: `scripts/vm-smoke.sh --tart fb-26 <app|dmg|--tag tag> [--dev-build]`.
The script clones the base VM, starts the clone without a window, waits for
the desktop, runs the checks, compares the metrics with the
[baselines](#5-metric-baselines-scriptsmetric-baselinespy) and deletes the
clone. Nothing to restore, nobody needed at the VM.

For the manual checks (fully tested level), one VM at a time:

```
scripts/vm-smoke.sh --tart fb-27-beta "$(scripts/build-beta.sh)" --dev-build --keep
```

`--keep` starts the clone with a window and leaves it running with the app
open. When you're done: `scripts/tart-cleanup.sh` (deletes all test clones,
never a base VM).

Each check prints `PASS`, `WARN`, `FAIL` or `SKIP`. Results are saved in
`tests/smoke-results/<time>-<vm>-<build>/` on this Mac (not committed):
`smoke.log` plus `out/` with the CSVs, the CLI's stderr, the filtered app log,
any crash reports and — for beta builds — `render/` with the rendered PNGs and
`backgrounds.csv`. `vm-test-all.sh` also keeps each VM's console output in
`tests/smoke-results/<time>-all/`.

The script still works with a VM that is already running and reachable over
SSH (`scripts/vm-smoke.sh <ssh-host> …`), for example a VM started by hand.

### 👤 YOU: before running

1. **Pick what to test:**
   - *Before tagging* (every release): a local beta build —
     `"$(scripts/build-beta.sh)" --dev-build`. `build-beta.sh` builds Release
     with the `BETA` flag, so the render check runs too. A pushed beta tag
     goes live to beta users immediately, so this is the only test that
     happens before users get the build.
   - *After the release workflow*: the published DMG — `--tag <tag>`. This
     also checks notarisation.
2. **No other VMs running.** macOS runs at most two VMs at a time, VMs from
   other apps included; `vm-test-all.sh` uses both places.
3. **Leave `--keep` windows alone** until the script has finished; clicking in
   them can affect the launch check.

### 👤 YOU: after running

For the fully tested level, run with `--keep`: the app is left open in the
clone's window. In that window:

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

Then delete the clone: `scripts/tart-cleanup.sh`.

### Which VMs

Every release: `vm-test-all.sh` (all base VMs, automatic level) and the manual
checks with `--keep` on `fb-27` and `fb-27-beta`. Also install the DMG normally
on this Mac.

### App Store builds (`--appstore`)

Build the App Store configuration locally and test it before uploading:

```
xcodebuild -project "FITS Blaster.xcodeproj" -scheme "FITS Blaster" -configuration "App Store" \
    -derivedDataPath <dir> ENABLE_CODE_COVERAGE=NO build
scripts/vm-test-all.sh "<dir>/Build/Products/App Store/FITS Blaster.app" --dev-build --appstore
scripts/vm-smoke.sh --tart fb-27-beta "<…>/FITS Blaster.app" --dev-build --appstore --keep
```

With `--appstore` the bundle check turns around: **Sparkle must be absent**
(build 198 was rejected for it) and the **app sandbox entitlement must be set**;
a network entitlement gives a warning. The command-line checks, rendering and
metric baselines are skipped: App Store builds have no command-line mode (the
binary opens the window instead). Install, signature, launch, crash and log
checks and Quick Look run as usual. The metrics are only checked by hand in the
manual checks (step 2), so do those on `fb-27-beta`, the newest macOS that
App Review is likely to use. First used for 1.23.1 (208) on 2026-10-22: all
four VMs passed, including Quick Look on macOS 15.8.1, which App Store build 202
didn't have.

---

## 3. Benchmarks and PixInsight comparison

**Benchmarks** measure load-and-measure speed on real data:

```
scripts/run-benchmark.sh v1.23 --rgb "<colour folder>" --mono "<mono folder>"
```

Results go to `tests/benchmarks/` (not committed). Test data lives in
`/Volumes/FITS Blaster/Test Data` (M31, California, Gamma Cygni, Rosette, ASI294MM SHO).

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
scripts/metric-baselines.py --only asi294mm-sho                             # one dataset (repeatable)
scripts/metric-baselines.py --app "/Applications/FITS Blaster Beta.app"     # an installed or downloaded build
scripts/metric-baselines.py --smoke-results tests/smoke-results/<run>      # CSVs from a VM smoke test (sample set)
```

Datasets: the sample set (unpacked from the published zip), the M31 night,
California, Gamma Cygni 03-04, Rosette R, G and B, and ASI294MM SHO (mono
narrowband H/O/S, `.fit` files, single-letter filter names; added 2026-10-21).
Each run's CLI output is kept in `tests/baseline-results/<time>/` (not committed).
To add a dataset, write only its baseline: `--only <name> --update`. A plain
`--update` rewrites every baseline.

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

The test VMs are [Tart](https://tart.run) VMs (Cirrus Labs; free on personal
computers). Tart replaced VirtualBuddy on 2026-10-15 because it can be driven
from scripts: clone, start, stop and delete.

### Base VMs

| Base VM | macOS | Level | Created with |
|---|---|---|---|
| `fb-27-beta` | 27.2 RC (26B118) | Fully tested | `tart-create-base.sh` (2026-10-22, no clicks needed, 6 minutes), 80 GB disk; replaced the 27.2 beta 3 VM (26B5101f, 2026-10-15) |
| `fb-27` | 27.0.1 (26A434) | Fully tested | `tart-create-base.sh` (2026-10-20, no clicks needed, 8 minutes), 80 GB disk; first built 2026-10-15 and deleted for space |
| `fb-26` | **26.6.2** (25G83) — not yet 26.7.1, see below | Automatically tested | `--manual` (2026-10-15), 50 GB disk |
| `fb-15` | 15.8.1 (24H32) | Automatically tested | `--manual` from 15.6.1, updated to 15.8.1 (2026-10-15), 50 GB disk |

**To do when the VM disk arrives (about 2026-10-22):** rebuild `fb-26` with the
script's 80 GB disk and update `fb-26` to the latest 26. The
26.7.1 update refused to install on the 50 GB disk: "Not enough free disk
space: a total of 21.55 GB is required". Enlarging a VM disk afterwards is
impractical (the recovery partition sits behind the system container, and
deleting it breaks `softwareupdate`), so new base VMs get 80 GB from the start.
It is sparse: on this Mac a VM only takes what macOS writes (about 30 GB).

Every base VM: user `fitstester` (password in the Keychain, item `fb-test-vm`),
automatic login, FileVault off, Remote Login on, **all automatic updates off**
(so a VM only changes when we update it), screen lock, sleep and screensaver
off, `sudo shutdown` allowed without a password, SSH key
`~/.ssh/fitsvm_ed25519`.

Why no screen lock: if the display sleeps and locks, macOS remembers it, and
after the next automatic login the screen is locked again (found on `fb-15`,
2026-10-15). The tests pass behind a locked screen, but the manual checks
would need the password. Everything else as on a normal
user's Mac: SIP and Gatekeeper on, no extra software.

A base VM is **never started for tests**: every test runs on a clone
(`<base>-smoke-<time>`), made instantly with APFS copy-on-write and deleted
afterwards.

**Where:** on the external SSD "FITS Blaster External" (1 TB, APFS, since
2026-10-22): `TART_HOME=/Volumes/FITS Blaster External/Tart` (set by the
scripts, which stop with a message when the drive isn't connected; set it
yourself when you run `tart` by hand, e.g.
`export TART_HOME="/Volumes/FITS Blaster External/Tart"`). Installers (IPSW) in
`/Volumes/FITS Blaster External/Tart/ipsw`. A macOS VM takes about 25–30 GB;
clones almost nothing until they change. Copying a VM to another volume:
`ditto` writes the disk image out in full (a 50–80 GB file each); `cp -Rp`
keeps it sparse but checks every 4 KB block, at about 0.6 MB/s (hours per VM).
`scripts/tart-copy-vm.py <source VM folder> <destination VM folder>` copies
only the data regions (`SEEK_DATA`/`SEEK_HOLE`), so the image stays sparse, at
drive speed: the move to the SSD took under 2 minutes for 76 GB. Shut the VM
down first and compare `shasum -a 256` of both `disk.img` files afterwards.

**Tart itself:** version 2.41.0 in `~/Applications/tart.app`, with `tart` linked
in `~/.local/bin`. Installed from the
[GitHub release](https://github.com/cirruslabs/tart/releases) (checksum and
notarisation checked): the Cirrus Labs Homebrew formula was broken with
Homebrew 7 on 2026-10-14.

### Create a base VM

macOS 27 and later (scripted; with a beta installer three clicks):

```
scripts/tart-create-base.sh fb-27 <ipsw-file-or-url>
```

Apple's guest provisioning creates the user and turns on automatic login and
Remote Login; the script then installs the SSH key, sets the rest, checks it
and shuts the VM down. Takes about 7 minutes from a release installer (27.0.1:
desktop 30 s after the first boot), about 12 from a beta installer.

macOS 15 and 26 (no provisioning before 27):

```
scripts/tart-create-base.sh fb-26 <ipsw-file-or-url> --manual
```

Apple only publishes VM installers up to the last release before the next
major: **15.6.1** and **26.6.2**. List: `curl -s 'https://api.ipsw.me/v4/device/VirtualMac2,1?type=ipsw'`.
Later 15.x and 26.x come through Software Update in the VM.

👤 **YOU:**
- **macOS 27+ beta installers:** watch the VM window. About 4 minutes in,
  the licence agreement appears: **Agree** (twice), then **Get Started**.
  Nothing else; the script continues by itself. Release installers (checked
  with 27.0.1) need no clicks at all.
- **`--manual`:** go through Setup Assistant as the script prints (account
  `fitstester` with the Keychain password, no Apple ID, FileVault off; then
  automatic login, Remote Login and all automatic updates off in System
  Settings).
- **15 and 26 only:** after the script has finished, update the VM to the
  latest release (see *Update a base VM*).
- **`--manual`: set automatic login before turning on Remote Login**, or the
  script sees the desktop too early and stops with "Not as expected:
  auto-login" (it leaves the VM running; finish the settings and ask Claude to
  rerun the check and shut it down).
- **Never use *Stop* in the Tart window, or `tart stop`, on a base VM.** It
  pulls the plug (no proper shutdown). It's fine for test clones.

### Update a base VM

For a new beta, build a new base VM from its installer and delete the old one
(`tart delete fb-27-beta`). For 26 and 15 (done this way for 15.8.1 on
2026-10-15): start the base VM (`tart run fb-15`), list the updates over SSH
with `softwareupdate --list`, and install **only the macOS update for that
major** (not the offered upgrade to 27, not Safari):

```
sudo softwareupdate --install 'macOS Sequoia 15.8.1-24H32' --restart --agree-to-license --user fitstester --stdinpass
```

(`sudo` and `--stdinpass` each read the password on stdin; pipe it in twice from
the Keychain.) The VM downloads in the background (the window shows nothing),
restarts and installs. Then check the version, and shut down properly with
`sudo shutdown -h now` over SSH. Update the table above.

Known oddity: after an update, `softwareupdate --schedule` reports "Automatic
checking for updates is turned on" even when the setting is off, and on 15.8.1
the check setting itself could not be switched off from the command line. It
only *checks*; downloading and installing stay off. Switch it off in System
Settings next time the VM is open, if it matters.

### Clean up

`scripts/tart-cleanup.sh` stops and deletes all test clones. `tart list` shows
all VMs; `tart delete <name>` removes one.

### Facts the scripts rely on

Checked 2026-10-14/15 (Tart 2.41.0, macOS 27.0 host):
- `tart stop` and *Stop* are a hard power-off. *Request Stop* (or `kill -USR2`
  to `tart run`) asks macOS to shut down: it shows "Are you sure you want to
  shut down your computer now?" and only shuts down after a click.
- macOS runs **at most two VMs at a time** (any tool); a third fails with "The
  number of VMs exceeds the system limit".
- A clone gets a new network address; scripts ask `tart ip`.
- Started without a window, a clone still logs in automatically and the app
  can be launched (desktop session with Finder and Dock).
- The SSH login works before the first-boot setup has finished; shutting down
  then brings Setup Assistant back. The scripts wait for the desktop.
- On first boot, Setup Assistant needs a window: without one it waits on the
  licence screen where nobody can see it.
- Renders and metrics of the sample set are byte-identical on macOS 15.8.1,
  26.6.2, 27.0.1 and 27.2 beta 3 (2026-10-15).
- `vm-test-all.sh` on three base VMs takes about 7 minutes.

### VirtualBuddy: removed

The VirtualBuddy VM with macOS 27.2 beta 1 (26B5086k), the build on which App
Review's build 199 crash reproduced, was kept until App Store build 202 was
approved. It was removed on 2026-10-20, with VirtualBuddy's settings and the
`fitsvm` SSH entry. The key `~/.ssh/fitsvm_ed25519` stays: the Tart VMs use it.
