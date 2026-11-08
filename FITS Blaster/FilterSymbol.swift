//
//  FilterSymbol.swift
//  FITS Blaster
//
//  The session chart's dot shape per filter group while macOS "Differentiate without color"
//  is on (step 10d): eight solid shapes and five outlined ones, one per group, the same in
//  every session. The legend draws the same shape.
//

import Charts
import SwiftUI

enum FilterSymbol: CaseIterable, Sendable {
    case circle, square, triangle, diamond, pentagon, plus, cross, asterisk
    case circleOutline, squareOutline, triangleOutline, diamondOutline, pentagonOutline

    /// The outline's line width in the chart and the legend.
    static let outlineWidth: CGFloat = 2

    /// The shape for Swift Charts' `.symbol(_:)`; also a SwiftUI shape for the legend.
    var shape: AnyChartSymbolShape {
        switch self {
        case .circle:          AnyChartSymbolShape(BasicChartSymbolShape.circle)
        case .square:          AnyChartSymbolShape(BasicChartSymbolShape.square)
        case .triangle:        AnyChartSymbolShape(BasicChartSymbolShape.triangle)
        case .diamond:         AnyChartSymbolShape(BasicChartSymbolShape.diamond)
        case .pentagon:        AnyChartSymbolShape(BasicChartSymbolShape.pentagon)
        case .plus:            AnyChartSymbolShape(BasicChartSymbolShape.plus)
        case .cross:           AnyChartSymbolShape(BasicChartSymbolShape.cross)
        case .asterisk:        AnyChartSymbolShape(BasicChartSymbolShape.asterisk)
        case .circleOutline:   AnyChartSymbolShape(BasicChartSymbolShape.circle.strokeBorder(lineWidth: Self.outlineWidth))
        case .squareOutline:   AnyChartSymbolShape(BasicChartSymbolShape.square.strokeBorder(lineWidth: Self.outlineWidth))
        case .triangleOutline: AnyChartSymbolShape(BasicChartSymbolShape.triangle.strokeBorder(lineWidth: Self.outlineWidth))
        case .diamondOutline:  AnyChartSymbolShape(BasicChartSymbolShape.diamond.strokeBorder(lineWidth: Self.outlineWidth))
        case .pentagonOutline: AnyChartSymbolShape(BasicChartSymbolShape.pentagon.strokeBorder(lineWidth: Self.outlineWidth))
        }
    }

    /// Dot sizes (Swift Charts symbol area) while the shapes are shown: larger than the
    /// plain dots (28, cursor 40), so the shapes can be told apart.
    static let dotSize: CGFloat = 50
    static let cursorDotSize: CGFloat = 70
}

extension FilterGroup {
    /// The chart's dot shape for this group (Tom, 2026-11-07): the common filters get the
    /// solid shapes, the multi-narrowband groups and Unfiltered the outlines.
    var chartSymbol: FilterSymbol {
        switch self {
        case .luminance:  .circle
        case .red:        .square
        case .green:      .triangle
        case .blue:       .diamond
        case .ha:         .pentagon
        case .oiii:       .plus
        case .sii:        .cross
        case .hbeta:      .asterisk
        case .ho:         .circleOutline
        case .so:         .squareOutline
        case .sho:        .triangleOutline
        case .quadNB:     .diamondOutline
        case .unfiltered: .pentagonOutline
        }
    }
}
