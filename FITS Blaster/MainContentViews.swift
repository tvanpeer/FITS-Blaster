//
//  MainContentViews.swift
//  FITS Blaster
//
//  Main image display area: resizable chart layout, toolbar, image viewer,
//  info bar, and metric chip.
//

import SwiftUI

// MARK: - Resizable Chart Layout

/// A VStack containing the main image and session chart, separated by a draggable
/// handle that persists the chart height across launches via AppStorage.
struct ResizableChartLayout: View {
    @Environment(ImageStore.self) private var store
    @AppStorage("sessionChartHeight") private var chartHeight: Double = 200

    /// Captured at the start of each drag so we can compute relative offset.
    @State private var heightAtDragStart: Double = 200

    var body: some View {
        VStack(spacing: 0) {
            MainContent(store: store)
                .frame(minHeight: 180)

            // Drag handle
            Rectangle()
                .fill(.quinary)
                .frame(height: 5)
                .overlay(
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.quaternary)
                        .frame(width: 32, height: 3)
                )
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            // Dragging up = negative translation = chart taller
                            chartHeight = max(80, min(600,
                                heightAtDragStart - value.translation.height))
                        }
                        .onEnded { _ in
                            heightAtDragStart = chartHeight
                        }
                )

            SessionChartView()
                .frame(height: chartHeight)
        }
        .onAppear { heightAtDragStart = chartHeight }
    }
}

// MARK: - Toolbar

struct FITSToolbar: View {
    let store: ImageStore
    @Environment(AppSettings.self) private var settings
    @State private var showExportSheet = false
    @State private var showAutoRejectSheet = false

    var body: some View {
        HStack {
            Button("Open Folder…") {
                store.openFolderPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: .command)
            .help("Open a folder of FITS files (⌘O)")

            // TODO: Open Files… is hidden until sandbox write-access for parent directories is resolved.
            // Button("Open Files…") { store.openFilesPanel(settings: settings) }
            //     .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Reset") {
                store.reset()
            }
            .disabled(store.entries.isEmpty)
            .help("Remove all loaded images from the list")

            Button {
                settings.debayerColorImages.toggle()
            } label: {
                Label {
                    Text(settings.debayerColorImages ? "Colour" : "Grey")
                } icon: {
                    if settings.debayerColorImages {
                        Image(systemName: "camera.filters")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.red, Color.green, Color.blue)
                    } else {
                        Image(systemName: "camera.filters")
                            .symbolRenderingMode(.monochrome)
                    }
                }
            }
            .help(settings.debayerColorImages ? "Switch to greyscale" : "Switch to colour")

            PlaybackControls()

            Button("Cancel") {
                store.cancelProcessing()
            }
            .disabled(!store.isBatchProcessing)
            .help("Cancel the current batch processing")

            Button("(De)flag", systemImage: "flag") {
                store.toggleFlagSelected()
            }
            .disabled(store.selectedEntry == nil && store.markedForRejectionIDs.isEmpty)
            .help("Flag or unflag the current selection")

            if !store.flaggedEntryIDs.isEmpty {
                Divider().frame(height: 20)
                Text("\(store.flaggedEntryIDs.count) flagged")
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !settings.isSimpleMode {
                Button("Auto-Flag", systemImage: "wand.and.stars") {
                    showAutoRejectSheet = true
                }
                .help("Auto-flag frames below quality thresholds")
                .disabled(store.entries.isEmpty)
            }

            Button("Export…", systemImage: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(store.entries.isEmpty)
            .help("Export a list of flagged or rejected frames")

            // Mode toggle: show the CURRENT mode (like "Colour"/"Grey").
            Button(settings.isSimpleMode ? "Simple" : "Geek",
                   systemImage: settings.isSimpleMode ? "dial.low" : "dial.high") {
                settings.isSimpleMode.toggle()
            }
            .help(settings.isSimpleMode ? "Switch to Geek Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))" : "Switch to Simple Mode (\(AppSettings.displayString(for: settings.toggleModeKey)))")

            if !settings.isSimpleMode {
                Button(settings.showInspector ? "Hide Inspector" : "Show Inspector",
                       systemImage: "sidebar.right") {
                    settings.showInspector.toggle()
                }
                .labelStyle(.iconOnly)
                .help(settings.showInspector ? "Hide Inspector" : "Show Inspector")
            }
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(isPresented: $showExportSheet)
                .environment(store)
                .environment(settings)
        }
        .sheet(isPresented: $showAutoRejectSheet) {
            AutoRejectSheet(isPresented: $showAutoRejectSheet)
                .environment(store)
        }
    }
}

