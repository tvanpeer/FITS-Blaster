//
//  CLIRunner.swift
//  FITS Blaster
//
//  Headless batch-processing entry point. Invoked when the binary is launched
//  from a terminal with a folder path argument. Computes metrics, optionally
//  auto-flags frames, and writes a CSV identical to the in-app export.
//
//  Sandbox note: the direct-distribution build must remove com.apple.security.app-sandbox
//  (or add com.apple.security.files.all) from FITS Blaster.entitlements for arbitrary
//  path access to work. CLI mode is excluded from App Store builds via #if !APPSTORE.
//

#if !APPSTORE
import Foundation

@MainActor
enum CLIRunner {

    // MARK: - Entry point

    static func run() async {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.isEmpty || args.contains("--help") {
            printUsage()
            exit(args.isEmpty ? 1 : 0)
        }

        // Folder path: first argument that doesn't start with --
        guard let folderStr = args.first(where: { !$0.hasPrefix("--") }) else {
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
            if options.mode == .absolute { config.absoluteStarCountFloor = Int(v) } else { config.starCountMultiplier = v }
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
                config.scoreFloor = v
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
            printError("no FITS files found in '\(folderStr)'")
            exit(1)
        }
        fputs("Found \(collected.count) file\(collected.count == 1 ? "" : "s"). Computing metrics…\n", stderr)

        // Mirror the rejectedURLs logic from openFolderPanel
        let rejectedURLs: Set<URL> = options.includeRejected
            ? Set(collected.filter {
                $0.url.deletingLastPathComponent().lastPathComponent
                    .caseInsensitiveCompare("REJECTED") == .orderedSame
              }.map { $0.url })
            : []

        // Load + compute metrics (full pipeline; display images are unused and discarded on exit)
        let store = ImageStore()
        store.openFiles(collected, rejectedURLs: rejectedURLs, rootFolderName: folderURL.lastPathComponent)
        await store.waitForProcessing()
        fputs("Done.\n", stderr)

        // Autoflag
        let doFlag = !options.noFlag && config.anyEnabled
        if doFlag {
            store.applyAutoFlag(config: config)
            let n = store.flaggedEntryIDs.count
            fputs("Flagged \(n) frame\(n == 1 ? "" : "s").\n", stderr)
        }

        // Resolve output URL
        let csvURL = options.outputURL ?? folderURL.appending(component: "frames.csv")

        // Export
        let frames = options.includeRejectedInCSV ? store.entries : store.entries.filter { !$0.isRejected }
        let content = ImageStore.exportContent(
            frames: frames,
            format: .csv,
            includeRejected: options.includeRejectedInCSV,
            headerKeys: options.headerKeys ?? defaultHeaderKeys,
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
        var subfolders        = false
        var includeRejected   = false
        var mode: AutoRejectConfig.Mode = .relative
        var noFlag            = false
        var pathStyle: PathStyle = .relative
        var headerKeys: [String]?
        var includeRejectedInCSV = false

        var fwhm:         Double?
        var eccentricity: Double?
        var stars:        Double?
        var snr:          Double?
        var skyBG:        Double?
        var psf:          Double?
        var score:        Int?

        init(_ args: [String]) {
            // First pass: resolve mode so metric values land in the right field
            for (i, arg) in args.enumerated() {
                if arg == "--mode", let val = args[safe: i + 1] {
                    mode = (val == "abs" || val == "absolute") ? .absolute : .relative
                }
            }

            // Second pass: everything else
            var i = 0
            while i < args.count {
                let arg = args[i]
                let next: String? = args[safe: i + 1]
                switch arg {
                case "--output":
                    if let v = next {
                        outputURL = URL(filePath: (v as NSString).expandingTildeInPath)
                        i += 1
                    }
                case "--subfolders":
                    subfolders = true
                case "--include-rejected":
                    includeRejected = true
                case "--mode":
                    i += 1  // already handled
                case "--no-flag":
                    noFlag = true
                case "--path-style":
                    if let v = next {
                        pathStyle = (v == "abs" || v == "absolute") ? .absolute : .relative
                        i += 1
                    }
                case "--headers":
                    if let v = next {
                        headerKeys = v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
                        i += 1
                    }
                case "--include-rejected-in-csv":
                    includeRejectedInCSV = true
                case "--fwhm":
                    fwhm = next.flatMap(Double.init); if fwhm != nil { i += 1 }
                case "--eccentricity":
                    eccentricity = next.flatMap(Double.init); if eccentricity != nil { i += 1 }
                case "--stars":
                    stars = next.flatMap(Double.init); if stars != nil { i += 1 }
                case "--snr":
                    snr = next.flatMap(Double.init); if snr != nil { i += 1 }
                case "--sky-bg":
                    skyBG = next.flatMap(Double.init); if skyBG != nil { i += 1 }
                case "--psf":
                    psf = next.flatMap(Double.init); if psf != nil { i += 1 }
                case "--score":
                    score = next.flatMap(Int.init); if score != nil { i += 1 }
                default:
                    break
                }
                i += 1
            }
        }
    }

    // MARK: - Helpers

    private static let defaultHeaderKeys = [
        "OBJECT", "DATE-OBS", "EXPTIME", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP",
        "FOCUSPOS", "AIRMASS", "OBJCTALT",
        "AMBTEMP", "HUMIDITY"
    ]

    private static func printError(_ message: String) {
        fputs("error: \(message)\nRun with --help for usage.\n", stderr)
    }

    private static func printUsage() {
        fputs("""
        Usage: FITS\\ Blaster.app/Contents/MacOS/FITS\\ Blaster <folder> [options]

          --output <path>             CSV output file  [default: <folder>/frames.csv]
          --subfolders                Include files from subfolders
          --include-rejected          Include REJECTED folder; mark those files as rejected

          --mode rel|abs              Autoflag threshold mode  [default: relative]
          --fwhm <n>                  FWHM: multiplier (rel) or pixel ceiling (abs)
          --eccentricity <n>          Eccentricity ceiling  [same in both modes]
          --stars <n>                 Star count: multiplier (rel) or floor (abs)
          --snr <n>                   SNR: multiplier (rel) or floor (abs)
          --sky-bg <n>                Sky BG: multiplier (rel) or ADU ceiling (abs)
          --psf <n>                   PSF weight: multiplier (rel) or floor (abs)
          --score <n>                 Quality score floor  [absolute mode only]
          --no-flag                   Export without autoflagging

          --path-style rel|abs        Path format in CSV  [default: relative]
          --headers KEY1,KEY2,...     FITS header columns to include
          --include-rejected-in-csv   Include rejected entries in the CSV

          --help                      Show this help

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
