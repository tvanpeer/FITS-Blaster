# How FITS Blaster Is Tested

FITS Blaster is tested in layers: fast automatic tests on every change, tests on
real astrophotography data before every release, and checks of the finished
download on clean test machines. Automatic tests only catch what they were
written to look for, so every release also gets a human look.

---

## The tests

| Test | What it checks | Data |
|---|---|---|
| **Unit and integration tests** | Star detection, FWHM, eccentricity, SNR, scoring, auto-reject, export, sorting, FITS reading, stretching and colour, GPU against CPU results — 223 tests | Synthetic images with planted stars, noise and gradients |
| **Rendering tests** | Each folder's typical frame renders with a neutral sky background (no colour cast) at the intended brightness | Real frames: one-shot colour (M31, California Nebula, Gamma Cygni) and mono (Rosette R, G, B) |
| **Metric baselines** | Every frame's metrics, and which frames the standard filter keeps, match stored results — so no metric changes unless we mean it to | The same real datasets, seven folders |
| **Smoke test on clean machines** | The app as you download it: installs, is correctly signed and notarised, launches and stays up without crashes, the command line works, frames render without a colour cast, and the metrics match | The published sample set, on fresh virtual machines with macOS 15, 26 and 27 |
| **Speed benchmarks** | Loading and measuring speed | Real colour and mono folders |
| **PixInsight comparison** | Our metrics rank frames the same way as PixInsight's SubframeSelector | Real data measured in both |

Metrics are reproducible: the same files give the same numbers every time, on
every Mac. That is what makes the baselines possible.

---

## When they run

| Phase | Tests |
|---|---|
| **Every code change** | Unit and integration tests — all must pass |
| **Before every release** | Unit tests · rendering tests (all folders when loading, stretching or colour changed) · metric baselines · smoke test of the release build on clean test machines, plus the human checks below |
| **Building the release** | Code signing and Apple notarisation, done automatically by the release pipeline |
| **After publishing** | Smoke test of the actual published download (including notarisation) on a clean test machine, plus the human checks |
| **When relevant** | Speed benchmarks for changes that could affect speed · PixInsight comparison for changes to star detection or metrics |

A failed test, or anything odd in the human checks, stops the release until it
is understood. When a metric changes on purpose, the new baseline is reviewed
and recorded with that change, so every change in the numbers is a deliberate
decision.

---

## What a human checks

- **Rendered frames** — the frames from the test machines are looked at, not
  just measured: neutral sky, no tint, stars and target looking right.
- **The app itself** — window and toolbar, opening the sample set, colour view,
  stepping through frames, flagging, rejecting and undo, Quick Look in Finder.
- **Warnings** — system log messages flagged by the smoke test are read and
  judged.
- **Unusual frames** — frames far from the rest of their folder should have a
  known reason (cloud, twilight, moon).

---

## Which macOS versions

FITS Blaster runs on macOS 15.6 and later. Each release is tested on clean
virtual machines, freshly cloned for every run, so each test sees FITS Blaster
the way a new user does:

| macOS | Tested |
|---|---|
| **27** (latest release) and the current **27 beta** | Everything: all automatic tests plus the human checks |
| **26 Tahoe** (latest release) | All automatic tests: install, signing, launch, command line, rendering and metrics |
| **15 Sequoia** (latest release) | All automatic tests |
| Other versions from 15.6 | Supported, not tested separately |

The automatic tests include the metrics: every frame of the sample set must
match the stored results on every tested macOS version.

---

## Not covered yet

- Automatic checks of what the app looks like on screen — this is done by a
  person.
- Clicking through the app automatically.
- Update checks (Sparkle).
