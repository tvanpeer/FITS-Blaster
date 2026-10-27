//
//  SidebarCursorScroller.swift
//  FITS Blaster
//

import SwiftUI

/// Keeps the sidebar scrolled to the cursor. An invisible view of its own, so the sidebar's
/// list body doesn't depend on `selectedEntry` (performance audit P1). While a navigation
/// key is held down it scrolls without animation, so the animations don't pile up (P5).
struct SidebarCursorScroller: View {
    let proxy: ScrollViewProxy

    @Environment(ImageStore.self) private var store
    @Environment(ViewerState.self) private var viewer

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onChange(of: store.selectedEntry?.id) { oldID, newID in
                guard let newID else { return }
                // First image auto-selected at load time (nil → non-nil): seed the
                // shift-click anchor so shift-click works without a prior click.
                if oldID == nil { store.shiftClickAnchorID = newID }
                if viewer.takeKeyRepeat() {
                    proxy.scrollTo(newID, anchor: .center)
                } else {
                    withAnimation { proxy.scrollTo(newID, anchor: .center) }
                }
            }
    }
}
