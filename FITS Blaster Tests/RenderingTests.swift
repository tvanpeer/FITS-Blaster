//
//  RenderingTests.swift
//  FITS Blaster Tests
//
//  Rendering tests on real data. Each test loads a folder exactly as the app does
//  (ImageStore.openFiles → waitForProcessing), reads back the pixels of every frame's
//  display image and measures the sky background per channel (the median, which stars
//  and nebulae are too sparse to move).
//
//  Checks: the typical frame of a folder — the one with the median background — must be
//  close to neutral and close to the 25% target (63 of 255). Other frames are only
//  reported: real frames differ (cloud, twilight, sky colour), so limits there would be
//  arbitrary.
//
//  Skipped unless FB_TEST_DATA points at the test data folder; the large folders also need
//  FB_TEST_DATA_FULL=1. Run them with scripts/run-render-tests.sh. For each folder the
//  typical frame is saved as a PNG, with a CSV of all frames, in tests/render-results/.
//  See docs/internal/testing.md.
//

import Testing
import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import FITS_Blaster

// MARK: - Test data

/// Test data location and switches, read from the environment.
enum RenderTestData {
    static let root: URL? = ProcessInfo.processInfo.environment["FB_TEST_DATA"].map { URL(filePath: $0) }
    static let full = ProcessInfo.processInfo.environment["FB_TEST_DATA_FULL"] == "1"

    /// The published sample set, as users download it.
    static let sampleZip = "Sample set (website)/FITS-Blaster-Sample-M31.zip"

    /// Colour (Bayer) light folders, relative to the root.
    static let colourFolders = [
        "M31/LIGHT",
        "California Nebula IMX571/2026-02-25_Antlia ALP-T/LIGHT",
        "Gamma Cygni Nebula IMX571/2026-03-04_Antlia ALP-T/LIGHT"
    ]

    /// Mono light folders (one filter each), relative to the root.
    static let monoFolders = [
        "NGC 2244-Rosette_Nebula original/R",
        "NGC 2244-Rosette_Nebula original/G",
        "NGC 2244-Rosette_Nebula original/B"
    ]
}

// MARK: - Tests

@Suite(.enabled(if: RenderTestData.root != nil, "Set FB_TEST_DATA to the test data folder"), .serialized)
@MainActor
struct RenderingTests {

    /// The stretch places the sky background at 25% grey: 0.25 × 255.
    static let targetLevel = 63

    // Limits, set 2026-10-13 from measurements of the typical frames (R/G/B):
    //
    //   folder         before the colour fix   after the fix
    //   sample set     58/29/61                62/61/63
    //   M31 night      62/59/61                62/61/61
    //   California     58/63/60                62/64/64
    //   Gamma Cygni    60/65/62                63/64/64
    //   Rosette mono   63                      63
    //
    // After the fix the channels differ by at most 2 and stay within 2 of the target;
    // before it they differed by 3 to 32. The limits leave room for small changes and
    // still catch the casts we had. Widen them only with a written reason.

    /// Largest allowed difference between the R, G and B background of the typical frame.
    static let maxChannelSpread = 4

    /// Largest allowed distance of any channel of the typical frame from `targetLevel`.
    static let maxLevelOffset = 6

    @Test("Sample set renders a neutral typical frame in colour")
    func sampleSetColour() async throws {
        let root = try #require(RenderTestData.root)
        let zip = root.appending(path: RenderTestData.sampleZip)
        let unpacked = try unzip(zip)
        defer { try? FileManager.default.removeItem(at: unpacked) }
        let folder = try #require(folderContainingFITS(in: unpacked))

        let frames = await renderFolder(folder, colour: true)
        #expect(frames.count == 8)
        checkColour(frames, label: "Sample set")
    }

    @Test("Colour folders render a neutral typical frame",
          .enabled(if: RenderTestData.full, "Set FB_TEST_DATA_FULL=1 for the large folders"),
          arguments: RenderTestData.colourFolders)
    func colourFolder(_ relativePath: String) async throws {
        let root = try #require(RenderTestData.root)
        let frames = await renderFolder(root.appending(path: relativePath), colour: true)
        try #require(!frames.isEmpty, "no frames rendered in \(relativePath)")
        checkColour(frames, label: relativePath)
    }

