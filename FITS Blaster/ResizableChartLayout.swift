//
//  ResizableChartLayout.swift
//  FITS Blaster
//

import SwiftUI

/// A VStack containing the main image and session chart, separated by a draggable
/// handle that persists the chart height across launches via AppStorage.
struct ResizableChartLayout: View {
    @Environment(ImageStore.self) private var store
    @AppStorage("sessionChartHeight") private var chartHeight: Double = 200

    @State private var heightAtDragStart: Double = 200

    var body: some View {
        VStack(spacing: 0) {
            MainContent(store: store)
                .frame(minHeight: 180)

            Rectangle()
                .fill(.quinary)
                .frame(height: 5)
                .overlay {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.quaternary)
                        .frame(width: 32, height: 3)
                }
                .onHover { inside in
                    if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                }
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            chartHeight = max(80, min(600,
                                heightAtDragStart - value.translation.height))
                        }
                        .onEnded { _ in
                            heightAtDragStart = chartHeight
                        }
                )

            SessionChartView()
                .frame(height: chartHeight)
        }
        .onAppear { heightAtDragStart = chartHeight }
    }
}
