//
//  BenchmarkTests.swift
//  FITS Blaster Tests
//
//  Throughput benchmarks — mirrors the app's loadMetricsOnly code path:
//  Metal GPU pipeline when available, CPU fallback otherwise.
//  Frames are processed with the same concurrent task group policy as the app.
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
        await runBenchmark(tag: "rgb", dirPath: pathString)
    }

    // MARK: - Mono

    @Test("Mono throughput — frames/sec for load and compute")
    func monoThroughput() async {
        guard let pathString = ProcessInfo.processInfo.environment["BENCH_MONO_PATH"] else {
            print("BENCH: mono skipped (BENCH_MONO_PATH not set)")
            return
        }
        await runBenchmark(tag: "mono", dirPath: pathString)
    }

    // MARK: - Core

    private func runBenchmark(tag: String, dirPath: String) async {
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

        let config   = MetricsConfig()
        let clock    = ContinuousClock()
        let device   = ImageStretcher.metalDevice
        let pathLabel = device != nil ? "Metal" : "CPU fallback"

        // Pipelined load+compute per frame, mirroring loadMetricsOnly.
        // Metal buffers are released as each task finishes, so memory stays bounded.
        let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

        struct FrameSize { let width: Int; let height: Int }

        let start = clock.now
        let processed: [FrameSize] = await withTaskGroup(of: FrameSize?.self) { group in
            var activeCount = 0
            var collected: [FrameSize] = []
            collected.reserveCapacity(urls.count)

            for url in urls {
                if activeCount >= maxConcurrency {
                    if let r = await group.next(), let r { collected.append(r) }
                    activeCount -= 1
                }
                group.addTask {
                    if let device,
                       let buf = try? FITSReader.readIntoBuffer(from: url, device: device) {
                        let meta = buf.metadata
                        _ = await MetricsCalculator.compute(
                            metalBuffer: buf.metalBuffer,
                            device: device,
                            width: meta.width, height: meta.height,
                            config: config,
                            bayerPattern: meta.bayerPattern)
                        return FrameSize(width: meta.width, height: meta.height)
                    } else if let fits = try? FITSReader.read(from: url) {
                        _ = await MetricsCalculator.compute(
                            pixels: fits.pixelValues,
                            width: fits.width, height: fits.height,
                            config: config,
                            bayerPattern: fits.bayerPattern)
                        return FrameSize(width: fits.width, height: fits.height)
                    }
                    return nil
                }
                activeCount += 1
            }
            for await r in group { if let r { collected.append(r) } }
            return collected
        }
        let elapsed = clock.now - start

        guard !processed.isEmpty else {
            print("BENCH: \(tag) failed to process any files")
            return
        }

        let n        = processed.count
        let totalMpx = processed.reduce(0.0) { $0 + Double($1.width * $1.height) / 1_000_000 }
        let sec      = elapsed.asSeconds

        // Machine-parseable line for run-benchmark.sh.
        // Format: BENCH:<tag>:<n>:<total_mpx>:<elapsed_s>
        print(String(format: "BENCH:%@:%d:%.2f:%.3f", tag, n, totalMpx, sec))

        func fps() -> String { sec > 0 ? String(format: "%.1f fps", Double(n) / sec) : "—" }
        func mps() -> String { sec > 0 ? String(format: "%.0f MP/s", totalMpx / sec) : "—" }
        print(String(format: """
            \n%@ benchmark (%d frames, %.0f MP total, %.0f MP/frame avg, %@)
              Total: %5.2f s  (%@  %@)
            """,
            tag.uppercased(), n, totalMpx, totalMpx / Double(n), pathLabel,
            sec, fps(), mps()))
    }
}

// MARK: - Duration helper

private extension Duration {
    var asSeconds: Double {
        let (secs, attosecs) = components
        return Double(secs) + Double(attosecs) * 1e-18
    }
}
