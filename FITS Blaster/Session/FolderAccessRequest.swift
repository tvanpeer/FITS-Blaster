//
//  FolderAccessRequest.swift
//  FITS Blaster
//
//  A folder the sandbox hasn't granted, needed to reject frames (CODE_AUDIT §5.13).
//

import Foundation

/// Set by the store when rejecting needs access to a folder it doesn't have — frames
/// dropped as single files in the sandboxed App Store build. ContentView asks the user
/// (`FileDialogs.requestFolderAccess`) and answers with `grantFolderAccess(_:)` or
/// `cancelFolderAccessRequest()`.
struct FolderAccessRequest: Equatable {
    /// The folder the frames are in; REJECTED is created inside it.
    let folder: URL
    /// The frames waiting to be rejected once access is granted.
    let entryIDs: [UUID]
}