// MARK: - Main Content

struct MainContent: View {
    let store: ImageStore

    var body: some View {
        if let entry = store.selectedEntry {
            if entry.isProcessing {
                ProgressView("Stretching \(entry.fileName)…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let displayImage = entry.displayImage {
                VStack(spacing: 0) {
                    Text(entry.fileName)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.horizontal)
                        .padding(.vertical, 4)
                    Divider()
                    ImageViewer(entryID: entry.id, displayImage: displayImage, isFlipped: entry.isFlipped)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Divider()
                    ImageAdjustControls()

                    Divider()
                    InfoBar(store: store, entry: entry)
                }
            } else if let error = entry.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .scaledFont(size: 10)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else {
            VStack {
                Image(systemName: "star.circle")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tertiary)
                Text("Ready to Blast through your frames?")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Open a folder with \u{2318}O or drag it onto the window")
                    .scaledFont(size: 10)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}


// MARK: - Info Bar

private struct InfoBar: View {
    let store: ImageStore
    let entry: ImageEntry
    @Environment(AppSettings.self) private var settings

    var body: some View {
        HStack {
            if store.isBatchProcessing {
                BatchProgressBar(store: store, showLoadedMetrics: true)
            } else if store.recolouringMessage != nil {
                BatchProgressBar(store: store, showLoadedMetrics: false)
            } else if let elapsed = store.batchElapsed {
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(store.entries.count) images")
                    .scaledFont(size: 10, monospaced: true)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Inline metrics summary (Geek mode only)
            if !settings.isSimpleMode, let m = entry.metrics, m.hasData {
                HStack(spacing: 12) {
                    if let v = m.fwhm        { MetricChip(label: "FWHM", value: "\(v.formatted(.number.precision(.fractionLength(1)))) px") }
                    if let v = m.eccentricity { MetricChip(label: "Ecc",  value: v.formatted(.number.precision(.fractionLength(2)))) }
                    if let v = m.snr          { MetricChip(label: "SNR",  value: v.formatted(.number.precision(.fractionLength(0)))) }
                    if let v = m.starCount     { MetricChip(label: "★",   value: "\(v)") }
                }
            }

            if !entry.imageInfo.isEmpty {
                Text(entry.imageInfo)
                    .scaledFont(size: 10)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}

// MARK: - Batch Progress Bar

private struct BatchProgressBar: View {
    let store: ImageStore
    /// True during an active batch load (shows Loaded + Metrics + Cancel).
    /// False during a post-load colour toggle (shows Colour bar only).
    let showLoadedMetrics: Bool
    @Environment(AppSettings.self) private var settings

    /// Polled every 200 ms by the .task modifier — never read in body directly
    /// so that property-level @Observable tracking on individual ImageEntry objects
    /// is not established, which would re-render this view on every per-entry change.
    @State private var loadedCount: Int = 0
    @State private var metricsCount: Int = 0

    var body: some View {
        let total = store.entries.count
        VStack(alignment: .leading, spacing: 3) {
            if showLoadedMetrics {
                ProgressBarRow(label: "Loaded", value: loadedCount, total: total, color: .teal)
                // Hidden in simple mode — metrics are not computed there.
                if !settings.isSimpleMode {
                    ProgressBarRow(label: "Metrics", value: metricsCount, total: total, color: .indigo)
                }
            }
            // Sampling and Colour bars appear only when colour rendering is active
            // (batchSamplingTotal / batchBayerTotal are non-zero). They stay visible
            // until the whole batch completes rather than disappearing when their own
            // pipeline finishes.
            if store.batchSamplingTotal > 0 {
                ProgressBarRow(label: "Sampling", value: store.batchSamplingCount, total: store.batchSamplingTotal, color: .mint)
            }
            if store.batchBayerTotal > 0 {
                ProgressBarRow(label: "Colour", value: store.batchColourCount, total: store.batchBayerTotal, color: .orange)
            }
        }
        .task {
            // Poll entry state every 200 ms. Running in a .task closure (not in body)
            // means @Observable tracking is NOT established for individual entries,
            // so this view is never re-rendered by per-entry isProcessing/metrics changes.
            repeat {
                loadedCount  = store.entries.count { !$0.isProcessing }
                metricsCount = store.entries.count { $0.metrics != nil }
                try? await Task.sleep(for: .milliseconds(200))
            } while !Task.isCancelled
        }
    }
}

private struct ProgressBarRow: View {
    let label: String
    let value: Int
    let total: Int
    let color: Color

    private var fraction: Double {
        total > 0 ? min(1, Double(value) / Double(total)) : 0
    }

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .scaledFont(size: 9)
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
            Capsule()
                .fill(color.opacity(0.2))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(color)
                        .scaleEffect(x: fraction, anchor: .leading)
                        .animation(.linear(duration: 0.2), value: fraction)
                }
                .frame(height: 4)
            Text("\(value) / \(total)")
                .scaledFont(size: 9, monospaced: true)
                .foregroundStyle(.secondary)
                .fixedSize()
        }
    }
}

private struct MetricChip: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 3) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
        .scaledFont(size: 10, monospaced: true)
    }
}

// MARK: - Image Viewer

/// Displays a stretched FITS image inside a scroll view with pinch-to-zoom support.
///
/// Scroll position is preserved across image navigation: `entryID` changes trigger
/// a programmatic scroll to the stored center fraction in `ImageStore`.
/// Zoom from the slider keeps the viewport center fixed by adjusting the scroll offset
/// proportionally before the next layout pass.
private struct ImageViewer: View {
    let entryID: UUID
    let displayImage: NSImage
    let isFlipped: Bool

    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @GestureState private var gestureScale: Double = 1.0
    // Named scrollPos (not scrollPosition) to avoid shadowing the SwiftUI .scrollPosition modifier.
    @State private var scrollPos = ScrollPosition(x: 0, y: 0)
    @State private var lastGeo: ViewportGeometry? = nil

