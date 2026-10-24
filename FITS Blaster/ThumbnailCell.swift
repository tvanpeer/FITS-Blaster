//
//  ThumbnailCell.swift
//  FITS Blaster
//

import SwiftUI

struct ThumbnailCell: View {
    let entry: ImageEntry
    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings
    @AppStorage("sessionChartMetric") private var selectedMetric: Metric = .qualityScore

    private var isCursor: Bool { store.selectedEntry === entry }
    private var isFlagged: Bool { store.flaggedEntryIDs.contains(entry.id) }
    private var isMarkedForRejection: Bool { store.markedForRejectionIDs.contains(entry.id) }

    private var groupStats: GroupStats? {
        store.groupStatistics[entry.filterGroup]
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                ZStack(alignment: .topLeading) {
                    ZStack(alignment: .bottomLeading) {
                        thumbnailImage
                        if entry.isFlipped {
                            Image(systemName: "arrow.trianglehead.2.counterclockwise.rotate.90")
                                .foregroundStyle(.white)
                                .scaledFont(size: 10)
                                .padding(3)
                                .background(.black.opacity(0.5), in: .rect(cornerRadius: 4))
                                .padding(4)
                        }
                    }
                    if isFlagged {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.white, Color.accentColor)
                            .scaledFont(size: 14)
                            .padding(4)
                    }
                }
                if !settings.isSimpleMode, let metrics = entry.metrics, metrics.hasData {
                    let stats = groupStats
                    let problem = metrics.badgeProblem(stats: stats)
                    let topThirdFloor = stats?.topThirdScoreFloor ?? Int.max
                    QualityBadge(score: metrics.qualityScore,
                                 color: metrics.badgeColor(problem: problem,
                                                           isTopThird: metrics.qualityScore >= topThirdFloor),
                                 problem: problem,
                                 tooltipText: metrics.tooltipString)
                }
            }

            Text(entry.fileName)
                .scaledFont(size: 9)
                .lineLimit(1)
                .truncationMode(.middle)

            if !settings.isSimpleMode {
                HStack(spacing: 4) {
                    if let filter = entry.filterName {
                        Text(filter)
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if let value = selectedMetric.value(from: entry.metrics) {
                        Text("\(selectedMetric.shortLabel) \(selectedMetric.formattedValue(value))")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMarkedForRejection ? Color.orange.opacity(0.15) :
                      isCursor ? Color.accentColor.opacity(0.2) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isMarkedForRejection ? Color.orange :
                        isCursor ? Color.accentColor : Color.clear, lineWidth: 2)
        )
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if entry.isProcessing {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay { ProgressView().scaleEffect(0.6) }
        } else if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(entry.isFlipped ? .degrees(180) : .zero)
                .clipShape(.rect(cornerRadius: 4))
                .overlay {
                    if entry.isRejected { RejectionOverlay() }
                    if isCursor { ViewportBox(fraction: store.viewportFraction) }
                }
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.red)
                }
        }
    }
}

// MARK: - Viewport Box

/// Draws a yellow rectangle on the thumbnail indicating which portion of the image
/// is currently visible in the main image viewer. Only shown when zoomed in enough
/// that the viewport covers less than the full image in at least one axis.
/// Uses Canvas (no GeometryReader) since Canvas receives its size directly.
private struct ViewportBox: View {
    let fraction: CGRect

    var body: some View {
        if fraction.width < 0.99 || fraction.height < 0.99 {
            Canvas { context, size in
                let boxW = max(4, fraction.width  * size.width)
                let boxH = max(4, fraction.height * size.height)
                let boxX = fraction.origin.x * size.width
                let boxY = fraction.origin.y * size.height
                let rect = CGRect(x: boxX, y: boxY, width: boxW, height: boxH)
                context.stroke(Path(rect), with: .color(.yellow.opacity(0.9)), lineWidth: 1.5)
            }
        }
    }
}
