# Scripts — overview

Everything in `scripts/` and the two GitHub workflows, grouped by job: what each is for, when it's
used and the command you usually type. Run them from the repository root. The details
(all options, what to do when a check fails) are in each script's header and in
`docs/internal/testing.md` and `docs/internal/release-procedure.md`.

State: 2026-11-11 (after 1.24-beta.5).

## At a glance

| Job | Scripts |
|---|---|
| Checks before a commit | `lint.sh`, `run-render-tests.sh`, `metric-baselines.py` (+ `baseline-data.py`, `testdata.py`) |
| Test builds on VMs | `build-beta.sh`, `vm-test-all.sh`, `vm-smoke.sh`, `vm-smoke-remote.sh`, `tart-cleanup.sh` |
| Test VMs themselves | `tart-create-base.sh`, `tart-resize-base.sh` (+ `tart-resize.pkr.hcl`), `tart-upgrade-base.sh`, `tart-copy-vm.py`, `tart-lib.sh` |
| Release (CI) | `make-dmg.sh`, `release-notes.py`, `generate-appcast.py`, `update-site.py`, `deploy-site.py`, `_common.py` |
| Builds by hand | `build-release.sh`, `make-dmg-background.swift` |
| App Store | `appstore-screenshots.sh` (+ `appstore-flatten.swift`) |
| Measuring and comparing | `run-benchmark.sh`, `compare.py` |
| Statistics | `download-stats.py`, `site-stats.py` |

## Checks before a commit

The project rule: before a commit that touches code, unit tests, render tests, metric
baselines and lint must all report nothing. Unit tests run through Xcode or `xcodebuild test`
(no script).

| Script | What it does | Usual command |
|---|---|---|
| `lint.sh` | SwiftLint (Homebrew) over the app, tests, Quick Look targets and Swift scripts, `--strict`. Findings in `.swiftlint-baseline.json` (from when SwiftLint came in, 2026-11-05) are not reported. Exit 0 = clean. | `scripts/lint.sh` |
| `run-render-tests.sh` | Runs `RenderingTests` on real data: each folder's typical frame (PNG) and every frame's background (CSV) must stay byte-identical. Output in `tests/render-results/<time>/`. | `scripts/run-render-tests.sh` (add `--full` for the large folders) |
| `metric-baselines.py` | Builds the checkout as Release, runs the command-line mode on the test sets and compares every frame's metrics and the standard filter's choice with `tests/baselines/*.csv`. Exit 0 within tolerance, 1 differences, 2 test data changed. | `scripts/metric-baselines.py` (`--quick` sample set only, `--only <set>`, `--update` only after review) |
| `baseline-data.py` | Makes and checks the test-data copy the two scripts above read: "Test Data (baselines)", APFS clones of "Test Data", with SHA-256 manifests in `tests/baselines/<set>.sha256`. | `create --only <set>`, `verify`, `restore` |
| `testdata.py` | The list of test sets and the manifest code. Imported by the three scripts above; not run on its own. | — |

## Testing a build on the VMs

Tart VMs: fb-15, fb-26 (tested automatically), fb-27, fb-27-beta (automatically and by hand). Tests
always run on a throwaway clone, never on a base VM.

| Script | What it does | Usual command |
|---|---|---|
| `build-beta.sh` | Local Release build with the BETA flag, as the workflow makes for beta tags (has the CLI `--render` the smoke test uses). Prints only the app path. Signed with the development certificate, not notarised. | `scripts/build-beta.sh` |
| `vm-test-all.sh` | Smoke test on every base VM, two at a time, then prints the commands for the manual checks on fb-27 and fb-27-beta. Without the external SSD only fb-27-beta is there and the run counts as "not a full release test". | `scripts/vm-test-all.sh "$(scripts/build-beta.sh)" --dev-build` · published: `--tag <tag>` · App Store: `--dev-build --appstore` |
| `vm-smoke.sh` | Smoke test on one VM: copies the DMG and the M31 sample set in, installs, checks signing and notarisation, launches, runs the CLI, renders (beta), compares metrics with the baselines. `--keep` leaves the clone running with a window for the manual checks. | `scripts/vm-smoke.sh --tart fb-27-beta "<app>" --dev-build --keep` |
| `vm-smoke-remote.sh` | The part that runs inside the VM (install, launch, CLI, Quick Look registration and thumbnail). Started by `vm-smoke.sh`; bash 3.2. | not by hand |
| `tart-cleanup.sh` | Stops and deletes all smoke-test clones (`*-smoke-*`) on every Tart home that's connected. Never touches base VMs. | `scripts/tart-cleanup.sh` |

Results: `tests/smoke-results/<time>-<vm>-<build>/` (not committed). `download-stats.py` also
uses these folders to count test downloads.

## Looking after the test VMs

| Script | What it does | Usual command |
|---|---|---|
| `tart-create-base.sh` | Makes a base VM from an IPSW: user, SSH key, passwordless `sudo shutdown`, updates, sleep and screen lock off. macOS 27+ needs no clicks (beta installers: licence and Get Started); 15 and 26 need `--manual` (Setup Assistant by hand). Goes on the external SSD unless `TART_HOME` says otherwise. | `scripts/tart-create-base.sh <name> <ipsw>` |
| `tart-resize-base.sh` | Gives a base VM a larger disk as a new VM next to it (Packer, `tart-resize.pkr.hcl`); recovery partition moved to the end. Replace the base yourself after a smoke test. | `scripts/tart-resize-base.sh fb-26 fb-26-big 120` |
| `tart-upgrade-base.sh` | Upgrades a VM in place with Apple's full installer (`InstallAssistant.pkg`), for 15 and 26, which get no new IPSW. 20–40 minutes, no clicks. Needs a 120 GB disk; upgrade a copy, not the base. | `scripts/tart-upgrade-base.sh <vm> <pkg> <version>` |
| `tart-copy-vm.py` | Copies a VM folder to another volume and keeps `disk.img` sparse (only the data regions), at drive speed. Shut the VM down first; check with `shasum -a 256`. | `scripts/tart-copy-vm.py <from> <to>` |
| `tart-lib.sh` | Shared helpers (which Tart home a VM is on, its state, SSH config, waiting for the desktop and for a quiet system, proper shutdown), sourced by `tart-create-base.sh`, `vm-smoke.sh` and `vm-test-all.sh`. | not by hand |

