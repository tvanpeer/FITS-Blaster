//
//  QuickLookRendering.swift
//  FITS Blaster
//
//  The code the Quick Look preview and thumbnail extensions share: read a FITS file for a
//  preview and stretch it on the CPU (CODE_AUDIT §7.8, Quick Look part of §9.11), and the
//  thumbnail size. Compiled into both extensions; in the app target only for the tests.
//

import AppKit

enum QuickLookRendering {

    /// Reads `url` for Quick Look — every Nth pixel, so the longest side is at most
    /// `readSize` — and stretches it on the CPU to at most `displaySize` pixels.
    /// Grey and RGB (NAXIS3 = 3) files; float formats too. Nil when the stretch fails.
    static func image(of url: URL, readSize: Int, displaySize: Int) throws -> NSImage? {
        var fitsImage = try FITSReader.readForPreview(from: url, maxSize: readSize)
        if fitsImage.channels == 3 {
            return ImageStretcher.createRGBImage(from: &fitsImage.pixelValues,
                                                 width: fitsImage.width,
                                                 height: fitsImage.height,
                                                 maxDisplaySize: displaySize)
        }
        return ImageStretcher.createImage(from: &fitsImage.pixelValues,
                                          width: fitsImage.width,
                                          height: fitsImage.height,
                                          maxDisplaySize: displaySize)
    }

    /// Largest thumbnail rendered, in pixels: with many icon-view requests at once the
    /// thumbnail extension must stay under its memory limit.
    static let maxThumbnailPixels = 512

    /// The thumbnail's size for a request of `maximumSize` points on a screen with `scale`
    /// pixels per point: `points` is the longest side shown (as before, at most 512), and
    /// `pixels` the longest side rendered — `points × scale`, at most `maxThumbnailPixels`.
    /// Rendering at `points` pixels made thumbnails soft on Retina screens (CODE_AUDIT §7.8).
    static func thumbnailBudget(maximumSize: CGSize, scale: CGFloat) -> (points: Int, pixels: Int) {
        let points = min(maxThumbnailPixels, Int(max(maximumSize.width, maximumSize.height)))
        let pixels = min(maxThumbnailPixels, Int((CGFloat(points) * max(1, scale)).rounded()))
        return (max(1, points), max(1, pixels))
    }

    /// The size, in points, to show `image` (rendered for `budget`) at: its longest side is
    /// `budget.points`, or its own pixel size when it is smaller (a small FITS file).
    static func thumbnailContextSize(for image: NSImage, budget: (points: Int, pixels: Int)) -> CGSize {
        let longest = max(image.size.width, image.size.height)
        guard longest > 0 else { return .zero }
        let shown = min(CGFloat(budget.points), longest)
        let factor = shown / longest
        return CGSize(width: (image.size.width * factor).rounded(),
                      height: (image.size.height * factor).rounded())
    }
}
