//
//  HistogramView.swift
//  Simple Claude fits viewer
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// Canvas-based pixel histogram using log₁₊ₓ scaling so faint star
/// pixels remain visible alongside the dominant sky background peak.
struct HistogramView: View {
    let histogram: [Int]

    var body: some View {
        Canvas { context, size in
            guard !histogram.isEmpty else { return }

            let maxLog = histogram.map { log1p(Double($0)) }.max() ?? 1
            guard maxLog > 0 else { return }

            let binW = size.width / CGFloat(histogram.count)

            for (i, count) in histogram.enumerated() {
                let logH = CGFloat(log1p(Double(count)) / maxLog)
                let barH = size.height * logH
                let rect = CGRect(
                    x: CGFloat(i) * binW,
                    y: size.height - barH,
                    width: max(binW, 1),
                    height: barH
                )
                context.fill(Path(rect), with: .color(.accentColor.opacity(0.75)))
            }
        }
        .frame(height: 72)
        .clipShape(.rect(cornerRadius: 4))
    }
}
