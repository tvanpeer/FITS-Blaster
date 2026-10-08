//
//  BenchmarkTests.swift
//  FITS Blaster Tests
//
//  Throughput benchmarks — measures FITS load time and MetricsCalculator compute
//  time separately so algorithm changes are isolated from I/O.
//
//  These tests are informational (no assertions fail). They are skipped when the
//  env vars are not set, so they never block CI.
//
//  Usage via run-benchmark.sh, or directly:
//    BENCH_RGB_PATH="/path/to/RGB/LIGHT" \
//    BENCH_MONO_PATH="/path/to/mono/LIGHT" \
//    xcodebuild test -scheme "FITS Blaster" -only-testing "FITS Blaster Tests/BenchmarkTests"
//

import Foundation
import Testing
@testable import FITS_Blaster

struct BenchmarkTests {

    // MARK: - RGB (Bayer)

    @Test("RGB throughput — frames/sec for load and compute")
    func rgbThroughput() async {
        guard let pathString = ProcessInfo.processInfo.environment["BENCH_RGB_PATH"] else {
            print("BENCH: rgb skipped (BENCH_RGB_PATH not set)")
            return
        }
        await runBenchmark(tag: "rgb", dirPath: pathString, expectBayer: true)
    }

    // MARK: - Mono

    @Test("Mono throughput — frames/sec for load and compute")
    func monoThroughput() async {
        guard let pathString = ProcessInfo.processInfo.environment["BENCH_MONO_PATH"] else {
            print("BENCH: mono skipped (BENCH_MONO_PATH not set)")
            return
        }
        await runBenchmark(tag: "mono", dirPath: pathString, expectBayer: false)
    }

    // MARK: - Core

    private func runBenchmark(tag: String, dirPath: String, expectBayer: Bool) async {
        let dir = URL(filePath: dirPath)
        let urls: [URL]
        do {
            urls = try FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension.lowercased() == "fits" || $0.pathExtension.lowercased() == "fit" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            print("BENCH: \(tag) error listing \(dirPath): \(error)")
            return
        }

        guard !urls.isEmpty else {
            print("BENCH: \(tag) no .fits/.fit files found in \(dirPath)")
            return
        }

        let config = MetricsConfig()
        let clock  = ContinuousClock()

        // --- Load pass ---
        var images: [FITSImage] = []
        images.reserveCapacity(urls.count)

        let loadStart = clock.now
        for url in urls {
            guard let image = try? FITSReader.read(from: url) else { continue }
            images.append(image)
        }
        let loadElapsed = clock.now - loadStart

        guard !images.isEmpty else {
            print("BENCH: \(tag) failed to load any files")
            return
        }

        // --- Compute pass ---
        let computeStart = clock.now
        for image in images {
            _ = await MetricsCalculator.compute(
                pixels: image.pixelValues,
                width: image.width,
                height: image.height,
                config: config,
                bayerPattern: image.bayerPattern)
        }
        let computeElapsed = clock.now - computeStart

        let n           = images.count
        let loadSec     = loadElapsed.asSeconds
        let computeSec  = computeElapsed.asSeconds
        let totalSec    = loadSec + computeSec

        // Print in a machine-parseable format for run-benchmark.sh
        // BENCH:<tag>:<n>:<load_s>:<compute_s>
        print(String(format: "BENCH:%@:%d:%.3f:%.3f", tag, n, loadSec, computeSec))

        // Human-readable summary
        func fps(_ sec: Double) -> String {
            sec > 0 ? String(format: "%.1f fps", Double(n) / sec) : "—"
        }
        print(String(format: """
            \n%@ benchmark (%d frames)
              Load:    %5.2f s  (%@)
              Compute: %5.2f s  (%@)
              Total:   %5.2f s  (%@)
            """,
            tag.uppercased(), n,
            loadSec,    fps(loadSec),
            computeSec, fps(computeSec),
            totalSec,   fps(totalSec)))
    }
}

// MARK: - Duration helper

private extension Duration {
    var asSeconds: Double {
        let (secs, attosecs) = components
        return Double(secs) + Double(attosecs) * 1e-18
    }
}
