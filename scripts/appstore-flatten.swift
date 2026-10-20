// appstore-flatten.swift — used by appstore-screenshots.sh. Redraws a PNG into an opaque RGB
// bitmap in the same colour space (App Store Connect can refuse screenshots with an alpha
// channel) and writes it as PNG. Without a size, the pixels and the colour profile stay the
// same; with a size, the image is scaled to it (high-quality interpolation).
//
// Usage: appstore-flatten <in.png> <out.png> [width height]

import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count == 3 || args.count == 5,
      let source = CGImageSourceCreateWithURL(URL(filePath: args[1]) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
      let space = image.colorSpace
else { fputs("usage: appstore-flatten <in.png> <out.png> [width height]\n", stderr); exit(1) }

let width = args.count == 5 ? Int(args[3]) ?? 0 : image.width
let height = args.count == 5 ? Int(args[4]) ?? 0 : image.height
guard width > 0, height > 0,
      let context = CGContext(data: nil, width: width, height: height,
                              bitsPerComponent: 8, bytesPerRow: 0, space: space,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
else { fputs("cannot make a \(width) × \(height) image\n", stderr); exit(1) }
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
guard let opaque = context.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(filePath: args[2]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(dest, opaque, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
