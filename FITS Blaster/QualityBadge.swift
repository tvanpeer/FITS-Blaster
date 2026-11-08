//
//  QualityBadge.swift
//  FITS Blaster
//

import SwiftUI

struct QualityBadge: View {
    let score: Int
    let color: Color
    let problem: BadgeProblem?
    /// A ★ before the score: a top-third frame with "Differentiate without color" on.
    var showsStar = false
    let tooltipText: String

    var body: some View {
        HStack(spacing: 2) {
            if let problem {
                Image(systemName: problem.systemImage)
                    .scaledFont(size: 7)
            } else if showsStar {
                Image(systemName: "star.fill")
                    .scaledFont(size: 7)
            }
            Text("\(score)")
                .scaledFont(size: 9, weight: .bold)
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 1)
        .background(color)
        .clipShape(.rect(cornerRadius: 3))
        .foregroundStyle(.white)
        .padding(4)
        .help(tooltipText)
    }
}
