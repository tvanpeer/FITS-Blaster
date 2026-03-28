# Release Procedure

## Before tagging

1. **Write release notes** — add a single clean entry at the top of `CHANGELOG.md`:
   ```
   ## YYYY-MM-DD — Short title

   ### Fixed
   - Item

   ### Added
   - Item

   ---
   ```

2. **Bump the version** — in Xcode, update `MARKETING_VERSION` under the project's Build Settings.

3. **Commit** the changelog and any pending source changes.

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

5. **Pull the updated site files:**
   ```
   git pull origin main
   ```

6. **Upload `site/` to your hosting provider.**

## Version naming

| Change type | Example |
|---|---|
| New feature | `v1.16` |
| Bug fix or performance | `v1.15.2` |

The tag name determines the DMG filename: `v1.16` → `FITS-Blaster-1.16.dmg`.
