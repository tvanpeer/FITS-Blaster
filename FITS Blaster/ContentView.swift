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
    @State private var keyMonitor: Any?

    var body: some View {
        ContentSplitLayout()
            .modifier(ContentFocusedValues())
            .frame(minWidth: minWindowWidth, minHeight: 400)
            .environment(\.fontSizeMultiplier, settings.fontSizeMultiplier)
            .preferredColorScheme(settings.preferredColorScheme)
            .background(WindowAccessor { window in
                hostingWindow = window
            })
            .onChange(of: settings.debayerColorImages) { _, _ in
                guard !store.entries.isEmpty else { return }
                store.recolorImages(settings: settings)
            }
            .onChange(of: settings.isSimpleMode) { _, isSimple in
                if !isSimple {
                    store.recomputeMetrics(metricsConfig: settings.effectiveMetricsConfig)
                }
                guard let window = hostingWindow,
                      !window.styleMask.contains(.fullScreen) else { return }
                var frame = window.frame
                frame.size.width = max(frame.size.width, isSimple ? 500 : (settings.showInspector ? 960 : 700))
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
        case playPause, flip
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
        (\.playPauseKey,   .playPause),
        (\.flipKey,        .flip),
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
        case .first:             store.stopPlayback(); store.selectFirst(in: sidebarNavigationEntries)
        case .last:              store.stopPlayback(); store.selectLast(in: sidebarNavigationEntries)
        case .previous:          store.stopPlayback(); store.selectPrevious(in: sidebarNavigationEntries)
        case .next:              store.stopPlayback(); store.selectNext(in: sidebarNavigationEntries)
        case .reject:
            let preReject = sidebarNavigationEntries
            if settings.useToggleReject { store.toggleRejectSelected() } else { store.rejectSelected() }
            store.advanceCursorIfNeeded(from: preReject)
        case .undo:
            guard !settings.useToggleReject else { return false }
            let preUndo = sidebarNavigationEntries
            store.undoRejectSelected()
            store.advanceCursorIfNeeded(from: preUndo)
        case .flag:
            let preFlag = sidebarNavigationEntries
            store.toggleFlagSelected()
            store.advanceCursorIfNeeded(from: preFlag)
        case .deflagAll: store.deflagAll()
        case .toggleMode:  settings.isSimpleMode.toggle()
        case .remove:      store.removeSelected()
        case .debayer:     settings.debayerColorImages.toggle()
        case .playPause:
            if store.isPlaying {
                store.stopPlayback()
            } else {
                guard store.selectedEntry != nil else { return false }
                store.startPlayback(settings: settings)
            }
        case .flip:
            store.toggleFlipSelected()
        }
        return true
    }

    /// Entries in thumbnail-sidebar visual order — used by keyboard navigation so
    /// ↑/↓ always step through frames in the same sequence shown in the strip.
    private var sidebarNavigationEntries: [ImageEntry] {
        store.sidebarNavigationEntries(isSimpleMode: settings.isSimpleMode)
    }

    // MARK: - Key handling

    /// Installs a window-level key monitor so navigation keys work regardless of
    /// which subview (e.g. the sidebar List) currently holds keyboard focus.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // assumeIsolated requires a Sendable return type; NSEvent is not Sendable.
            // Return Bool (true = pass event through, false = consume) and decide outside.
            let passThrough: Bool = MainActor.assumeIsolated {
                // System shortcuts first, so a configured plain key doesn't swallow them.
                switch SystemKeyShortcut.match(event) {
                case .toggleFullScreen:
                    // Same route as View → Enter Full Screen: the key window via the responder chain.
                    return !NSApp.sendAction(#selector(NSWindow.toggleFullScreen(_:)), to: nil, from: nil)
                case .passToSystem:
                    return true
                case nil:
                    break
                }

                // Don't steal from text inputs.
                guard !(NSApp.keyWindow?.firstResponder is NSText) else { return true }

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
                        return false
                    }
                }

                // ⇧ + configured nav key — extend selection.
                if shift, !mods.contains(.command), !mods.contains(.option), !mods.contains(.control) {
                    if let key = Self.keyString(from: event) {
                        if key == self.settings.prevImageKey {
                            self.store.extendSelectionPrevious(in: self.sidebarNavigationEntries)
                            return false
                        }
                        if key == self.settings.nextImageKey {
                            self.store.extendSelectionNext(in: self.sidebarNavigationEntries)
                            return false
                        }
                    }
                }

                // Don't intercept events with command/option/control modifiers.
                guard mods.intersection([.command, .option, .control]).isEmpty else { return true }
                guard let key = Self.keyString(from: event) else { return true }
                return !self.handleKey(key)
            }
            return passThrough ? event : nil
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

    func makeCoordinator() -> Coordinator { Coordinator(onWindow: onWindow) }
    func makeNSView(context: Context) -> AccessorView { AccessorView(coordinator: context.coordinator) }
    func updateNSView(_ nsView: AccessorView, context: Context) { context.coordinator.onWindow = onWindow }

    final class Coordinator {
        var onWindow: (NSWindow?) -> Void
        init(onWindow: @escaping (NSWindow?) -> Void) { self.onWindow = onWindow }
    }
}

private final class AccessorView: NSView {
    private let coordinator: WindowAccessor.Coordinator

    init(coordinator: WindowAccessor.Coordinator) {
        self.coordinator = coordinator
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        coordinator.onWindow(window)
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ImageStore())
}
