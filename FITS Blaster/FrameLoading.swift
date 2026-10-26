//
//  FrameLoading.swift
//  FITS Blaster
//
//  The per-file work of the loading pipeline, off the main actor: the header check,
//  Phase A (read, histogram, grey stretch), the metrics-only read and the colour
//  re-render of one frame. Used by LoadPipeline.
//

import Foundation
import AppKit
import Metal

enum FrameLoading {

    /// Filters a list of candidate URLs off the main thread: strips unsupported
    /// extensions, removes duplicates, and reads the first header block of each
    /// remaining file to detect and reject floating-point FITS.
    ///
    /// This function is `nonisolated` so Swift runs it on the cooperative thread
    /// pool rather than the main actor, keeping the UI responsive even when files
    /// are stored on iCloud Drive, SMB mounts, or a loaded SSD.
    /// `progress` receives the number of files done so far, and is finished at the end.
    /// The headers are read `headerChecksAtOnce` at a time: each costs a round trip on a
    /// network share (8 at once: about 6× faster than one by one, measured 2026-10-25).
    /// The result keeps the input order.
    @concurrent static func filterItems(
        _ items: [(url: URL, subfolderPath: String)],
        existingURLs: Set<URL>,
        progress: AsyncStream<Int>.Continuation? = nil
    ) async -> (valid: [(url: URL, subfolderPath: String)], skippedFloat: [String]) {
        defer { progress?.finish() }
        let candidates = items.filter { FITSFile.hasFITSExtension($0.url) && !existingURLs.contains($0.url) }
        var done = items.count - candidates.count   // skipped without reading
        if done > 0 { progress?.yield(done) }

        var bitpix = [Int?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, Int?).self) { group in
            var next = 0
            while next < min(headerChecksAtOnce, candidates.count) {
                let i = next
                group.addTask { (i, FITSReader.peekBitpix(url: candidates[i].url)) }
                next += 1
            }
            for await (i, value) in group {
                bitpix[i] = value
                done += 1
                progress?.yield(done)
                if next < candidates.count {
                    let j = next
                    group.addTask { (j, FITSReader.peekBitpix(url: candidates[j].url)) }
                    next += 1
                }
            }
        }

