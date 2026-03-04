//
//  RatingView.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// Interactive 1–5 star rating control.
/// Clicking a filled star that is already the current rating clears the rating.
struct RatingView: View {
    let currentRating: Int
    let onRate: (Int) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { star in
                Button("", systemImage: star <= currentRating ? "star.fill" : "star") {
                    onRate(star == currentRating ? 0 : star)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(star <= currentRating ? Color.yellow : Color.secondary)
            }
        }
    }
}
