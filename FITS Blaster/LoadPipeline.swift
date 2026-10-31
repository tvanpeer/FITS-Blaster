//
//  LoadPipeline.swift
//  FITS Blaster
//
//  The loading pipeline: batches (open, new sizes, metrics recompute, colour toggle),
//  the concurrent Phase A / Phase B work, grey and colour normalisation, and the batch
//  state the progress UI shows. Owned by ImageStore (`store.pipeline`); the per-file
//  work is in FrameLoading.
//
//  Batches run one at a time, in the order they were asked for (`enqueueBatch`,
//  CODE_AUDIT §3.1). A colour or grey re-render only changes what is shown while its
//  `renderGeneration` is current, so a replaced render never overwrites a newer one (§3.2).
//

import Foundation
import AppKit
import Metal

@Observable
@MainActor
final class LoadPipeline {

    /// The store whose entries this pipeline loads; set by `ImageStore.init`.
    @ObservationIgnored weak var store: ImageStore?

    // MARK: - Concurrency limits

    /// Phase A (read, histogram, grey stretch) frames at once: high, to keep the disk busy.
    nonisolated static let phaseAConcurrency = max(8, ProcessInfo.processInfo.activeProcessorCount)
    /// Phase B (star detection, Moffat fitting) frames at once; bounds the live full-frame
    /// Metal buffers kept from Phase A.
    nonisolated static let phaseBConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
    /// Re-reads and re-renders at once across the whole pipeline: colour per folder, grey
    /// normalisation per group, colour sampling, grey re-render and the metrics recompute
    /// share these slots, so the number of folders or filters doesn't multiply the live
    /// full-frame buffers (CODE_AUDIT §3.5).
    nonisolated static let renderConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

    @ObservationIgnored private let renderSlots = AsyncSemaphore(count: LoadPipeline.renderConcurrency)

    /// The colour proxies a load keeps from Phase A for its folders' colour renders, within
    /// a quarter of the Mac's memory (master-plan 9f part 2b). Replaced by tests that need a
    /// smaller budget.
    @ObservationIgnored var colourProxies = ColourProxies()

    // MARK: - Batch state

    var batchElapsed: Double?
    var batchMegapixels: Double?
    /// Number of images in the last finished batch (not the whole session).
    var batchImageCount: Int?
    var isBatchProcessing: Bool = false

    /// The newest batch: it waits for the batches queued before it. Stored so it can be
    /// cancelled by the user; nil when nothing is queued.
    var processingTask: Task<Void, Never>?

    /// Identifies the newest batch; only that batch may clear the busy state when it ends.
    @ObservationIgnored private(set) var processingBatchID: UUID?

    /// The last batch started, also after it was cancelled: a new batch waits for it, so
    /// the work a cancelled batch still has in flight ends before the next one starts.
    @ObservationIgnored private var lastBatch: Task<Void, Never>?

    /// Raised whenever the wanted colour rendering changes (colour toggle, Reset). A colour
    /// or grey re-render only updates the display while its generation is current; the
    /// render caches are filled either way (CODE_AUDIT §3.2).
    @ObservationIgnored private(set) var renderGeneration = 0

    /// The folder scan of a drag & drop, before its batch load starts (`openDroppedItems`).
    var dropScanTask: Task<Void, Never>?

    /// What a load is doing before its frames appear (scanning, checking headers); nil otherwise.
    var preparation: LoadPreparation?

    /// Suspends the caller until any in-progress drop scan and all queued batches complete.
    /// Used by CLI mode and the tests.
    func waitForProcessing() async {
        await dropScanTask?.value
        await processingTask?.value
        await thumbnailTask?.value
        await redrawTask?.value
    }

    /// New thumbnails made from the display images in memory (`regenerateThumbnails`).
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?

    // MARK: - Batch progress counters
    // batchLoadedCount and batchMetricsCount are intentionally absent: updating them
    // per-image via MainActor.run creates back-pressure that serialises the pipeline.
    // BatchProgressBar polls entry state every 200 ms instead (see its .task modifier).
    // Only the lower-frequency restretch/sampling counters are stored here.
    /// Set to the full entry count when a restretch pass begins; 0 at all other times.
    var batchRestretchTotal: Int = 0
    var batchRestretchCount: Int = 0
    /// Tracks per-channel clip sampling before colour rendering begins (recolorImages path).
    var batchSamplingTotal: Int = 0
    var batchSamplingCount: Int = 0

    /// Non-nil while a restretch pass is running; the value is the status message to display.
    var restretchingMessage: String? = nil

    /// Cancels the running batch and every batch queued behind it, and the drop scan.
    /// In-flight GPU/I/O work runs to completion (it can't be interrupted mid-flight),
    /// but no new work is started and the UI is cleaned up immediately.
    func cancelProcessing() {
        dropScanTask?.cancel()
        dropScanTask = nil
        processingTask?.cancel()
        processingTask = nil
        processingBatchID = nil
        preparation = nil
        restretchingMessage = nil
        for entry in store?.entries ?? [] where entry.isProcessing {
            entry.isProcessing = false
        }
        isBatchProcessing = false
        batchElapsed = nil
        batchMegapixels = nil
        batchImageCount = nil
    }

    /// Stops all work and clears the batch state; called by `ImageStore.reset()` before it
    /// empties the session, so a running load can't add frames to the new one (§3.1).
    func reset() {
        cancelProcessing()
        thumbnailTask?.cancel()
        thumbnailTask = nil
        redrawTask?.cancel()
        redrawTask = nil
        redrawQueue = []
        renderGeneration += 1
        batchRestretchTotal = 0
        batchRestretchCount = 0
        batchSamplingTotal = 0
        batchSamplingCount = 0
    }

    // MARK: - Batch queue

