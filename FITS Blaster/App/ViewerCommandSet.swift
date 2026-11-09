//
//  ViewerCommandSet.swift
//  FITS Blaster
//

/// The zoom and pan actions of the focused window and their keys, for the View menu.
/// Equal when the keys are equal: the closures are re-created on every view update, and
/// what they act on comes from the `@Observable` objects they capture (as `FocusedAction`).
struct ViewerCommandSet: Equatable {
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let zoomToFit: () -> Void
    let actualSize: () -> Void
    let pan: (PanDirection) -> Void
    let zoomInKey: String
    let zoomOutKey: String
    let zoomToFitKey: String
    let actualSizeKey: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.zoomInKey == rhs.zoomInKey && lhs.zoomOutKey == rhs.zoomOutKey
            && lhs.zoomToFitKey == rhs.zoomToFitKey && lhs.actualSizeKey == rhs.actualSizeKey
    }
}
