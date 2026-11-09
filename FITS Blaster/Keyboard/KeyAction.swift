//
//  KeyAction.swift
//  FITS Blaster
//

/// Every configurable action a key can trigger. Each has one row in `KeyBinding.all`.
enum KeyAction: CaseIterable, Sendable {
    case selectAll, deselectAll, invertSelection, selectAllRejected
    case first, last, previous, next
    case reject, undo
    case flag, deflagAll
    case toggleMode, remove, debayer
    case playPause, flip
    case zoomIn, zoomOut, zoomToFit, zoomActualSize
}
