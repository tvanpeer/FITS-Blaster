//
//  CLIExitCode.swift
//  FITS Blaster
//
//  The CLI's exit codes, documented in --help (step 12b, CODE_AUDIT §5.11, §5.12).
//

#if !APPSTORE
enum CLIExitCode: Int32 {
    /// The CSV was written with every file read.
    case success = 0
    /// A usage error, or a folder that is missing, can't be read or has no FITS files.
    case usage = 1
    /// The CSV (or, in beta builds, the renders) could not be written.
    case writeFailed = 2
    /// Filter checks were given and no frame passes them: the CSV has only the header row.
    /// Wins over `unreadableFiles` (Tom, 2026-11-08).
    case nothingPassed = 3
    /// The CSV was written, but some files could not be read; they are listed on stderr.
    case unreadableFiles = 4
}
#endif
