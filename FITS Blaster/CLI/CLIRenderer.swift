//
//  CLIRenderer.swift
//  FITS Blaster
//
//  The CLI --render option (beta and Debug builds only; not listed in --help). Writes
//  each frame's display image as a PNG — colour frames as the app shows them with Colour
//  on, mono frames in greyscale — and every frame's background per channel to
//  backgrounds.csv. Lets the VM smoke test check the shipped binary's rendering without
//  the GUI. It writes data only; scripts/vm-smoke-remote.sh judges it.
//  See docs/internal/testing.md.
//
//  Beta builds get the BETA compilation condition from the release workflow (beta tags)
//  or scripts/build-beta.sh; stable and App Store builds don't contain this code.
//

#if !APPSTORE && (BETA || DEBUG)
import Foundation
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum CLIRenderer {

    /// Writes PNGs and backgrounds.csv for `entries` into `directory`.
    /// PNGs go in one subfolder per source folder (the folder path relative to the
    /// scanned folder's parent). With `typicalOnly`, only each folder's typical frame
    /// (median green background) is written as a PNG; the CSV always lists every frame.
    /// - Returns: the number of PNGs written.
    static func write(_ entries: [ImageEntry], to directory: URL, typicalOnly: Bool) throws -> Int {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var csv = "folder,frame,view,r,g,b,typical\n"
        var written = 0
        let folders = Dictionary(grouping: entries, by: \.qualifiedFolderPath)
        for folder in folders.keys.sorted() {
            let measured: [(entry: ImageEntry, frame: RenderedFrame)] = (folders[folder] ?? []).compactMap { entry in
                guard let image = entry.displayImage, let pixels = RGBAPixels(image) else {
                    fputs("warning: no display image for \(entry.url.lastPathComponent); not rendered\n", stderr)
                    return nil
                }
                let frame = RenderedFrame(name: entry.url.lastPathComponent,
                                          background: pixels.channelMedians(),
                                          image: pixels.image)
                return (entry, frame)
            }
            let typicalName = RenderedFrame.typical(of: measured.map(\.frame))?.name

            let folderDirectory = directory.appending(path: folder)
            try FileManager.default.createDirectory(at: folderDirectory, withIntermediateDirectories: true)
            for (entry, frame) in measured.sorted(by: { $0.frame.name < $1.frame.name }) {
                let isTypical = frame.name == typicalName
                let bg = frame.background
                csv += [ExportTable.csvCell(folder), ExportTable.csvCell(frame.name), view(of: entry),
                        String(bg[0]), String(bg[1]), String(bg[2]), isTypical ? "yes" : ""]
                    .joined(separator: ",") + "\n"
                if !typicalOnly || isTypical {
                    try writePNG(frame.image, to: folderDirectory.appending(path: frame.name + ".png"))
                    written += 1
                }
            }
        }
        try csv.write(to: directory.appending(path: "backgrounds.csv"), atomically: true, encoding: .utf8)
        return written
    }

    /// `colour` for a Bayer frame showing its colour render, `grey` for a Bayer frame
    /// that didn't get one (a failure the smoke test reports), `mono` otherwise.
    private static func view(of entry: ImageEntry) -> String {
        guard entry.isBayer else { return "mono" }
        if let colour = entry.cachedColourDisplay, entry.displayImage === colour { return "colour" }
        return "grey"
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path(percentEncoded: false)])
        }
    }
}
#endif
