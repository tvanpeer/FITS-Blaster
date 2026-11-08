//
//  CLIArgumentsTests.swift
//  FITS Blaster Tests
//
//  Step 12a (CODE_AUDIT §5.10, §5.12): the command line read in one pass, with usage
//  errors for unknown options and bad values, and the rule for CLI or window.
//

#if !APPSTORE
import Foundation
import Testing
@testable import FITS_Blaster

struct CLIArgumentsTests {

    private let cwd = URL(filePath: "/work/astro", directoryHint: .isDirectory)
    private let home = URL(filePath: "/Users/someone", directoryHint: .isDirectory)

    private func parse(_ args: [String]) throws(CLIUsageError) -> CLIArguments {
        try CLIArguments.parse(args, currentDirectory: cwd, home: home)
    }

    private func usageError(_ args: [String]) -> String? {
        do {
            _ = try parse(args)
            return nil
        } catch {
            return error.message
        }
    }

    // MARK: - Folder

    @Test("-o before the folder: the output is not taken for the folder")
    func outputBeforeFolder() throws {
        let parsed = try parse(["-o", "/tmp/out.csv", "/data/night1"])
        #expect(parsed.folder.path(percentEncoded: false) == "/data/night1")
        #expect(parsed.outputURL?.path(percentEncoded: false) == "/tmp/out.csv")
    }

    @Test("Folders and paths: absolute, ~, ~/…, relative, ..",
          arguments: [("/data/M31", "/data/M31"), ("~", "/Users/someone/"), ("~/Astro/M31", "/Users/someone/Astro/M31"),
                      ("M31/LIGHT", "/work/astro/M31/LIGHT"), ("../M31", "/work/M31"), (".", "/work/astro/")])
    func folderPaths(typed: String, path: String) throws {
        let parsed = try parse([typed])
        #expect(parsed.folder.path(percentEncoded: false) == path)
        #expect(parsed.folderArgument == typed)
    }

    @Test("A relative output path is taken from the current folder")
    func relativeOutput() throws {
        let parsed = try parse(["M31", "-o", "keep.csv"])
        #expect(parsed.outputURL?.path(percentEncoded: false) == "/work/astro/keep.csv")
    }

    // MARK: - Options

    @Test("Every option with its value; -m after the thresholds still applies")
    func allOptions() throws {
        let parsed = try parse(["M31", "-f", "1.5", "-e", "0.6", "-n", "0.5", "-s", "0.7", "-b", "1.2",
                                "-p", "0.4", "-q", "40", "-S", "-r", "-P", "abs", "-H", "DATE-OBS, FILTER",
                                "-m", "abs"])
        #expect(parsed.mode == .absolute)
        #expect(parsed.fwhm == 1.5 && parsed.eccentricity == 0.6 && parsed.stars == 0.5)
        #expect(parsed.snr == 0.7 && parsed.skyBG == 1.2 && parsed.psf == 0.4 && parsed.score == 40)
        #expect(parsed.subfolders && parsed.includeRejected)
        #expect(parsed.pathStyle == .absolute)
        #expect(parsed.headerKeys == ["DATE-OBS", "FILTER"])
    }

    @Test("Long option names work like the short ones")
    func longOptions() throws {
        let parsed = try parse(["--mode", "absolute", "--fwhm", "3.5", "--score", "50", "--subfolders",
                                "--include-rejected", "--path-style", "relative", "--output", "~/x.csv", "/d"])
        #expect(parsed.mode == .absolute && parsed.fwhm == 3.5 && parsed.score == 50)
        #expect(parsed.subfolders && parsed.includeRejected && parsed.pathStyle == .relative)
        #expect(parsed.outputURL?.path(percentEncoded: false) == "/Users/someone/x.csv")
    }

    @Test("Defaults: relative mode, relative paths, no checks")
    func defaults() throws {
        let parsed = try parse(["M31"])
        #expect(parsed.mode == .relative && parsed.pathStyle == .relative)
        #expect(parsed.fwhm == nil && parsed.score == nil && parsed.outputURL == nil && parsed.headerKeys == nil)
        #expect(!parsed.subfolders && !parsed.includeRejected)
    }

    @Test("rel/abs in any case, for -m and -P",
          arguments: [("abs", true), ("ABSOLUTE", true), ("rel", false), ("Relative", false)])
    func modeValues(value: String, absolute: Bool) throws {
        #expect(try CLIArguments.isAbsolute(value, flag: "-m") == absolute)
    }

