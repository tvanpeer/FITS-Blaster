# FITS Blaster — SwiftUI Pro Review

Reviewed against the SwiftUI Pro skill references: API, Views, Data, Navigation, Design, Accessibility, Performance, Swift, and Hygiene.

---

## ContentView.swift

**Line 53–56: `Binding(get:set:)` in view body — use `@State` or a dedicated optional binding instead.**

The error alert uses a manual `Binding(get:set:)` in `body`. This is fragile and re-creates the binding on every render. Since `store.errorMessage` is an optional `String`, prefer `sheet(item:)` style or hoist the bool to a stored property.

```swift
// Before
.alert("Error", isPresented: Binding(
    get: { store.errorMessage != nil },
    set: { if !$0 { store.errorMessage = nil } }
)) {
    Button("OK") { store.errorMessage = nil }
} message: {
    Text(store.errorMessage ?? "")
}

// After — derive a @State bool or use an Identifiable wrapper
// Simplest fix: the OK button does nothing but dismiss, so omit it entirely
.alert("Error", isPresented: Binding(
    get: { store.errorMessage != nil },
    set: { if !$0 { store.errorMessage = nil } }
)) {
    // Default OK button is provided automatically when no actions are specified
} message: {
    Text(store.errorMessage ?? "")
}
```

Note: the `Binding(get:set:)` pattern is unavoidable here due to the optional-to-bool conversion. However the explicit `Button("OK")` that only dismisses is redundant — SwiftUI adds a default OK button when no actions are supplied.

**Lines 65, 77, 93, 108: View body broken into computed properties returning `some View`.**

`contentWithFocus`, `contentWithSelectionFocus`, `splitContentWithAppFocus`, and `splitContent` are all computed properties used to decompose the view body. The reference guidance is to extract these into separate `View` structs instead.

That said, these properties exist purely to chain `.focusedSceneValue()` modifiers and don't contain meaningful independent layout logic. The refactor would require passing many bindings and closures and would add significant boilerplate for minimal gain. This is a judgement call — flagging it for awareness but not a high-priority fix.

**Lines 95–102: More `Binding(get:set:)` in body.**

The `simpleModeBinding` and `debayerColorBinding` focused values use inline `Binding(get:set:)`. These exist specifically to pass a `Binding<Bool>` through the focused-value system, which is one of the few legitimate uses. No change needed.

**Line 343: `RoundedRectangle(cornerRadius: 8)` — prefer static member lookup.**

```swift
// Before
RoundedRectangle(cornerRadius: 8)
    .stroke(.blue, lineWidth: 4)

// After
RoundedRectangle(cornerRadius: 8)  // No .rect equivalent for standalone shape usage — this is fine
```

Actually, `.rect(cornerRadius:)` is for `.clipShape()` — standalone `RoundedRectangle` usage is correct here. No change needed.

---

## MainContentViews.swift

**Line 29: `.fill(Color.secondary.opacity(0.15))` — prefer hierarchical style.**

```swift
// Before
.fill(Color.secondary.opacity(0.15))

// After
.fill(.quinary)
```

Using `.quinary` (or `.quaternary`) is more semantically correct and adapts to light/dark mode better than a manual opacity on `.secondary`.

**Line 147: Empty-string button label `""` — bad for VoiceOver.**

```swift
// Before
Button("", systemImage: "sidebar.right") {
    settings.showInspector.toggle()
}

// After
Button(settings.showInspector ? "Hide Inspector" : "Show Inspector",
       systemImage: "sidebar.right") {
    settings.showInspector.toggle()
}
.labelStyle(.iconOnly)
```

An empty string label means VoiceOver reads nothing for this button. Provide a meaningful label and use `.labelStyle(.iconOnly)` to hide it visually.

**Line 240: Empty-string button label `""` — bad for VoiceOver.**

