//
//  CLIRunner.swift
//  FITS Blaster
//
//  Headless batch-processing entry point. Invoked when the binary is launched
//  from a terminal with a folder path argument. Computes metrics, optionally
//  filters frames by quality criteria, and writes a CSV identical to the in-app export.
//
//  File access notes:
//  - The direct-distribution build has com.apple.security.app-sandbox removed from
//    FITS Blaster.entitlements so arbitrary paths can be opened.
//  - macOS TCC still protects iCloud Drive (~/Library/Mobile Documents/…). Grant FITS
//    Blaster Full Disk Access in System Settings → Privacy & Security → Full Disk Access
//    to allow CLI access to iCloud Drive folders.
//  - CLI mode is excluded from App Store builds via #if !APPSTORE.
//

#if !APPSTORE
import Foundation

@MainActor
enum CLIRunner {

    /// The CSV text and how it came about.
    private struct CSVExport {
        let content: String
        let rows: Int
        /// Filter checks were given and no frame passed them: the CSV has only the header row.
        let nothingPassed: Bool
    }

    // MARK: - Entry point

    /// Runs the CLI with `args` (without the program name) and returns the exit code
    /// (step 12b, CODE_AUDIT §5.11, §5.12).
    static func run(arguments args: [String], currentDirectory: URL) async -> CLIExitCode {
        if args.isEmpty || args.contains(where: CLIArguments.helpFlags.contains) {
            printUsage()
            return args.isEmpty ? .usage : .success
        }
        let options: CLIArguments
        do {
            options = try CLIArguments.parse(args, currentDirectory: currentDirectory)
        } catch {
            printError(error.message)
            return .usage
        }
        guard CLIArguments.isFolder(options.folder) else {
            printError("'\(options.folderArgument)' is not a directory")
            return .usage
        }
        guard let collected = scan(options) else { return .usage }
        let store = await measure(collected, options: options)

        #if BETA || DEBUG
        if let renderURL = options.renderURL,
           !writeRenders(store.entries, to: renderURL, typicalOnly: options.renderTypicalOnly) {
            return .writeFailed
        }
        #endif

        let unreadable = unreadableFiles(in: store)
        report(unreadable)
        let export = csv(for: store, options: options)
        let csvURL = options.outputURL ?? options.folder.appending(component: "frames.csv")
        do {
            try export.content.write(to: csvURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("error: could not write '\(csvURL.path(percentEncoded: false))': \(error.localizedDescription)\n", stderr)
            return .writeFailed
        }
        print(csvURL.path(percentEncoded: false))
        fputs("Exported \(plural(export.rows, "row")) → \(csvURL.lastPathComponent)\n", stderr)

        if export.nothingPassed { return .nothingPassed }
        return unreadable.isEmpty ? .success : .unreadableFiles
    }

    // MARK: - Scan and measure

    /// The FITS files in the folder; nil (with the error printed) when there are none or
    /// the folder can't be read.
    private static func scan(_ options: CLIArguments) -> [(url: URL, subfolderPath: String)]? {
        fputs("Scanning \(options.folder.lastPathComponent)…\n", stderr)
        let collected = ImageStore.collectFITSURLs(
            in: options.folder,
            relativePath: "",
            excludedNames: [],
            includeSubfolders: options.subfolders,
            includeRejected: options.includeRejected)
        guard collected.isEmpty else {
            fputs("Found \(plural(collected.count, "file")). Computing metrics…\n", stderr)
            return collected
        }
        // Check whether the directory itself is inaccessible — a common cause is macOS TCC
        // blocking access to iCloud Drive (~/Library/Mobile Documents/…). Fix: grant
        // FITS Blaster Full Disk Access in System Settings → Privacy & Security.
        if (try? FileManager.default.contentsOfDirectory(
                at: options.folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) == nil {
            fputs("""
                error: cannot read '\(options.folderArgument)' — permission denied.
                If the folder is on iCloud Drive, grant FITS Blaster Full Disk Access in
                System Settings → Privacy & Security → Full Disk Access.

                """, stderr)
        } else {
            printError("no FITS files found in '\(options.folderArgument)'")
        }
        return nil
    }

    /// Loads the files and computes the metrics. Without --render nothing is shown, so the
    /// pipeline makes no display images or thumbnails and skips the grey normalisation
    /// re-read (§7.7).
    private static func measure(_ collected: [(url: URL, subfolderPath: String)],
                                options: CLIArguments) async -> ImageStore {
        // The same rule as Open Folder in the app.
        let rejectedURLs: Set<URL> = options.includeRejected ? RejectedFolder.rejectedURLs(in: collected) : []
        let store = ImageStore()
        #if BETA || DEBUG
        // --render needs the images, with the colour renders the app makes with Colour on.
        let render = options.renderURL != nil
        #else
        let render = false
        #endif
        store.pipeline.openFiles(collected, rejectedURLs: rejectedURLs, rootFolderName: options.folder.lastPathComponent,
                                 debayerColorImages: render, rendersImages: render)
        await store.pipeline.waitForProcessing()
        fputs("Done.\n", stderr)
        return store
    }

    #if BETA || DEBUG
    /// --render: PNGs and backgrounds.csv. False (with the error printed) when they can't be written.
    private static func writeRenders(_ entries: [ImageEntry], to renderURL: URL, typicalOnly: Bool) -> Bool {
        do {
            let count = try CLIRenderer.write(entries, to: renderURL, typicalOnly: typicalOnly)
            fputs("Rendered \(plural(count, "PNG")) → \(renderURL.path(percentEncoded: false))\n", stderr)
            return true
        } catch {
            fputs("error: could not write renders to '\(renderURL.path(percentEncoded: false))': \(error.localizedDescription)\n", stderr)
            return false
        }
    }
    #endif

    // MARK: - Files that could not be read

    /// The files without measurements (they could not be read), then the files left out
    /// because of their format (floating-point or multi-channel stacks), with the reason.
    static func unreadableFiles(in store: ImageStore) -> [(fileName: String, reason: String)] {
        let failed = store.entries.filter { $0.metrics == nil }
            .map { (fileName: $0.fileName, reason: $0.errorMessage ?? "could not be measured") }
        let skipped = store.pipeline.skippedUnsupported
            .map { (fileName: $0.fileName, reason: "floating-point or multi-channel stack, not supported") }
        return failed + skipped
    }

    /// "warning: 2 files could not be read:", one line per file (at most `maxListed`),
    /// then "and N more".
    static func unreadableMessage(_ files: [(fileName: String, reason: String)], maxListed: Int = 10) -> String {
        var lines = ["warning: \(plural(files.count, "file")) could not be read:"]
        lines += files.prefix(maxListed).map { "  \($0.fileName) — \($0.reason)" }
        if files.count > maxListed { lines.append("  and \(files.count - maxListed) more") }
        return lines.joined(separator: "\n")
    }

    private static func report(_ unreadable: [(fileName: String, reason: String)]) {
        guard !unreadable.isEmpty else { return }
        fputs(unreadableMessage(unreadable) + "\n", stderr)
    }

    // MARK: - CSV

    /// The CSV: every frame without filter checks (rejected ones only with -r); with checks
    /// the frames that pass them. When none passes, only the header row, with the columns
    /// all frames would have had.
    private static func csv(for store: ImageStore, options: CLIArguments) -> CSVExport {
        let config = options.autoRejectConfig
        let baseFrames = options.includeRejected ? store.entries : store.entries.filter { !$0.isRejected }
        let frames = config.isAnyCheckOn ? passingFrames(baseFrames, store: store, config: config) : baseFrames
        let nothingPassed = config.isAnyCheckOn && frames.isEmpty
        if nothingPassed {
            fputs("warning: no frame passes the filter; the CSV has only the header row.\n", stderr)
        }
        let table = ExportTable(frames: nothingPassed ? baseFrames : frames, includeRejected: options.includeRejected,
                                headerKeys: options.headerKeys ?? ExportHeaderKeys.defaults,
                                pathStyle: options.pathStyle)
        return CSVExport(content: table.delimited(.csv, includesRows: !nothingPassed),
                         rows: nothingPassed ? 0 : frames.count, nothingPassed: nothingPassed)
    }

    /// The frames that pass the checks. Files that could not be read have no measurements
    /// to judge, so they are left out too, with a note (Tom, 2026-11-08; before, they passed).
    private static func passingFrames(_ baseFrames: [ImageEntry], store: ImageStore,
                                      config: AutoRejectConfig) -> [ImageEntry] {
        // previewAutoReject returns the frames that fail the checks.
        let badIDs = Set(store.previewAutoReject(config: config).map(\.id))
        let unmeasured = baseFrames.filter { $0.metrics == nil }
        let good = baseFrames.filter { !badIDs.contains($0.id) && $0.metrics != nil }
        fputs("Filtered out \(plural(badIDs.count, "frame")); keeping \(good.count).\n", stderr)
        if !unmeasured.isEmpty {
            fputs("note: left out of the CSV: \(plural(unmeasured.count, "file")) that could not be read.\n", stderr)
        }
        if config.isAnyRelativeCheckOn {
            for (group, count) in store.groupsTooSmallForRelativeChecks {
                fputs("""
                    note: filter group \(group.rawValue): \(plural(count, "frame")), relative checks \
                    skipped (they need at least \(GroupStats.minimumFramesForRelativeChecks)).\n
                    """, stderr)
            }
        }
        return good
    }

    // MARK: - Helpers

    /// "1 frame", "3 frames".
    private static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    private static func printError(_ message: String) {
        fputs("error: \(message)\nRun with --help for usage.\n", stderr)
    }

    private static func printUsage() {
        fputs("""
        Usage: FITS\\ Blaster.app/Contents/MacOS/FITS\\ Blaster <folder> [options]

        The folder can be absolute, start with ~, or be relative to the current folder.

          -o, --output <path>         CSV output file  [default: <folder>/frames.csv]
          -S, --subfolders            Include files from subfolders
          -r, --include-rejected      Scan REJECTED folder; include those files in CSV with status=rejected

          -m, --mode rel|abs          Filter threshold mode  [default: relative]
          -f, --fwhm <n>              FWHM: multiplier (rel) or pixel ceiling (abs)
          -e, --eccentricity <n>      Eccentricity ceiling  [same in both modes]
          -n, --stars <n>             Star count: multiplier (rel) or floor (abs)
          -s, --snr <n>               SNR: multiplier (rel) or floor (abs)
          -b, --sky-bg <n>            Sky BG: multiplier (rel) or ADU ceiling (abs)
          -p, --psf <n>               PSF weight: multiplier (rel) or floor (abs)
          -q, --score <n>             Quality score floor  [absolute mode only]

        When filter criteria are given, only the frames that pass every check are exported;
        files that could not be read are left out.

          -P, --path-style rel|abs    Path format in CSV  [default: relative]
          -H, --headers KEY1,KEY2,…   FITS header columns to include

          -h, --help                  Show this help

        Progress is written to stderr. The CSV path is written to stdout.

        Exit codes:
          0  done
          1  usage error, or the folder is missing, can't be read or has no FITS files
          2  the CSV could not be written
          3  no frame passes the filter; the CSV has only the header row
          4  the CSV was written, but some files could not be read (listed on stderr)

        """, stderr)
    }
}

#endif
