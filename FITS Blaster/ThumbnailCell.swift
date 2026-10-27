//
//  ThumbnailCell.swift
//  FITS Blaster
//

import SwiftUI

/// One frame in the sidebar. The cursor, flag, range-selection and group-statistics state
/// come in as plain values from `ThumbnailRow`, so a cursor move or a flag only redraws
/// the cells whose values changed (CODE_AUDIT §8.1).
struct ThumbnailCell: View {
    let entry: ImageEntry
    /// The chart's metric, shown under the thumbnail (passed in, not read here: see ThumbnailSidebar).
    let metric: Metric
    let isCursor: Bool
    let isFlagged: Bool
    let isMarkedForRejection: Bool
    let groupStats: GroupStats?

    @Environment(AppSettings.self) private var settings

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
                    if let value = metric.value(from: entry.metrics) {
                        Text("\(metric.shortLabel) \(metric.formattedValue(value))")
                            .scaledFont(size: 9)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        // The setting is the thumbnail's shown width; in a sidebar dragged wider the cell
        // keeps that width and is centred, with the highlight around the thumbnail.
        .frame(maxWidth: CGFloat(settings.maxThumbnailSize))
        .padding(SidebarLayout.cellPadding)
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
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var thumbnailImage: some View {
        if entry.isProcessing {
            RoundedRectangle(cornerRadius: 4)
                .fill(.quaternary)
                .aspectRatio(1, contentMode: .fit)
                // A small spinner, animated by the system: scaling a regular one updated
                // SwiftUI on every animation frame for every loading thumbnail.
                .overlay { ProgressView().controlSize(.small) }
        } else if let thumbnail = entry.thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .rotationEffect(entry.isFlipped ? .degrees(180) : .zero)
                .clipShape(.rect(cornerRadius: 4))
                .overlay {
                    if entry.isRejected { RejectionOverlay() }
                    if isCursor { ViewportBox() }
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
/// Reads the viewport itself, so scrolling redraws only the box, not the cell.
private struct ViewportBox: View {
    @Environment(ViewerState.self) private var viewer

    var body: some View {
        let fraction = viewer.viewportFraction
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
