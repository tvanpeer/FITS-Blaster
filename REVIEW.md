# Code Review

Review against guidelines in `~/.claude/CLAUDE.md`.

---

## Critical Issues

### 1. `@Observable` classes missing `@MainActor` (ImageStore.swift:12, 57)
Both `ImageEntry` and `ImageStore` are `@Observable` but neither is marked `@MainActor`. The guideline requires all `@Observable` classes to carry `@MainActor`. This also means mutations of `entry.displayImage`, `entry.isProcessing`, etc. from within `DispatchQueue.main.async` blocks are not compiler-enforced.

### 2. Old-style GCD concurrency (ImageStore.swift:207–260)
`processParallel` uses `DispatchQueue`, `DispatchSemaphore`, `DispatchGroup`, and `DispatchQueue.main.async`. The guideline explicitly bans `DispatchQueue.main.async` and GCD-style concurrency. The equivalent in modern Swift concurrency is a `TaskGroup` with `withTaskGroup(of:)` and an actor-isolated or `await MainActor.run { }` update, or a custom `AsyncChannel` / `withThrowingTaskGroup` pattern with `maxConcurrency` via a task-limiting actor.

---

## SwiftUI Violations

### 3. Computed properties used as subviews (ContentView.swift:65, 82, 110)
`thumbnailSidebar`, `toolbar`, and `mainContent` are `private var` computed properties on `ContentView`. The guideline requires these to be separate `View` structs instead.

### 4. `onTapGesture` used where `Button` should be (ContentView.swift:70)
```swift
.onTapGesture { store.selectedEntry = entry }
```
There's no need to know the tap location or count, so this should be a `Button`.

### 5. Hard-coded font sizes (ContentView.swift:155, 169, 307)
```swift
.font(.system(size: 36))   // error icon
.font(.system(size: 48))   // empty state icon
.font(.system(size: 10))   // thumbnail label
```
Dynamic Type sizes (e.g. `.caption`, `.body`, `.largeTitle`) should be used instead.

### 6. `clipShape(RoundedRectangle(...))` instead of `clipShape(.rect(cornerRadius:))` (ContentView.swift:289)
```swift
.clipShape(RoundedRectangle(cornerRadius: 4))
```
Should be:
```swift
.clipShape(.rect(cornerRadius: 4))
```

### 7. C-style string formatting (ContentView.swift:137)
```swift
Text(String(format: "%.2fs for %d images", elapsed, store.entries.count))
```
The guideline forbids `String(format:...)` for number display. Rewrite using format styles, for example by splitting into two `Text` views composed with string interpolation and `.formatted()`.

### 8. `GeometryReader` in scroll view (ContentView.swift:118–123)
```swift
GeometryReader { geometry in
    ScrollView([.horizontal, .vertical]) { … }
    .frame(width: geometry.size.width, height: geometry.size.height)
}
```
`GeometryReader` is used just to size the `ScrollView` to fill available space, which `.frame(maxWidth: .infinity, maxHeight: .infinity)` or `containerRelativeFrame` would achieve without it.

The `GeometryReader` in `RejectionOverlay` (ContentView.swift:325) for drawing a `Path` is harder to avoid and is more justified.

### 9. Hard-coded padding and spacing values
Multiple fixed values throughout ContentView: `spacing: 8`, `spacing: 12`, `spacing: 4`, `.padding(8)`, `.padding(.horizontal, 12)`, `.padding(.vertical, 6)` etc. The guideline says to avoid these unless requested.

---

## Foundation / Swift API Violations

### 10. `appendingPathComponent` instead of modern `appending` (ImageStore.swift:119–120)
```swift
parentDir.appendingPathComponent("REJECTED", isDirectory: true)
rejectedDir.appendingPathComponent(originalURL.lastPathComponent)
```
Modern equivalents:
```swift
parentDir.appending(path: "REJECTED", directoryHint: .isDirectory)
rejectedDir.appending(component: originalURL.lastPathComponent)
```

### 11. `FileManager.contentsOfDirectory(atPath: rejectedDir.path)` (ImageStore.swift:152)
Uses the `atPath: String` variant with the deprecated `.path` property. Prefer the URL-based `contentsOfDirectory(at:includingPropertiesForKeys:options:)`.

---

## Architecture Concern

### 12. File-panel logic in the View (ContentView.swift:184–266)
`openFolderPanel()` and `openFilesPanel()` live directly on `ContentView`. Per the guideline ("place view logic into view models or similar, so it can be tested"), this logic should move to `ImageStore` or a dedicated coordinator/view model — especially since it directly calls `store.openFiles(...)`.

---

## Summary Table

| # | File | Line(s) | Rule violated |
|---|------|---------|---------------|
| 1 | ImageStore.swift | 12, 57 | `@Observable` must be `@MainActor` |
| 2 | ImageStore.swift | 207–260 | No GCD / `DispatchQueue.main.async` |
| 3 | ContentView.swift | 65, 82, 110 | No computed-property subviews |
| 4 | ContentView.swift | 70 | Use `Button` not `onTapGesture` |
| 5 | ContentView.swift | 155, 169, 307 | No hard-coded font sizes |
| 6 | ContentView.swift | 289 | Use `clipShape(.rect(cornerRadius:))` |
| 7 | ContentView.swift | 137 | No C-style `String(format:)` |
| 8 | ContentView.swift | 118 | Avoid `GeometryReader` when alternatives exist |
| 9 | ContentView.swift | various | Avoid hard-coded padding/spacing |
| 10 | ImageStore.swift | 119–120 | Use `appending(path:)` / `appending(component:)` |
| 11 | ImageStore.swift | 152 | Use URL-based `contentsOfDirectory(at:)` |
| 12 | ContentView.swift | 184–266 | View logic belongs in view model |
