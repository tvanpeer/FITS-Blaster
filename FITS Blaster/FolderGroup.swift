//
//  FolderGroup.swift
//  FITS Blaster
//

/// One subfolder's worth of entries, pre-grouped by filter for sidebar rendering.
struct FolderGroup: Identifiable {
    let rootFolderName: String
    /// Qualified path: "\(rootFolderName)/\(subfolderPath)", or just subfolderPath
    /// when there is only one root folder. Used as the stable unique identifier.
    let folderPath: String
    /// Short name shown in section headers and folder pills.
    let folderDisplayName: String
    /// Entries split by their canonical filter group, in FilterGroup canonical order.
    let filterGroups: [(FilterGroup, [ImageEntry])]

    var id: String { folderPath }
    var totalCount: Int { filterGroups.reduce(0) { $0 + $1.1.count } }
}
