//
//  FolderScanItem.swift
//  FITS Blaster
//
//  One entry of a folder as the folder scan walks it: a file, a subfolder, or a FITS file
//  from the REJECTED folder sorted in with the folder's own files (step 11).
//

import Foundation

struct FolderScanItem {
    let name: String
    let isDirectory: Bool
    /// Set for a file in the folder's REJECTED folder; `name` is its file name.
    let rejectedFile: URL?

    /// The folder's entries in name order. With `includeRejected` the FITS files in its
    /// REJECTED folder take the place of that folder, sorted in by file name, so a rejected
    /// frame keeps its place after reopening, as during the session; without it REJECTED is
    /// left out. The same name in the folder and in REJECTED: the folder's file first.
    nonisolated static func sorted(_ listing: [(name: String, isDirectory: Bool)], in folder: URL,
                                   includeRejected: Bool) -> [FolderScanItem] {
        var items: [FolderScanItem] = []
        for (name, isDirectory) in listing {
            guard isDirectory, RejectedFolder.isRejectedFolder(name: name) else {
                items.append(FolderScanItem(name: name, isDirectory: isDirectory, rejectedFile: nil))
                continue
            }
            guard includeRejected else { continue }
            let rejectedFolder = folder.appending(component: name, directoryHint: .isDirectory)
            items += ImageStore.collectFITSURLs(in: rejectedFolder, relativePath: "", excludedNames: [],
                                                includeSubfolders: false, includeRejected: false)
                .map { FolderScanItem(name: $0.url.lastPathComponent, isDirectory: false, rejectedFile: $0.url) }
        }
        return items.sorted { a, b in
            switch a.name.localizedStandardCompare(b.name) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: a.rejectedFile == nil && b.rejectedFile != nil
            }
        }
    }
}
