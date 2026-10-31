//
//  ColourProxy.swift
//  FITS Blaster
//
//  The per-channel averages of a Bayer frame at display size, before the stretch: the
//  first half of the colour render, kept so the folder's shared stretch can be applied
//  later without reading the file again (master-plan 9f part 2b).
//

import Foundation

struct ColourProxy: Sendable {
    /// R, G, B as float32 per output pixel, packed row-major: an exact copy of the GPU
    /// output, so the proxy can move between tasks and the image stays the same.
    let averages: Data
    let width: Int
    let height: Int

    /// Copies the averages of a `width` × `height` image from `source` (the GPU buffer).
    /// The copy has memory of its own from the system (`mmap`), given back when the proxy
    /// goes: through the allocator, the freed blocks stayed with the app after the load
    /// (M81 at 1024: 514 MB in 64 empty blocks; at 4096: 2.2 GB). Nil when there is no memory.
    init?(copying source: UnsafeRawPointer, width: Int, height: Int) {
        let length = Self.byteCount(width: width, height: height)
        guard length > 0,
              let memory = mmap(nil, length, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0),
              memory != UnsafeMutableRawPointer(bitPattern: -1) else { return nil }
        memory.copyMemory(from: source, byteCount: length)
        averages = Data(bytesNoCopy: memory, count: length, deallocator: .unmap)
        self.width = width
        self.height = height
    }

    /// Memory the proxy of a `width` × `height` display image takes (12 bytes per pixel).
    static func byteCount(width: Int, height: Int) -> Int {
        width * height * 3 * MemoryLayout<Float>.stride
    }

    var byteCount: Int { averages.count }
}
