//
//  FileDialogs.swift
//  FITS Blaster
//
//  The open and save panels, shown from the views; the store only receives the
//  chosen URL (master-plan step 4). The panels open with `begin` instead of
//  `runModal`, so they don't block the main thread while they are up.
//

import AppKit
import UniformTypeIdentifiers

@MainActor
enum FileDialogs {
    /// Asks where to save the frame list; nil when the user cancels.
    static func chooseExportDestination(format: ExportFormat) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Export Frame List"
        panel.nameFieldStringValue = "frames.\(format.fileExtension)"
        switch format {
        case .plainText: panel.allowedContentTypes = [.plainText]
        case .csv:       panel.allowedContentTypes = [.commaSeparatedText]
        case .tsv:       panel.allowedContentTypes = [.tabSeparatedText]
        }
        guard await panel.begin() == .OK else { return nil }
        return panel.url
    }
}
