//
//  FITSHeader.swift
//  FITS Blaster
//
//  The FITS header: the cheap BITPIX check and the validating header parser,
//  shared by every read path. Every file is untrusted input (CODE_AUDIT §5.2).
//

import Foundation

extension FITSReader {

    // MARK: - BITPIX Peek (cheap format check)

    /// Reads only the first FITS header block (2880 bytes) and returns the BITPIX value.
    /// Used to skip unsupported formats before creating an entry. Returns nil on any error.
    static func peekBitpix(url: URL) -> Int? {
        guard let block = readFirstBlock(of: url), block.count >= 80 else { return nil }
        for i in stride(from: 0, to: block.count, by: 80) {
            let end = min(i + 80, block.count)
            guard let cardString = String(data: block[i..<end], encoding: .ascii) else { continue }
            let card = parseCard(cardString)
            guard card.keyword == "BITPIX" else { continue }
            return card.value.flatMap { Int($0) }
        }
        return nil
    }

    /// The first 2880-byte block of a file (less if the file is shorter), read with POSIX
    /// open/read: on an SMB share FileHandle took about 4 times as long per file (100 ms
    /// against 27 ms, measured 2026-10-25), and this runs for every file of a folder.
    private static func readFirstBlock(of url: URL) -> Data? {
        let fd = Darwin.open(url.path(percentEncoded: false), O_RDONLY)
        guard fd >= 0 else { return nil }
        defer { Darwin.close(fd) }
        var block = Data(count: 2880)
        var filled = 0
        while filled < 2880 {
            let n = block.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress?.advanced(by: filled), 2880 - filled) }
            if n <= 0 { break }   // end of file, or an error
            filled += n
        }
        return block.prefix(filled)
    }

    // MARK: - Header Parsing (shared between both read paths)

    /// Splits one 80-character header card into its keyword and, for `KEY = value / comment`
    /// cards, the value without the comment. Cards without `= ` in columns 9–10 have no value.
    static func parseCard(_ card: String) -> (keyword: String, value: String?) {
        let keyword = String(card.prefix(8)).trimmingCharacters(in: .whitespaces)
        guard card.count > 10, card.dropFirst(8).prefix(2) == "= " else { return (keyword, nil) }
        let valueComment = card.dropFirst(10)
        let value = valueComment.firstIndex(of: "/").map { valueComment[..<$0] } ?? valueComment
        return (keyword, value.trimmingCharacters(in: .whitespaces))
    }

    /// Removes FITS string quoting and trailing whitespace from a header value.
    static func cleanHeaderString(_ s: String) -> String {
        var result = s.trimmingCharacters(in: .whitespaces)
        if result.hasPrefix("'") { result.removeFirst() }
        if result.hasSuffix("'") { result.removeLast() }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Parsed header info needed before pixel reading
    struct HeaderInfo {
        let width: Int
        let height: Int
        let bitpix: Int
        let channels: Int
        let bzero: Double
        let bscale: Double
        let dataOffset: Int
        let headers: [String: String]
    }

    /// Largest NAXIS1 or NAXIS2 accepted. Far above any camera sensor; larger images
    /// (big mosaics) are made after culling and stacking.
    static let maxAxisLength = 65_536

    /// Header blocks (2880 bytes each) searched for the END card before giving up,
    /// so a file without END isn't parsed card by card to its end.
    static let maxHeaderBlocks = 100

    /// Every FITS file is untrusted input (Quick Look parses files from Finder without
    /// the user opening them), so every size and scale value is checked here before
    /// anything is allocated or indexed. Anything invalid throws, never traps.
    ///
    /// `data` holds the file from its start, at least up to the END card; `fileSize` is the
    /// whole file's size when `data` holds only the header (`readIntoBuffer`), so the size
    /// checks see the real file.
    static func parseHeader(from data: Data, fileSize: Int? = nil,
                                    forPreview: Bool = false) throws -> HeaderInfo {
        let fileSize = fileSize ?? data.count
        guard fileSize >= 2880, data.count >= min(fileSize, 2880) else {
            throw FITSError.invalidFormat("File too small to be a valid FITS file.")
        }

        var headerCards: [(String, String)] = []
        var offset = 0
        var foundEnd = false
        var blockCount = 0

        while offset < data.count {
            guard blockCount < maxHeaderBlocks else {
                throw FITSError.invalidFormat("No END card in the first \(maxHeaderBlocks) header blocks.")
            }
            blockCount += 1
            let blockEnd = min(offset + 2880, data.count)
            let block = data[offset..<blockEnd]

            for cardStart in stride(from: block.startIndex, to: block.endIndex, by: 80) {
                let cardEnd = min(cardStart + 80, block.endIndex)
                guard cardEnd - cardStart == 80 else { break }
                let cardData = block[cardStart..<cardEnd]
                guard let cardString = String(data: cardData, encoding: .ascii) else { continue }

                let card = parseCard(cardString)

                if card.keyword == "END" {
                    foundEnd = true
                    break
                }

                if let value = card.value {
                    headerCards.append((card.keyword, value))
                }
            }

            offset = blockEnd
            if foundEnd { break }
        }

        guard foundEnd else {
            throw FITSError.invalidFormat("No END card found in header.")
        }

        guard let bitpixStr = headerCards.first(where: { $0.0 == "BITPIX" })?.1,
              let bitpix = Int(bitpixStr) else {
            throw FITSError.invalidFormat("Missing or invalid BITPIX keyword.")
        }
        let supported = forPreview ? [8, 16, 32, -32, -64] : [8, 16, 32]
        guard supported.contains(bitpix) else {
            throw FITSError.unsupportedBitpix(bitpix)
        }

        guard let naxisStr = headerCards.first(where: { $0.0 == "NAXIS" })?.1,
              let naxis = Int(naxisStr), (2...999).contains(naxis) else {
            throw FITSError.invalidFormat("Missing NAXIS, or NAXIS outside 2–999.")
        }

        // Multi-channel FITS (NAXIS=3, NAXIS3=3): allowed only in preview mode.
        let channels: Int
        if naxis > 2,
           let naxis3Str = headerCards.first(where: { $0.0 == "NAXIS3" })?.1,
           let naxis3 = Int(naxis3Str), naxis3 > 1 {
            if forPreview && naxis3 == 3 {
                channels = 3
            } else {
                throw FITSError.invalidFormat(
                    "Multi-channel FITS files (NAXIS=\(naxis), NAXIS3=\(naxis3)) are not supported. " +
                    "Load the raw single-frame sub-exposures instead."
                )
            }
        } else {
            channels = 1
        }

        guard let naxis1Str = headerCards.first(where: { $0.0 == "NAXIS1" })?.1,
              let width = Int(naxis1Str) else {
            throw FITSError.invalidFormat("Missing NAXIS1.")
        }

        guard let naxis2Str = headerCards.first(where: { $0.0 == "NAXIS2" })?.1,
              let height = Int(naxis2Str) else {
            throw FITSError.invalidFormat("Missing NAXIS2.")
        }

        let axisRange = 1...maxAxisLength
        guard axisRange.contains(width), axisRange.contains(height) else {
            throw FITSError.invalidFormat(
                "Image size \(width) × \(height) is outside 1–\(maxAxisLength) pixels per side.")
        }

        let bzero: Double
        if let bzeroStr = headerCards.first(where: { $0.0 == "BZERO" })?.1 {
            bzero = Double(bzeroStr) ?? 0.0
        } else {
            bzero = 0.0
        }

        let bscale: Double
        if let bscaleStr = headerCards.first(where: { $0.0 == "BSCALE" })?.1 {
            bscale = Double(bscaleStr) ?? 1.0
        } else {
            bscale = 1.0
        }

        // The pixels are scaled in Float, so the values must also be finite as Float.
        guard bzero.isFinite, bscale.isFinite, Float(bzero).isFinite, Float(bscale).isFinite else {
            throw FITSError.invalidFormat("BSCALE or BZERO is not a finite number.")
        }

        let bytesPerPixel = abs(bitpix) / 8
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (totalValues, valuesOverflow) = pixelCount.multipliedReportingOverflow(by: channels)
        let (dataBytes, bytesOverflow) = totalValues.multipliedReportingOverflow(by: bytesPerPixel)
        let (dataEnd, endOverflow) = offset.addingReportingOverflow(dataBytes)
        guard !(pixelOverflow || valuesOverflow || bytesOverflow || endOverflow) else {
            throw FITSError.invalidFormat("Image size \(width) × \(height) is too large.")
        }

        guard offset < fileSize else {
            throw FITSError.noImageData
        }

        guard dataEnd <= fileSize else {
            throw FITSError.invalidFormat("Not enough data for \(totalValues) values at \(bytesPerPixel) bytes each.")
        }

        // Build a flat dictionary of all parsed header cards. String values are cleaned
        // here, once (quotes and padding removed), not by every reader (CODE_AUDIT §7.5).
        var headers: [String: String] = [:]
        for (key, value) in headerCards where !key.isEmpty {
            headers[key] = cleanHeaderString(value)
        }

        return HeaderInfo(width: width, height: height, bitpix: bitpix, channels: channels,
                          bzero: bzero, bscale: bscale, dataOffset: offset, headers: headers)
    }
}
