//
//  ThumbnailProvider.swift
//  FITSBlasterQLThumb
//
//  QuickLook Thumbnail extension for FITS files.
//  Shares FITSReader and ImageStretcher with the main app and preview extension.
//

import AppKit
import QuickLookThumbnailing

class ThumbnailProvider: QLThumbnailProvider {

    override func provideThumbnail(for request: QLFileThumbnailRequest,
                                   _ handler: @escaping (QLThumbnailReply?, Error?) -> Void) {
        let url = request.fileURL
        let maxSize = Int(max(request.maximumSize.width, request.maximumSize.height))

        do {
            var fitsImage = try FITSReader.read(from: url)
            guard let nsImage = ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                                           width: fitsImage.width,
                                                           height: fitsImage.height,
                                                           maxDisplaySize: maxSize) else {
                handler(nil, CocoaError(.fileReadCorruptFile))
                return
            }

            let reply = QLThumbnailReply(contextSize: nsImage.size) {
                nsImage.draw(in: CGRect(origin: .zero, size: nsImage.size))
                return true
            }
            handler(reply, nil)
        } catch {
            handler(nil, error)
        }
    }
}