    /// Queues a batch behind any batch already running and returns at once (CODE_AUDIT §3.1).
    /// `body` returns the entries it loaded, for the timing line ("…s for n images"), or
    /// nil when it did no load work. With `showsTiming` false (a colour re-render) the
    /// timing line of the last load stays.
    func enqueueBatch(showsTiming: Bool = true,
                      _ body: @escaping @MainActor (LoadPipeline, ImageStore) async -> [ImageEntry]?) {
        let previous = lastBatch
        let batchID = UUID()
        processingBatchID = batchID
        isBatchProcessing = true
        if showsTiming {
            batchElapsed = nil
            batchMegapixels = nil
            batchImageCount = nil
        }
        let task = Task(priority: .utility) { [weak self] in
            // Cancelling this batch also cancels the batches queued before it.
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard let self, let store = self.store, !Task.isCancelled else { return }
            // The time shown is the batch's own, from when it starts, not when it was queued.
            let startTime = CFAbsoluteTimeGetCurrent()
            let processed = await body(self, store)
            guard !Task.isCancelled, self.processingBatchID == batchID else { return }
            if showsTiming, let processed {
                self.batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
                self.batchImageCount = processed.count
                self.batchMegapixels = Self.megapixels(of: processed)
            }
            self.isBatchProcessing = false
            self.processingTask = nil
            self.processingBatchID = nil
        }
        processingTask = task
        lastBatch = task
    }

    /// Total image size of `entries` in megapixels, from their NAXIS1 × NAXIS2 headers.
    static func megapixels(of entries: [ImageEntry]) -> Double {
        entries.reduce(0.0) {
            guard let w = $1.headers["NAXIS1"].flatMap(Int.init),
                  let h = $1.headers["NAXIS2"].flatMap(Int.init) else { return $0 }
            return $0 + Double(w * h) / 1_000_000
        }
    }

    // MARK: - Loading

    func openFiles(_ urlsWithPaths: [(url: URL, subfolderPath: String)],
                   rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "",
                   rootFolderNames: [URL: String] = [:],
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false,
                   rendersImages: Bool = true) {
        enqueueBatch { pipeline, store in
            // Taken when the batch starts, not when it was queued: an earlier batch may
            // still have added frames, so the same folder dropped twice loads once.
            let selectFirst = (store.selectedEntry == nil)
            // Both paths of each entry: a file rejected this session sits at …/REJECTED/x.fits
            // (url) while originalURL is …/x.fits, and reopening the folder with REJECTED
            // scans the former (CODE_AUDIT §5.8).
            let existingURLs = Set(store.entries.flatMap { [$0.url, $0.originalURL] })

            // FITS files not loaded yet. No header is read here: Phase A leaves out files
            // in an unsupported format, so the first frames start loading at once.
            let validItems = FrameLoading.candidates(urlsWithPaths, existingURLs: existingURLs)
            pipeline.skippedUnsupported = []

            // Add entries on the main actor so the sidebar shows loading spinners.
            var newEntries: [ImageEntry] = []
            for item in validItems {
                let isRejected = rejectedURLs.contains(item.url)
                let computedOriginalURL: URL? = isRejected
                    ? item.url.deletingLastPathComponent()  // …/Ha/REJECTED/
                               .deletingLastPathComponent() // …/Ha/
                               .appending(component: item.url.lastPathComponent) // …/Ha/image.fits
                    : nil
                let entry = ImageEntry(url: item.url, originalURL: computedOriginalURL,
                                       directoryBookmark: store.bookmark(for: item.url))
                entry.subfolderPath = item.subfolderPath
                // Per-frame names (several dropped folders) win over the batch name.
                entry.rootFolderName = rootFolderNames[item.url] ?? rootFolderName
                if isRejected {
                    entry.isRejected = true
                    store.rejectedEntryIDs.insert(entry.id)
                }
                entry.displayMemory = store.displayMemory
                store.entries.append(entry)
                newEntries.append(entry)
            }
            guard !newEntries.isEmpty else { return nil }

            if selectFirst { store.selectedEntry = newEntries[0] }

            // Populate the sort/filter cache so the sidebar renders immediately.
            store.updateActiveFilterGroups()
            store.updateCachedSort()

            let greyPending = await pipeline.processParallel(newEntries, selectFirst: selectFirst,
                                           maxDisplaySize: maxDisplaySize,
                                           maxThumbnailSize: maxThumbnailSize,
                                           metricsConfig: metricsConfig,
                                           debayerColorImages: debayerColorImages,
                                           rendersImages: rendersImages)
            // Frames Phase A left out (unsupported format), named in one message — also after
            // Cancel (the ones found so far), but not after Reset: then none of this load's
            // frames are in the session any more and the message would be about nothing shown.
            let skipped = pipeline.skippedUnsupported
            let stillShown = newEntries.contains { entry in store.entries.contains { $0 === entry } }
            if !skipped.isEmpty, stillShown {
                let names   = skipped.map(\.url.lastPathComponent)
                let preview = names.prefix(5).joined(separator: ", ")
                let suffix  = names.count > 5 ? " and \(names.count - 5) more" : ""
                store.errorMessage = "Skipped \(names.count) file\(names.count == 1 ? "" : "s") FITS Blaster doesn't load (floating-point or multi-channel stacks): \(preview)\(suffix)"
            }
            let loaded = newEntries.filter { entry in !skipped.contains { $0 === entry } }
            if !Task.isCancelled {
                let pending = greyPending.filter { entry in !skipped.contains { $0 === entry } }
                await pipeline.normalizeGreyStretch(pending, maxDisplaySize: maxDisplaySize,
                                                    maxThumbnailSize: maxThumbnailSize)
            }
            return loaded.isEmpty ? nil : loaded
        }
    }

    /// Frames of the running load that Phase A left out (unsupported format).
    @ObservationIgnored var skippedUnsupported: [ImageEntry] = []

    /// Takes a frame in an unsupported format out of the session (Phase A found out).
    private func leaveOut(_ entry: ImageEntry) {
        skippedUnsupported.append(entry)
        guard let store else { return }
        store.entries.removeAll { $0 === entry }
        store.rejectedEntryIDs.remove(entry.id)
        if store.selectedEntry === entry {
            store.selectedEntry = store.entries.first { !$0.isProcessing } ?? store.entries.first
        }
        store.updateActiveFilterGroups()
        store.updateCachedSort()
    }

    /// Re-renders display images and thumbnails at new sizes without touching metrics.
    ///
    /// Unlike a normal load, this never runs Phase B (star detection). After Phase A
    /// completes, each entry's `metrics` is restored from its `cachedMetrics` so the
    /// displayed values remain unchanged throughout. Queued behind a running load.
    func regenerateSizes(settings: AppSettings) {
        regenerateSizes(maxDisplaySize: settings.maxDisplaySize,
                        maxThumbnailSize: settings.thumbnailRenderSize,
                        metricsConfig: settings.effectiveMetricsConfig,
                        debayer: settings.debayerColorImages)
    }

