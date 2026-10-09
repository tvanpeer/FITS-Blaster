//
//  ZoomAnchorIndicator.swift
//  FITS Blaster
//

import SwiftUI

/// A fixed-size crosshair drawn at the zoom anchor point on the image.
struct ZoomAnchorIndicator: View {
    var body: some View {
        ZStack {
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 18, height: 1)
            Rectangle()
                .fill(.white.opacity(0.9))
                .frame(width: 1, height: 18)
            Circle()
                .stroke(.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: 8, height: 8)
        }
        .shadow(color: .black.opacity(0.6), radius: 2)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
