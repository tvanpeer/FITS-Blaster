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

        if args.isEmpty || args.contains("--help") || args.contains("-h") {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        // Folder path: first argument that starts with / or ~ (absolute path).
        // Values following flags (e.g. "3.3" after -f) are skipped correctly.
        let folderCandidates = args.indices.filter { i in
            #if BETA || DEBUG
            if i > 0, args[i - 1] == "--render" { return false }   // the --render directory
            #endif
            return true
        }.map { args[$0] }
        guard let folderStr = folderCandidates.first(where: { $0.hasPrefix("/") || $0.hasPrefix("~") }) else {
            printError("no folder path provided")
            exit(1)
        }

        let expanded = (folderStr as NSString).expandingTildeInPath
        let folderURL = URL(filePath: expanded)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            printError("'\(folderStr)' is not a directory")
            exit(1)
        }

        let options = Options(args)

        // Build AutoRejectConfig from parsed thresholds
        var config = AutoRejectConfig()
        config.mode = options.mode
        config.useFWHM         = false
        config.useEccentricity = false
        config.useStarCount    = false
        config.useSNR          = false
        config.useSkyBackground = false
        config.usePSF          = false
        config.useScore        = false

        if let v = options.fwhm {
            config.useFWHM = true
            if options.mode == .absolute { config.absoluteFWHM = v } else { config.fwhmMultiplier = v }
        }
        if let v = options.eccentricity {
            config.useEccentricity = true
            config.eccentricityThreshold = v
        }
        if let v = options.stars {
            config.useStarCount = true
            if options.mode == .absolute { config.absoluteStarCountFloor = v } else { config.starCountMultiplier = v }
        }
        if let v = options.snr {
            config.useSNR = true
            if options.mode == .absolute { config.absoluteSNRFloor = v } else { config.snrMultiplier = v }
        }
        if let v = options.skyBG {
            config.useSkyBackground = true
            if options.mode == .absolute { config.absoluteSkyBackgroundCeiling = v } else { config.skyBackgroundMultiplier = v }
        }
        if let v = options.psf {
            config.usePSF = true
            if options.mode == .absolute { config.absolutePSFFloor = v } else { config.psfMultiplier = v }
        }
        if let v = options.score {
            if options.mode == .absolute {
                config.useScore = true
                config.scoreFloor = Double(v)
            } else {
                fputs("warning: --score is only supported in absolute mode; ignored\n", stderr)
            }
        }

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
        let rejectedURLs: Set<URL> = options.includeRejected ? ImageStore.rejectedURLs(in: collected) : []

        // Load + compute metrics (full pipeline; display images are unused and discarded on exit)
        let store = ImageStore()
        #if BETA || DEBUG
        // --render needs the colour renders the app makes with Colour on.
        let debayer = options.renderURL != nil
        #else
        let debayer = false
        #endif
        store.pipeline.openFiles(collected, rejectedURLs: rejectedURLs, rootFolderName: folderURL.lastPathComponent,
                        debayerColorImages: debayer)
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

        // Filter: previewAutoReject returns the BAD frames (those failing the thresholds).
        // We export the complement — the frames that are NOT flagged as bad.
        let baseFrames = options.includeRejectedInCSV ? store.entries : store.entries.filter { !$0.isRejected }
        let frames: [ImageEntry]
        if config.anyEnabled {
            let badIDs = Set(store.previewAutoReject(config: config).map { $0.id })
            let good = baseFrames.filter { !badIDs.contains($0.id) }
            let nBad = badIDs.count
            fputs("Filtered out \(nBad) frame\(nBad == 1 ? "" : "s"); keeping \(good.count).\n", stderr)
            if good.isEmpty {
                fputs("warning: no frames passed the filter criteria; exporting all \(baseFrames.count) frame\(baseFrames.count == 1 ? "" : "s").\n", stderr)
                frames = baseFrames
            } else {
                frames = good
            }
        } else {
            frames = baseFrames
        }

        let content = ImageStore.exportContent(
            frames: frames,
            format: .csv,
            includeRejected: options.includeRejectedInCSV,
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

    // MARK: - Options

    private struct Options {
        var outputURL: URL?
        var subfolders      = false
        var includeRejected = false
        var mode: AutoRejectConfig.Mode = .relative
        var pathStyle: PathStyle = .relative
        var headerKeys: [String]?

        var includeRejectedInCSV: Bool { includeRejected }

        var fwhm:         Double?
        var eccentricity: Double?
        var stars:        Double?
        var snr:          Double?
        var skyBG:        Double?
        var psf:          Double?
        var score:        Int?

        #if BETA || DEBUG
        /// --render <dir>: write PNGs and backgrounds.csv (see CLIRenderer). Not in --help.
        var renderURL: URL?
        /// --render-typical: write only each folder's typical frame as a PNG.
        var renderTypicalOnly = false
        #endif

        init(_ args: [String]) {
            // First pass: resolve mode so metric values land in the right field
            for (i, arg) in args.enumerated() {
                if (arg == "--mode" || arg == "-m"), let val = args[safe: i + 1] {
                    mode = (val == "abs" || val == "absolute") ? .absolute : .relative
                }
            }

            // Second pass: everything else
            var i = 0
            while i < args.count {
                let arg = args[i]
                let next: String? = args[safe: i + 1]
                switch arg {
                case "--output", "-o":
                    if let v = next {
                        outputURL = URL(filePath: (v as NSString).expandingTildeInPath)
                        i += 1
                    }
                case "--subfolders", "-S":
                    subfolders = true
                case "--include-rejected", "-r":
                    includeRejected = true
                case "--mode", "-m":
                    i += 1  // already handled in first pass
                case "--path-style", "-P":
                    if let v = next {
                        pathStyle = (v == "abs" || v == "absolute") ? .absolute : .relative
                        i += 1
                    }
                case "--headers", "-H":
                    if let v = next {
                        headerKeys = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        i += 1
                    }
                case "--fwhm", "-f":
                    fwhm = next.flatMap(Double.init); if fwhm != nil { i += 1 }
                case "--eccentricity", "-e":
                    eccentricity = next.flatMap(Double.init); if eccentricity != nil { i += 1 }
                case "--stars", "-n":
                    stars = next.flatMap(Double.init); if stars != nil { i += 1 }
                case "--snr", "-s":
                    snr = next.flatMap(Double.init); if snr != nil { i += 1 }
                case "--sky-bg", "-b":
                    skyBG = next.flatMap(Double.init); if skyBG != nil { i += 1 }
                case "--psf", "-p":
                    psf = next.flatMap(Double.init); if psf != nil { i += 1 }
                case "--score", "-q":
                    score = next.flatMap(Int.init); if score != nil { i += 1 }
                #if BETA || DEBUG
                case "--render":
                    if let v = next {
                        renderURL = URL(filePath: (v as NSString).expandingTildeInPath)
                        i += 1
                    }
                case "--render-typical":
                    renderTypicalOnly = true
                #endif
                default:
                    break
                }
                i += 1
            }
        }
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

// MARK: - AutoRejectConfig helpers

private extension AutoRejectConfig {
    var anyEnabled: Bool {
        useFWHM || useEccentricity || useStarCount || useSNR || useSkyBackground || usePSF || useScore
    }
}

// MARK: - Array safe subscript

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
#endif
