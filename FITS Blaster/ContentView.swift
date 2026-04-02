//
//  ContentView.swift
//  FITS Blaster
//
//  Root view: HSplitView layout, key monitoring, drag-drop, and window management.
//  Sidebar views live in SidebarViews.swift; main-area views in MainContentViews.swift.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var hostingWindow: NSWindow?
    @State private var isDragTarget = false
    @State private var keyMonitor: Any?

    var body: some View {
        contentWithFocus
            .onChange(of: settings.metricsConfig) { _, newConfig in
                guard !settings.isSimpleMode else { return }
                store.recomputeMetrics(metricsConfig: newConfig)
            }
            .onChange(of: settings.debayerColorImages) { _, _ in
                guard !store.entries.isEmpty else { return }
                store.recolorImages(settings: settings)
            }
            .onChange(of: settings.isSimpleMode) { _, isSimple in
                if !isSimple {
                    store.recomputeMetrics(metricsConfig: settings.metricsConfig)
                }
                guard let window = hostingWindow else { return }
                var frame = window.frame
                if isSimple {
                    if settings.showInspector { frame.size.width -= 260 }
                    frame.size.width = max(frame.size.width, 500)
                } else {
                    if settings.showInspector { frame.size.width += 260 }
                    frame.size.width = max(frame.size.width, settings.showInspector ? 960 : 700)
                }
                window.setFrame(frame, display: true, animate: true)
            }
            .onChange(of: settings.showInspector) { _, shown in
                guard !settings.isSimpleMode, let window = hostingWindow else { return }
                let delta: CGFloat = 260
                var frame = window.frame
                frame.size.width += shown ? delta : -delta
                frame.size.width = max(frame.size.width, shown ? 960 : 700)
                window.setFrame(frame, display: true, animate: true)
            }
            .alert("Error", isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } }
            )) {
                Button("OK") { store.errorMessage = nil }
            } message: {
                Text(store.errorMessage ?? "")
            }
            .onAppear { installKeyMonitor() }
            .onDisappear { removeKeyMonitor() }
    }

    private var contentWithFocus: some View {
        contentWithSelectionFocus
            .focusedSceneValue(\.selectAllShiftFV,           settings.selectAllShift)
            .focusedSceneValue(\.deselectAllShiftFV,         settings.deselectAllShift)
            .focusedSceneValue(\.invertSelectionShiftFV,     settings.invertSelectionShift)
            .focusedSceneValue(\.selectAllRejectedShiftFV,   settings.selectAllRejectedShift)
            .frame(minWidth: minWindowWidth, minHeight: 400)
            .environment(\.fontSizeMultiplier, settings.fontSizeMultiplier)
            .preferredColorScheme(settings.preferredColorScheme)
            .background(WindowAccessor { hostingWindow = $0 })
    }

    private var contentWithSelectionFocus: some View {
        splitContentWithAppFocus
            .focusedSceneValue(\.selectAllAction)          { store.selectAllVisible() }
            .focusedSceneValue(\.deselectAllAction)        { store.deselectAll() }
            .focusedSceneValue(\.invertSelectionAction)    { store.invertSelection() }
            .focusedSceneValue(\.selectAllRejectedAction)  { store.selectAllRejected() }
            .focusedSceneValue(\.toggleFlagAction)         { store.toggleFlagSelected() }
            .focusedSceneValue(\.deflagAllAction)          { store.deflagAll() }
            .focusedSceneValue(\.flagKeyString,              settings.flagKey)
            .focusedSceneValue(\.deflagAllKeyString,         settings.deflagAllKey)
            .focusedSceneValue(\.selectAllKeyString,         settings.selectAllKey)
            .focusedSceneValue(\.deselectAllKeyString,       settings.deselectAllKey)
            .focusedSceneValue(\.invertSelectionKeyString,   settings.invertSelectionKey)
            .focusedSceneValue(\.selectAllRejectedKeyString, settings.selectAllRejectedKey)
    }

    private var splitContentWithAppFocus: some View {
        splitContent
            .focusedSceneValue(\.simpleModeBinding, Binding(
                get: { settings.isSimpleMode },
                set: { settings.isSimpleMode = $0 }
            ))
            .focusedSceneValue(\.debayerColorBinding, Binding(
                get: { settings.debayerColorImages },
                set: { settings.debayerColorImages = $0 }
            ))
            .focusedSceneValue(\.toggleModeKeyString, settings.toggleModeKey)
            .focusedSceneValue(\.debayerKeyString, settings.debayerKey)
            .focusedSceneValue(\.openFolderAction) { store.openFolderPanel(settings: settings) }
    }

    private var splitContent: some View {
        HSplitView {
            ThumbnailSidebar()
                .frame(minWidth: 140, idealWidth: 165, maxWidth: 220)

            VStack(spacing: 0) {
                FITSToolbar(store: store)
                Divider()
                if settings.isSimpleMode {
                    MainContent(store: store)
                } else {
                    ResizableChartLayout()
                }
            }
            .frame(minWidth: settings.isSimpleMode ? 380 : 400)

            if settings.showInspector && !settings.isSimpleMode {
                InspectorView()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            }
        }
        .overlay { if isDragTarget { DropTargetOverlay() } }
        .onDrop(of: [.fileURL], isTargeted: $isDragTarget) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var minWindowWidth: CGFloat {
        if settings.isSimpleMode { return 500 }
        return settings.showInspector ? 960 : 700
    }

    // MARK: - Key dispatch tables

    /// Every configurable action the key monitor can trigger.
    private enum NavAction {
        case selectAll, deselectAll, invertSelection, selectAllRejected
        case first, last, previous, next
        case reject, undo
        case flag, deflagAll
        case toggleMode, remove, debayer
    }

    /// ⌘(⇧)+key bindings: KeyPath to the key string, KeyPath to the shift flag, action.
    /// Adding a new ⌘ shortcut is a single line here — no edits to installKeyMonitor.
    private static let cmdKeyBindings:
        [(key: KeyPath<AppSettings, String>, shift: KeyPath<AppSettings, Bool>, action: NavAction)] = [
        (\.selectAllKey,         \.selectAllShift,         .selectAll),
        (\.deselectAllKey,       \.deselectAllShift,       .deselectAll),
        (\.invertSelectionKey,   \.invertSelectionShift,   .invertSelection),
        (\.selectAllRejectedKey, \.selectAllRejectedShift, .selectAllRejected),
    ]

    /// Plain-key bindings (no modifier): KeyPath to the key string, action.
    /// Adding a new navigation shortcut is a single line here — no edits to handleKey.
    private static let plainKeyBindings:
        [(key: KeyPath<AppSettings, String>, action: NavAction)] = [
        (\.firstImageKey,  .first),
        (\.lastImageKey,   .last),
        (\.prevImageKey,   .previous),
        (\.nextImageKey,   .next),
        (\.rejectKey,      .reject),
        (\.undoKey,        .undo),
        (\.flagKey,        .flag),
        (\.deflagAllKey,   .deflagAll),
        (\.toggleModeKey,  .toggleMode),
        (\.removeKey,      .remove),
        (\.debayerKey,     .debayer),
    ]

    /// Executes a `NavAction` against the current store/settings state.
    /// Returns false only for bindings that should not consume the event
    /// (e.g. `undo` when toggle-reject mode is on).
    @discardableResult
    private func dispatch(_ action: NavAction) -> Bool {
        switch action {
        case .selectAll:         store.selectAllVisible()
        case .deselectAll:       store.deselectAll()
        case .invertSelection:   store.invertSelection()
        case .selectAllRejected: store.selectAllRejected()
        case .first:             store.selectFirst()
        case .last:              store.selectLast()
        case .previous:          store.selectPrevious()
        case .next:              store.selectNext()
        case .reject:
            if settings.useToggleReject { store.toggleRejectSelected() } else { store.rejectSelected() }
        case .undo:
            guard !settings.useToggleReject else { return false }
            store.undoRejectSelected()
        case .flag:     store.toggleFlagSelected()
        case .deflagAll: store.deflagAll()
        case .toggleMode:  settings.isSimpleMode.toggle()
        case .remove:      store.removeSelected()
        case .debayer:     settings.debayerColorImages.toggle()
        }
        return true
    }

    // MARK: - Key handling

    /// Installs a window-level key monitor so navigation keys work regardless of
    /// which subview (e.g. the sidebar List) currently holds keyboard focus.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated {
                // Don't steal from text inputs.
                guard !(NSApp.keyWindow?.firstResponder is NSText) else { return event }

                let mods = event.modifierFlags
                let shift = mods.contains(.shift)

                // ⌘(⇧) + configured key — selection shortcuts.
                // Use charactersIgnoringModifiers for reliable key matching across
                // keyboard layouts and macOS versions (Cmd+A can produce "\x01" via
                // event.characters on some systems).
                if mods.contains(.command),
                   !mods.contains(.option),
                   !mods.contains(.control),
                   let key = event.charactersIgnoringModifiers?.lowercased() {
                    if let binding = Self.cmdKeyBindings.first(where: {
                        self.settings[keyPath: $0.key] == key &&
                        self.settings[keyPath: $0.shift] == shift
                    }) {
                        self.dispatch(binding.action)
                        return nil
                    }
                }

                // ⇧ + configured nav key — extend selection.
                if shift, !mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
                    if let key = Self.keyString(from: event) {
                        if key == self.settings.prevImageKey {
                            self.store.extendSelectionPrevious(); return nil
                        }
                        if key == self.settings.nextImageKey {
                            self.store.extendSelectionNext(); return nil
                        }
                    }
                }

                // Don't intercept events with command/option/control modifiers.
                guard mods.intersection([.command, .option, .control]).isEmpty else { return event }
                guard let key = Self.keyString(from: event) else { return event }
                return self.handleKey(key) ? nil : event
            }
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Converts an NSEvent to the key-string format used by AppSettings (e.g. "↑", "x", " ").
    private static func keyString(from event: NSEvent) -> String? {
        if let special = event.specialKey {
            switch special {
            case .upArrow:    return "↑"
            case .downArrow:  return "↓"
            case .leftArrow:  return "←"
            case .rightArrow: return "→"
            case .home:       return "⇱"
            case .end:        return "⇲"
            default:          return nil
            }
        }
        return event.characters?.lowercased()
    }

    /// Looks up the matching plain-key binding and dispatches it.
    /// Returns true if a binding matched and the event should be consumed.
    @discardableResult
    private func handleKey(_ key: String) -> Bool {
        guard let binding = Self.plainKeyBindings.first(where: { settings[keyPath: $0.key] == key }) else {
            return false
        }
        return dispatch(binding.action)
    }

    private func handleDrop(providers: [NSItemProvider]) {
        Task { @MainActor in
            var urls: [URL] = []
            await withTaskGroup(of: URL?.self) { group in
                for provider in providers {
                    group.addTask {
                        await withCheckedContinuation { continuation in
                            provider.loadObject(ofClass: NSURL.self) { object, _ in
                                continuation.resume(returning: (object as? NSURL) as? URL)
                            }
                        }
                    }
                }
                for await url in group {
                    if let url { urls.append(url) }
                }
            }
            guard !urls.isEmpty else { return }
            store.openDroppedItems(urls, settings: settings)
        }
    }
}

// MARK: - Drop Target Overlay

struct DropTargetOverlay: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .stroke(.blue, lineWidth: 4)
            .fill(.blue.opacity(0.04))
            .padding(4)
            .allowsHitTesting(false)
    }
}

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        Task { @MainActor in self.onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        Task { @MainActor in self.onWindow(nsView.window) }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ImageStore())
}
