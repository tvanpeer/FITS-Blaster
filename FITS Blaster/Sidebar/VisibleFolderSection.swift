//
//  VisibleFolderSection.swift
//  FITS Blaster
//

/// A folder section of the sidebar with only the frames currently shown (filter strip and
/// All / Flagged / Rejected applied). Built once per change by the store, so the sidebar
/// doesn't filter while it draws (CODE_AUDIT §8.5).
struct VisibleFolderSection: Identifiable {
    let folder: FolderGroup
    /// The visible frames per filter group, in canonical order; groups with none are left out.
    let filterGroups: [(group: FilterGroup, entries: [ImageEntry])]
    /// All visible frames of the folder, in sidebar order.
    let entries: [ImageEntry]

    var id: String { folder.id }
}
