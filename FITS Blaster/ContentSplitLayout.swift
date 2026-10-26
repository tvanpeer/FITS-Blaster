//
//  ContentSplitLayout.swift
//  FITS Blaster
//

import SwiftUI

/// The main HSplitView layout: thumbnail sidebar, content+toolbar column, and optional inspector.
///
/// The SwiftUI .inspector modifier creates a nested SplitViewChildController layer
/// on top of HSplitView's own layer; on macOS 27 without the app sandbox this causes
/// an infinite constraint-update loop (NSGenericException). Using a plain third column
/// in the same HSplitView avoids the nested controller entirely.
struct ContentSplitLayout: View {
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @State private var isDragTarget = false

    var body: some View {
        HSplitView {
            ThumbnailSidebar()
                .frame(minWidth: 140, idealWidth: 200, maxWidth: 360)

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

            if !settings.isSimpleMode && settings.showInspector {
                InspectorView()
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)
            }
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
}
