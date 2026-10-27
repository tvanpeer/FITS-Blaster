//
//  FITSTypes.swift
//  FITS Blaster
//
//  Errors and result types of FITSReader.
//

import Foundation

/// Errors that can occur when reading FITS files
enum FITSError: LocalizedError {
    case cannotOpenFile
    case invalidFormat(String)
    case unsupportedBitpix(Int)
    /// A stack with colour planes (NAXIS3 > 1): the app loads single frames only.
    case multiChannel(naxis: Int, planes: Int)
    case noImageData
    case metalBufferAllocationFailed

    var errorDescription: String? {
        switch self {
        case .cannotOpenFile:
            return "Cannot open the FITS file."
        case .invalidFormat(let detail):
            return "Invalid FITS format: \(detail)"
        case .unsupportedBitpix(let value):
            if value < 0 {
                return "Unsupported image format: floating-point FITS files (BITPIX=\(value)) are not supported. Only integer formats (8, 16, 32-bit) are supported."
            }
            return "Unsupported BITPIX value: \(value). Supported values are 8, 16, and 32."
        case .multiChannel(let naxis, let planes):
            return "Multi-channel FITS files (NAXIS=\(naxis), NAXIS3=\(planes)) are not supported. Load the raw single-frame sub-exposures instead."
        case .noImageData:
            return "No image data found in the FITS file."
        case .metalBufferAllocationFailed:
            return "Failed to allocate Metal buffer for image data."
        }
    }
}

/// Lightweight metadata from a parsed FITS file (no pixel data)
struct FITSMetadata {
    let width: Int
    let height: Int
    let bitpix: Int
    let minValue: Float
    let maxValue: Float
    let headers: [String: String]
    /// Non-nil when the FITS headers declare a recognised Bayer CFA pattern.
    let bayerPattern: BayerPattern?
}

/// Represents a parsed FITS image with its raw pixel data and metadata.
struct FITSImage {
    let width: Int
    let height: Int
    let bitpix: Int
    /// Number of colour channels: 1 for greyscale, 3 for RGB (NAXIS3=3).
    let channels: Int
    /// Pixel values. For `channels == 1`: `width × height` floats.
    /// For `channels == 3`: `width × height × 3` interleaved R,G,B floats.
    var pixelValues: [Float]
    let minValue: Float
    let maxValue: Float
    let headers: [String: String]
    /// Non-nil when the FITS headers declare a recognised Bayer CFA pattern.
    let bayerPattern: BayerPattern?
}
