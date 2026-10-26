//
//  ContentSplitLayout.swift
//  FITS Blaster
//

import SwiftUI

/// The main layout: thumbnail sidebar, content+toolbar column, and optional inspector.
///
/// The sidebar's width is set by the app — its natural width follows the thumbnail size
/// (`SidebarLayout`), and `SidebarDivider` drags it wider. A split view pane kept its
/// maximum width and couldn't be told to take a new natural width.
///
/// Content and inspector share an HSplitView. The SwiftUI .inspector modifier creates a
/// nested SplitViewChildController layer on top of HSplitView's own layer; on macOS 27
/// without the app sandbox this causes an infinite constraint-update loop
/// (NSGenericException). Using a plain column in the same HSplitView avoids the nested
/// controller entirely.
struct ContentSplitLayout: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var isDragTarget = false
    /// How much wider than its natural width the sidebar was dragged; kept between launches,
    /// back to 0 when the thumbnail size changes.
    @AppStorage("sidebarExtraWidth") private var sidebarExtraWidth: Double = 0
    /// The width of the whole layout, to keep the main column at its minimum while dragging.
    @State private var layoutWidth: CGFloat = 0

    var body: some View {
        let naturalWidth = SidebarLayout.width(forThumbnail: settings.maxThumbnailSize)
        let maxExtra = maxExtraWidth(natural: naturalWidth)
        HStack(spacing: 0) {
            // The sidebar's width follows the thumbnail size, plus what it was dragged wider.
            ThumbnailSidebar()
                .frame(width: naturalWidth + CGFloat(min(sidebarExtraWidth, maxExtra)))

            SidebarDivider(extraWidth: $sidebarExtraWidth, maxExtraWidth: maxExtra)

            HSplitView {
                VStack(spacing: 0) {
                    FITSToolbar(store: store)
                    Divider()
                    if settings.isSimpleMode {
                        MainContent(store: store)
                    } else {
                        ResizableChartLayout()
                    }
                }
                .frame(minWidth: mainColumnMinWidth)

                if !settings.isSimpleMode && settings.showInspector {
                    InspectorView()
                        .frame(minWidth: Self.inspectorMinWidth, idealWidth: 260, maxWidth: 320)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { layoutWidth = $0 }
        .onChange(of: settings.maxThumbnailSize) { _, _ in
            // A new thumbnail size: the sidebar takes its new natural width.
            sidebarExtraWidth = 0
        }
        .overlay { if isDragTarget { DropTargetOverlay() } }
        // Dropped folders and files arrive as URLs, in drop order; the first one decides
        // the bookmark and root name. No item providers or continuations (CODE_AUDIT §4.1).
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            store.openDroppedItems(urls, settings: settings)
            return true
        } isTargeted: { isDragTarget = $0 }
    }

    private static let inspectorMinWidth: CGFloat = 220
    private var mainColumnMinWidth: CGFloat { settings.isSimpleMode ? 380 : 400 }

    /// The most the sidebar may be dragged wider: `SidebarLayout.extraDragWidth`, and no more
    /// than leaves the main column and the Inspector at their minimum widths.
    private func maxExtraWidth(natural: CGFloat) -> Double {
        let inspector = !settings.isSimpleMode && settings.showInspector ? Self.inspectorMinWidth : 0
        let room = layoutWidth - natural - mainColumnMinWidth - inspector - 2
        return Double(max(0, min(SidebarLayout.extraDragWidth, room)))
    }
}