        var valid: [(url: URL, subfolderPath: String)] = []
        var skippedFloat: [String] = []
        for (item, value) in zip(candidates, bitpix) {
            if let value, ![8, 16, 32].contains(value) {
                skippedFloat.append(item.url.lastPathComponent)
            } else {
                valid.append(item)
            }
        }
        return (valid, skippedFloat)
    }

    /// How many file headers `filterItems` reads at the same time.
    nonisolated static let headerChecksAtOnce = 8

    @concurrent static func loadMetricsOnly(url: URL,
                                            config: MetricsConfig) async -> FrameMetrics? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // GPU path: read into a Metal shared buffer (same path as the initial load),
        // then run the GPU detection kernel. Much faster than the CPU fallback because
        // the Metal kernel uses the full frame, while the CPU path is limited to a crop.
        if let device = MetalContext.device,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta = bufferResult.metadata
            return await MetricsCalculator.compute(metalBuffer: bufferResult.metalBuffer,
                                                   width: meta.width, height: meta.height,
                                                   config: config,
                                                   bayerPattern: meta.bayerPattern)
        }

        // CPU fallback when Metal is unavailable.
        guard let fits = try? FITSReader.read(from: url) else { return nil }
        return await MetricsCalculator.compute(pixels: fits.pixelValues,
                                               width: fits.width, height: fits.height,
                                               config: config,
                                               bayerPattern: fits.bayerPattern)
    }

    /// Re-reads a single FITS file and renders it in colour with the given shared clip bounds.
    /// Called by `LoadPipeline.renderFolderInColour`.
    @concurrent static func recolorBayerEntry(
        url: URL, rOffset: UInt32, clips: BayerClips,
        maxDisplaySize: Int, maxThumbnailSize: Int
    ) async -> (display: NSImage, thumb: NSImage?)? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let device = MetalContext.device,
              let result = try? FITSReader.readIntoBuffer(from: url, device: device)
        else { return nil }

        guard let display = await ImageStretcher.createBayerImage(
            inputBuffer: result.metalBuffer,
            width: result.metadata.width, height: result.metadata.height,
            rOffset: rOffset, clips: clips, maxDisplaySize: maxDisplaySize
        ) else { return nil }

        let thumb = ImageStretcher.createThumbnail(from: display, maxSize: maxThumbnailSize)
        return (display, thumb)
    }

    /// Phase A of the loading pipeline: read the FITS file, compute the histogram,
    /// and GPU-stretch to produce the display image and thumbnail.
    ///
    /// The returned `FastLoadResult.metalBuffer` is retained so Phase B can run
    /// GPU star-detection on the same buffer without a second file read.
    @concurrent static func loadFast(url: URL,
                                     maxDisplaySize: Int = 1024,
                                     maxThumbnailSize: Int = 120,
                                     debayerColorImages: Bool = false) async -> FastLoadResult {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if let device = MetalContext.device,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta     = bufferResult.metadata
            let floatPtr = bufferResult.metalBuffer.contents().assumingMemoryBound(to: Float.self)
            let histogram = MetricsCalculator.computeHistogram(ptr: floatPtr,
                                                               count: meta.width * meta.height,
                                                               minVal: meta.minValue,
                                                               maxVal: meta.maxValue)

            // Always render a greyscale image immediately so the UI shows something fast.
            // For Bayer images with debayering enabled, also compute per-channel clip bounds
            // so the post-batch normalise pass can re-render in colour with shared median clips.
            // Pass bayerPattern so the greyscale stretch applies 2×2 Bayer binning,
            // eliminating the screen-door effect on raw Bayer mosaic files.
            let display = await ImageStretcher.createImage(inputBuffer: bufferResult.metalBuffer,
                                                           width: meta.width, height: meta.height,
                                                           maxDisplaySize: maxDisplaySize,
                                                           bayerPattern: meta.bayerPattern)
            let bayerClips: BayerClips?
            if debayerColorImages, let pattern = meta.bayerPattern {
                bayerClips = ImageStretcher.computeBayerClips(bufferResult.metalBuffer,
                                                              width: meta.width, height: meta.height,
                                                              rOffset: pattern.rOffset)
            } else {
                bayerClips = nil
            }

            // Compute greyscale clip bounds for non-Bayer images so the post-batch
            // normalisation pass can re-render with per-(folder, filter) median clips.
            let greyClips: GreyClips?
            if meta.bayerPattern == nil {
                greyClips = ImageStretcher.computeGreyClips(bufferResult.metalBuffer,
                                                            pixelCount: meta.width * meta.height)
            } else {
                greyClips = nil
            }

            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            // metalBuffer is retained in FastLoadResult so Phase B can use it.
            return FastLoadResult(
                display: display, thumb: thumb,
                info: "\(meta.width) × \(meta.height)  |  BITPIX: \(meta.bitpix)",
                error: nil, histogram: histogram, headers: meta.headers,
                metalBuffer: bufferResult.metalBuffer, bayerPattern: meta.bayerPattern,
                width: meta.width, height: meta.height,
                bayerClips: bayerClips, greyClips: greyClips)
        }

        do {
            var fits  = try FITSReader.read(from: url)
            let histogram = MetricsCalculator.computeHistogram(pixels: fits.pixelValues,
                                                               minVal: fits.minValue, maxVal: fits.maxValue)
            let display = ImageStretcher.createImage(from: &fits.pixelValues,
                                                     width: fits.width, height: fits.height,
                                                     maxDisplaySize: maxDisplaySize)
            let info    = "\(fits.width) × \(fits.height)  |  BITPIX: \(fits.bitpix)"
            let headers = fits.headers
            let w = fits.width, h = fits.height
            fits.pixelValues = []
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return FastLoadResult(display: display, thumb: thumb, info: info, error: nil,
                                  histogram: histogram, headers: headers,
                                  metalBuffer: nil, bayerPattern: fits.bayerPattern,
                                  width: w, height: h,
                                  bayerClips: nil, greyClips: nil)
        } catch {
            return FastLoadResult(display: nil, thumb: nil, info: "", error: error.localizedDescription,
                                  histogram: nil, headers: [:],
                                  metalBuffer: nil, bayerPattern: nil,
                                  width: 0, height: 0,
                                  bayerClips: nil, greyClips: nil)
        }
    }
}

// MARK: - Phase A result

struct FastLoadResult {
    let display:     NSImage?
    let thumb:       NSImage?
    let info:        String
    let error:       String?
    let histogram:   [Int]?
    let headers:     [String: String]
    /// Raw FITS float pixels in a Metal shared buffer. Passed to Phase B so
    /// GPU detection and Moffat fitting can run without a second file read.
    /// Released when the Phase B task ends. `nil` when the CPU fallback path
    /// was used (Metal unavailable).
    let metalBuffer: MTLBuffer?
    /// The CFA pattern from the header, nil for mono and RGB images.
    let bayerPattern: BayerPattern?
    let width:       Int
    let height:      Int
    /// Per-channel Bayer clip bounds computed during the grey-pass.
    /// `nil` for non-Bayer images or when `debayerColorImages` is false.
    let bayerClips:  BayerClips?
    /// Greyscale clip bounds for non-Bayer images, used by the post-batch normalisation pass.
    let greyClips:   GreyClips?
}
