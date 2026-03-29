# Issues 1.15.1 — Analysis & Proposed Fixes

Evaluated against the current codebase. Each issue is confirmed (or flagged for verification), categorised by effort, and given a concrete fix proposal.

---

## Issue 1 — After Reset, switch back to 'All' frames

**Status:** Confirmed bug.

`reset()` in `ImageStore.swift` clears entries, selection, and filter group, but never resets `rejectionVisibility`. If the user is in "Selected" or "Rejected" mode when they reset, the picker stays there and the empty list confuses things.

**Fix:** One line added to `reset()`:

```swift
func reset() {
    entries = []
    rejectionVisibility = .all   // ← add this
    selectedEntry = nil
    // … rest unchanged
}
```

**Effort:** Trivial.

---

## Issue 2 — Cmd+A should work in Selected mode

**Status:** Confirmed bug.

The key monitor calls `store.selectAllVisible()` for Cmd+A regardless of mode. `selectAllVisible()` uses `visibilityFilteredEntries`, which in Selected mode only contains flagged entries — so it should work. However, in Selected mode a plain Cmd+click *unflags* entries instead of toggling the multi-selection. This means after Cmd+A selects all, a Cmd+click unexpectedly unflags them. The user's expectation is that Cmd+A highlights all visible thumbnails just as it does in All/Rejected mode.

**Fix:** Guard the unflag-on-cmd-click behaviour so it only triggers when the user Cmd+clicks a *single* entry, not after a Cmd+A multi-select. Alternatively, make Cmd+click in Selected mode toggle the multi-selection as in All mode, and use a separate gesture for unflagging (e.g. the Reject key).

The simplest targeted fix — check `selectedEntryIDs.isEmpty` before switching to unflag behaviour:

```swift
// In thumbnailButton(for:), replace the .selected branch:
if store.rejectionVisibility == .selected {
    // Only unflag on a deliberate single cmd+click, not after a Cmd+A select-all.
    if store.selectedEntryIDs.isEmpty || store.selectedEntryIDs == [entry.id] {
        store.unflagEntries([entry.id])
        // … existing navigation logic
    } else {
        // Fall through to normal cmd+click toggle behaviour.
        // … same as the else branch below
    }
}
```

**Effort:** Small.

---

## Issue 3 — Cmd+… shortcut to select all rejected images

**Status:** Not yet implemented.

No existing shortcut selects all rejected frames. `r` alone is the reject key; `Cmd+R` is free, so that is the default. Needs:
1. A new key binding pair in `AppSettings` (key + shift flag, defaulting to Cmd+R).
2. A new `selectAllRejected()` method in `ImageStore` that sets `selectedEntryIDs` to all entries where `isRejected == true`.
3. A new case in the key monitor in `ContentView`.
4. A row in Settings → Keys so the user can reconfigure it.

```swift
// ImageStore
func selectAllRejected() {
    let rejected = entries.filter { $0.isRejected }
    guard !rejected.isEmpty else { return }
    selectedEntryIDs = Set(rejected.map { $0.id })
    selectedEntry = rejected.first
}
```

**Effort:** Small–Medium (4 touch points, all mechanical).

---

## Issue 4 — Add sort by 'Rejected' to the thumbnail sort picker

**Status:** Confirmed gap.

`ThumbnailSortOrder` has six cases (Name, Score, FWHM, Eccentricity, SNR, Stars). A `rejected` case is missing.

**Fix:**

```swift
// ImageStore.swift
enum ThumbnailSortOrder: String, CaseIterable {
    // … existing cases …
    case rejected = "Rejected"
}

// In the sort switch, add:
case .rejected:
    return lhs.isRejected && !rhs.isRejected ? 1
         : !lhs.isRejected && rhs.isRejected ? -1
         : lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending ? -1 : 1
```

(Rejected entries sort to the bottom; within each group, alphabetical by filename.)

**Effort:** Small.

---

## Issue 5 — On folder open, option to include REJECTED directory

**Status:** Confirmed gap. Skipping REJECTED on open remains the default behaviour; a checkbox in the open-folder dialog lets the user override it per-open without touching Settings.

`collectFITSURLs` unconditionally skips any directory named REJECTED. The new behaviour: add a checkbox to the `NSOpenPanel` accessory view ("Include REJECTED folder"). When checked, scan the REJECTED directory and pre-mark those entries as rejected. The checkbox state is **not** written back to `AppSettings`. Instead, a small helper label below the checkbox reads: *"To change the default, go to Settings → Files & Folders."*

**Fix outline:**
1. Add a second checkbox (and the helper label) to the `NSOpenPanel` accessory view in `openFolderPanel`, defaulting to unchecked.
2. In `collectFITSURLs`, when `includeRejected` is true, scan the REJECTED directory and tag collected URLs with a `wasInRejected: Bool` flag.
3. After loading, mark those entries' `isRejected = true` and add their IDs to `rejectedEntryIDs`.
4. Add `var includeRejectedFolder: Bool` to `AppSettings` and a toggle in Settings → Files & Folders so the user can make it the default without using the dialog.

**Effort:** Medium. Most complexity is in the `collectFITSURLs` signature change and propagating the rejected flag through the load pipeline.

---

## Issue 6 — Subfolder scanning checkbox in dialog should update Settings

**Status:** Intentional omission — the checkbox state is not written back to Settings by design, and this remains correct. The dialog checkbox is a per-open override only.

