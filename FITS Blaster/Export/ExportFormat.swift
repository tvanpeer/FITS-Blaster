//
//  ExportFormat.swift
//  FITS Blaster
//

enum ExportFormat: String, CaseIterable {
    case plainText
    case csv
    case tsv

    var displayName: String {
        switch self {
        case .plainText: "Plain text (.txt)"
        case .csv:       "CSV (.csv)"
        case .tsv:       "Tab-separated (.tsv)"
        }
    }

    /// File extension used by the save panel and DMG builder.
    var fileExtension: String {
        switch self {
        case .plainText: "txt"
        case .csv:       "csv"
        case .tsv:       "tsv"
        }
    }

    /// Column delimiter for tabular formats. Plain text uses newlines only.
    var delimiter: String {
        switch self {
        case .plainText: "\n"
        case .csv:       ","
        case .tsv:       "\t"
        }
    }
}
