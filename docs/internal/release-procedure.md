# Release Procedure

## Before tagging

Ask Claude to wrap up the session. Claude will:

1. Update `CHANGELOG.md` with a clean release entry.
2. Bump `MARKETING_VERSION` (and `CURRENT_PROJECT_VERSION`) in `project.pbxproj`.
3. Commit everything.

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