**Fix:** When the user dismisses the panel with a checkbox state that differs from `settings.includeSubfolders`, show a brief macOS notification (or a non-blocking banner within the app) saying: *"To make this the default, change it permanently in Settings → Files & Folders."*

This can be a one-time nudge: only fire it when the chosen state differs from the stored default, so users who always use the default are never interrupted.

**Effort:** Small (observe checkbox state at panel close, compare to settings, post notification if different).

---

## Issue 7 — Colour/Grey button should use icons not text

**Status:** Confirmed. The toolbar button (line 694 in `ContentView.swift`) is plain text.

The user's intent: three overlapping colour circles for Colour, two greyscale circles for Grey.

Use `camera.filters` for both states, differentiated by fill and foreground style:
- Colour mode: `camera.filters` rendered with a multicolour tint (`.foregroundStyle(.red, .green, .blue)` or `.symbolRenderingMode(.multicolor)`)
- Grey mode: `camera.filters` rendered in the standard monochrome label colour

**Fix:**

```swift
Button {
    settings.debayerColorImages.toggle()
} label: {
    Label(
        settings.debayerColorImages ? "Colour" : "Grey",
        systemImage: "camera.filters"
    )
    .labelStyle(.iconOnly)
    .symbolRenderingMode(settings.debayerColorImages ? .multicolor : .monochrome)
}
.help(settings.debayerColorImages ? "Switch to greyscale" : "Switch to colour")
```

**Effort:** Small.

---

## Issue 8 — Add Ko-fi link in 'About FITS Blaster'

**Status:** Not yet implemented. macOS shows a standard About panel automatically; there is no custom About window in the app.

The standard panel can be customised by passing `NSAboutPanelOptionKey.credits` with an `NSAttributedString`. The cleanest approach that avoids a full custom window:

```swift
// In FitsBlasterApp.swift, add a custom About menu command:
CommandGroup(replacing: .appInfo) {
    Button("About FITS Blaster") {
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(
                string: "If FITS Blaster saves you time, please consider supporting development on Ko-fi.\nko-fi.com/tomvp",
                attributes: [
                    .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                    .foregroundColor: NSColor.secondaryLabelColor
                ]
            )
        ])
    }
}
```

A clickable hyperlink requires an `NSAttributedString` with `.link` attribute, which the standard About panel does render as a tappable link.

**Effort:** Small.

---

## Issue 9 — Multi-selected thumbnails: all dots should enlarge in session chart

**Status:** Confirmed bug.

`SessionChartView.swift` line 300:

```swift
.symbolSize(store.selectedEntry === item.entry ? 90 : 28)
```

Only the primary `selectedEntry` dot is enlarged. `selectedEntryIDs` (the multi-selection set) is ignored.

**Fix:** One line change:

```swift
.symbolSize(
    (store.selectedEntry === item.entry || store.selectedEntryIDs.contains(item.entry.id))
    ? 90 : 28
)
```

**Effort:** Trivial.

---

## Issue 10 — Shift+click doesn't multi-select on first open

**Status:** Confirmed bug.

The shift+click handler in `thumbnailButton(for:)` requires `lastClickedID` to be non-nil (line 489: `if mods.contains(.shift), let lastID = lastClickedID`). On first load the initial entry is auto-selected but `lastClickedID` is never set, so the `let lastID =` binding fails and the shift+click is silently ignored.

**Fix:** Fall back to `selectedEntry?.id` when `lastClickedID` is nil:

```swift
} else if mods.contains(.shift), let lastID = lastClickedID ?? store.selectedEntry?.id {
    // … rest of shift+click logic unchanged
```

**Effort:** Trivial.

---

## Issue 11 — Move Score.md to public docs, verify accuracy, add as web page

**Status:** Docs + web task. Requires checking Score.md content against current code before publishing.

**Steps:**
1. Read `docs/internal/Score.md` and verify the scoring formula against `MetricsCalculator.swift`.
2. Move to `docs/public/Score.md`.
3. Add `site/score.html` styled like `faq.html`.
4. Link from `site/index.html` and the footer of other pages.

**Effort:** Medium (mostly writing/verification, not code).

---

## Issue 12 — Update release-procedure.md

**Status:** Minor update needed. The current document is mostly correct but predates the fully automated pipeline. The "Deploy site to hosting" step is now also automatic, so the manual upload step can be removed.

**Effort:** Trivial.

---

## Issue 13 — Move RAW-support.md to internal

**Status:** Simple file move. We moved it to `docs/public/` earlier in this session — the user now wants it back in `docs/internal/`.

**Effort:** Trivial.

---

## Summary

| # | Issue | Effort | Type |
|---|---|---|---|
| 1 | Reset → 'All' | Trivial | Bug |
| 2 | Cmd+A in Selected mode | Small | Bug |
| 3 | Select all rejected shortcut | Small–Medium | Feature |
| 4 | Sort by Rejected | Small | Feature |
| 5 | Include REJECTED folder on open | Medium | Feature |
| 6 | Subfolder checkbox → notify user | Small | UX |
| 7 | Colour/Grey icon button | Small | UI |
| 8 | Ko-fi in About | Small | Feature |
| 9 | Multi-select dots in chart | Trivial | Bug |
| 10 | Shift+click at first open | Trivial | Bug |
| 11 | Score.md → public + web page | Medium | Docs |
| 12 | Update release-procedure.md | Trivial | Docs |
| 13 | Move RAW-support.md to internal | Trivial | Docs |