    /// `regenerateSizes(settings:)` with the values passed in (also used by the tests, which
    /// mustn't change the app's saved settings).
    func regenerateSizes(maxDisplaySize: Int, maxThumbnailSize: Int,
                         metricsConfig: MetricsConfig, debayer: Bool) {
        enqueueBatch { pipeline, store in
            // The frames when the batch starts, including those a queued load added.
            let entriesToProcess = store.entries
            for entry in entriesToProcess {
                entry.isProcessing = true
                entry.displayImage = nil
                entry.thumbnail    = nil
                entry.histogram    = nil
                // The cached grey and colour renders have the old size too: without them the
                // colour render below makes new ones instead of showing the old colour images,
                // and a later colour toggle renders at the new size.
                entry.cachedGreyscaleDisplay = nil
                entry.cachedGreyscaleThumb   = nil
                entry.cachedColourDisplay    = nil
                entry.cachedColourThumb      = nil
                entry.greyRecipe   = nil
                entry.colourRecipe = nil
                entry.forgetDrop()
                // Intentionally leave entry.metrics and entry.cachedMetrics intact.
            }

            let folders = store.accessFolders(for: entriesToProcess)
            defer { for folder in folders { folder.stopAccessingSecurityScopedResource() } }

            // Pass an all-disabled MetricsConfig so processParallel skips Phase B entirely.
            let greyPending = await pipeline.processParallel(entriesToProcess, selectFirst: false,
                                           maxDisplaySize: maxDisplaySize,
                                           maxThumbnailSize: maxThumbnailSize,
                                           metricsConfig: .off,
                                           debayerColorImages: debayer)
            // Restore metric values from cache now that Phase A is done.
            for entry in entriesToProcess {
                if let cached = entry.cachedMetrics {
                    entry.metrics = cached.filtered(by: metricsConfig)
                }
            }
            if !Task.isCancelled {
                await pipeline.normalizeGreyStretch(greyPending,
                                                    maxDisplaySize: maxDisplaySize,
                                                    maxThumbnailSize: maxThumbnailSize)
            }
            return entriesToProcess
        }
    }

    // MARK: - Thumbnails only

    /// New thumbnails at the current thumbnail size, made from the display images already
    /// in memory — no file is read, and no progress is shown. A thumbnail is always made
    /// from its display image, so this gives the same thumbnails as reloading the frames.
    /// During a load it is queued behind the load, so the frames still loading get the new
    /// size too.
    func regenerateThumbnails(settings: AppSettings) {
        regenerateThumbnails(size: settings.thumbnailRenderSize)
    }

    /// `regenerateThumbnails(settings:)` with the pixel size passed in (also for the tests).
    func regenerateThumbnails(size: Int) {
        if processingTask != nil {
            enqueueBatch(showsTiming: false) { pipeline, _ in
                await pipeline.makeThumbnails(size: size)
                return nil
            }
            return
        }
        // Nothing is loading: make them right away, without the batch UI. A newer request
        // replaces an older one that is still running.
        thumbnailTask?.cancel()
        thumbnailTask = Task(priority: .utility) { [weak self] in
            await self?.makeThumbnails(size: size)
        }
    }

