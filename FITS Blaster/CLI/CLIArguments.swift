//
//  CLIArguments.swift
//  FITS Blaster
//
//  The command line, read in one pass (step 12a, CODE_AUDIT §5.10, §5.12): each option
//  takes its value, exactly one argument is left, the folder (absolute, ~ or relative).
//  An unknown option or a bad value is a usage error instead of being ignored. Pure, so
//  it is tested without running the CLI; `main.swift` uses `isCLIInvocation` to decide
//  between the CLI and the window.
//

#if !APPSTORE
import Foundation

/// A problem with the command line; the message names it.
struct CLIUsageError: Error, Equatable {
    let message: String
}

struct CLIArguments {
    var folder: URL
    /// The folder as typed, for messages.
    var folderArgument: String
    var outputURL: URL?
    var subfolders = false
    var includeRejected = false
    var mode: AutoRejectConfig.Mode = .relative
    var pathStyle: PathStyle = .relative
    var headerKeys: [String]?

    var fwhm: Double?
    var eccentricity: Double?
    var stars: Double?
    var snr: Double?
    var skyBG: Double?
    var psf: Double?
    var score: Int?

    #if BETA || DEBUG
    /// --render <dir>: write PNGs and backgrounds.csv (see CLIRenderer). Not in --help.
    var renderURL: URL?
    /// --render-typical: write only each folder's typical frame as a PNG.
    var renderTypicalOnly = false
    #endif

    /// The options that take a value.
    private enum Valued {
        case output, mode, pathStyle, headers, fwhm, eccentricity, stars, snr, skyBG, psf, score
        #if BETA || DEBUG
        case render
        #endif
    }

    /// The options without a value.
    private enum Switch {
        case subfolders, includeRejected
        #if BETA || DEBUG
        case renderTypical
        #endif
    }

    private static let valued: [String: Valued] = {
        var table: [String: Valued] = [
            "-o": .output, "--output": .output,
            "-m": .mode, "--mode": .mode,
            "-P": .pathStyle, "--path-style": .pathStyle,
            "-H": .headers, "--headers": .headers,
            "-f": .fwhm, "--fwhm": .fwhm,
            "-e": .eccentricity, "--eccentricity": .eccentricity,
            "-n": .stars, "--stars": .stars,
            "-s": .snr, "--snr": .snr,
            "-b": .skyBG, "--sky-bg": .skyBG,
            "-p": .psf, "--psf": .psf,
            "-q": .score, "--score": .score
        ]
        #if BETA || DEBUG
        table["--render"] = .render
        #endif
        return table
    }()

    private static let switches: [String: Switch] = {
        var table: [String: Switch] = [
            "-S": .subfolders, "--subfolders": .subfolders,
            "-r": .includeRejected, "--include-rejected": .includeRejected
        ]
        #if BETA || DEBUG
        table["--render-typical"] = .renderTypical
        #endif
        return table
    }()

    /// The options `--help` and `-h`; the runner checks for them before parsing.
    static let helpFlags: Set<String> = ["-h", "--help"]

    // MARK: - Parsing

    /// Reads the arguments (without the program name). Relative paths are taken from
    /// `currentDirectory`, `~` from `home`.
    static func parse(_ args: [String], currentDirectory: URL,
                      home: URL = .homeDirectory) throws(CLIUsageError) -> CLIArguments {
        var parsed = CLIArguments(folder: currentDirectory, folderArgument: "")
        var folders: [String] = []
        var i = 0
        while i < args.count {
            let arg = args[i]
            if let option = valued[arg] {
                let next = args.indices.contains(i + 1) ? args[i + 1] : nil
                // A following option is not a value: "-f -e 0.5" is a missing value for -f.
                guard let value = next, !(value.hasPrefix("-") && Double(value) == nil) else {
                    throw CLIUsageError(message: "\(arg) needs a value")
                }
                try parsed.set(option, value, flag: arg, currentDirectory: currentDirectory, home: home)
                i += 2
            } else if let option = switches[arg] {
                parsed.set(option)
                i += 1
            } else if arg.hasPrefix("-"), arg.count > 1 {
                throw CLIUsageError(message: "unknown option '\(arg)'")
            } else {
                folders.append(arg)
                i += 1
            }
        }

        guard let folder = folders.first else { throw CLIUsageError(message: "no folder given") }
        guard folders.count == 1 else {
            throw CLIUsageError(message: "more than one folder given: '\(folders[0])' and '\(folders[1])'")
        }
        if parsed.score != nil, parsed.mode != .absolute {
            throw CLIUsageError(message: "--score works only in absolute mode (-m abs)")
        }
        parsed.folderArgument = folder
        parsed.folder = fileURL(folder, currentDirectory: currentDirectory, home: home)
        return parsed
    }

