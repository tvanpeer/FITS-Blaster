//
//  ThumbnailProvider.swift
//  FITSBlasterQLThumb
//
//  QuickLook Thumbnail extension for FITS files.
//  Shares FITSReader and ImageStretcher with the main app and preview extension.
//

import AppKit
import OSLog
import QuickLookThumbnailing

private let logger = Logger(subsystem: "com.astrophotoapp.FitsBlaster.FITSBlasterQLThumb", category: "thumbnail")

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = min(512, Int(max(request.maximumSize.width, request.maximumSize.height)))
        logger.info("provideThumbnail: \(url.lastPathComponent) maxSize=\(maxSize)")

        do {
            var fitsImage = try FITSReader.read(from: url)
            logger.info("FITSReader succeeded: \(fitsImage.width)×\(fitsImage.height)")
            guard let nsImage = ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                                           width: fitsImage.width,
                                                           height: fitsImage.height,
                                                           maxDisplaySize: maxSize) else {
                logger.error("ImageStretcher returned nil")
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }

            logger.info("Thumbnail ready: \(nsImage.size.width)×\(nsImage.size.height)")
            let reply = QLThumbnailReply(contextSize: nsImage.size) {
                nsImage.draw(in: CGRect(origin: .zero, size: nsImage.size))
                return true
            }
            handler(reply, nil)
        } catch {
            logger.error("FITSReader error: \(error)")
            handler(nil, error)
        }
    }
}
