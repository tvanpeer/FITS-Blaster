//
//  ThumbnailProvider.swift
//  FITSBlasterQLThumb
//
//  QuickLook Thumbnail extension for FITS files.
//  Shares FITSReader and ImageStretcher with the main app and preview extension.
//  Supports integer, float, and RGB FITS files.
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
            // Bail out early for iCloud stubs that haven't been downloaded yet.
            // Trying to read them returns a tiny placeholder file that fails FITS
            // parsing; worse, a crash here poisons thumbnails for other in-flight files.
            if let resources = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               resources.ubiquitousItemDownloadingStatus == .notDownloaded {
                handler(nil, CocoaError(.fileNoSuchFile))
                return
            }

            // Pass maxSize so readForPreview only subsamples to the needed resolution.
            // Without this, a 32-px list-view thumbnail would still load a 2048-px
            // intermediate Float array (~24 MB), and with many concurrent icon-view
            // requests the QL extension process would hit its memory limit and die,
            // leaving those files permanently showing the app icon.
            var fitsImage = try FITSReader.readForPreview(from: url, maxSize: maxSize)
            logger.info("FITSReader succeeded: \(fitsImage.width)×\(fitsImage.height) ch=\(fitsImage.channels)")

            let nsImage: NSImage?
            if fitsImage.channels == 3 {
                nsImage = ImageStretcher.createRGBImage(from: &fitsImage.pixelValues,
                                                         width: fitsImage.width,
                                                         height: fitsImage.height,
                                                         maxDisplaySize: maxSize)
            } else {
                nsImage = ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                                      width: fitsImage.width,
                                                      height: fitsImage.height,
                                                      maxDisplaySize: maxSize)
            }

            guard let image = nsImage else {
                logger.error("ImageStretcher returned nil")
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }

            logger.info("Thumbnail ready: \(image.size.width)×\(image.size.height)")
            let reply = QLThumbnailReply(contextSize: image.size) {
                image.draw(in: CGRect(origin: .zero, size: image.size))
                return true
            }
            handler(reply, nil)
        } catch {
            logger.error("FITSReader error: \(error)")
            handler(nil, error)
        }
    }
}
