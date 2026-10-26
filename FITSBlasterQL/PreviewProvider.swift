//
//  PreviewProvider.swift
//  FITSBlasterQL
//
//  QuickLook Preview extension for FITS files.
//
//  Renders a stretched preview using the CPU path (no Metal — keeps peak memory
//  well under the QL process limit). Supports integer, float, and RGB FITS.
//

import Cocoa
import Quartz

class PreviewProvider: QLPreviewProvider, QLPreviewingController {

    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let url = request.fileURL

        // Read at 2048 and show at 1024: the read takes every Nth pixel, and a smaller read
        // size would give odd N for typical sensors, which mixes the colours of a raw Bayer
        // frame into a checkerboard (decided 2026-10-26, not changed in step 8).
        let nsImage = try QuickLookRendering.image(of: url, readSize: 2048, displaySize: 1024)
        guard let image = nsImage,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw CocoaError(.fileReadCorruptFile)
        }

        let size = CGSize(width: cgImage.width, height: cgImage.height)
        return QLPreviewReply(contextSize: size, isBitmap: true) { context, _ in
            context.draw(cgImage, in: CGRect(origin: .zero, size: size))
        }
    }
}