```swift
// Before
Button("", systemImage: settings.chartUseBars ? "chart.bar.fill" : "circle.grid.3x3.fill") {
    settings.chartUseBars.toggle()
}

// After
Button(settings.chartUseBars ? "Switch to dots" : "Switch to bars",
       systemImage: settings.chartUseBars ? "chart.bar.fill" : "circle.grid.3x3.fill") {
    settings.chartUseBars.toggle()
}
.labelStyle(.iconOnly)
```

Same issue — provide an accessible label.

**Line 306: `store.entries.filter { !$0.isProcessing }.count` — use `count(where:)`.**

```swift
// Before
loadedCount  = store.entries.filter { !$0.isProcessing }.count
metricsCount = store.entries.filter {  $0.metrics != nil }.count

// After
loadedCount  = store.entries.count { !$0.isProcessing }
metricsCount = store.entries.count { $0.metrics != nil }
```

`count(where:)` avoids creating intermediate arrays.

**Line 352: `Text("\\(i)").font(.system(size: 9))` in chart axis — hardcoded font size.**

```swift
// SessionChartView.swift lines 352, 362
.font(.system(size: 9))
```

These hardcoded chart axis font sizes don't respect the app's Dynamic Type scaling. Consider using `.scaledFont(size: 9)` for consistency, though Swift Charts axis labels don't support custom view modifiers easily — this is a known limitation of the Charts API and is acceptable as-is.

---

## SidebarViews.swift

**Lines 261–265, 267–271: Computed properties `medianFWHM` and `medianScore` in `FilterGroupHeader` re-sort on every render.**

```swift
// Before (computed in the view body path)
private var medianFWHM: Float? {
    let values = entries.compactMap { $0.metrics?.fwhm }.sorted()
    ...
}
```

These O(n log n) sorts run every time the view is evaluated. Since `entries` is passed from the parent, consider computing these values once upstream (in `ImageStore.groupStatistics`) and passing them as simple properties. The existing `GroupStats` already has `medianFWHM` — wire it through instead of recomputing.

**Line 312: `Image(systemName: "chevron.right")` without text label in a Button.**

The `FolderSectionHeader` button uses images without accessible text. However, the button does contain a `Text(folderGroup.folderDisplayName)` alongside it, so VoiceOver can read the folder name. The chevron and folder images are decorative and could benefit from `.accessibilityHidden(true)`:

```swift
Image(systemName: "chevron.right")
    .scaledFont(size: 9)
    .foregroundStyle(.secondary)
    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
    .animation(.easeInOut(duration: 0.15), value: isCollapsed)
    .accessibilityHidden(true)
Image(systemName: "folder")
    .scaledFont(size: 10)
    .foregroundStyle(.secondary)
    .accessibilityHidden(true)
```

**Lines 509, 529: `GeometryReader` usage in `ViewportBox` and `RejectionOverlay`.**

