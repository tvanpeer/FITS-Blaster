//
//  TooltipView.swift
//  FITS Blaster
//

import SwiftUI

/// SwiftUI's `.help()` modifier loses its tooltip state whenever `@Observable`
/// properties trigger a view re-render. This modifier uses `NSView.toolTip`
/// directly, which survives SwiftUI view updates. The underlying NSView returns
/// `nil` from `hitTest(_:)` so all mouse events pass through to the SwiftUI
/// content underneath.
class TooltipNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

struct TooltipOverlay: NSViewRepresentable {
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
