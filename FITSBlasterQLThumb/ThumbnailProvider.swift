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
        // Rendered at points × screen scale (sharp on Retina), at most 512 pixels.
        let budget = QuickLookRendering.thumbnailBudget(maximumSize: request.maximumSize, scale: request.scale)
        logger.info("provideThumbnail: \(url.lastPathComponent) points=\(budget.points) pixels=\(budget.pixels)")

        do {
            // Bail out early for iCloud stubs that haven't been downloaded yet.
            // Trying to read them returns a tiny placeholder file that fails FITS
            // parsing; worse, a crash here poisons thumbnails for other in-flight files.
            if let resources = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey]),
               resources.ubiquitousItemDownloadingStatus == .notDownloaded {
                handler(nil, CocoaError(.fileNoSuchFile))
                return
            }

            // Read only at the needed resolution. Without this, a 32-px list-view thumbnail
            // would still load a 2048-px intermediate Float array (~24 MB), and with many
            // concurrent icon-view requests the QL extension process would hit its memory
            // limit and die, leaving those files permanently showing the app icon.
            let nsImage = try QuickLookRendering.image(of: url, readSize: budget.pixels,
                                                       displaySize: budget.pixels)

            guard let image = nsImage else {
                logger.error("ImageStretcher returned nil")
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }

            // Shown at the requested size in points; the image has up to `scale` pixels per point.
            let contextSize = QuickLookRendering.thumbnailContextSize(for: image, budget: budget)
            logger.info("Thumbnail ready: \(image.size.width)×\(image.size.height) px shown at \(contextSize.width)×\(contextSize.height) pt")
            let reply = QLThumbnailReply(contextSize: contextSize) {
                image.draw(in: CGRect(origin: .zero, size: contextSize))
                return true
            }
            handler(reply, nil)
        } catch {
            logger.error("FITSReader error: \(error)")
            handler(nil, error)
        }
    }
}