Both use `GeometryReader` to draw proportional overlays on thumbnails. There is no modern alternative for this specific use case (drawing at fractional positions within a parent's coordinate space). `GeometryReader` is acceptable here.

---

## SessionChartView.swift

**Line 374: `onTapGesture` used on a Rectangle — should have accessibility trait.**

```swift
// Before
.onTapGesture { location in
    handleTap(at: location, proxy: proxy, geo: geo)
}

// After
.onTapGesture { location in
    handleTap(at: location, proxy: proxy, geo: geo)
}
.accessibilityAddTraits(.isButton)
```

Since this uses `onTapGesture` (which is justified here because the tap location is needed), it should declare `.isButton` for VoiceOver.

**Lines 122–130: `chartEntries` computed property runs O(n) filter on every body evaluation.**

This property is read in `body` and also from `chartPoints` and `groupMedians` — meaning it may execute multiple times per render. Consider caching with `@State` and updating via `onChange`, or at minimum ensure the compiler can optimize the multiple reads.

---

## SettingsView.swift

**Line 17: `tabItem()` used instead of `Tab` API.**

```swift
// Before
TabView {
    UISettingsTab()
        .tabItem { Label("Interface", systemImage: "keyboard") }
    ImageDisplayTab()
        .tabItem { Label("Display", systemImage: "photo") }
    FilesAndFoldersTab()
        .tabItem { Label("Files & Folders", systemImage: "folder") }
}

// After
TabView {
    Tab("Interface", systemImage: "keyboard") {
        UISettingsTab()
    }
    Tab("Display", systemImage: "photo") {
        ImageDisplayTab()
    }
    Tab("Files & Folders", systemImage: "folder") {
        FilesAndFoldersTab()
    }
}
```

The `tabItem()` modifier is deprecated. Use the `Tab` view API instead.

---

## FitsBlasterApp.swift

**Line 15: `AppDelegate` class is not marked `@MainActor`.**

`AppDelegate` accesses `pendingURLs` (mutable state) and `openURLsHandler`. The `application(_:open:)` callback runs on the main thread, but this should be explicitly annotated for strict concurrency:

```swift
// Before
final class AppDelegate: NSObject, NSApplicationDelegate {

// After
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
```

**Lines 84, 90, 91: Multiple type definitions in a single file.**

`FitsBlasterApp.swift` contains `FitsBlasterApp`, `AppDelegate`, `MainWindowCommand`, `CloseWindowCommand`, `SettingsMenuCommand`, `DebayerColourCommand`, `OpenFolderCommand`, `SelectAllCommand`, `DeselectAllCommand`, `InvertSelectionCommand`, `SelectAllRejectedCommand`, `ToggleFlagCommand`, `DeflagAllCommand`, `CheckForUpdatesView`, and `SimpleModeCommand`.

The reference guidance is to place each type in its own file. The menu command structs are small and tightly coupled to the app definition, so this is a judgement call. Consider grouping the menu commands into a separate `MenuCommands.swift` file at minimum.

---

## ImageStore.swift

**Lines 17, 29: Multiple type definitions (`ThumbnailSortOrder`, `ExportFormat`, `FolderGroup`, `ImageEntry`, `ImageStore`) in a single file.**

`ThumbnailSortOrder`, `ExportFormat`, and `FolderGroup` are defined alongside `ImageEntry` and `ImageStore`. These supporting types should each be in their own file per the project style guide.

---

## AppSettings.swift

**Lines 401–413: `AppearanceMode` enum defined in the same file as `AppSettings`.**

Should be in its own file per the project conventions about one type per file.

---

## AutoRejectSheet.swift

**Lines 187–190, 233–235: `Binding(get:set:)` in view body for Int-to-Double slider conversion.**

```swift
// Before
Slider(value: Binding(
    get: { Double(config.absoluteStarCountFloor) },
    set: { config.absoluteStarCountFloor = Int($0) }
), in: 5...100, step: 5)

// After — use onChange to avoid inline binding
// This is a known limitation with Slider and integer values.
// The Binding(get:set:) pattern is the pragmatic solution here.
```

This is one of the few cases where `Binding(get:set:)` is acceptable — there's no clean alternative for bridging `Int` to `Slider`'s `Double` requirement.

---

## ExportPanel.swift

**Line 18: `store.entries.filter { !$0.isRejected }.count` — use `count(where:)`.**

```swift
// Before
private var keptCount: Int {
    store.entries.filter { !$0.isRejected }.count
}

// After
private var keptCount: Int {
    store.entries.count { !$0.isRejected }
}
```

---

## FrameMetrics.swift

**Lines 29–34: `BayerPattern.rOffset` uses explicit `return` for single expressions.**

```swift
// Before
var rOffset: UInt32 {
    switch self {
    case .rggb: return 0
    case .grbg: return 1
    case .gbrg: return 2
    case .bggr: return 3
    }
}

// After
var rOffset: UInt32 {
    switch self {
    case .rggb: 0
    case .grbg: 1
    case .gbrg: 2
    case .bggr: 3
    }
}
```

This is in `BayerPattern.swift` line 29. Modern Swift allows omitting `return` in single-expression switch cases. The same pattern exists throughout `FrameMetrics.swift` (e.g. `badgeColor` at line 156) where explicit `return` is used unnecessarily.

---

## General Observations (No File-Specific Issues)

### What the project does well

- **`@Observable` + `@MainActor`**: Both `ImageStore` and `AppSettings` correctly use the modern observation pattern with main-actor isolation.
- **`@Entry` macro**: `FocusedValues` and `EnvironmentValues` extensions use the modern `@Entry` macro rather than the legacy `EnvironmentKey` pattern.
- **`foregroundStyle()` everywhere**: No instances of the deprecated `foregroundColor()`.
- **`clipShape(.rect(cornerRadius:))`**: Used consistently; no instances of `.cornerRadius()`.
- **`onChange` two-parameter form**: All `onChange` modifiers use the `{ _, new in }` or `{ _, _ in }` form. No single-parameter variants.
- **No `ObservableObject`/`@Published`/`@StateObject`**: Fully migrated to `@Observable`.
- **No `NavigationView`**: The app uses `HSplitView` directly rather than navigation, which is appropriate for its single-window macOS layout.
- **`scrollIndicators(.hidden)`**: Used correctly instead of `showsIndicators: false`.
- **No `AnyView`**: None found anywhere in the codebase.
- **Modern formatting**: Uses `FormatStyle` APIs (`.number.precision(.fractionLength(...))`, `.percent`) consistently. No `String(format:)` C-style formatting.
- **`localizedStandardCompare`/`localizedStandardContains`**: Used for user-facing text comparisons.
- **No GCD**: All concurrency uses `async`/`await` and `Task`. No `DispatchQueue` usage.
- **`Task.sleep(for:)`**: Used consistently instead of the nanoseconds variant.
- **Well-structured caching**: `groupStatistics`, `cachedSortedEntries`, `visibilityFilteredEntries` are stored properties updated at batch boundaries — excellent for performance.
- **LazyVStack in sidebar**: The thumbnail list uses `LazyVStack` correctly for the large dataset.

---

## Summary — Prioritised by Impact

| # | Category | Severity | File | Description |
|---|----------|----------|------|-------------|
| 1 | **Accessibility** | High | MainContentViews.swift:147 | Inspector toggle button has empty `""` label — invisible to VoiceOver |
| 2 | **Accessibility** | High | SessionChartView.swift:240 | Chart style toggle button has empty `""` label — invisible to VoiceOver |
| 3 | **Accessibility** | Medium | SessionChartView.swift:374 | `onTapGesture` on chart overlay missing `.accessibilityAddTraits(.isButton)` |
| 4 | **Deprecated API** | Medium | SettingsView.swift:17 | Uses `.tabItem()` instead of the `Tab` API |
| 5 | **Performance** | Medium | SidebarViews.swift:261 | `FilterGroupHeader` recomputes O(n log n) median on every render — use cached `GroupStats` |
| 6 | **Swift** | Medium | ExportPanel.swift:18, MainContentViews.swift:306 | `.filter { }.count` should be `.count(where:)` |
| 7 | **Concurrency** | Medium | FitsBlasterApp.swift:15 | `AppDelegate` should be `@MainActor` for strict concurrency |
| 8 | **Design** | Low | MainContentViews.swift:29 | `Color.secondary.opacity(0.15)` — prefer `.quinary` semantic style |
| 9 | **Swift** | Low | BayerPattern.swift:29, FrameMetrics.swift:156 | Unnecessary explicit `return` in single-expression switch cases |
| 10 | **Hygiene** | Low | FitsBlasterApp.swift, ImageStore.swift | Multiple type definitions per file — consider splitting menu commands and supporting enums |
