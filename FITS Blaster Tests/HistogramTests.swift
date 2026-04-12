//
//  HistogramTests.swift
//  FITS Blaster Tests
//
//  Tests for MetricsCalculator.computeHistogram: bin count, boundary values,
//  uniform/skewed distributions, edge cases, and the median helper.
//

import XCTest
@testable import FITS_Blaster

final class HistogramTests: XCTestCase {

    // MARK: - Bin count

    func testHistogramAlwaysReturns256Bins() {
        let pixels: [Float] = [0, 50, 100, 200, 255]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: 255)
        XCTAssertEqual(hist.count, 256)
    }

    // MARK: - Empty and degenerate inputs

    func testEmptyArrayReturns256Zeros() {
        let hist = MetricsCalculator.computeHistogram(pixels: [], minVal: 0, maxVal: 255)
        XCTAssertEqual(hist.count, 256)
        XCTAssertEqual(hist.reduce(0, +), 0)
    }

    func testEqualMinMaxReturns256Zeros() {
        // All pixels identical → maxVal == minVal → guard returns zeros
        let pixels: [Float] = [42, 42, 42]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 42, maxVal: 42)
        XCTAssertEqual(hist.reduce(0, +), 0)
    }

    // MARK: - Single pixel

    func testSinglePixelAtMinGoesToFirstBin() {
        let hist = MetricsCalculator.computeHistogram(pixels: [0], minVal: 0, maxVal: 100)
        XCTAssertEqual(hist[0], 1)
        XCTAssertEqual(hist.reduce(0, +), 1)
    }

    func testSinglePixelAtMaxGoesToLastBin() {
        let hist = MetricsCalculator.computeHistogram(pixels: [100], minVal: 0, maxVal: 100)
        XCTAssertEqual(hist[255], 1)
        XCTAssertEqual(hist.reduce(0, +), 1)
    }

    // MARK: - Known distribution

    func testTwoValuesSplitToFirstAndLastBins() {
        let pixels: [Float] = [0, 1000]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: 1000)
        XCTAssertEqual(hist[0], 1)
        XCTAssertEqual(hist[255], 1)
        XCTAssertEqual(hist.reduce(0, +), 2)
    }

    func testMidValueGoesToMiddleBin() {
        let pixels: [Float] = [500]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: 1000)
        // 500/1000 * 255 ≈ 127
        let midBin = Int((500.0 / 1000.0) * 255.0)
        XCTAssertEqual(hist[midBin], 1)
    }

    // MARK: - Stride sampling

    func testStrideSamplingOnLargeArray() {
        // With > 60,000 pixels, stride > 1, so not every pixel is counted.
        // Total samples should be approximately count / stride.
        let count = 120_000
        let pixels = [Float](repeating: 500, count: count)
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: 1000)
        let totalSampled = hist.reduce(0, +)

        let stride = max(1, count / 60_000)   // = 2
        let expectedSamples = (count + stride - 1) / stride
        // Allow some tolerance for off-by-one in stride loop
        XCTAssertGreaterThan(totalSampled, expectedSamples - 2)
        XCTAssertLessThanOrEqual(totalSampled, expectedSamples + 1)
    }

    func testNoStrideSamplingOnSmallArray() {
        // With ≤ 60,000 pixels, every pixel should be counted.
        let count = 100
        let pixels = (0..<count).map { Float($0) }
        let hist = MetricsCalculator.computeHistogram(pixels: pixels,
                                                       minVal: 0, maxVal: Float(count - 1))
        XCTAssertEqual(hist.reduce(0, +), count)
    }

    // MARK: - Auto min/max overload

    func testAutoMinMaxOverload() {
        let pixels: [Float] = [10, 20, 30, 40, 50]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, width: 5, height: 1)
        XCTAssertEqual(hist.count, 256)
        // All 5 pixels should be sampled (count < 60,000)
        XCTAssertEqual(hist.reduce(0, +), 5)
        // Min pixel (10) → bin 0, max pixel (50) → bin 255
        XCTAssertEqual(hist[0], 1)
        XCTAssertEqual(hist[255], 1)
    }

    // MARK: - Negative pixel values (BZERO-shifted data)

    func testNegativePixelValues() {
        let pixels: [Float] = [-100, -50, 0, 50, 100]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: -100, maxVal: 100)
        XCTAssertEqual(hist.count, 256)
        XCTAssertEqual(hist.reduce(0, +), 5)
        XCTAssertEqual(hist[0], 1)     // -100 → first bin
        XCTAssertEqual(hist[255], 1)   // 100 → last bin
    }

    // MARK: - Median helper

    func testMedianOddCount() {
        XCTAssertEqual(MetricsCalculator.median([3, 1, 2]), 2)
    }

    func testMedianEvenCount() {
        // vDSP sort + index count/2 → picks element at index 2 (0-indexed) from sorted
        let result = MetricsCalculator.median([4, 1, 3, 2])
        XCTAssertEqual(result, 3)  // sorted: [1,2,3,4], index 4/2=2 → 3
    }

    func testMedianSingleElement() {
        XCTAssertEqual(MetricsCalculator.median([42]), 42)
    }

    func testMedianEmptyReturnsNil() {
        XCTAssertNil(MetricsCalculator.median([]))
    }
}
