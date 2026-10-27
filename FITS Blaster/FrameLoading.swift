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

    /// The items to load: FITS files that aren't in the session yet, in input order. No
    /// file is read here: a file with an unsupported format (floating-point FITS) is
    /// recognised by Phase A, which reads the header anyway, and then left out — so the
    /// first frames start loading right after the scan (decided 2026-10-27; the separate
    /// header check before the load cost up to 13 s over a network).
    static func candidates(_ items: [(url: URL, subfolderPath: String)],
                           existingURLs: Set<URL>) -> [(url: URL, subfolderPath: String)] {
        items.filter { FITSFile.hasFITSExtension($0.url) && !existingURLs.contains($0.url) }
    }

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

        // An unsupported format (floating-point FITS, or a stack with colour planes) is
        // reported as such, so the load
        // leaves the frame out; it is recognised from the header, before the pixels are read.
        var bufferResult: FITSBufferResult?
        if let device = MetalContext.device {
            do {
                bufferResult = try FITSReader.readIntoBuffer(from: url, device: device)
            } catch FITSError.unsupportedBitpix, FITSError.multiChannel {
                return .unsupported
            } catch {
                bufferResult = nil   // the CPU read below reports the error
            }
        }
        if let bufferResult {
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
        } catch FITSError.unsupportedBitpix, FITSError.multiChannel {
            return .unsupported
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
    /// The file has a format FITS Blaster doesn't load (floating-point FITS, or a stack with
    /// colour planes): the load
    /// leaves the frame out and lists it as skipped.
    var isUnsupported = false

    /// The result for a file in an unsupported format.
    static var unsupported: FastLoadResult { FastLoadResult(display: nil, thumb: nil, info: "", error: nil,
                                            histogram: nil, headers: [:],
                                            metalBuffer: nil, bayerPattern: nil,
                                            width: 0, height: 0,
                                            bayerClips: nil, greyClips: nil, isUnsupported: true) }
}
