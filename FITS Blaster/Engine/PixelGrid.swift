//
//  PixelGrid.swift
//  FITS Blaster
//
//  Read access to a rectangle of float pixels stored row by row: the input of the star
//  shape measurement, which works the same on the whole frame (mono) and on a star crop
//  (Bayer luminance) (CODE_AUDIT §9.4). Both measurements skip, or read 0 for, pixels
//  outside the grid; the crop itself is filled with 0 outside the frame by `extractCrop`.
//

/// A width × height grid of float pixels, row by row.
protocol PixelGrid {
    var width: Int { get }
    var height: Int { get }
    /// Number of stored pixels (width × height).
    var count: Int { get }
    subscript(index: Int) -> Float { get }
}

/// The whole frame, read in place (no copy).
struct FramePixels: PixelGrid {
    let pixels: UnsafeBufferPointer<Float>
    let width: Int
    let height: Int

    var count: Int { pixels.count }
    subscript(index: Int) -> Float { pixels[index] }
}

/// A square crop of side × side pixels around a star.
struct CropPixels: PixelGrid {
    let crop: [Float]
    let side: Int

    var width: Int { side }
    var height: Int { side }
    var count: Int { crop.count }
    subscript(index: Int) -> Float { crop[index] }
}
