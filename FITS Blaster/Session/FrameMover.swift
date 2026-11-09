//
//  FrameMover.swift
//  FITS Blaster
//
//  The file work of a batch reject or undo, off the main actor, so a large batch on a
//  network share doesn't freeze the window (step 11b, CODE_AUDIT §5.14).
//

import Foundation

enum FrameMover {

    /// Why a file could not be moved.
    struct Failure: Sendable {
        let reason: String
        /// A "no permission" error: in the sandboxed build the folder can still be granted.
        let permissionDenied: Bool
    }

    /// Moves one file. With `createsFolder` the destination folder (REJECTED) is created
    /// first when it doesn't exist. Returns nil when the file was moved.
    @concurrent static func move(from source: URL, to destination: URL, createsFolder: Bool) async -> Failure? {
        do {
            let folder = destination.deletingLastPathComponent()
            if createsFolder, ImageStore.isDirectory(folder) == nil {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try FileManager.default.moveItem(at: source, to: destination)
            return nil
        } catch {
            return failure(moving: source, error: error)
        }
    }

    /// A short reason for a failed move, without the file name (the message already has it).
    /// FileManager's own text names the file twice and blames the destination folder for a
    /// file locked in Finder, so a locked file is checked first.
    nonisolated static func failure(moving source: URL, error: Error) -> Failure {
        // Read from the disk, not URL resource values: the URL may hold values cached by the folder scan.
        let attributes = try? FileManager.default.attributesOfItem(atPath: source.path(percentEncoded: false))
        if attributes?[.immutable] as? Bool == true {
            return Failure(reason: "the file is locked (Finder: Get Info → Locked)", permissionDenied: false)
        }
        let permissionDenied = ImageStore.isPermissionDenied(error)
        let reason: String
        if permissionDenied {
            reason = "no permission to change this folder"
        } else if hasCode(error, cocoa: NSFileWriteFileExistsError, posix: EEXIST) {
            reason = "a file with this name is already there"
        } else if hasCode(error, cocoa: NSFileNoSuchFileError, posix: ENOENT) {
            reason = "the file is no longer there"
        } else {
            reason = error.localizedDescription
        }
        return Failure(reason: reason, permissionDenied: permissionDenied)
    }

    /// True when `error`, or an error underneath it, has the Cocoa or POSIX code.
    private nonisolated static func hasCode(_ error: Error, cocoa: Int, posix: Int32) -> Bool {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == cocoa { return true }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(posix) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error { return hasCode(underlying, cocoa: cocoa, posix: posix) }
        return false
    }

    /// Removes each REJECTED folder that is empty after an undo (`ImageStore.removeFolderIfEmpty`).
    @concurrent static func removeFoldersIfEmpty(_ folders: [URL]) async {
        for folder in folders { ImageStore.removeFolderIfEmpty(folder) }
    }
}
