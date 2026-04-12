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

        var fitsImage = try FITSReader.readForPreview(from: url)
        let isFloat = fitsImage.bitpix < 0
        let nsImage: NSImage?
        if fitsImage.channels == 3 {
            nsImage = ImageStretcher.createRGBImage(from: &fitsImage.pixelValues,
                                                     width: fitsImage.width,
                                                     height: fitsImage.height,
                                                     maxDisplaySize: 1024)
        } else {
            nsImage = ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                                  width: fitsImage.width,
                                                  height: fitsImage.height,
                                                  maxDisplaySize: 1024,
                                                  useAsinhStretch: isFloat)
        }
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
