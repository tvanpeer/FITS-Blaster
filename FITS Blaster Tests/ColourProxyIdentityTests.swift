//
//  ColourProxyIdentityTests.swift
//  FITS Blaster Tests
//
//  Master-plan 9f part 2b-0: the colour render in two passes (`averageBayer`, then
//  `createBayerImage(from:clips:)`) must give the same bytes as the one-pass kernel
//  (`createBayerImage(inputBuffer:…)`), on real frames and at the display sizes that
//  scale down and that don't. The shaders are compiled with fast math, so the compiler
//  could round differently where the kernel is split; this checks that it doesn't.
//
//  Every Bayer frame of the render-test colour folders, with the folder's median clips
//  (as the load uses) at 1024, 2048 and 4096, and with the frame's own clips at 1024.
//  Needs FB_TEST_DATA and FB_TEST_DATA_FULL=1, like the large render tests.
//

import AppKit
import Testing
@testable import FITS_Blaster

@Suite(.enabled(if: RenderTestData.root != nil && RenderTestData.full && MetalContext.device != nil,
                "Set FB_TEST_DATA and FB_TEST_DATA_FULL=1; needs Metal"),
       .serialized)
struct ColourProxyIdentityTests {

    static let displaySizes = [1024, 2048, 4096]

    @Test("Two passes give the one-pass colour bytes", arguments: RenderTestData.colourFolders)
    func sameBytes(_ relativePath: String) async throws {
        let root = try #require(RenderTestData.root)
        let device = try #require(MetalContext.device)
        let folder = root.appending(path: relativePath)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { FITSFile.hasFITSExtension($0) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        try #require(!files.isEmpty, "no frames in \(relativePath)")

        // The folder's shared clips, as the load computes them.
        var ownClips: [URL: BayerClips] = [:]
        for url in files {
            let read = try FITSReader.readIntoBuffer(from: url, device: device)
            let pattern = try #require(read.metadata.bayerPattern, "\(url.lastPathComponent) is not a Bayer frame")
            ownClips[url] = ImageStretcher.computeBayerClips(read.metalBuffer, width: read.metadata.width,
                                                             height: read.metadata.height, rOffset: pattern.rOffset)
        }
        let shared = BayerClips.median(of: files.compactMap { ownClips[$0] })
        try #require(shared.isValid)

        var compared = 0, differing: [String] = []
        for url in files {
            let read = try FITSReader.readIntoBuffer(from: url, device: device)
            let width = read.metadata.width, height = read.metadata.height
            let rOffset = try #require(read.metadata.bayerPattern).rOffset
            var cases = Self.displaySizes.map { (size: $0, clips: shared, label: "shared") }
            if let own = ownClips[url], own.isValid { cases.append((1024, own, "own")) }
            for item in cases {
                let onePass = try #require(await ImageStretcher.createBayerImage(
                    inputBuffer: read.metalBuffer, width: width, height: height,
                    rOffset: rOffset, clips: item.clips, maxDisplaySize: item.size))
                let proxy = try #require(await ImageStretcher.averageBayer(
                    inputBuffer: read.metalBuffer, width: width, height: height,
                    rOffset: rOffset, maxDisplaySize: item.size))
                let twoPass = try #require(await ImageStretcher.createBayerImage(from: proxy, clips: item.clips))
                let a = try #require(RGBAPixels(onePass)), b = try #require(RGBAPixels(twoPass))
                compared += 1
                if a.width != b.width || a.height != b.height || a.bytes != b.bytes {
                    let diff = zip(a.bytes, b.bytes).filter { $0 != $1 }.count
                    differing.append("\(url.lastPathComponent) at \(item.size) (\(item.label) clips): \(diff) bytes differ")
                }
            }
        }
        print("PROXY IDENTITY \(relativePath): \(compared) renders compared, \(differing.count) differ")
        #expect(differing.isEmpty, "\(differing.prefix(10).joined(separator: "; "))")
    }
}