    // MARK: - Usage errors

    @Test("Usage errors name the problem", arguments: [
        (["M31", "--fwmh", "1.5"], "unknown option '--fwmh'"),
        (["M31", "-x"], "unknown option '-x'"),
        (["M31", "-f"], "-f needs a value"),
        (["M31", "-f", "-e", "0.5"], "-f needs a value"),
        (["M31", "-f", "abc"], "-f needs a number, not 'abc'"),
        (["M31", "-f", "nan"], "-f needs a number, not 'nan'"),
        (["M31", "-m", "abs", "-q", "4.5"], "-q needs a whole number, not '4.5'"),
        (["M31", "-m", "foo"], "-m takes rel or abs, not 'foo'"),
        (["M31", "-P", "full"], "-P takes rel or abs, not 'full'"),
        (["-f", "1.5"], "no folder given"),
        (["M31", "M42"], "more than one folder given: 'M31' and 'M42'"),
        (["M31", "-q", "40"], "--score works only in absolute mode (-m abs)")
    ])
    func usageErrors(args: [String], message: String) {
        #expect(usageError(args) == message)
    }

    // MARK: - CLI or window

    @Test("CLI or window: the CLI's options and paths start the CLI, macOS's own arguments don't")
    func cliOrWindow() throws {
        let folder = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder.appending(path: "M31/LIGHT"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let isCLI = { (args: [String]) in CLIArguments.isCLIInvocation(args, currentDirectory: folder) }

        #expect(isCLI(["M31/LIGHT"]))                       // a relative folder that exists
        #expect(isCLI(["-o", "out.csv", "M31"]))
        #expect(isCLI(["/data/M31"]))
        #expect(isCLI(["~/Astro"]))
        #expect(isCLI(["--fwmh"]))                          // a mistyped option: usage error, not the window
        #expect(isCLI(["-h"]))
        #expect(!isCLI([]))
        #expect(!isCLI(["-NSDocumentRevisionsDebugMode", "YES"]))
        #expect(!isCLI(["-AppleLanguages", "(en)"]))
        #expect(!isCLI(["NoSuchFolder"]))
    }

    @Test("A folder through a symlink counts as a folder")
    func symlinkedFolder() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appending(path: "real"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"),
                                                   withDestinationURL: root.appending(path: "real"))
        try Data([0]).write(to: root.appending(path: "file.fits"))

        #expect(CLIArguments.isFolder(root.appending(path: "link")))
        #expect(!CLIArguments.isFolder(root.appending(path: "file.fits")))
        #expect(!CLIArguments.isFolder(root.appending(path: "missing")))
    }

    @Test("The filter: only the given checks, with the value in the chosen mode")
    func filterConfig() throws {
        let relative = try parse(["M31", "-f", "1.3", "-e", "0.6"]).autoRejectConfig
        #expect(relative.mode == .relative && relative.useFWHM && relative.fwhmMultiplier == 1.3)
        #expect(relative.useEccentricity && relative.eccentricityThreshold == 0.6)
        #expect(!relative.useStarCount && !relative.useSNR && !relative.useSkyBackground && !relative.usePSF
                && !relative.useScore)
        #expect(relative.absoluteFWHM == AutoRejectConfig().absoluteFWHM)

        let absolute = try parse(["M31", "-m", "abs", "-f", "4", "-n", "30", "-s", "150", "-b", "2000",
                                  "-p", "0.8", "-q", "45"]).autoRejectConfig
        #expect(absolute.mode == .absolute && absolute.absoluteFWHM == 4 && absolute.absoluteStarCountFloor == 30)
        #expect(absolute.absoluteSNRFloor == 150 && absolute.absoluteSkyBackgroundCeiling == 2000)
        #expect(absolute.absolutePSFFloor == 0.8 && absolute.useScore && absolute.scoreFloor == 45)
        #expect(absolute.fwhmMultiplier == AutoRejectConfig().fwhmMultiplier)

        #expect(!(try parse(["M31"]).autoRejectConfig.isAnyCheckOn))
    }

    @Test("allDisabled has every check off")
    func allDisabled() {
        var config = AutoRejectConfig.allDisabled
        #expect(!config.isAnyCheckOn)
        config.mode = .absolute
        #expect(!config.isAnyCheckOn)
    }
}
#endif
