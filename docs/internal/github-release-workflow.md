# GitHub Release Workflow

The `release.yml` workflow automates building, signing, notarising, and publishing
a new DMG release. Once configured, releasing a new version is a single command:

```
git tag v1.16 && git push --tags
```

GitHub then does the rest.

---

## One-time setup

### 1. ExportOptions.plist

Xcode needs a file that describes how to package the app for distribution.
Generate it once by doing a manual export:

1. In Xcode: **Product → Archive**
2. In the Organiser window: **Distribute App**
3. Choose **Direct Distribution**
4. Step through the signing options
5. On the final screen, export the plist and save it to the repo root as `ExportOptions.plist`

This file is reused by the workflow on every release.

---

### 2. GitHub Actions secrets

GitHub's servers know nothing about you or your Apple account. Secrets are how
you pass that information securely — they are never visible in logs or code.

Set these at: **GitHub repo → Settings → Secrets and variables → Actions → New repository secret**

| Secret | What it is | Where to find it |
|---|---|---|
| `DEVELOPMENT_TEAM` | Your 10-character Apple Developer team ID, e.g. `AB12CD34EF` | developer.apple.com → Membership, or Xcode → project Signing settings |
| `CODE_SIGN_IDENTITY` | Your signing certificate name, e.g. `Developer ID Application: Your Name (AB12CD34EF)` | Keychain Access — search for "Developer ID" |
| `APPLE_ID` | Your Apple ID email address | The email you use at developer.apple.com |
| `APPLE_APP_PASSWORD` | An app-specific password (not your real Apple ID password) | appleid.apple.com → Sign-In and Security → App-Specific Passwords → Generate |

---

### 3. Code signing certificate (advanced)

GitHub's machines don't have your signing certificate installed. You need to
export it from your Mac and store it as an additional secret so the workflow
can install it before building.

Steps (do this when ready to wire up the full pipeline):

1. Open **Keychain Access** on your Mac
2. Find your **Developer ID Application** certificate (it will have a private key nested under it)
3. Right-click → **Export** — save as a `.p12` file and set a strong password
4. Base64-encode the file:
   ```
   base64 -i certificate.p12 | pbcopy
   ```
5. Add two more secrets to GitHub:
   - `CERTIFICATES_P12` — paste the base64 string
   - `CERTIFICATES_P12_PASSWORD` — the password you chose in step 3
6. Add a workflow step before the build step that installs the certificate:
   ```yaml
   - name: Install certificate
     env:
       CERTIFICATES_P12: ${{ secrets.CERTIFICATES_P12 }}
       CERTIFICATES_P12_PASSWORD: ${{ secrets.CERTIFICATES_P12_PASSWORD }}
     run: |
       echo "$CERTIFICATES_P12" | base64 --decode > certificate.p12
       security create-keychain -p "" build.keychain
       security import certificate.p12 -k build.keychain -P "$CERTIFICATES_P12_PASSWORD" -T /usr/bin/codesign
       security list-keychains -s build.keychain
       security default-keychain -s build.keychain
       security unlock-keychain -p "" build.keychain
       security set-key-partition-list -S apple-tool:,apple: -s -k "" build.keychain
   ```

---

## Release flow (once everything is configured)

```
git tag v1.16 && git push --tags
        ↓
GitHub Actions picks up the tag
        ↓
Checks out code on a macOS runner
        ↓
Installs your signing certificate
        ↓
Builds the app with xcodebuild
        ↓
Packages into a DMG
        ↓
Sends to Apple for notarisation (proves the app is safe to run)
        ↓
Apple stamps it, GitHub creates a Release, DMG is attached
        ↓
Users download from the GitHub Releases page
```

---

## Version tag convention

Tags should match the pattern `v<major>.<minor>` or `v<major>.<minor>.<patch>`:

```
v1.16       # minor release
v1.16.1     # patch / hotfix
```

The workflow strips the leading `v` when naming the DMG file,
so `v1.16` produces `FITS-Blaster-1.16.dmg`.