    @Test("Mono folders render the typical frame at the target level",
          .enabled(if: RenderTestData.full, "Set FB_TEST_DATA_FULL=1 for the large folders"),
          arguments: RenderTestData.monoFolders)
    func monoFolder(_ relativePath: String) async throws {
        let root = try #require(RenderTestData.root)
        let frames = await renderFolder(root.appending(path: relativePath), colour: false)
        try #require(!frames.isEmpty, "no frames rendered in \(relativePath)")
        let typical = report(frames, label: relativePath)
        let level = typical.background[1]
        #expect(abs(level - Self.targetLevel) <= Self.maxLevelOffset,
                "typical frame \(typical.name) background \(level), target \(Self.targetLevel) ± \(Self.maxLevelOffset)")
    }

    // MARK: - Checks

    private func checkColour(_ frames: [RenderedFrame], label: String) {
        let typical = report(frames, label: label)
        let bg = typical.background
        let spread = (bg.max() ?? 0) - (bg.min() ?? 0)
        #expect(spread <= Self.maxChannelSpread,
                "typical frame \(typical.name) R/G/B \(bg): channels differ by \(spread), allowed \(Self.maxChannelSpread)")
        for (channel, level) in zip(["R", "G", "B"], bg) {
            #expect(abs(level - Self.targetLevel) <= Self.maxLevelOffset,
                    "typical frame \(typical.name) \(channel) background \(level), target \(Self.targetLevel) ± \(Self.maxLevelOffset)")
        }
    }

    /// Prints every frame's background, saves the results, and returns the typical frame
    /// (median green background; for mono frames all channels are equal).
    private func report(_ frames: [RenderedFrame], label: String) -> RenderedFrame {
        let typical = RenderedFrame.typical(of: frames) ?? frames[0]
        print("── \(label): \(frames.count) frames, background R/G/B (typical frame marked *)")
        for frame in frames.sorted(by: { $0.name < $1.name }) {
            let mark = frame.name == typical.name ? "*" : " "
            print("[\(mark)] \(frame.name)  \(frame.background.map(String.init).joined(separator: "/"))")
        }
        RenderResults.save(frames, typical: typical, label: label)
        return typical
    }

    // MARK: - Loading and measuring

    /// Loads a folder the way the app does and measures every frame's display image.
    private func renderFolder(_ folder: URL, colour: Bool) async -> [RenderedFrame] {
        let collected = ImageStore.collectFITSURLs(in: folder, relativePath: "",
                                                   excludedNames: [], includeSubfolders: false)
        let store = ImageStore()
        store.openFiles(collected, rootFolderName: folder.lastPathComponent, debayerColorImages: colour)
        await store.waitForProcessing()
        return store.entries.compactMap { entry in
            guard let image = entry.displayImage,
                  let pixels = RGBAPixels(image) else { return nil }
            return RenderedFrame(name: entry.url.lastPathComponent,
                                 background: pixels.channelMedians(),
                                 image: pixels.image)
        }
    }

    private func unzip(_ zip: URL) throws -> URL {
        let destination = FileManager.default.temporaryDirectory.appending(path: "render-tests-\(UUID().uuidString)")
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", zip.path(percentEncoded: false), destination.path(percentEncoded: false)]
        try process.run()
        process.waitUntilExit()
        try #require(process.terminationStatus == 0, "could not unzip \(zip.path(percentEncoded: false))")
        return destination
    }

    private func folderContainingFITS(in directory: URL) -> URL? {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension.lowercased() == "fits" { return url.deletingLastPathComponent() }
        }
        return nil
    }
}

// MARK: - Helpers

// RenderedFrame and RGBAPixels live in the app (RenderedPixels.swift), shared with the
// CLI --render option.

/// Writes the typical frame as a PNG and every frame's background as a CSV to
/// tests/render-results/<time>/<folder>/ (ignored by git) for the visual check.
enum RenderResults {
    static let runDirectory: URL = {
        let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let stamp = Date().formatted(.verbatim("\(year: .defaultDigits)\(month: .twoDigits)\(day: .twoDigits)-\(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)\(second: .twoDigits)",
                                               timeZone: .current, calendar: .current))
        return repoRoot.appending(path: "tests/render-results/\(stamp)")
    }()

    static func save(_ frames: [RenderedFrame], typical: RenderedFrame, label: String) {
        let folderName = label.replacing("/", with: " - ")
        let directory = runDirectory.appending(path: folderName)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var csv = "frame,r,g,b,typical\n"
        for frame in frames.sorted(by: { $0.name < $1.name }) {
            let bg = frame.background
            csv += "\(frame.name),\(bg[0]),\(bg[1]),\(bg[2]),\(frame.name == typical.name ? "yes" : "")\n"
        }
        try? csv.write(to: directory.appending(path: "backgrounds.csv"), atomically: true, encoding: .utf8)

        let pngURL = directory.appending(path: "typical-\(typical.name).png")
        if let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, typical.image, nil)
            CGImageDestinationFinalize(destination)
        }
    }
}
