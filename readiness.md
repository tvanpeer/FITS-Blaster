# App Store Readiness Checklist

**Model**: Freemium (free core, paid unlock via In-App Purchase)
**Languages**: English only at launch
**Status**: Work in progress — items marked [ ] are open, [x] are done.

---

## 1. Business & Legal

- [x] Enrol in the Apple Developer Program ($99/yr) at developer.apple.com
- [x] Decide on a legal entity — personal / sole trader; name "Tom van Peer" will appear as Seller
- [ ] Complete tax and banking setup in App Store Connect (required before IAP revenue can be received)
- [x] Choose a final app name — **FITS Blaster** (previous name "Claude FITS Viewer" contained Anthropic's registered trademark)
- [x] Write a Privacy Policy — drafted in `privacy-policy.md`; needs final app name, support URL, and a home on the website before submission
- [ ] Decide on support e-mail address — will create once domain is registered (section 8)

---

## 2. App Name & Branding

- [x] Choose final app name — **FITS Blaster**
- [x] Trademark search — USPTO (clear), EUIPO (clear), BOIP (clear)
- [ ] Design app icon — must be provided as a single 1024×1024 PNG (no alpha); Xcode generates all sub-sizes
- [x] Rename Xcode project / bundle ID — project is "FITS Blaster.xcodeproj", bundle ID is "com.astrophotoapp.FitsBlaster"
- [x] Update all in-app references to the app name — display name, product name, entitlements, Swift file headers, app struct
- [ ] Rename scheme from "Claude FITS Viewer" to "FITS Blaster" in Xcode (cosmetic, low priority)

---

## 3. Monetisation (Freemium / In-App Purchase)

- [ ] Decide which features are free and which require the paid unlock (examples: unlimited images free; metrics, colour rendering, export behind paywall — this needs an explicit decision)
- [ ] Decide IAP type: **one-time non-consumable** (simplest, recommended for a pro tool) vs subscription
- [ ] Implement StoreKit 2: fetch products, present paywall, process purchase, handle errors
- [ ] Implement **Restore Purchases** button (required by App Review)
- [ ] Implement **Family Sharing** for the IAP (opt-in, recommended)
- [ ] Add a paywall / upgrade prompt UI at appropriate points in the app
- [ ] Gate the paid features behind an entitlement check that survives app restarts
- [ ] Test purchase flow end-to-end in StoreKit sandbox and with TestFlight
- [ ] Set IAP price in App Store Connect (all regions)

---

## 4. App Store Connect Setup

- [ ] Create App ID / Bundle ID in the Apple Developer portal
- [ ] Create the app record in App Store Connect
- [ ] Set up Certificates, Identifiers & Profiles for distribution
- [ ] Declare export compliance (does the app use encryption? — HTTPS counts; answer "standard encryption" if so)
- [ ] Answer the App Store content rights questionnaire
- [ ] Complete age rating questionnaire (likely 4+)
- [ ] Set up banking and tax information to receive IAP revenue
- [ ] Create the IAP product in App Store Connect (product ID, price tier, display name, description)

---

## 5. Technical Requirements

- [ ] Add a **Privacy Manifest** (`PrivacyInfo.xcprivacy`) — required since 2024; declare all APIs used (e.g. UserDefaults = NSPrivacyAccessedAPICategoryUserDefaults) and confirm no data collection
- [ ] Audit entitlements: confirm `com.apple.security.files.user-selected.read-write` is correct; remove any unused entitlements
- [ ] Verify the app runs correctly on the **minimum supported OS** (macOS 15.0 — or decide whether to raise/lower this)
- [ ] Confirm the app is a **universal binary** (Apple Silicon + Intel) — check with `lipo -info` on the built binary
- [ ] Ensure there are no crashes on launch with an empty state (no images loaded)
- [ ] Ensure the app handles the case where the IAP cannot be fetched (no network, parental controls)
- [ ] Archive and validate with Xcode Organizer before first submission

---

## 6. Testing

- [ ] Set up **TestFlight** for macOS and invite at least a handful of external testers
- [ ] Manual test matrix: test on both Apple Silicon and Intel if possible; test on minimum and latest macOS
- [ ] Test with large image sets (200–600 frames) for memory and performance regressions
- [ ] Test **Accessibility**: VoiceOver labels on key controls, keyboard-only navigation
- [ ] Test all keyboard shortcuts on a non-UK keyboard layout (arrow keys, space, special chars)
- [ ] Test rejection / undo / move-to-rejected workflow thoroughly
- [ ] Test the subfolder scanning edge cases (deeply nested, excluded names, mixed content)
- [ ] Test IAP purchase, failure, and restore flows in sandbox

---

## 7. Help & Onboarding

- [ ] First-launch onboarding: at minimum a brief welcome screen explaining how to open a folder
- [ ] In-app help: populate the macOS Help menu (Help Book or redirect to web docs)
- [ ] Keyboard shortcut reference accessible from within the app (Settings already has this — verify it's complete)
- [ ] Empty-state guidance: when no images are loaded, show a clear call to action ("Open a folder…")
- [ ] Error messages: review all user-visible error strings for clarity

---

## 8. Website & Support

- [ ] Register a domain for the app
- [ ] Create a landing page (App Store requires a support URL and optionally a marketing URL)
- [ ] Add a **Support** page with contact e-mail and basic FAQ
- [ ] Add a **Privacy Policy** page (the URL must be submitted to App Store Connect)
- [ ] Optional: add a brief feature overview / screenshots for discoverability

---

## 9. App Store Listing

- [ ] Write **app description** (up to 4000 characters) — lead with the key value proposition
- [ ] Write **promotional text** (up to 170 characters, can be updated without a new submission)
- [ ] Choose **keywords** (100 characters total; think: FITS viewer, astrophotography, image quality, FWHM, culling)
- [ ] Choose **primary and secondary categories** (Photo & Video is the obvious primary)
- [ ] Capture **macOS screenshots** at required resolutions (at least one set for 1280×800 or 1440×900)
- [ ] Optional: record a short **app preview video**
- [ ] Fill in the **support URL** and optionally marketing URL

---

## 10. Post-Launch

- [ ] Integrate **MetricKit** for crash and hang reporting (Apple-native, no third-party SDK needed, privacy-preserving)
- [ ] Monitor App Store Connect for user reviews and respond promptly
- [ ] Set up a process for bug reports (support e-mail → GitHub issue or similar)
- [ ] Plan first update cycle: what goes in v2.0? (localisation, additional metrics, etc.)

---

## Open Decisions (need answers before work can start)

| Decision | Notes |
|----------|-------|
| Final app name | Must not infringe trademarks; must clear App Store search |
| Free vs paid feature split | Drives entire StoreKit implementation |
| IAP type: one-time vs subscription | One-time is simpler and better received for pro tools |
| Minimum macOS version | Currently targeting 15.0 — confirm or adjust |
| Support domain / website | Needed before submitting to App Store |

---

*Last updated: 2026-03-10*