    private var effectiveZoom: Double { settings.zoomScale * gestureScale }

    var body: some View {
        @Bindable var settings = settings

        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: displayImage)
                .resizable()
                .frame(
                    width:  displayImage.size.width  * effectiveZoom,
                    height: displayImage.size.height * effectiveZoom
                )
                .rotationEffect(isFlipped ? .degrees(180) : .zero)
                .brightness(store.displayBrightness)
                .contrast(store.displayStretch)
        }
        .scrollPosition($scrollPos)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: ViewportGeometry.self, of: ViewportGeometry.init) { _, geo in
            lastGeo = geo
            let cw = geo.contentSize.width, ch = geo.contentSize.height
            guard cw > 0, ch > 0 else { return }
            store.viewportFraction = CGRect(
                x: max(0, geo.contentOffset.x / cw),
                y: max(0, geo.contentOffset.y / ch),
                width:  min(1, geo.containerSize.width  / cw),
                height: min(1, geo.containerSize.height / ch)
            )
            store.viewportCenter = CGPoint(
                x: (geo.contentOffset.x + geo.containerSize.width  / 2) / cw,
                y: (geo.contentOffset.y + geo.containerSize.height / 2) / ch
            )
        }
        // Restore the stored scroll position when the displayed entry changes.
        .onChange(of: entryID) { _, _ in
            guard let geo = lastGeo else { return }
            let cw = displayImage.size.width  * settings.zoomScale
            let ch = displayImage.size.height * settings.zoomScale
            let x = store.viewportCenter.x * cw - geo.containerSize.width  / 2
            let y = store.viewportCenter.y * ch - geo.containerSize.height / 2
            scrollPos.scrollTo(x: max(0, x), y: max(0, y))
        }
        // Keep the viewport center fixed when the zoom slider moves.
        .onChange(of: settings.zoomScale) { oldZoom, newZoom in
            guard let geo = lastGeo, oldZoom != newZoom, geo.contentSize.width > 0 else { return }
            let centerX = (geo.contentOffset.x + geo.containerSize.width  / 2) / geo.contentSize.width
            let centerY = (geo.contentOffset.y + geo.containerSize.height / 2) / geo.contentSize.height
            let newCW = displayImage.size.width  * newZoom
            let newCH = displayImage.size.height * newZoom
            let x = centerX * newCW - geo.containerSize.width  / 2
            let y = centerY * newCH - geo.containerSize.height / 2
            scrollPos.scrollTo(x: max(0, x), y: max(0, y))
        }
        .gesture(
            MagnificationGesture()
                .updating($gestureScale) { value, state, _ in state = value }
                .onEnded { value in
                    settings.zoomScale = max(0.25, min(4.0, settings.zoomScale * value))
                }
        )
    }
}

/// Equatable snapshot of `ScrollGeometry` for use with `onScrollGeometryChange`.
private struct ViewportGeometry: Equatable {
    let contentOffset: CGPoint
    let contentSize: CGSize
    let containerSize: CGSize

    init(_ geometry: ScrollGeometry) {
        contentOffset  = geometry.contentOffset
        contentSize    = geometry.contentSize
        containerSize  = geometry.containerSize
    }
}

// MARK: - Image Adjust Controls

