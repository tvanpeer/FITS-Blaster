//
//  ContentView.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 28/02/2026.
//

import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @State private var hostingWindow: NSWindow?

    var body: some View {
        HSplitView {
            ThumbnailSidebar(store: store)
                .frame(minWidth: 140, idealWidth: 165, maxWidth: 220)

            VStack(spacing: 0) {
                FITSToolbar(store: store)
                Divider()
                MainContent(store: store)
            }
            .frame(minWidth: 400)

            if settings.showInspector {
                InspectorView()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            }
        }
        .frame(minWidth: settings.showInspector ? 960 : 700, minHeight: 400)
        .preferredColorScheme(settings.preferredColorScheme)
        .background(WindowAccessor { hostingWindow = $0 })
        .onChange(of: settings.metricsConfig) { _, newConfig in
            store.recomputeMetrics(metricsConfig: newConfig)
        }
        .onChange(of: settings.showInspector) { _, shown in
            guard let window = hostingWindow else { return }
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
        .focusable()
        .focusEffectDisabled()
        // Navigation
        .onKeyPress(settings.firstImageKeyEquivalent) { store.selectFirst();          return .handled }
        .onKeyPress(settings.lastImageKeyEquivalent)  { store.selectLast();           return .handled }
        .onKeyPress(settings.prevKeyEquivalent)       { store.selectPrevious();       return .handled }
        .onKeyPress(settings.nextKeyEquivalent)       { store.selectNext();           return .handled }
        .onKeyPress(settings.rejectKeyEquivalent)     { store.rejectSelected();       return .handled }
        .onKeyPress(settings.undoKeyEquivalent)       { store.undoRejectSelected();   return .handled }
        // Rating
        .onKeyPress(settings.rating1KeyEquivalent)    { store.setRating(1, for: store.selectedEntry); return .handled }
        .onKeyPress(settings.rating2KeyEquivalent)    { store.setRating(2, for: store.selectedEntry); return .handled }
        .onKeyPress(settings.rating3KeyEquivalent)    { store.setRating(3, for: store.selectedEntry); return .handled }
        .onKeyPress(settings.rating4KeyEquivalent)    { store.setRating(4, for: store.selectedEntry); return .handled }
        .onKeyPress(settings.rating5KeyEquivalent)    { store.setRating(5, for: store.selectedEntry); return .handled }
        .onKeyPress(settings.clearRatingKeyEquivalent){ store.setRating(0, for: store.selectedEntry); return .handled }
    }
}

// MARK: - Thumbnail Sidebar

struct ThumbnailSidebar: View {
    @Bindable var store: ImageStore

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Sort")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Picker("Sort", selection: $store.thumbnailSortOrder) {
                    ForEach(ThumbnailSortOrder.allCases, id: \.self) { order in
                        Text(order.rawValue).tag(order)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .font(.caption)
                Button(store.thumbnailSortAscending ? "Sort Ascending" : "Sort Descending",
                       systemImage: store.thumbnailSortAscending ? "arrow.up" : "arrow.down") {
                    store.thumbnailSortAscending.toggle()
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .font(.caption)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack {
                        ForEach(store.sortedEntries) { entry in
                            Button {
                                store.selectedEntry = entry
                            } label: {
                                ThumbnailCell(entry: entry, isSelected: store.selectedEntry === entry)
                            }
                            .buttonStyle(.plain)
                            .id(entry.id)
                        }
                    }
                    .padding()
                }
                .scrollIndicators(.hidden)
                .background(.background)
                .onChange(of: store.selectedEntry?.id) { _, id in
                    guard let id else { return }
                    withAnimation { proxy.scrollTo(id, anchor: .center) }
                }
            }
        }
    }
}

// MARK: - Toolbar

struct FITSToolbar: View {
    let store: ImageStore
    @Environment(AppSettings.self) private var settings
    @State private var showExportSheet = false

