//
//  SortOrderTests.swift
//  FITS Blaster Tests
//
//  Tests for ImageStore.updateCachedSort: metric-based ordering, nil-metrics
//  trailing, load-order (filename) sort, and rejected-entry placement.
//

import Foundation
import Testing
@testable import FITS_Blaster

@MainActor
struct SortOrderTests {

    // MARK: - Helpers

    private func makeEntry(fwhm: Float?, snr: Float? = nil,
                            filename: String, isRejected: Bool = false) -> ImageEntry {
        let entry = ImageEntry(url: URL(fileURLWithPath: "/tmp/\(filename)"))
        entry.isProcessing = false
        if fwhm != nil || snr != nil {
            entry.metrics = FrameMetrics(fwhm: fwhm, eccentricity: nil, snr: snr,
                                         starCount: nil, qualityScore: 50,
                                         skyBackground: nil, psfSignalWeight: nil)
        }
        entry.isRejected = isRejected
        return entry
    }

    /// Populates a store with entries and triggers an initial sort.
    private func makeStore(_ entries: [ImageEntry]) -> ImageStore {
        let store = ImageStore()
        for e in entries { store.entries.append(e) }
        store.updateGroupStatistics()   // initialises cachedSortedEntries
        return store
    }

    // MARK: - byMetric FWHM ascending

    @Test("byMetric(.fwhm) ascending places lowest FWHM first")
    func fwhmAscending() {
        let a = makeEntry(fwhm: 4.0, filename: "a.fits")
        let b = makeEntry(fwhm: 2.0, filename: "b.fits")
        let c = makeEntry(fwhm: 6.0, filename: "c.fits")
        let store = makeStore([a, b, c])

        store.thumbnailSortAscending = true
        store.thumbnailSortOrder = .byMetric(.fwhm)

        let sorted = store.cachedSortedEntries
        #expect(sorted[0] === b, "Lowest FWHM (2.0) should be first")
        #expect(sorted[1] === a, "Middle FWHM (4.0) should be second")
        #expect(sorted[2] === c, "Highest FWHM (6.0) should be last")
    }

    // MARK: - byMetric FWHM descending

    @Test("byMetric(.fwhm) descending places highest FWHM first")
    func fwhmDescending() {
        let a = makeEntry(fwhm: 4.0, filename: "a.fits")
        let b = makeEntry(fwhm: 2.0, filename: "b.fits")
        let c = makeEntry(fwhm: 6.0, filename: "c.fits")
        let store = makeStore([a, b, c])

        store.thumbnailSortAscending = false
        store.thumbnailSortOrder = .byMetric(.fwhm)

        let sorted = store.cachedSortedEntries
        #expect(sorted[0] === c, "Highest FWHM (6.0) should be first in descending")
        #expect(sorted[2] === b, "Lowest FWHM (2.0) should be last in descending")
    }

    // MARK: - nil metrics trail in both directions

    @Test("Entries with nil metrics sort after entries with metric values, ascending")
    func nilMetricsTrailAscending() {
        let a = makeEntry(fwhm: 3.0, filename: "a.fits")
        let b = makeEntry(fwhm: nil, filename: "b.fits")   // no metrics
        let c = makeEntry(fwhm: 1.0, filename: "c.fits")
        let store = makeStore([a, b, c])

        store.thumbnailSortAscending = true
        store.thumbnailSortOrder = .byMetric(.fwhm)

        let sorted = store.cachedSortedEntries
        #expect(sorted.last === b, "nil-metrics entry should trail in ascending sort")
    }

    @Test("Entries with nil metrics sort after entries with metric values, descending")
    func nilMetricsTrailDescending() {
        let a = makeEntry(fwhm: 3.0, filename: "a.fits")
        let b = makeEntry(fwhm: nil, filename: "b.fits")
        let c = makeEntry(fwhm: 1.0, filename: "c.fits")
        let store = makeStore([a, b, c])

        store.thumbnailSortAscending = false
        store.thumbnailSortOrder = .byMetric(.fwhm)

        let sorted = store.cachedSortedEntries
        #expect(sorted.last === b, "nil-metrics entry should trail in descending sort too")
    }

    // MARK: - byMetric SNR

    @Test("byMetric(.snr) ascending places lowest SNR first")
    func snrAscending() {
        let lo = makeEntry(fwhm: nil, snr: 20,  filename: "lo.fits")
        let hi = makeEntry(fwhm: nil, snr: 150, filename: "hi.fits")
        let store = makeStore([hi, lo])

        store.thumbnailSortAscending = true
        store.thumbnailSortOrder = .byMetric(.snr)

        #expect(store.cachedSortedEntries[0] === lo)
        #expect(store.cachedSortedEntries[1] === hi)
    }

    // MARK: - filename (load order) sort

    @Test("filename ascending preserves load order")
    func filenameAscending() {
        let a = makeEntry(fwhm: nil, filename: "a.fits")
        let b = makeEntry(fwhm: nil, filename: "b.fits")
        let c = makeEntry(fwhm: nil, filename: "c.fits")
        let store = makeStore([c, a, b])   // added in c, a, b order

        store.thumbnailSortAscending = true
        store.thumbnailSortOrder = .filename

        let sorted = store.cachedSortedEntries
        #expect(sorted[0] === c)   // first loaded
        #expect(sorted[1] === a)
        #expect(sorted[2] === b)
    }

    @Test("filename descending reverses load order")
    func filenameDescending() {
        let a = makeEntry(fwhm: nil, filename: "a.fits")
        let b = makeEntry(fwhm: nil, filename: "b.fits")
        let c = makeEntry(fwhm: nil, filename: "c.fits")
        let store = makeStore([c, a, b])

        store.thumbnailSortAscending = false
        store.thumbnailSortOrder = .filename

        let sorted = store.cachedSortedEntries
        #expect(sorted[0] === b)   // last loaded comes first
        #expect(sorted[2] === c)   // first loaded comes last
    }

    // MARK: - rejected sort

    @Test("rejected ascending places non-rejected entries before rejected ones")
    func rejectedAscending() {
        let kept     = makeEntry(fwhm: nil, filename: "kept.fits",     isRejected: false)
        let rejected = makeEntry(fwhm: nil, filename: "rejected.fits", isRejected: true)
        let store = makeStore([rejected, kept])

        store.thumbnailSortAscending = true
        store.thumbnailSortOrder = .rejected

        #expect(store.cachedSortedEntries[0] === kept,     "Non-rejected entry should come first")
        #expect(store.cachedSortedEntries[1] === rejected, "Rejected entry should come last")
    }

    @Test("rejected descending places rejected entries before non-rejected ones")
    func rejectedDescending() {
        let kept     = makeEntry(fwhm: nil, filename: "kept.fits",     isRejected: false)
        let rejected = makeEntry(fwhm: nil, filename: "rejected.fits", isRejected: true)
        let store = makeStore([kept, rejected])

        store.thumbnailSortAscending = false
        store.thumbnailSortOrder = .rejected

        #expect(store.cachedSortedEntries[0] === rejected, "Rejected entry should come first in descending")
        #expect(store.cachedSortedEntries[1] === kept,     "Non-rejected entry should come last")
    }
}
