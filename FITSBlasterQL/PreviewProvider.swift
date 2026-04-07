//
//  PreviewProvider.swift
//  FITSBlasterQL
//
//  QuickLook Preview extension for FITS files.
//
//  Renders a stretched greyscale preview using the same CPU path as the main app
//  (no Metal — keeps peak memory well under the QL process limit).
//

import QuickLook
import AppKit

@objc(PreviewProvider)
final class PreviewProvider: NSObject, QLPreviewingController {

    // Called by the system to render a preview for a single file URL.
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        // Read and stretch on a background thread via the CPU path.
        // Avoids Metal buffer allocation; peak memory stays well under the QL process limit.
        let nsImage = try await Task.detached(priority: .userInitiated) {
            var fitsImage = try FITSReader.read(from: url)
            return ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                              width: fitsImage.width,
                                              height: fitsImage.height,
                                              maxDisplaySize: 1024)
        }.value

        guard let nsImage else { throw CocoaError(.fileReadCorruptFile) }
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let reply = QLPreviewReply(
            dataOfContentType: .png,
            contentSize: CGSize(width: cgImage.width, height: cgImage.height)
        ) { _, _ in
            let mutableData = NSMutableData()
            guard let dest = CGImageDestinationCreateWithData(mutableData, "public.png" as CFString, 1, nil) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            CGImageDestinationAddImage(dest, cgImage, nil)
            CGImageDestinationFinalize(dest)
            return mutableData as Data
        }

        return reply
    }
}
