//
//  SidebarDivider.swift
//  FITS Blaster
//
//  The line between the sidebar and the main column, which can be dragged to make the
//  sidebar wider than its natural width (the thumbnail size). The app sets the sidebar's
//  width itself: a split view kept the pane at its maximum width and couldn't be told to
//  take a new natural width when the thumbnail size changed.
//

import SwiftUI

struct SidebarDivider: View {
    /// How much wider than its natural width the sidebar is, in points.
    @Binding var extraWidth: Double
    /// The most it may be dragged wider (also limited by the window's width).
    let maxExtraWidth: Double

    @State private var dragStartExtra: Double?

    var body: some View {
        Divider()
            .overlay {
                // A wider, invisible grab area over the 1-point line.
                Color.clear
                    .frame(width: 8)
                    .contentShape(.rect)
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                let start = dragStartExtra ?? extraWidth
                                dragStartExtra = start
                                extraWidth = min(max(0, start + value.translation.width), maxExtraWidth)
                            }
                            .onEnded { _ in dragStartExtra = nil }
                    )
            }
            .zIndex(1)
            .accessibilityElement()
            .accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(extraWidth)) points wider than the thumbnails need")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: extraWidth = min(extraWidth + 20, maxExtraWidth)
                case .decrement: extraWidth = max(extraWidth - 20, 0)
                @unknown default: break
                }
            }
    }
}
