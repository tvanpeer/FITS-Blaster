//
//  HistogramTests.swift
//  FITS Blaster Tests
//
//  Tests for MetricsCalculator.computeHistogram: bin count, boundary values,
//  uniform/skewed distributions, edge cases, and the median helper.
//

import Testing
@testable import FITS_Blaster

struct HistogramTests {

    // MARK: - Bin count

    @Test("Histogram always returns 256 bins")
    func histogramReturns256Bins() {
        let hist = MetricsCalculator.computeHistogram(pixels: [0, 50, 100, 200, 255],
                                                       minVal: 0, maxVal: 255)
        #expect(hist.count == 256)
    }

    // MARK: - Empty and degenerate inputs

    @Test("Empty array returns 256 zeros")
    func emptyArrayReturns256Zeros() {
        let hist = MetricsCalculator.computeHistogram(pixels: [], minVal: 0, maxVal: 255)
        #expect(hist.count == 256)
        #expect(hist.reduce(0, +) == 0)
    }

    @Test("Equal min/max returns 256 zeros")
    func equalMinMaxReturns256Zeros() {
        let hist = MetricsCalculator.computeHistogram(pixels: [42, 42, 42], minVal: 42, maxVal: 42)
        #expect(hist.reduce(0, +) == 0)
    }

    // MARK: - Single pixel

    @Test("Single pixel at min goes to first bin")
    func singlePixelAtMin() {
        let hist = MetricsCalculator.computeHistogram(pixels: [0], minVal: 0, maxVal: 100)
        #expect(hist[0] == 1)
        #expect(hist.reduce(0, +) == 1)
    }

    @Test("Single pixel at max goes to last bin")
    func singlePixelAtMax() {
        let hist = MetricsCalculator.computeHistogram(pixels: [100], minVal: 0, maxVal: 100)
        #expect(hist[255] == 1)
        #expect(hist.reduce(0, +) == 1)
    }

    // MARK: - Known distribution

    @Test("Two extreme values split to first and last bins")
    func twoValuesSplitToFirstAndLastBins() {
        let hist = MetricsCalculator.computeHistogram(pixels: [0, 1000], minVal: 0, maxVal: 1000)
        #expect(hist[0] == 1)
        #expect(hist[255] == 1)
        #expect(hist.reduce(0, +) == 2)
    }

    @Test("Mid value goes to middle bin")
    func midValueGoesToMiddleBin() {
        let hist = MetricsCalculator.computeHistogram(pixels: [500], minVal: 0, maxVal: 1000)
        let midBin = Int((500.0 / 1000.0) * 255.0)
        #expect(hist[midBin] == 1)
    }

    // MARK: - Stride sampling

    @Test("Large arrays are stride-sampled")
    func strideSamplingOnLargeArray() {
        let count = 120_000
        let pixels = [Float](repeating: 500, count: count)
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: 1000)
        let totalSampled = hist.reduce(0, +)
        let stride = max(1, count / 60_000)
        let expectedSamples = (count + stride - 1) / stride
        #expect(totalSampled >= expectedSamples - 2 && totalSampled <= expectedSamples + 1)
    }

    @Test("Small arrays are fully sampled")
    func noStrideSamplingOnSmallArray() {
        let count = 100
        let pixels = (0..<count).map { Float($0) }
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, minVal: 0, maxVal: Float(count - 1))
        #expect(hist.reduce(0, +) == count)
    }

    // MARK: - Auto min/max overload

    @Test("Auto min/max overload finds bounds and samples all pixels")
    func autoMinMaxOverload() {
        let pixels: [Float] = [10, 20, 30, 40, 50]
        let hist = MetricsCalculator.computeHistogram(pixels: pixels, width: 5, height: 1)
        #expect(hist.count == 256)
        #expect(hist.reduce(0, +) == 5)
        #expect(hist[0] == 1, "Min pixel should be in first bin")
        #expect(hist[255] == 1, "Max pixel should be in last bin")
    }

    // MARK: - Negative pixel values

    @Test("Negative pixel values (BZERO-shifted data)")
    func negativePixelValues() {
        let hist = MetricsCalculator.computeHistogram(pixels: [-100, -50, 0, 50, 100],
                                                       minVal: -100, maxVal: 100)
        #expect(hist.count == 256)
        #expect(hist.reduce(0, +) == 5)
        #expect(hist[0] == 1, "-100 should be in first bin")
        #expect(hist[255] == 1, "100 should be in last bin")
    }

    // MARK: - Median helper

    @Test("Median of odd count")
    func medianOddCount() {
        #expect(MetricsCalculator.median([3, 1, 2]) == 2)
    }

    @Test("Median of even count picks element at count/2")
    func medianEvenCount() {
        // sorted: [1,2,3,4], index 4/2=2 → 3
        #expect(MetricsCalculator.median([4, 1, 3, 2]) == 3)
    }

    @Test("Median of single element")
    func medianSingleElement() {
        #expect(MetricsCalculator.median([42]) == 42)
    }

    @Test("Median of empty array returns nil")
    func medianEmptyReturnsNil() {
        #expect(MetricsCalculator.median([]) == nil)
    }
}