    private mutating func set(_ option: Valued, _ value: String, flag: String,
                              currentDirectory: URL, home: URL) throws(CLIUsageError) {
        switch option {
        case .output: outputURL = Self.fileURL(value, currentDirectory: currentDirectory, home: home)
        case .mode: mode = try Self.isAbsolute(value, flag: flag) ? .absolute : .relative
        case .pathStyle: pathStyle = try Self.isAbsolute(value, flag: flag) ? .absolute : .relative
        case .headers: headerKeys = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        case .fwhm, .eccentricity, .stars, .snr, .skyBG, .psf:
            try setNumber(option, Self.number(value, flag: flag))
        case .score:
            guard let whole = Int(value) else {
                throw CLIUsageError(message: "\(flag) needs a whole number, not '\(value)'")
            }
            score = whole
        #if BETA || DEBUG
        case .render: renderURL = Self.fileURL(value, currentDirectory: currentDirectory, home: home)
        #endif
        }
    }

    private mutating func setNumber(_ option: Valued, _ number: Double) {
        switch option {
        case .fwhm: fwhm = number
        case .eccentricity: eccentricity = number
        case .stars: stars = number
        case .snr: snr = number
        case .skyBG: skyBG = number
        case .psf: psf = number
        default: break
        }
    }

    private mutating func set(_ option: Switch) {
        switch option {
        case .subfolders: subfolders = true
        case .includeRejected: includeRejected = true
        #if BETA || DEBUG
        case .renderTypical: renderTypicalOnly = true
        #endif
        }
    }

    /// `rel`/`relative` or `abs`/`absolute` (any case), for `-m` and `-P`.
    static func isAbsolute(_ value: String, flag: String) throws(CLIUsageError) -> Bool {
        switch value.lowercased() {
        case "abs", "absolute": true
        case "rel", "relative": false
        default: throw CLIUsageError(message: "\(flag) takes rel or abs, not '\(value)'")
        }
    }

    private static func number(_ value: String, flag: String) throws(CLIUsageError) -> Double {
        guard let number = Double(value), number.isFinite else {
            throw CLIUsageError(message: "\(flag) needs a number, not '\(value)'")
        }
        return number
    }

    /// A path as typed: absolute, `~` or `~/…` (the home folder), or relative to `currentDirectory`.
    static func fileURL(_ path: String, currentDirectory: URL, home: URL = .homeDirectory) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home.appending(path: String(path.dropFirst(2))) }
        if path.hasPrefix("/") { return URL(filePath: path) }
        return currentDirectory.appending(path: path).standardized
    }

    // MARK: - Filter

    /// The Auto-Flag checks given on the command line, with their values in the chosen
    /// mode; every other check off.
    var autoRejectConfig: AutoRejectConfig {
        var config = AutoRejectConfig.allDisabled
        config.mode = mode
        let absolute = mode == .absolute
        if let fwhm {
            config.useFWHM = true
            if absolute { config.absoluteFWHM = fwhm } else { config.fwhmMultiplier = fwhm }
        }
        if let eccentricity {
            config.useEccentricity = true
            config.eccentricityThreshold = eccentricity
        }
        if let stars {
            config.useStarCount = true
            if absolute { config.absoluteStarCountFloor = stars } else { config.starCountMultiplier = stars }
        }
        if let snr {
            config.useSNR = true
            if absolute { config.absoluteSNRFloor = snr } else { config.snrMultiplier = snr }
        }
        if let skyBG {
            config.useSkyBackground = true
            if absolute { config.absoluteSkyBackgroundCeiling = skyBG } else { config.skyBackgroundMultiplier = skyBG }
        }
        if let psf {
            config.usePSF = true
            if absolute { config.absolutePSFFloor = psf } else { config.psfMultiplier = psf }
        }
        if let score {   // absolute mode only; parse(_:) checks that
            config.useScore = true
            config.scoreFloor = Double(score)
        }
        return config
    }

    // MARK: - CLI or window

    /// True when the arguments ask for the CLI: one of its options (or anything starting
    /// with "--", so a mistyped option gets a usage error), a single "-x", a path starting
    /// with / or ~, or a relative path to a folder that exists. macOS's own arguments
    /// (-NSDocumentRevisionsDebugMode YES, -AppleLanguages (en)) open the window.
    static func isCLIInvocation(_ args: [String], currentDirectory: URL) -> Bool {
        args.contains { arg in
            if valued[arg] != nil || switches[arg] != nil || helpFlags.contains(arg) { return true }
            if arg.hasPrefix("--") || arg.hasPrefix("/") || arg.hasPrefix("~") { return true }
            if arg.count == 2, arg.hasPrefix("-"), arg.last?.isLetter == true { return true }
            if arg.hasPrefix("-") || arg.isEmpty { return false }
            return isFolder(fileURL(arg, currentDirectory: currentDirectory))
        }
    }

    /// True for a folder, also through a symlink (URL resource values don't follow one).
    static func isFolder(_ url: URL) -> Bool {
        (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
#endif
