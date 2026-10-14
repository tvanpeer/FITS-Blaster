# Release Procedure

## Before tagging

Ask Claude to wrap up the session. Claude will:

1. Update `CHANGELOG.md` with a clean release entry.
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.pbxproj`.
3. Commit everything.

## Test before tagging

A pushed beta tag goes live to beta users straight away, so test first. See
[testing.md](testing.md) — including the manual checks, which are part of the
test.

- Run the unit tests (⌘U). All must pass.
- Run the rendering tests: `scripts/run-render-tests.sh` (add `--full` when
  the release touches loading, the stretch or colour), and look at the PNGs.
- Run the metric baselines: `scripts/metric-baselines.py`. Any failure blocks
  the release until it is explained (see testing.md).
- Build a beta Release and run the VM smoke test on a clean VM:
  `scripts/vm-smoke.sh <vm> "$(scripts/build-beta.sh)" --dev-build`,
  then do the manual checks in the VM window and look at the rendered PNGs in
  `tests/smoke-results/<run>/out/render/`. (Use the beta build for stable
  releases too: the app is the same apart from the test-only `--render`
  option, which the smoke test needs.)

## Publish

4. **Tag and push:**
   ```
   git tag v1.16 && git push --tags
   ```

   GitHub Actions then automatically:
   - Builds and signs the app
   - Creates the DMG
   - Submits to Apple for notarisation
   - Publishes a GitHub Release with the DMG attached
   - Updates `site/index.html` (download button) and `site/changelog.html`
   - Commits the site changes back to `main`

   Watch progress at: **github.com/tvanpeer/FITS-Blaster → Actions**

## After the workflow completes

5. **Pull the updated site files** (the workflow commits site changes back to `main`):
   ```
   git pull origin main
   ```

The workflow also deploys the updated site to astrophoto-app.com automatically — no manual upload needed.

6. **Smoke-test the published DMG** (this also checks notarisation):
   `scripts/vm-smoke.sh <vm> --tag <tag>`, on a clean VM, plus the manual
   checks in [testing.md](testing.md).

## Version naming

| Change type | Example |
|---|---|
| New feature | `v1.16` |
| Bug fix or performance | `v1.15.2` |

The tag name determines the DMG filename: `v1.16` → `FITS-Blaster-1.16.dmg`.