    var body: some View {
        HStack {
            Button("Open Folder…") {
                store.openFolderPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: .command)

            Button("Open Files…") {
                store.openFilesPanel(settings: settings)
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])

            Button("Reset") {
                store.reset()
            }
            .disabled(store.entries.isEmpty)

            if let entry = store.selectedEntry {
                Divider().frame(height: 20)
                Text(entry.fileName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Divider().frame(height: 20)

                RatingView(currentRating: entry.rating) { rating in
                    store.setRating(rating, for: entry)
                }
            }

            Spacer()

            Button("Export…", systemImage: "square.and.arrow.up") {
                showExportSheet = true
            }
            .disabled(store.entries.isEmpty)

            Button("", systemImage: "sidebar.right") {
                settings.showInspector.toggle()
            }
            .help(settings.showInspector ? "Hide Inspector" : "Show Inspector")
        }
        .padding()
        .sheet(isPresented: $showExportSheet) {
            ExportSheet(isPresented: $showExportSheet)
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
                    ScrollView([.horizontal, .vertical]) {
                        Image(nsImage: displayImage)
                    }
                    .id(entry.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .scrollIndicators(.hidden)

                    Divider()
                    InfoBar(store: store, entry: entry)
                }
            } else if let error = entry.errorMessage {
                VStack {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
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
                Text("Open a folder of FITS files to view them")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text("Use the button above or \u{2318}O")
                    .font(.caption)
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

    var body: some View {
        HStack {
            if store.isBatchProcessing {
                ProgressView().scaleEffect(0.5).frame(width: 12, height: 12)
                Text("Processing…").font(.caption).foregroundStyle(.secondary)
            } else if let elapsed = store.batchElapsed {
                Text("\(elapsed, format: .number.precision(.fractionLength(2)))s for \(store.entries.count) images")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // Inline metrics summary
            if let m = entry.metrics, m.hasData {
                HStack(spacing: 12) {
                    if let v = m.fwhm        { MetricChip(label: "FWHM", value: "\(v.formatted(.number.precision(.fractionLength(1)))) px") }
                    if let v = m.eccentricity { MetricChip(label: "Ecc",  value: v.formatted(.number.precision(.fractionLength(2)))) }
                    if let v = m.snr          { MetricChip(label: "SNR",  value: v.formatted(.number.precision(.fractionLength(0)))) }
                    if let v = m.starCount     { MetricChip(label: "★",   value: "\(v)") }
                }
            }

            if !entry.imageInfo.isEmpty {
                Text(entry.imageInfo)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
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
        .font(.caption.monospacedDigit())
    }
}

// MARK: - Thumbnail Cell

struct ThumbnailCell: View {
    let entry: ImageEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                thumbnailImage
                if let metrics = entry.metrics, metrics.hasData {
                    QualityBadge(score: metrics.qualityScore, color: metrics.badgeColor)
                }
            }

            Text(entry.fileName)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 4) {
                if let filter = entry.filterName {
                    Text(filter)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if entry.rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(1...entry.rating, id: \.self) { _ in
                            Image(systemName: "star.fill")
                                .font(.caption2)
                                .foregroundStyle(.yellow)
                        }
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if entry.isProcessing {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView().scaleEffect(0.6) }
        } else if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .clipShape(.rect(cornerRadius: 4))
                .overlay { if entry.isRejected { RejectionOverlay() } }
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
        }
    }
}

// MARK: - Quality Badge

struct QualityBadge: View {
    let score: Int
    let color: Color

    var body: some View {
        Text("\(score)")
            .font(.caption2.bold())
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(color)
            .clipShape(.rect(cornerRadius: 3))
            .foregroundStyle(.white)
            .padding(4)
    }
}

// MARK: - Rejection Overlay

// MARK: - Window Accessor

private struct WindowAccessor: NSViewRepresentable {
    let onWindow: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { self.onWindow(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { self.onWindow(nsView.window) }
    }
}

// MARK: - Rejection Overlay

struct RejectionOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: w, y: h))
                path.move(to: CGPoint(x: w, y: 0))
                path.addLine(to: CGPoint(x: 0, y: h))
            }
            .stroke(.red, lineWidth: 3)
        }
    }
}

#Preview {
    ContentView()
        .environment(AppSettings())
        .environment(ImageStore())
}
