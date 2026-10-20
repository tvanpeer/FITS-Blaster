//
//  RenderedPixels.swift
//  FITS Blaster
//
//  Reads back the pixels of a display image and measures its sky background per
//  channel. Used by the rendering tests and the beta-only CLI --render option, so both
//  measure the same way. Compiled into Debug and beta builds only (see CLIRenderer).
//

#if !APPSTORE && (BETA || DEBUG)
import AppKit

/// One rendered frame: its background per channel (R, G, B, 0–255) and the image itself.
struct RenderedFrame {
    let name: String
    let background: [Int]
    let image: CGImage

    /// The typical frame of a set: the one with the median green background
    /// (for mono frames all channels are equal). `nil` for an empty set.
    static func typical(of frames: [RenderedFrame]) -> RenderedFrame? {
        guard !frames.isEmpty else { return nil }
        let sorted = frames.sorted { $0.background[1] < $1.background[1] }
        return sorted[sorted.count / 2]
    }
}

/// A display image drawn 1:1 into an RGBA buffer in the same colour space it was made in
/// (device RGB), so the values are exactly what the app put on screen.
struct RGBAPixels {
    let width: Int
    let height: Int
    let bytes: [UInt8]
    let image: CGImage

    init?(_ nsImage: NSImage) {
        guard let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let width = cgImage.width
        let height = cgImage.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let context = CGContext(data: raw.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .none
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        bytes = buffer
        image = cgImage
    }

    /// Median of each of R, G and B over all pixels.
    func channelMedians() -> [Int] {
        (0..<3).map { channel in
            var histogram = [Int](repeating: 0, count: 256)
            for pixel in 0..<(width * height) { histogram[Int(bytes[pixel * 4 + channel])] += 1 }
            let half = (width * height + 1) / 2
            var seen = 0
            for (level, count) in histogram.enumerated() {
                seen += count
                if seen >= half { return level }
            }
            return 255
        }
    }
}
#endif
