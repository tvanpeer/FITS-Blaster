//
//  HeaderFactsTests.swift
//  FITS Blaster Tests
//
//  Header values are cleaned once when a file is read, and ImageEntry stores the
//  facts derived from them (filter name, filter group, Bayer pattern) when its headers
//  are set (CODE_AUDIT §7.5a).
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct HeaderFactsTests {

    private func entry(_ headers: [String: String]) -> ImageEntry {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/data/frame.fits"))
        entry.headers = headers
        return entry
    }

    @Test("Setting headers stores the filter name, filter group and Bayer pattern")
    func factsStored() {
        let e = entry(["FILTER": "Ha", "BAYERPAT": "RGGB"])
        #expect(e.filterName == "Ha")
        #expect(e.filterGroup == FilterGroup.normalise("Ha"))
        #expect(e.bayerPattern == .rggb)
        #expect(e.isBayer)
    }

    @Test("No FILTER, or an empty one, means no filter name and the unfiltered group")
    func noFilter() {
        for headers in [[:], ["FILTER": ""]] {
            let e = entry(headers)
            #expect(e.filterName == nil)
            #expect(e.filterGroup == .unfiltered)
            #expect(e.bayerPattern == nil)
            #expect(!e.isBayer)
        }
    }

    @Test("Changing the headers updates the stored facts")
    func factsFollowHeaders() {
        let e = entry(["FILTER": "Ha"])
        e.headers = ["FILTER": "OIII", "COLORTYP": "GBRG"]
        #expect(e.filterName == "OIII")
        #expect(e.filterGroup == FilterGroup.normalise("OIII"))
        #expect(e.bayerPattern == .gbrg)
    }

    @Test("The reader cleans string values once: quotes and padding removed, numbers unchanged")
    func readerCleansValues() throws {
        let cards = TestFITS.imageCards(bitpix: 16, width: 4, height: 4, bzero: 32768, extraCards: [
            TestFITS.card("FILTER", value: "'Ha      '"),
            TestFITS.card("BAYERPAT", value: "'RGGB'"),
            TestFITS.card("EXPTIME", float: 300),
        ])
        let data = TestFITS.fileData(cards: cards, pixels: TestFITS.bigEndian([Int16](repeating: 0, count: 16)))
        let url = FileManager.default.temporaryDirectory.appending(component: "\(UUID().uuidString).fits")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let image = try FITSReader.read(from: url)
        #expect(image.headers["FILTER"] == "Ha")
        #expect(image.headers["BAYERPAT"] == "RGGB")
        #expect(image.headers["EXPTIME"].flatMap(Double.init) == 300)
        #expect(image.bayerPattern == .rggb)
    }
}
