//
//  ColourProxy.swift
//  FITS Blaster
//
//  The per-channel averages of a Bayer frame at display size, before the stretch: the
//  first half of the colour render, kept so the folder's shared stretch can be applied
//  later without reading the file again (master-plan 9f part 2b).
//

import Metal

struct ColourProxy {
    /// R, G, B as float32 per output pixel, packed row-major (12 bytes per pixel).
    let averages: MTLBuffer
    let width: Int
    let height: Int

    var byteCount: Int { averages.length }
}
