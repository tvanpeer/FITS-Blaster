//
//  RejectedFolderPathTests.swift
//  FITS Blaster Tests
//
//  Step 11a: the REJECTED folder rules in `RejectedFolder`, shared by the app, the folder
//  scan, the load pipeline and the CLI (CODE_AUDIT §9.8).
//

import Foundation
import Testing
@testable import FITS_Blaster

struct RejectedFolderPathTests {

    @Test("The folder name matches in any case", arguments: ["REJECTED", "rejected", "Rejected"])
    func nameAnyCase(name: String) {
        #expect(RejectedFolder.isRejectedFolder(name: name))
    }

    @Test("Other folder names don't match", arguments: ["REJECTED2", "NOT REJECTED", "Ha", ""])
    func otherNames(name: String) {
        #expect(!RejectedFolder.isRejectedFolder(name: name))
    }

    @Test("A frame goes into REJECTED next to it, and comes back from there")
    func bothDirections() {
        let frame = URL(fileURLWithPath: "/night/LIGHT/Ha/frame 1.fits")
        let rejected = RejectedFolder.rejectedURL(for: frame)
        #expect(rejected == URL(fileURLWithPath: "/night/LIGHT/Ha/REJECTED/frame 1.fits"))
        #expect(RejectedFolder.folder(for: frame) == URL(fileURLWithPath: "/night/LIGHT/Ha/REJECTED/"))
        #expect(RejectedFolder.isInRejectedFolder(rejected))
        #expect(!RejectedFolder.isInRejectedFolder(frame))
        #expect(RejectedFolder.originalURL(for: rejected) == frame)
    }

    @Test("A lower-case rejected folder leads back to the folder above it")
    func originalFromLowerCase() {
        #expect(RejectedFolder.originalURL(for: URL(fileURLWithPath: "/n/Ha/rejected/c.fits"))
                == URL(fileURLWithPath: "/n/Ha/c.fits"))
    }

    @Test("Only files directly in REJECTED count, not deeper ones")
    func onlyDirectChildren() {
        #expect(!RejectedFolder.isInRejectedFolder(URL(fileURLWithPath: "/n/REJECTED/sub/d.fits")))
    }

    @Test("The scan with REJECTED on finds exactly the files the app and the CLI mark rejected")
    func scanAndRuleAgree() throws {
        let root = FileManager.default.temporaryDirectory.appending(component: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        for dir in ["Ha/REJECTED", "OIII/rejected", "REJECTED"] {
            try fm.createDirectory(at: root.appending(path: dir), withIntermediateDirectories: true)
        }
        let files = ["a.fits", "Ha/b.fits", "Ha/REJECTED/c.fits", "OIII/d.fits", "OIII/rejected/e.fits",
                     "REJECTED/f.fits"]
        for file in files { try Data([0]).write(to: root.appending(path: file)) }

        let collected = ImageStore.collectFITSURLs(in: root, relativePath: "", excludedNames: [],
                                                   includeSubfolders: true, includeRejected: true)
        let names = Set(RejectedFolder.rejectedURLs(in: collected).map(\.lastPathComponent))
        #expect(collected.count == files.count)
        #expect(names == ["c.fits", "e.fits", "f.fits"])
    }
}