Needs: Tart, the key `~/.ssh/fitsvm_ed25519`, the fitstester password in the Keychain (service
`fb-test-vm`), and for resizing Packer with its Tart plugin.

## Release (run by the GitHub Actions workflow)

Pushing a tag `v<version>` starts `.github/workflows/release.yml`. It archives, signs, notarises,
then calls these scripts in this order:

| Script | What it does |
|---|---|
| `make-dmg.sh` | The installer DMG: app next to an Applications link, background `resources/installer-background.png`, volume icon. Needs `create-dmg`. Also used by `build-release.sh`. |
| `release-notes.py` | The newest N entries of `CHANGELOG.md` as Markdown, for the GitHub release and Sparkle (workflow: N = 1). |
| `generate-appcast.py` | Adds the release to `site/appcast-beta.xml` (beta) or to both `appcast.xml` and `appcast-beta.xml` (stable, so beta users get it: issue #11), with the EdDSA signature and size. |
| `update-site.py` | Stable: changelog page, download link and version on the home page, empties the beta list. Beta: adds the entry on top of the beta page. |
| `deploy-site.py` | Uploads `site/` to the DirectAdmin hosting. The key (`DA_KEY`) exists only as a GitHub secret. Never deletes files on the server. |
| `_common.py` | `is_beta` and `changelog_entries`, shared by the three Python scripts above. |

`.github/workflows/site.yml` ("Deploy site", started by hand from the Actions tab) runs only
`deploy-site.py`, from `main`, for site changes without a release.

Keep CHANGELOG bullets flat: `update-site.py` doesn't handle nested bullets.

## Builds by hand

| Script | What it does | Usual command |
|---|---|---|
| `build-release.sh` | Archive, export, DMG on the Desktop (`FITS-Blaster-<version>.dmg`), optionally notarised and stapled. For a DMG you give someone personally; releases go through the workflow. Needs the Developer ID certificate and `create-dmg`. | `bash scripts/build-release.sh [--notarise]` |
| `make-dmg-background.swift` | Draws the DMG background (800 × 400 points, 2× Display P3, seeded star field). Writes `installer-background.png` in the current folder; the committed copy is `resources/installer-background.png`. Only needed to change the picture. | `cd resources && swift ../scripts/make-dmg-background.swift` |

## App Store

| Script | What it does | Usual command |
|---|---|---|
| `appstore-screenshots.sh` | Screenshots at an App Store size (2880 × 1800). Window mode sets the main window to 1440 × 900 points; `--fullscreen` captures the whole 16:10 screen. Enter = countdown and capture, with a beep afterwards. Numbers continue after the highest one in the folder and never overwrite. Use the App Store build (no Check for Updates). | `scripts/appstore-screenshots.sh --fullscreen` (`DELAY=15`, `BEEP=none`) |
| `appstore-flatten.swift` | Removes the alpha channel (App Store Connect can refuse it), optionally scales. Compiled and called by the screenshot script. | not by hand |

## Measuring and comparing

| Script | What it does | Usual command |
|---|---|---|
| `run-benchmark.sh` | Runs `BenchmarkTests` (Release with testability) on a colour and/or a mono folder and saves the throughput under `tests/benchmarks/`. | `scripts/run-benchmark.sh <version> --rgb <folder> --mono <folder>` |
| `compare.py` | Compares FITS Blaster's `frames.csv` with PixInsight's `SubframeSelector.csv` in one folder (Spearman rank per metric). Used for `FWHM-comparison.md`. | `python3 scripts/compare.py <folder>` |

The FAQ speed tables (2026-11-11) were measured with a separate script outside the repo
(cold cache through `purge`, app started through `open`), not with `run-benchmark.sh`.

## Statistics

| Script | What it does | Usual command |
|---|---|---|
| `download-stats.py` | DMG downloads per release from GitHub (new downloads and Sparkle updates together), minus test downloads: one per published-DMG smoke test folder, plus `--extra TAG=N`. Needs `gh`. App Store numbers are in App Store Connect. | `scripts/download-stats.py` (`--stable`, `--since <date>`) |
| `site-stats.py` | Reads the DirectAdmin access logs (in "/Volumes/FITS Blaster/Site logs"): daily update checks per version (active copies estimate), visitors, sample-set downloads. Prints counts only, never addresses. Own addresses to leave out: `~/.config/fits-blaster/site-stats-exclude.txt` (outside the repo). | `scripts/site-stats.py` (`--since`, `--exclude`) |

## Where the output goes

| Folder | From | In git |
|---|---|---|
| `tests/smoke-results/` | `vm-smoke.sh`, `vm-test-all.sh` | no |
| `tests/render-results/` | `run-render-tests.sh` | no |
| `tests/baseline-results/` | `metric-baselines.py` | no |
| `tests/baselines/` | `metric-baselines.py --update`, `baseline-data.py` (manifests) | yes |
| `tests/benchmarks/` | `run-benchmark.sh` | no (results `*.json` are ignored) |
| `build/` | `build-beta.sh`, `build-release.sh`, `metric-baselines.py` | no |
| `~/Pictures/FITS Blaster App Store/<date>/` | `appstore-screenshots.sh` | no |