    /// Makes the thumbnails of every frame from its display image and its cached grey and
    /// colour renders, off the main thread. A frame whose image changed meanwhile (a colour
    /// toggle) keeps the thumbnail that came with the new image.
    private func makeThumbnails(size: Int) async {
        guard let store else { return }
        let frames = store.entries.map {
            (entry: $0, display: $0.displayImage, grey: $0.cachedGreyscaleDisplay, colour: $0.cachedColourDisplay,
             dropped: $0.droppedDisplay.map { (recipe: $0.recipe, token: $0.token) })
        }
        // A frame whose display image was dropped (9f part 1) is drawn once from its file
        // for its thumbnail; the image itself isn't kept, so it pushes no other frame out.
        let droppedEntries = frames.filter { $0.display == nil && $0.dropped != nil }.map(\.entry)
        let folders = store.accessFolders(for: droppedEntries)
        defer { for folder in folders { folder.stopAccessingSecurityScopedResource() } }
        await forEachWithRenderSlot(frames) { frame in
            if frame.display == nil, let dropped = frame.dropped {
                // The current URL: the frame may have been rejected (moved) since (§3.9).
                let url = await frame.entry.url
                guard let image = await FrameLoading.renderAgain(url: url, recipe: dropped.recipe),
                      let thumb = ImageStretcher.createThumbnail(from: image, maxSize: size) else { return }
                await MainActor.run {
                    let entry = frame.entry
                    // Still dropped by the same drop: drawn again meanwhile, it has a new thumbnail.
                    guard entry.droppedDisplay?.token == dropped.token, entry.displayImage == nil else { return }
                    entry.replaceDroppedThumbnail(thumb)
                }
                return
            }
            let thumb  = frame.display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: size) }
            // A cached render that is the image shown shares its new thumbnail.
            let grey   = frame.grey === frame.display ? thumb
                : frame.grey.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: size) }
            let colour = frame.colour === frame.display ? thumb
                : frame.colour.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: size) }
            await MainActor.run {
                let entry = frame.entry
                if entry.displayImage === frame.display, let thumb { entry.thumbnail = thumb }
                if entry.cachedGreyscaleDisplay === frame.grey, let grey { entry.cachedGreyscaleThumb = grey }
                if entry.cachedColourDisplay === frame.colour, let colour { entry.cachedColourThumb = colour }
            }
        }
    }

    // MARK: - Dropped display images

    /// Draws dropped display images again (9f part 1); the cursor first.
    @ObservationIgnored private var redrawTask: Task<Void, Never>?
    /// The frames still to draw, in order; a newer request replaces them.
    @ObservationIgnored private var redrawQueue: [ImageEntry] = []
    @ObservationIgnored private var redrawing: Set<UUID> = []

    /// Redraws at a time. On M81 at 4096 from the SSD, colour: 1 → 16.6, 2 → 32.4,
    /// 4 → 26.8, 8 → 17.5 frames/s; grey levels off at about 35 from 4.
    static let redrawConcurrency = 2

    /// Draws the dropped display images of `entries` again from their files, in this order.
    /// Replaces the frames still waiting from an earlier request; redraws already running finish.
    func redrawDropped(_ entries: [ImageEntry]) {
        redrawQueue = entries.filter(\.needsRedraw)
        guard redrawTask == nil, !redrawQueue.isEmpty else { return }
        redrawTask = Task { [weak self] in
            await self?.runRedraws()
            self?.redrawTask = nil
        }
    }

    private func runRedraws() async {
        await withTaskGroup(of: Void.self) { group in
            var running = 0
            while !Task.isCancelled {
                while running < Self.redrawConcurrency, let entry = nextRedraw() {
                    running += 1
                    group.addTask { [weak self] in await self?.redraw(entry) }
                }
                guard running > 0 else { break }
                await group.next()
                running -= 1
            }
        }
    }

    private func nextRedraw() -> ImageEntry? {
        while !redrawQueue.isEmpty {
            let entry = redrawQueue.removeFirst()
            if entry.needsRedraw, !redrawing.contains(entry.id) { return entry }
        }
        return nil
    }

    /// Draws one dropped display image again. A frame that was drawn or dropped again
    /// meanwhile keeps what it has; a file that can't be read marks the frame, and the
    /// next visit tries again.
    private func redraw(_ entry: ImageEntry) async {
        guard let dropped = entry.droppedDisplay, let store else { return }
        redrawing.insert(entry.id)
        defer { redrawing.remove(entry.id) }
        let folders = store.accessFolders(for: [entry])
        defer { for folder in folders { folder.stopAccessingSecurityScopedResource() } }
        // The current URL: the frame may have been rejected (moved) since (§3.9).
        let image = await FrameLoading.renderAgain(url: entry.url, recipe: dropped.recipe)
        guard entry.droppedDisplay?.token == dropped.token, entry.displayImage == nil else { return }
        guard let image else {
            entry.redrawFailed = true
            return
        }
        entry.restoreDisplay(image, isColour: dropped.isColour)
    }

    // MARK: - Metrics-only recompute

    /// Applies a new metrics config without re-reading FITS files where possible.
    ///
    /// - If all metrics requested by `newConfig` are already in an entry's `cachedMetrics`,
    ///   the displayed `metrics` is rebuilt from cache instantly — no I/O.
    /// - Only entries genuinely missing a newly-enabled metric trigger a file re-read,
    ///   and only for those specific missing metrics.
    func recomputeMetrics(metricsConfig: MetricsConfig) {
        guard let store else { return }
        let entriesToProcess = store.entries.filter { !$0.isProcessing }
        guard !entriesToProcess.isEmpty, !isBatchProcessing else { return }

        // Pass 1 (synchronous, no I/O): restore from cache for everything we already have.
        for entry in entriesToProcess {
            if let cached = entry.cachedMetrics {
                entry.metrics = cached.filtered(by: metricsConfig)
            }
        }

        // Refresh the sort cache now that cached metrics have been restored synchronously.
        store.updateCachedSort()

        // Pass 2: with metrics on, collect entries that have no cached metrics yet
        // (loaded in Simple mode, or no stars found) and measure them from disk.
        let needsRecompute = metricsConfig.computeMetrics
            ? entriesToProcess.filter { $0.cachedMetrics == nil }
            : []

        guard !needsRecompute.isEmpty else { return }

        enqueueBatch { pipeline, store in
            let folders = store.accessFolders(for: needsRecompute)
            defer { for folder in folders { folder.stopAccessingSecurityScopedResource() } }

            await pipeline.forEachWithRenderSlot(needsRecompute) { entry in
                // The current URL: the frame may have been rejected (moved) since (§3.9).
                let url = await entry.url
                let newMetrics = await FrameLoading.loadMetricsOnly(url: url, config: metricsConfig)
                await MainActor.run {
                    if let newMetrics {
                        entry.cachedMetrics = newMetrics
                        entry.metrics = newMetrics.filtered(by: metricsConfig)
                    }
                }
            }

            guard !Task.isCancelled else { return nil }
            store.updateGroupStatistics()
            return needsRecompute
        }
    }

    // MARK: - Shared render slots

    /// Runs `work` for each item, in order, each holding one of the shared render slots
    /// (`renderConcurrency`, CODE_AUDIT §3.5), and returns when all have finished.
    /// After Cancel no new item starts; items already running finish.
    private func forEachWithRenderSlot<Item: Sendable>(_ items: [Item],
                                                       _ work: @escaping @Sendable (Item) async -> Void) async {
        let slots = renderSlots
        await withTaskGroup(of: Void.self) { group in
            for item in items {
                guard await slots.wait() else { break }
                group.addTask {
                    await work(item)
                    await slots.signal()
                }
            }
        }
    }

    /// Starts the colour render of one folder as soon as its clips are known (the files
    /// are still in the OS cache). The task is returned so the batch can wait for it,
    /// and cancel it on Cancel.
    private func spawnColourRender(_ entries: [ImageEntry], generation: Int,
                                   maxDisplaySize: Int, maxThumbnailSize: Int) -> Task<Void, Never> {
        Task(priority: .utility) { [weak self] in
            await self?.renderFolderInColour(entries, generation: generation,
                                             maxDisplaySize: maxDisplaySize,
                                             maxThumbnailSize: maxThumbnailSize)
        }
    }

    /// Waits for work the batch started as separate tasks (Phase B, colour renders).
    /// On Cancel the colour renders are cancelled, so they start no new frames; work
    /// already running finishes before this returns, so no file is read after the batch
    /// has ended its folder access (CODE_AUDIT §3.6) and the next batch finds the GPU free.
    private func waitForSpawned(phaseB: [Task<Void, Never>], colour: [Task<Void, Never>]) async {
        await withTaskCancellationHandler {
            for task in phaseB { await task.value }
            for task in colour { await task.value }
        } onCancel: {
            for task in colour { task.cancel() }
        }
    }

    // MARK: - Concurrent pipeline

    /// Two-phase pipeline per image:
    ///
    /// **Phase A** — I/O + GPU stretch (~100–300 ms total): the image becomes
    /// visible immediately. The MTLBuffer with the raw pixels is kept for Phase B,
    /// so no second file read is needed.
    ///
    /// **Phase B** — GPU star-detection + Moffat fitting: runs in a detached
    /// task using the retained MTLBuffer. Concurrency is bounded by
    /// `phaseBSemaphore` (acquired in the group task after Phase A, before
    /// the slot is freed), keeping live MTLBuffer count and memory predictable.
    /// After Cancel no new Phase B starts (CODE_AUDIT §3.4).
    ///
    /// **Colour normalisation** — fires per folder as soon as all entries in
    /// that folder complete Phase A. Runs concurrently with Phase B and Phase A for
    /// other folders, rather than waiting for the entire batch to finish. A frame
    /// whose colour proxy (the averages before the stretch) Phase A could keep within
    /// `colourProxies`' budget is rendered from it; the others read their file again
    /// (master-plan 9f part 2b).
    ///
    /// **Grey normalisation** — a mono folder gets its shared grey stretch as soon as
    /// it is read, before the next folder's Phase A starts, while its files are still
    /// in the file cache (master-plan 9f part 2a). Returns the entries whose grey
    /// normalisation is still due: the caller runs it after the load, as before.
    @discardableResult
    func processParallel(_ entriesToProcess: [ImageEntry], selectFirst: Bool,
                         maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                         metricsConfig: MetricsConfig = MetricsConfig(),
                         debayerColorImages: Bool = false,
                         rendersImages: Bool = true) async -> [ImageEntry] {

        // Reset colour counters for this pass so a grey-mode pass never shows a stale
        // Restretching bar from a previous session. When debayering, set the total
        // upfront to the full entry count so the bar stays visible for the entire load
        // rather than flickering in/out as each folder completes.
        batchRestretchTotal  = debayerColorImages ? entriesToProcess.count : 0
        batchRestretchCount = 0
        // The colour renders of this load show only while no colour toggle came since.
        let generation = renderGeneration

        // Phase A: high I/O concurrency keeps the SSD pipeline full.
        // Phase B: bounded separately to prevent CPU/memory over-subscription.
        let ioConcurrency   = Self.phaseAConcurrency
        let phaseBSemaphore = AsyncSemaphore(count: Self.phaseBConcurrency)
        var phaseBTasks:   [Task<Void, Never>] = []
        var colourTasks:   [Task<Void, Never>] = []

        // Pre-group entries by folder so each folder's colour task can access its siblings.
        // Only built when colour debayering is enabled — avoids the allocation otherwise.
        let folderEntriesMap: [String: [ImageEntry]] = debayerColorImages
            ? Dictionary(grouping: entriesToProcess, by: \.qualifiedFolderPath)
            : [:]
        let folderTracker = FolderTracker(grouping: entriesToProcess)
        // Folder by folder, so each folder is read completely before the next one starts.
        let ordered = Self.groupedByFolder(entriesToProcess)
        // Mono folders whose grey normalisation ran during the load.
        var normalizedFolders: Set<String> = []
        var folderEntries: [ImageEntry] = []
        let proxies = colourProxies

        await withTaskGroup(of: (ImageEntry, Task<Void, Never>?, Task<Void, Never>?).self) { group in
            var activeCount = 0
            for entry in ordered {
                if Task.isCancelled { break }

                // At a folder boundary a mono folder (one of its frames already read is mono)
                // finishes its Phase A and gets its shared grey stretch before the next folder
                // is read. Run after the whole load, most files had left the file cache: a
                // 7.4 GB mono set was read 1.7 times. Other folders don't wait; a folder not
                // known to be mono yet, and the last one, are normalised after the load.
                if let last = folderEntries.last, last.qualifiedFolderPath != entry.qualifiedFolderPath {
                    if Self.isMonoFolder(folderEntries) {
                        while let (_, phaseB, colour) = await group.next() {
                            if let t = phaseB  { phaseBTasks.append(t) }
                            if let t = colour  { colourTasks.append(t) }
                        }
                        activeCount = 0
                        if !Task.isCancelled {
                            await normalizeGreyStretch(folderEntries, maxDisplaySize: maxDisplaySize,
                                                       maxThumbnailSize: maxThumbnailSize)
                            normalizedFolders.insert(last.qualifiedFolderPath)
                        }
                    }
                    folderEntries = []
                }
                folderEntries.append(entry)

                if activeCount >= ioConcurrency {
                    if let (_, phaseB, colour) = await group.next() {
                        if let t = phaseB  { phaseBTasks.append(t) }
                        if let t = colour  { colourTasks.append(t) }
                    }
                    activeCount -= 1
                }
                let url  = entry.url
                let path = entry.qualifiedFolderPath
                let entryID = entry.id
                group.addTask { [weak self] in
                    // ── Phase A: I/O + histogram + GPU stretch ────────────────
                    let fast = await FrameLoading.loadFast(url: url,
                                                   maxDisplaySize: maxDisplaySize,
                                                   maxThumbnailSize: maxThumbnailSize,
                                                   debayerColorImages: debayerColorImages,
                                                   rendersImages: rendersImages)
                    // Only these values go to the main actor; `fast` itself, with its
                    // Metal buffer, stays with Phase B below (CODE_AUDIT §3.3).
                    let display    = fast.display
                    let thumb      = fast.thumb
                    let info       = fast.info
                    let error      = fast.error
                    let histogram  = fast.histogram
                    let headers    = fast.headers
                    let bayerClips = fast.bayerClips
                    let greyClips  = fast.greyClips
                    let recipe     = fast.recipe
                    // A file in an unsupported format leaves the session; it still counts
                    // as done for its folder's colour render below, but gets no Phase B.
                    let unsupported = fast.isUnsupported
                    if unsupported {
                        await MainActor.run { [weak self] in self?.leaveOut(entry) }
                    } else { await MainActor.run { [weak self] in
                        entry.displayImage = display
                        entry.thumbnail    = thumb
                        entry.imageInfo    = info
                        entry.errorMessage = error
                        entry.histogram    = histogram
                        entry.headers      = headers
                        entry.bayerClips   = bayerClips
                        entry.greyClips    = greyClips
                        entry.greyRecipe   = recipe
                        // Pre-populate the greyscale cache so any toggle to grey is instant.
                        if entry.isBayer {
                            entry.cachedGreyscaleDisplay = display
                            entry.cachedGreyscaleThumb   = thumb
                        }
                        entry.isProcessing = false   // ← image visible now

                        if selectFirst, entry === entriesToProcess.first, display != nil {
                            self?.store?.selectedEntry = entry
                        }
                    } }

                    // ── Colour proxy (9f part 2b) ─────────────────────────────
                    // While the frame is still in its Metal buffer, keep the first half of its
                    // colour render if it fits the budget: the folder's colour render then
                    // needs no second read of the file (a 7 GB night doesn't stay in the
                    // file cache). Without room the frame is read again, as before.
                    if debayerColorImages, bayerClips != nil, let buffer = fast.metalBuffer,
                       let pattern = fast.bayerPattern {
                        let (w, h) = ImageStretcher.bayerDisplaySize(width: fast.width, height: fast.height,
                                                                     maxDisplaySize: maxDisplaySize)
                        let bytes = ColourProxy.byteCount(width: w, height: h)
                        if await proxies.reserve(bytes) {
                            if let proxy = await ImageStretcher.averageBayer(
                                inputBuffer: buffer, width: fast.width, height: fast.height,
                                rOffset: pattern.rOffset, maxDisplaySize: maxDisplaySize) {
                                await proxies.store(proxy, for: entryID)
                            } else {
                                await proxies.cancelReservation(bytes)
                            }
                        }
                    }

                    // ── Per-folder colour normalisation (streaming) ───────────
                    // When every entry in a folder has finished Phase A the per-channel
                    // Bayer clips are all available. Fire the colour render immediately
                    // while those FITS pages are still warm in the OS file cache —
                    // rather than waiting for the entire batch (including Phase B) to
                    // finish, by which time the cache may have been evicted.
                    var colourTask: Task<Void, Never>? = nil
                    if debayerColorImages {
                        let folderDone = await folderTracker.complete(path: path)
                        if folderDone, !Task.isCancelled, let fEntries = folderEntriesMap[path] {
                            colourTask = await self?.spawnColourRender(fEntries, generation: generation,
                                                                       maxDisplaySize: maxDisplaySize,
                                                                       maxThumbnailSize: maxThumbnailSize)
                        }
                    }

                    // ── Phase B: GPU detection + Moffat fitting ───────────────
                    // Acquire a Phase B slot before spawning the detached task.
                    // This bounds the number of live MTLBuffers to phaseBSemaphore.count
                    // while still freeing this group slot immediately after.
                    // A cancelled load gets no slot, so no new detection starts (§3.4).
                    guard metricsConfig.needsStarDetection, !unsupported else { return (entry, nil, colourTask) }
                    guard await phaseBSemaphore.wait() else { return (entry, nil, colourTask) }
                    let phaseB = Task(priority: .utility) {
                        defer { Task { await phaseBSemaphore.signal() } }

                        let metrics: FrameMetrics?
                        let bayerPattern = fast.bayerPattern
                        if let buffer = fast.metalBuffer {
                            metrics = await MetricsCalculator.compute(
                                metalBuffer: buffer,
                                width: fast.width, height: fast.height, config: metricsConfig,
                                bayerPattern: bayerPattern)
                        } else {
                            // CPU fallback: Metal was unavailable during Phase A. Read the
                            // current URL: the frame may have been rejected (moved) since (§3.9).
                            let currentURL = await entry.url
                            metrics = await FrameLoading.loadMetricsOnly(url: currentURL, config: metricsConfig)
                        }
                        await MainActor.run {
                            entry.metrics       = metrics
                            entry.cachedMetrics = metrics
                        }
                    }
                    return (entry, phaseB, colourTask)
                }
                activeCount += 1
            }
            for await (_, phaseB, colour) in group {
                if let t = phaseB  { phaseBTasks.append(t) }
                if let t = colour  { colourTasks.append(t) }
            }
        }

        await waitForSpawned(phaseB: phaseBTasks, colour: colourTasks)
        // Proxies the colour renders didn't use (Cancel, a colour toggle meanwhile) go now.
        await proxies.discardAll()

        store?.updateGroupStatistics()
        return entriesToProcess.filter { !normalizedFolders.contains($0.qualifiedFolderPath) }
    }

    /// The entries grouped by folder: the folders in the order they first appear, each
    /// folder's frames in their order. Input that is already grouped stays as it is.
    /// (A folder scan lists files and subfolders by name, so a folder's files can come
    /// before and after a subfolder's.)
    static func groupedByFolder(_ entries: [ImageEntry]) -> [ImageEntry] {
        var folderOrder: [String] = []
        var byFolder: [String: [ImageEntry]] = [:]
        for entry in entries {
            let path = entry.qualifiedFolderPath
            if byFolder[path] == nil { folderOrder.append(path) }
            byFolder[path, default: []].append(entry)
        }
        return folderOrder.flatMap { byFolder[$0] ?? [] }
    }

    /// A folder whose grey normalisation can run as soon as it is read: at least two frames
    /// (a single frame has no shared stretch) and a mono frame among those already read.
    private static func isMonoFolder(_ entries: [ImageEntry]) -> Bool {
        entries.count >= 2 && entries.contains { !$0.isBayer && $0.greyClips != nil }
    }

    /// Re-renders only display images and thumbnails for Bayer frames when the
    /// colour debayering preference is toggled. Does NOT touch metrics or histograms.
    ///
    /// - Colour ON:  computes missing per-channel clip bounds (if images were loaded
    ///               with debayer off), then re-renders with per-folder median clips.
    /// - Colour OFF: re-renders Bayer images as greyscale.
    ///
    /// A batch: during a load it runs after the load, so it also covers the frames that
    /// weren't loaded yet when colour was toggled (CODE_AUDIT §3.2); Cancel stops it.
    func recolorImages(settings: AppSettings) {
        recolorImages(debayer: settings.debayerColorImages,
                      maxDisplaySize: settings.maxDisplaySize,
                      maxThumbnailSize: settings.thumbnailRenderSize)
    }

    /// `recolorImages(settings:)` with the values passed in (also used by the tests, which
    /// mustn't change the app's saved settings).
    func recolorImages(debayer: Bool, maxDisplaySize: Int, maxThumbnailSize: Int) {
        guard let store else { return }
        // Nothing to do without Bayer frames, unless a running load may still add some.
        guard processingTask != nil || store.entries.contains(where: { $0.isBayer }) else { return }

        // The wanted rendering changes now: renders of an earlier setting that are still
        // running or queued no longer change what is shown.
        renderGeneration += 1
        let generation = renderGeneration

        enqueueBatch(showsTiming: false) { pipeline, store in
            // A newer toggle is queued behind this one: it does the work.
            guard generation == pipeline.renderGeneration else { return nil }
            let bayerEntries = store.entries.filter { $0.isBayer }
            guard !bayerEntries.isEmpty else { return nil }

            let folders = store.accessFolders(for: bayerEntries)
            defer { for folder in folders { folder.stopAccessingSecurityScopedResource() } }

            if debayer {
                await pipeline.renderBayerEntriesInColour(bayerEntries, generation: generation,
                                                          maxDisplaySize: maxDisplaySize,
                                                          maxThumbnailSize: maxThumbnailSize)
            } else {
                await pipeline.renderBayerEntriesInGrey(bayerEntries, generation: generation,
                                                        maxDisplaySize: maxDisplaySize,
                                                        maxThumbnailSize: maxThumbnailSize)
            }
            return nil
        }
    }

    /// The colour-on part of `recolorImages`: samples the clips that are missing, then
    /// renders each folder in colour as soon as its clips are all known.
    private func renderBayerEntriesInColour(_ bayerEntries: [ImageEntry], generation: Int,
                                            maxDisplaySize: Int, maxThumbnailSize: Int) async {
        restretchingMessage = "Rendering colour…"
        defer { restretchingMessage = nil }

        let needsClips = bayerEntries.filter { $0.bayerClips == nil }
        // Set progress counters upfront so the bars are stable for the full run.
        batchSamplingTotal = bayerEntries.count
        batchSamplingCount = bayerEntries.count - needsClips.count
        batchRestretchTotal    = bayerEntries.count
        batchRestretchCount   = 0

        // Group by folder to enable per-folder streaming: colour rendering fires
        // as soon as all entries in a folder are sampled, rather than waiting for
        // the entire set to finish sampling.
        let folderEntriesMap = Dictionary(grouping: bayerEntries, by: \.qualifiedFolderPath)
        let folderTracker    = FolderTracker(grouping: bayerEntries)
        var colourTasks: [Task<Void, Never>] = []

        // Pre-credit entries that already have clips. If every entry in a folder
        // was loaded in colour mode previously, that folder can render immediately.
        for entry in bayerEntries where entry.bayerClips != nil {
            if await folderTracker.complete(path: entry.qualifiedFolderPath),
               let fEntries = folderEntriesMap[entry.qualifiedFolderPath] {
                colourTasks.append(spawnColourRender(fEntries, generation: generation,
                                                     maxDisplaySize: maxDisplaySize,
                                                     maxThumbnailSize: maxThumbnailSize))
            }
        }

        // Sample the missing clips; the last frame of a folder starts its colour render.
        // A cancelled toggle gets no slot, so no new sampling starts.
        let slots = renderSlots
        await withTaskGroup(of: String?.self) { group in
            for entry in needsClips {
                guard await slots.wait() else { break }
                let bayerPattern = entry.bayerPattern
                let path         = entry.qualifiedFolderPath
                group.addTask { [weak self] in
                    defer { Task { await slots.signal() } }
                    // The current URL: the frame may have been rejected (moved) since (§3.9).
                    let url = await entry.url
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    guard let pattern = bayerPattern,
                          let device  = MetalContext.device,
                          let result  = try? FITSReader.readIntoBuffer(from: url, device: device)
                    else { return nil }
                    let clips = ImageStretcher.computeBayerClips(
                        result.metalBuffer,
                        width: result.metadata.width, height: result.metadata.height,
                        rOffset: pattern.rOffset)
                    let capturedSelf = self
                    await MainActor.run {
                        entry.bayerClips = clips
                        capturedSelf?.batchSamplingCount += 1
                    }
                    // Return the folder path if this was the last entry in the folder
                    // to be sampled, signalling that colour rendering can now begin.
                    return await folderTracker.complete(path: path) ? path : nil
                }
            }
            for await taskResult in group {
                if let path = taskResult, !Task.isCancelled, let fEntries = folderEntriesMap[path] {
                    colourTasks.append(spawnColourRender(fEntries, generation: generation,
                                                         maxDisplaySize: maxDisplaySize,
                                                         maxThumbnailSize: maxThumbnailSize))
                }
            }
        }
        // Wait for all per-folder colour renders to finish (cancelled on Cancel).
        await waitForSpawned(phaseB: [], colour: colourTasks)
    }

    /// The colour-off part of `recolorImages`: shows the grey renders, re-rendering the
    /// Bayer frames that have none cached. Metrics and histograms are unchanged.
    private func renderBayerEntriesInGrey(_ bayerEntries: [ImageEntry], generation: Int,
                                          maxDisplaySize: Int, maxThumbnailSize: Int) async {
        // Use cached greyscale renders if available to avoid file re-reads.
        let needsRender = bayerEntries.filter { $0.cachedGreyscaleDisplay == nil }
        if !needsRender.isEmpty {
            restretchingMessage = "Rendering greyscale…"
            defer { restretchingMessage = nil }
            await forEachWithRenderSlot(needsRender) { [weak self] entry in
                let pipeline = self
                // The current URL: the frame may have been rejected (moved) since (§3.9).
                let url = await entry.url
                // Binned 2×2 with the Bayer pattern, as Phase A renders it, so the grey image
                // is the load's (before 9f part 1c this path rendered without binning).
                let recipe = DisplayRecipe.grey(bayerPattern: await entry.bayerPattern,
                                                maxDisplaySize: maxDisplaySize)
                let display = await FrameLoading.renderAgain(url: url, recipe: recipe)
                let thumb = display.flatMap {
                    ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize)
                }
                await MainActor.run {
                    entry.cachedGreyscaleDisplay = display
                    entry.cachedGreyscaleThumb   = thumb
                    entry.greyRecipe = display == nil ? nil : recipe
                    guard pipeline?.renderGeneration == generation else { return }
                    if let d = display { entry.displayImage = d }
                    if let t = thumb   { entry.thumbnail    = t }
                }
            }
        }
        // Apply cached renders for entries that already had them.
        guard renderGeneration == generation else { return }
        for entry in bayerEntries where entry.cachedGreyscaleDisplay != nil && !needsRender.contains(where: { $0 === entry }) {
            entry.displayImage = entry.cachedGreyscaleDisplay
            entry.thumbnail    = entry.cachedGreyscaleThumb
        }
    }

    // MARK: - Greyscale normalisation

    /// Groups non-Bayer entries by (folder, filter), computes the per-group median
    /// clip bounds from the `greyClips` stored during Phase A, then re-renders each
    /// group with the shared clips so same-filter frames have consistent stretch.
    ///
    /// Groups with fewer than two images are skipped — a single image is already as
    /// consistent as it can be. Bayer images (handled by the colour normalisation path)
    /// are always excluded.
    private func normalizeGreyStretch(_ entries: [ImageEntry],
                                      maxDisplaySize: Int,
                                      maxThumbnailSize: Int) async {
        let greyEntries = entries.filter { !$0.isBayer && $0.greyClips != nil }
        guard !greyEntries.isEmpty else { return }

        let groups = Dictionary(grouping: greyEntries) {
            "\($0.qualifiedFolderPath)::\($0.filterGroup.rawValue)"
        }

        // The groups render at the same time, sharing the render slots.
        await withTaskGroup(of: Void.self) { group in
            for (_, groupEntries) in groups {
                guard groupEntries.count >= 2 else { continue }
                let clips = GreyClips.median(of: groupEntries.compactMap(\.greyClips))
                guard clips.isValid else { continue }
                group.addTask { [weak self] in
                    guard let self else { return }
                    await self.renderGroupWithSharedGreyClips(groupEntries, clips: clips,
                                                              maxDisplaySize: maxDisplaySize,
                                                              maxThumbnailSize: maxThumbnailSize)
                }
            }
        }
    }

    /// Re-renders a (folder, filter) group of greyscale images with the given shared clip bounds.
    private func renderGroupWithSharedGreyClips(_ entries: [ImageEntry],
                                                clips: GreyClips,
                                                maxDisplaySize: Int,
                                                maxThumbnailSize: Int) async {
        let items = entries.map { (entry: $0, bayerPattern: $0.bayerPattern) }
        await forEachWithRenderSlot(items) { item in
            let entry = item.entry
            // The current URL: the frame may have been rejected (moved) since (§3.9).
            let url = await entry.url
            let didStart = url.startAccessingSecurityScopedResource()
            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
            guard let device = MetalContext.device,
                  let result = try? FITSReader.readIntoBuffer(from: url, device: device)
            else { return }
            let display = await ImageStretcher.createImage(
                inputBuffer: result.metalBuffer,
                width: result.metadata.width, height: result.metadata.height,
                clips: clips, maxDisplaySize: maxDisplaySize,
                bayerPattern: item.bayerPattern)
            let thumb = display.flatMap {
                ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize)
            }
            await MainActor.run {
                if let d = display {
                    entry.displayImage = d
                    entry.greyRecipe   = .sharedGrey(clips: clips, bayerPattern: item.bayerPattern,
                                                     maxDisplaySize: maxDisplaySize)
                }
                if let t = thumb   { entry.thumbnail    = t }
            }
        }
    }

    /// Renders one folder group's Bayer images in colour using the per-channel median of
    /// the individual `bayerClips` already computed during Phase A or sampling.
    ///
    /// Called from `processParallel` and `recolorImages` as soon as all entries in a
    /// folder complete their clip computation. Frames with a colour proxy from Phase A are
    /// rendered from it, without reading their file again.
    /// Updates `batchRestretchCount` so the Restretching bar advances smoothly.
    /// `batchRestretchTotal` must be set to the full entry count by the caller upfront.
    /// The renders are shown only while `generation` is current; they are cached either way.
    private func renderFolderInColour(_ entries: [ImageEntry], generation: Int,
                                      maxDisplaySize: Int,
                                      maxThumbnailSize: Int) async {
        let bayerEntries = entries.filter { $0.bayerClips != nil }

        // Non-Bayer entries in this folder need no colour rendering — count them immediately
        // so progress advances correctly against the full batchRestretchTotal.
        batchRestretchCount += entries.count - bayerEntries.count

        guard !bayerEntries.isEmpty else { return }

        let sharedClips = BayerClips.median(of: bayerEntries.compactMap(\.bayerClips))
        guard sharedClips.isValid else { return }

        // Render the selected entry first so the on-screen image switches to colour immediately.
        if !Task.isCancelled,
           let selected = store?.selectedEntry,
           bayerEntries.contains(where: { $0 === selected }),
           selected.cachedColourDisplay == nil,
           let pattern = selected.bayerPattern,
           let (display, thumb) = await FrameLoading.recolorBayerEntry(
               url: selected.url, rOffset: pattern.rOffset, clips: sharedClips,
               maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize,
               proxy: await colourProxies.take(selected.id)) {
            selected.cachedColourDisplay = display
            selected.cachedColourThumb   = thumb
            selected.colourRecipe = .colour(rOffset: pattern.rOffset, clips: sharedClips,
                                            maxDisplaySize: maxDisplaySize)
            if renderGeneration == generation {
                selected.displayImage    = display
                selected.thumbnail       = thumb
            }
            batchRestretchCount += 1
        }

        // Apply cached colour renders (e.g. the priority pass above) without a task.
        var toRender: [(entry: ImageEntry, id: UUID, bayerPattern: BayerPattern?)] = []
        for entry in bayerEntries {
            if entry.cachedColourDisplay != nil {
                if renderGeneration == generation {
                    entry.displayImage = entry.cachedColourDisplay
                    entry.thumbnail    = entry.cachedColourThumb
                }
                batchRestretchCount += 1
            } else {
                toRender.append((entry, entry.id, entry.bayerPattern))
            }
        }

        let proxies = colourProxies
        await forEachWithRenderSlot(toRender) { [weak self] item in
            let pipeline = self
            let entry = item.entry
            // The current URL: the frame may have been rejected (moved) since (§3.9).
            let url = await entry.url
            guard let pattern = item.bayerPattern,
                  let (display, thumb) = await FrameLoading.recolorBayerEntry(
                      url: url, rOffset: pattern.rOffset, clips: sharedClips,
                      maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize,
                      proxy: await proxies.take(item.id)
                  ) else {
                await MainActor.run { pipeline?.batchRestretchCount += 1 }
                return
            }
            await MainActor.run {
                entry.cachedColourDisplay = display
                entry.cachedColourThumb   = thumb
                entry.colourRecipe = .colour(rOffset: pattern.rOffset, clips: sharedClips,
                                             maxDisplaySize: maxDisplaySize)
                if pipeline?.renderGeneration == generation {
                    entry.displayImage    = display
                    entry.thumbnail       = thumb
                }
                pipeline?.batchRestretchCount += 1
            }
        }
    }
}
