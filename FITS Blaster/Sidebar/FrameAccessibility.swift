//
//  FrameAccessibility.swift
//  FITS Blaster
//
//  What VoiceOver says for a frame (step 10d, CODE_AUDIT §8.2): the thumbnail's one label
//  and the main image's label, built from plain values so they can be tested without a view.
//

import Foundation

enum FrameAccessibility {

    /// How far a thumbnail has loaded.
    enum LoadState: Sendable { case loading, loaded, failed }

    /// What a thumbnail shows, for its label.
    struct Thumbnail {
        var fileName: String
        var filter: String?
        /// The badge's score; nil when no badge is shown (Simple mode, no metrics).
        var score: Int?
        var problem: BadgeProblem?
        var isTopThird = false
        var isFlagged = false
        var isRejected = false
        var isFlipped = false
        var loadState = LoadState.loaded

        /// "M31_0001.fits, filter L, score 72, top third, flagged". The score parts only
        /// with a badge; a badge problem replaces "top third", as on the badge.
        var label: String {
            var parts = [fileName]
            if let filter { parts.append("filter \(filter)") }
            switch loadState {
            case .loading: parts.append("loading")
            case .failed:  parts.append("could not load")
            case .loaded:  break
            }
            if let score {
                parts.append("score \(score)")
                if let problem {
                    parts.append(FrameAccessibility.spokenProblem(problem))
                } else if isTopThird {
                    parts.append("top third")
                }
            }
            if isFlagged { parts.append("flagged") }
            if isRejected { parts.append("rejected") }
            if isFlipped { parts.append("flipped") }
            return parts.joined(separator: ", ")
        }
    }

    /// The main image's label: "Frame, M31_0001.fits, flagged, rejected".
    static func mainImageLabel(fileName: String, isFlagged: Bool, isRejected: Bool) -> String {
        var parts = ["Frame", fileName]
        if isFlagged { parts.append("flagged") }
        if isRejected { parts.append("rejected") }
        return parts.joined(separator: ", ")
    }

    /// A folder header in the thumbnail list: "Folder B, 20 frames". Whether it is open
    /// is its accessibility value, `folderHeaderValue`.
    static func folderHeaderLabel(name: String, frameCount: Int) -> String {
        "Folder \(name), \(frameCount) \(frameCount == 1 ? "frame" : "frames")"
    }

    /// "expanded" or "collapsed", read after the folder header's label.
    static func folderHeaderValue(isCollapsed: Bool) -> String {
        isCollapsed ? "collapsed" : "expanded"
    }

    /// A filter header in the thumbnail list: "Filter L, 12 frames, median FWHM 3.2 pixels,
    /// median score 72". The medians only where the header shows them.
    static func filterHeaderLabel(group: FilterGroup, frameCount: Int, medianFWHM: Double? = nil,
                                  medianScore: Double? = nil, locale: Locale = .current) -> String {
        var parts = [group == .unfiltered ? "Unfiltered" : "Filter \(group.rawValue)",
                     "\(frameCount) \(frameCount == 1 ? "frame" : "frames")"]
        if let medianFWHM {
            let text = medianFWHM.formatted(.number.precision(.fractionLength(1)).locale(locale))
            parts.append("median FWHM \(text) pixels")
        }
        if let medianScore {
            let text = medianScore.formatted(.number.precision(.fractionLength(0)).locale(locale))
            parts.append("median score \(text)")
        }
        return parts.joined(separator: ", ")
    }

    /// A badge problem as the FAQ names it.
    static func spokenProblem(_ problem: BadgeProblem) -> String {
        switch problem {
        case .trailing:  "trailing stars"
        case .focusFail: "focus problem"
        case .lowStars:  "low star count"
        }
    }
}
