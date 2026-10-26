//
//  QuickLookRenderingTests.swift
//  FITS Blaster Tests
//
//  The code the Quick Look extensions share (CODE_AUDIT §7.8): thumbnails are rendered at
//  points × screen scale, at most 512 pixels, and shown at the requested size in points;
//  the shared read-and-stretch gives the same image the extensions made before.
//

import AppKit
import Testing
@testable import FITS_Blaster

struct QuickLookRenderingTests {

    // MARK: - Thumbnail size

    @Test("Thumbnail pixels are points × scale, at most 512", arguments: [
        // (requested points, scale, expected points, expected pixels)
        (32.0, 2.0, 32, 64),     // list view on Retina: twice the pixels
        (128.0, 2.0, 128, 256),
        (256.0, 2.0, 256, 512),
        (512.0, 2.0, 512, 512),  // large: capped, as before
        (1024.0, 2.0, 512, 512),
        (128.0, 1.0, 128, 128),  // non-Retina: as before
        (64.0, 3.0, 64, 192),
    ])
    func thumbnailBudget(requested: Double, scale: Double, points: Int, pixels: Int) {
        let budget = QuickLookRendering.thumbnailBudget(maximumSize: CGSize(width: requested, height: requested),
                                                        scale: scale)
        #expect(budget.points == points)
        #expect(budget.pixels == pixels)
    }

    @Test("A thumbnail is shown at the requested points; a small image at its own size")
    func contextSize() {
        let budget = QuickLookRendering.thumbnailBudget(maximumSize: CGSize(width: 128, height: 128), scale: 2)
        let wide = NSImage(size: NSSize(width: 256, height: 170))     // rendered at 256 px
        #expect(QuickLookRendering.thumbnailContextSize(for: wide, budget: budget) == CGSize(width: 128, height: 85))
        let small = NSImage(size: NSSize(width: 60, height: 40))      // a 60 × 40 FITS file
        #expect(QuickLookRendering.thumbnailContextSize(for: small, budget: budget) == CGSize(width: 60, height: 40))
    }

    // MARK: - Shared read and stretch

    @Test("The shared read-and-stretch gives the image the extensions made before")
    func sameImageAsBefore() throws {
        let width = 900, height = 600
        let stored = (0..<(width * height)).map { i in
            Int16(bitPattern: UInt16(1000 + (i * 37) % 20000) &- 32768)
        }
        let cards = TestFITS.imageCards(bitpix: 16, width: width, height: height, bzero: 32768)
        let url = try TestFITS.write(TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian(stored)))
        defer { try? FileManager.default.removeItem(at: url) }

        let shared = try #require(try QuickLookRendering.image(of: url, readSize: 256, displaySize: 256))
        // What the thumbnail extension did itself before 8e.
        var fits = try FITSReader.readForPreview(from: url, maxSize: 256)
        let before = try #require(ImageStretcher.createImage(from: &fits.pixelValues, width: fits.width,
                                                             height: fits.height, maxDisplaySize: 256))
        let a = try #require(shared.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let b = try #require(before.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(a.width == b.width && a.height == b.height)
        #expect(a.dataProvider?.data as Data? == b.dataProvider?.data as Data?)
    }
}