/// A compact strip of session-level display sliders: zoom, brightness, and stretch.
/// Shown below the image viewer; resets on session reset but zoom persists across launches.
private struct ImageAdjustControls: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    private var isDefault: Bool {
        settings.zoomScale == 1.0 && store.displayBrightness == 0.0 && store.displayStretch == 1.0
    }

    var body: some View {
        HStack(spacing: 12) {
            ZoomControl()
            Divider().frame(height: 14)
            BrightnessControl()
            Divider().frame(height: 14)
            StretchControl()

            Button("Defaults", systemImage: "arrow.counterclockwise") {
                settings.zoomScale = 1.0
                store.displayBrightness = 0.0
                store.displayStretch = 1.0
            }
            .disabled(isDefault)
            .tooltip("Reset all display adjustments")
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

/// Each slider control is its own struct so that value changes only re-render
/// that single control, not the entire HStack. This prevents tooltip hover
/// state from being reset when any slider value changes.
private struct ZoomControl: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        @Bindable var bound = settings
        Button("Zoom", systemImage: "plus.magnifyingglass") {
            settings.zoomScale = 1.0
        }
        .tooltip("Zoom — click to reset")
        Slider(value: $bound.zoomScale, in: 0.25...4.0)
            .frame(width: 80)
        Text("\(settings.zoomScale, format: .number.precision(.fractionLength(1)))×")
            .scaledFont(size: 10, monospaced: true)
            .frame(width: 34, alignment: .leading)
    }
}

private struct BrightnessControl: View {
    @Environment(ImageStore.self) private var store

    var body: some View {
        @Bindable var bound = store
        Button("Brightness", systemImage: "sun.max") {
            store.displayBrightness = 0.0
        }
        .tooltip("Brightness — click to reset")
        Slider(value: $bound.displayBrightness, in: -0.5...0.5)
            .frame(width: 80)
    }
}

private struct StretchControl: View {
    @Environment(ImageStore.self) private var store

    var body: some View {
        @Bindable var bound = store
        Button("Stretch", systemImage: "waveform.path.ecg") {
            store.displayStretch = 1.0
        }
        .tooltip("Stretch — click to reset")
        Slider(value: $bound.displayStretch, in: 0.5...3.0)
            .frame(width: 80)
    }
}

// MARK: - Playback Controls

/// Play/pause button with a speed slider, shown in the toolbar.
private struct PlaybackControls: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    /// True while the user is dragging the speed slider — playback pauses during the drag.
    @State private var wasPlayingBeforeDrag = false

    var body: some View {
        @Bindable var bound = settings

        Button(store.isPlaying ? "Pause" : "Play",
               systemImage: store.isPlaying ? "pause.fill" : "play.fill") {
            guard store.selectedEntry != nil else { return }
            if store.isPlaying {
                store.stopPlayback()
            } else {
                store.startPlayback(settings: settings)
            }
        }
        .disabled(store.selectedEntry == nil)
        .tooltip(store.isPlaying
                 ? "Pause slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))"
                 : "Play slideshow (\(AppSettings.displayString(for: settings.playPauseKey)))")

        if store.isPlaying || wasPlayingBeforeDrag {
            Slider(value: $bound.playbackSpeed, in: 0.2...5.0, step: 0.1,
                   onEditingChanged: { editing in
                if editing {
                    wasPlayingBeforeDrag = store.isPlaying
                    store.stopPlayback()
                } else if wasPlayingBeforeDrag {
                    wasPlayingBeforeDrag = false
                    store.startPlayback(settings: settings)
                }
            })
                .frame(width: 60)
            Text("\(settings.playbackSpeed, format: .number.precision(.fractionLength(1)))s")
                .scaledFont(size: 10, monospaced: true)
                .frame(width: 28, alignment: .leading)
        }
    }
}


// MARK: - Native macOS Tooltip

/// SwiftUI's `.help()` modifier loses its tooltip state whenever `@Observable`
/// properties trigger a view re-render. This modifier uses `NSView.toolTip`
/// directly, which survives SwiftUI view updates. The underlying NSView returns
/// `nil` from `hitTest(_:)` so all mouse events pass through to the SwiftUI
/// content underneath.
private class TooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct TooltipOverlay: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TooltipNSView {
        let view = TooltipNSView()
        view.toolTip = text
        return view
    }
    func updateNSView(_ nsView: TooltipNSView, context: Context) {
        nsView.toolTip = text
    }
}

extension View {
    func tooltip(_ text: String) -> some View {
        overlay { TooltipOverlay(text: text) }
    }
}

