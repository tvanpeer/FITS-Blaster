//
//  RejectionOverlay.swift
//  FITS Blaster
//

import SwiftUI

/// Red X overlay drawn across a thumbnail to indicate a rejected frame.
/// Uses Canvas (no GeometryReader) since Canvas receives its size directly.
struct RejectionOverlay: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.move(to: CGPoint(x: size.width, y: 0))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            context.stroke(path, with: .color(.red), lineWidth: 3)
        }
    }
}
