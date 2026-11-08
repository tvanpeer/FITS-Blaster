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

    // MARK: - Entry point

    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains(where: CLIArguments.helpFlags.contains) {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        let options: CLIArguments
        do {
            options = try CLIArguments.parse(args, currentDirectory: .currentDirectory())
        } catch {
            printError(error.message)
            exit(1)
        }
        let folderStr = options.folderArgument
        let folderURL = options.folder
        guard CLIArguments.isFolder(folderURL) else {
            printError("'\(folderStr)' is not a directory")
            exit(1)
        }

        let config = options.autoRejectConfig

        // Scan
        fputs("Scanning \(folderURL.lastPathComponent)…\n", stderr)

        let collected = ImageStore.collectFITSURLs(
            in: folderURL,
            relativePath: "",
            excludedNames: [],
            includeSubfolders: options.subfolders,
            includeRejected: options.includeRejected)

        guard !collected.isEmpty else {
            // Check whether the directory itself is inaccessible — a common cause is macOS TCC
            // blocking access to iCloud Drive (~/Library/Mobile Documents/…). Fix: grant
            // FITS Blaster Full Disk Access in System Settings → Privacy & Security.
            if (try? FileManager.default.contentsOfDirectory(
                    at: folderURL, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) == nil {
                fputs("""
                    error: cannot read '\(folderStr)' — permission denied.
                    If the folder is on iCloud Drive, grant FITS Blaster Full Disk Access in
                    System Settings → Privacy & Security → Full Disk Access.
                    """, stderr)
                exit(1)
            }
            printError("no FITS files found in '\(folderStr)'")
            exit(1)
        }
        fputs("Found \(collected.count) file\(collected.count == 1 ? "" : "s"). Computing metrics…\n", stderr)

        // The same rule as Open Folder in the app.
        let rejectedURLs: Set<URL> = options.includeRejected ? RejectedFolder.rejectedURLs(in: collected) : []

        // Load + compute metrics. Without --render nothing is shown, so the pipeline makes no
        // display images or thumbnails and skips the grey normalisation re-read (§7.7).
        let store = ImageStore()
        #if BETA || DEBUG
        // --render needs the images, with the colour renders the app makes with Colour on.
        let render = options.renderURL != nil
        #else
        let render = false
        #endif
        store.pipeline.openFiles(collected, rejectedURLs: rejectedURLs, rootFolderName: folderURL.lastPathComponent,
                        debayerColorImages: render, rendersImages: render)
        await store.pipeline.waitForProcessing()
        fputs("Done.\n", stderr)

        #if BETA || DEBUG
        if let renderURL = options.renderURL {
            do {
                let count = try CLIRenderer.write(store.entries, to: renderURL, typicalOnly: options.renderTypicalOnly)
                fputs("Rendered \(count) PNG\(count == 1 ? "" : "s") → \(renderURL.path(percentEncoded: false))\n", stderr)
            } catch {
                fputs("error: could not write renders to '\(renderURL.path(percentEncoded: false))': \(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }
        #endif

        // Resolve output URL
        let csvURL = options.outputURL ?? folderURL.appending(component: "frames.csv")

        let frames = framesToExport(from: store, config: config, includeRejected: options.includeRejected)

        let content = ImageStore.exportContent(
            frames: frames,
            format: .csv,
            includeRejected: options.includeRejected,
            headerKeys: options.headerKeys ?? ExportHeaderKeys.defaults,
            pathStyle: options.pathStyle)

        do {
            try content.write(to: csvURL, atomically: true, encoding: .utf8)
        } catch {
            fputs("error: could not write '\(csvURL.path(percentEncoded: false))': \(error.localizedDescription)\n", stderr)
            exit(2)
        }

        print(csvURL.path(percentEncoded: false))
        fputs("Exported \(frames.count) row\(frames.count == 1 ? "" : "s") → \(csvURL.lastPathComponent)\n", stderr)
    }

    /// The frames for the CSV: without filter checks every frame (rejected ones only with
    /// -r); with checks the frames that pass them.
    private static func framesToExport(from store: ImageStore, config: AutoRejectConfig,
                                       includeRejected: Bool) -> [ImageEntry] {
        // Filter: previewAutoReject returns the BAD frames (those failing the thresholds).
        // We export the complement — the frames that are NOT flagged as bad.
        let baseFrames = includeRejected ? store.entries : store.entries.filter { !$0.isRejected }
        if config.isAnyCheckOn {
            let badIDs = Set(store.previewAutoReject(config: config).map { $0.id })
            let good = baseFrames.filter { !badIDs.contains($0.id) }
            let nBad = badIDs.count
            fputs("Filtered out \(nBad) frame\(nBad == 1 ? "" : "s"); keeping \(good.count).\n", stderr)
            if config.isAnyRelativeCheckOn {
                for (group, count) in store.groupsTooSmallForRelativeChecks {
                    fputs("""
                        note: filter group \(group.rawValue): \(count) frame\(count == 1 ? "" : "s"), relative checks \
                        skipped (they need at least \(GroupStats.minimumFramesForRelativeChecks)).\n
                        """, stderr)
                }
            }
            if good.isEmpty {
                fputs("warning: no frames passed the filter criteria; exporting all \(baseFrames.count) frame\(baseFrames.count == 1 ? "" : "s").\n", stderr)
                return baseFrames
            }
            return good
        }
        return baseFrames
    }

    // MARK: - Helpers

    private static func printError(_ message: String) {
        fputs("error: \(message)\nRun with --help for usage.\n", stderr)
    }

    private static func printUsage() {
        fputs("""
        Usage: FITS\\ Blaster.app/Contents/MacOS/FITS\\ Blaster <folder> [options]

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

        When filter criteria are given, only the best frames are exported.

          -P, --path-style rel|abs    Path format in CSV  [default: relative]
          -H, --headers KEY1,KEY2,…   FITS header columns to include

          -h, --help                  Show this help

        Progress is written to stderr. The CSV path is written to stdout.

        """, stderr)
    }
}

#endif
