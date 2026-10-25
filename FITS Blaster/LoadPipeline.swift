//
//  LoadPipeline.swift
//  FITS Blaster
//
//  The loading pipeline: batches (open, new sizes, metrics recompute, colour toggle),
//  the concurrent Phase A / Phase B work, grey and colour normalisation, and the batch
//  state the progress UI shows. Owned by ImageStore (`store.pipeline`); the per-file
//  work is in FrameLoading.
//

import Foundation
import AppKit
import Metal

@Observable
@MainActor
final class LoadPipeline {

    /// The store whose entries this pipeline loads; set by `ImageStore.init`.
    @ObservationIgnored weak var store: ImageStore?

    // MARK: - Batch state

    var batchElapsed: Double?
    var batchMegapixels: Double?
    /// Number of images in the last finished batch (not the whole session).
    var batchImageCount: Int?
    var isBatchProcessing: Bool = false

    /// The currently running load / reprocess task. Stored so it can be cancelled by the user.
    var processingTask: Task<Void, Never>?

    /// The folder scan of a drag & drop, before its batch load starts (`openDroppedItems`).
    var dropScanTask: Task<Void, Never>?

    /// What a load is doing before its frames appear (scanning, checking headers); nil otherwise.
    var preparation: LoadPreparation?

    /// Suspends the caller until any in-progress drop scan and batch load complete.
    /// Used by CLI mode and the tests.
    func waitForProcessing() async {
        await dropScanTask?.value
        await processingTask?.value
    }

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

    /// Cancels any in-progress loading or recompute batch.
    /// In-flight GPU/I/O tasks run to completion (they can't be interrupted mid-flight),
    /// but no new work is started and the UI is cleaned up immediately.
    func cancelProcessing() {
        dropScanTask?.cancel()
        dropScanTask = nil
        processingTask?.cancel()
        processingTask = nil
        preparation = nil
        for entry in store?.entries ?? [] where entry.isProcessing {
            entry.isProcessing = false
        }
        isBatchProcessing = false
        batchElapsed = nil
        batchMegapixels = nil
        batchImageCount = nil
    }

    /// Clears the batch display state, as Reset does.
    func clearBatchState() {
        batchElapsed = nil
        batchMegapixels = nil
        batchImageCount = nil
        isBatchProcessing = false
        batchRestretchTotal = 0
        batchRestretchCount = 0
        batchSamplingTotal = 0
        batchSamplingCount = 0
    }

    // MARK: - Loading

    func openFiles(_ urlsWithPaths: [(url: URL, subfolderPath: String)],
                   rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "",
                   rootFolderNames: [URL: String] = [:],
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false) {
        guard let store else { return }
        let selectFirst = (store.selectedEntry == nil)

        // Snapshot existing URLs now, on the main actor, before handing off to the task.
        // Both paths of each entry: a file rejected this session sits at …/REJECTED/x.fits
        // (url) while originalURL is …/x.fits, and reopening the folder with REJECTED
        // scans the former (CODE_AUDIT §5.8).
        let existingURLs = Set(store.entries.flatMap { [$0.url, $0.originalURL] })

        batchElapsed = nil
        batchMegapixels = nil
        batchImageCount = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            // Phase 0: validate files off the main thread.
            //
            // peekBitpix does a synchronous FileHandle.read — moving it here via a
            // nonisolated function ensures the main thread is never blocked by slow
            // I/O (iCloud materialisation, SMB mounts, heavy disk pressure, etc.).
            // Over a network this reads hundreds of files, so its progress is shown.
            let total = urlsWithPaths.count
            preparation = .checking(done: 0, total: total)
            let (progress, progressContinuation) = AsyncStream.makeStream(of: Int.self,
                                                                          bufferingPolicy: .bufferingNewest(1))
            async let filtered = FrameLoading.filterItems(urlsWithPaths, existingURLs: existingURLs,
                                                  progress: progressContinuation)
            for await done in progress {
                preparation = .checking(done: done, total: total)
            }
            let (validItems, skippedFloat) = await filtered
            preparation = nil

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
                store.entries.append(entry)
                newEntries.append(entry)
            }
            if !skippedFloat.isEmpty {
                let preview = skippedFloat.prefix(5).joined(separator: ", ")
                let suffix  = skippedFloat.count > 5 ? " and \(skippedFloat.count - 5) more" : ""
                store.errorMessage = "Skipped \(skippedFloat.count) floating-point FITS file\(skippedFloat.count == 1 ? "" : "s") (not supported): \(preview)\(suffix)"
            }
            guard !newEntries.isEmpty else {
                isBatchProcessing = false
                processingTask = nil
                return
            }

            if selectFirst { store.selectedEntry = newEntries[0] }

            // Populate the sort/filter cache so the sidebar renders immediately.
            store.updateActiveFilterGroups()
            store.updateCachedSort()

            await processParallel(newEntries, selectFirst: selectFirst,
                                  maxDisplaySize: maxDisplaySize,
                                  maxThumbnailSize: maxThumbnailSize,
                                  metricsConfig: metricsConfig,
                                  debayerColorImages: debayerColorImages)
            if !Task.isCancelled {
                await normalizeGreyStretch(newEntries, maxDisplaySize: maxDisplaySize,
                                           maxThumbnailSize: maxThumbnailSize)
            }
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            batchImageCount = newEntries.count
            batchMegapixels = newEntries.reduce(0.0) {
                guard let w = $1.headers["NAXIS1"].flatMap(Int.init),
                      let h = $1.headers["NAXIS2"].flatMap(Int.init) else { return $0 }
                return $0 + Double(w * h) / 1_000_000
            }
            isBatchProcessing = false
            processingTask = nil
        }
    }

    /// Re-renders display images and thumbnails at new sizes without touching metrics.
    ///
    /// Unlike a normal load, this never runs Phase B (star detection). After Phase A
    /// completes, each entry's `metrics` is restored from its `cachedMetrics` so the
    /// displayed values remain unchanged throughout.
    func regenerateSizes(settings: AppSettings) {
        guard let store else { return }
        let entriesToProcess = store.entries
        let metricsConfig    = settings.effectiveMetricsConfig
        for entry in entriesToProcess {
            entry.isProcessing = true
            entry.displayImage = nil
            entry.thumbnail    = nil
            entry.histogram    = nil
            // Intentionally leave entry.metrics and entry.cachedMetrics intact.
        }

        let accessedDirs = entriesToProcess.compactMap { store.accessDirectory(for: $0) }

        batchElapsed = nil
        batchMegapixels = nil
        batchImageCount = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task { [weak self] in
            guard let self else { return }
            // Pass an all-disabled MetricsConfig so processParallel skips Phase B entirely.
            await processParallel(entriesToProcess, selectFirst: false,
                                  maxDisplaySize: settings.maxDisplaySize,
                                  maxThumbnailSize: settings.maxThumbnailSize,
                                  metricsConfig: .off,
                                  debayerColorImages: settings.debayerColorImages)
            // Restore metric values from cache now that Phase A is done.
            for entry in entriesToProcess {
                if let cached = entry.cachedMetrics {
                    entry.metrics = cached.filtered(by: metricsConfig)
                }
            }
            if !Task.isCancelled {
                await normalizeGreyStretch(entriesToProcess,
                                           maxDisplaySize: settings.maxDisplaySize,
                                           maxThumbnailSize: settings.maxThumbnailSize)
            }
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            batchImageCount = entriesToProcess.count
            batchMegapixels = entriesToProcess.reduce(0.0) {
                guard let w = $1.headers["NAXIS1"].flatMap(Int.init),
                      let h = $1.headers["NAXIS2"].flatMap(Int.init) else { return $0 }
                return $0 + Double(w * h) / 1_000_000
            }
            isBatchProcessing = false
            processingTask = nil
        }
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

        let accessedDirs = needsRecompute.compactMap { store.accessDirectory(for: $0) }
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            // Scale to core count, same policy as processParallel.
            let maxConcurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

            await withTaskGroup(of: Void.self) { group in
                var activeCount = 0
                for entry in needsRecompute {
                    if activeCount >= maxConcurrency {
                        await group.next()
                        activeCount -= 1
                    }
                    let url = entry.url
                    group.addTask {
                        let newMetrics = await FrameLoading.loadMetricsOnly(url: url, config: metricsConfig)
                        await MainActor.run {
                            if let newMetrics {
                                entry.cachedMetrics = newMetrics
                                entry.metrics = newMetrics.filtered(by: metricsConfig)
                            }
                        }
                    }
                    activeCount += 1
                }
            }

            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            store.updateGroupStatistics()
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            batchImageCount = needsRecompute.count
            batchMegapixels = needsRecompute.reduce(0.0) {
                guard let w = $1.headers["NAXIS1"].flatMap(Int.init),
                      let h = $1.headers["NAXIS2"].flatMap(Int.init) else { return $0 }
                return $0 + Double(w * h) / 1_000_000
            }
            isBatchProcessing = false
            processingTask = nil
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
    ///
    /// **Colour normalisation** — fires per folder as soon as all entries in
    /// that folder complete Phase A, while their FITS pages are still warm in
    /// the OS file cache. Runs concurrently with Phase B and Phase A for other
    /// folders, rather than waiting for the entire batch to finish.
    func processParallel(_ entriesToProcess: [ImageEntry], selectFirst: Bool,
                         maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                         metricsConfig: MetricsConfig = MetricsConfig(),
                         debayerColorImages: Bool = false) async {

        // Reset colour counters for this pass so a grey-mode pass never shows a stale
        // Restretching bar from a previous session. When debayering, set the total
        // upfront to the full entry count so the bar stays visible for the entire load
        // rather than flickering in/out as each folder completes.
        batchRestretchTotal  = debayerColorImages ? entriesToProcess.count : 0
        batchRestretchCount = 0

        // Phase A: high I/O concurrency keeps the SSD pipeline full.
        // Phase B: bounded separately to prevent CPU/memory over-subscription.
        let ioConcurrency   = max(8, ProcessInfo.processInfo.activeProcessorCount)
        let phaseBSemaphore = AsyncSemaphore(count: max(4, ProcessInfo.processInfo.activeProcessorCount - 2))
        var phaseBTasks:   [Task<Void, Never>] = []
        var colourTasks:   [Task<Void, Never>] = []

        // Pre-group entries by folder so each folder's colour task can access its siblings.
        // Only built when colour debayering is enabled — avoids the allocation otherwise.
        let folderEntriesMap: [String: [ImageEntry]] = debayerColorImages
            ? Dictionary(grouping: entriesToProcess, by: \.qualifiedFolderPath)
            : [:]
        let folderTracker = FolderTracker(grouping: entriesToProcess)

        await withTaskGroup(of: (ImageEntry, Task<Void, Never>?, Task<Void, Never>?).self) { group in
            var activeCount = 0
            for entry in entriesToProcess {
                if Task.isCancelled { break }

                if activeCount >= ioConcurrency {
                    if let (_, phaseB, colour) = await group.next() {
                        if let t = phaseB  { phaseBTasks.append(t) }
                        if let t = colour  { colourTasks.append(t) }
                    }
                    activeCount -= 1
                }
                let url  = entry.url
                let path = entry.qualifiedFolderPath
                group.addTask { [weak self] in
                    // ── Phase A: I/O + histogram + GPU stretch ────────────────
                    let fast = await FrameLoading.loadFast(url: url,
                                                   maxDisplaySize: maxDisplaySize,
                                                   maxThumbnailSize: maxThumbnailSize,
                                                   debayerColorImages: debayerColorImages)
                    await MainActor.run { [weak self] in
                        entry.displayImage = fast.display
                        entry.thumbnail    = fast.thumb
                        entry.imageInfo    = fast.info
                        entry.errorMessage = fast.error
                        entry.histogram    = fast.histogram
                        entry.headers      = fast.headers
                        entry.bayerClips   = fast.bayerClips
                        entry.greyClips    = fast.greyClips
                        // Pre-populate the greyscale cache so any toggle to grey is instant.
                        if entry.isBayer {
                            entry.cachedGreyscaleDisplay = fast.display
                            entry.cachedGreyscaleThumb   = fast.thumb
                        }
                        entry.isProcessing = false   // ← image visible now

                        if selectFirst, entry === entriesToProcess.first, fast.display != nil {
                            self?.store?.selectedEntry = entry
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
                        if folderDone, let fEntries = folderEntriesMap[path] {
                            colourTask = Task(priority: .utility) { [weak self] in
                                guard let self else { return }
                                await self.renderFolderInColour(fEntries,
                                                                maxDisplaySize: maxDisplaySize,
                                                                maxThumbnailSize: maxThumbnailSize)
                            }
                        }
                    }

                    // ── Phase B: GPU detection + Moffat fitting ───────────────
                    // Acquire a Phase B slot before spawning the detached task.
                    // This bounds the number of live MTLBuffers to phaseBSemaphore.count
                    // while still freeing this group slot immediately after.
                    guard metricsConfig.needsStarDetection else { return (entry, nil, colourTask) }
                    await phaseBSemaphore.wait()
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
                            // CPU fallback: Metal was unavailable during Phase A.
                            metrics = await FrameLoading.loadMetricsOnly(url: url, config: metricsConfig)
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

        // Wait for all Phase B tasks. On cancellation, break early — queued
        // tasks will complete in the background and harmlessly update entries.
        for task in phaseBTasks {
            if Task.isCancelled { break }
            await task.value
        }

        // Wait for any per-folder colour tasks that are still running.
        for task in colourTasks {
            if Task.isCancelled { break }
            await task.value
        }

        store?.updateGroupStatistics()
    }

    /// Re-renders only display images and thumbnails for Bayer frames when the
    /// colour debayering preference is toggled. Does NOT touch metrics or histograms.
    ///
    /// - Colour ON:  computes missing per-channel clip bounds (if images were loaded
    ///               with debayer off), then re-renders with per-folder median clips.
    /// - Colour OFF: re-renders Bayer images as greyscale.
    func recolorImages(settings: AppSettings) {
        let debayer          = settings.debayerColorImages
        let maxDisplaySize   = settings.maxDisplaySize
        let maxThumbnailSize = settings.maxThumbnailSize
        guard let store else { return }
        let bayerEntries     = store.entries.filter { $0.isBayer }
        guard !bayerEntries.isEmpty else { return }

        let accessedDirs = bayerEntries.compactMap { store.accessDirectory(for: $0) }

        Task { [weak self] in
            guard let self else { return }
            defer { for d in accessedDirs { d.stopAccessingSecurityScopedResource() } }

            if debayer {
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
                        let t = Task(priority: .utility) { [weak self] in
                            guard let self else { return }
                            await self.renderFolderInColour(fEntries,
                                                           maxDisplaySize: maxDisplaySize,
                                                           maxThumbnailSize: maxThumbnailSize)
                        }
                        colourTasks.append(t)
                    }
                }

                let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
                await withTaskGroup(of: String?.self) { group in
                    var active = 0
                    for entry in needsClips {
                        // Drain a result before adding another task when at capacity.
                        while active >= concurrency {
                            guard let taskResult = await group.next() else { break }
                            if let path = taskResult, let fEntries = folderEntriesMap[path] {
                                let t = Task(priority: .utility) { [weak self] in
                                    guard let self else { return }
                                    await self.renderFolderInColour(fEntries,
                                                                   maxDisplaySize: maxDisplaySize,
                                                                   maxThumbnailSize: maxThumbnailSize)
                                }
                                colourTasks.append(t)
                            }
                            active -= 1
                        }
                        let url     = entry.url
                        let bayerPattern = entry.bayerPattern
                        let path    = entry.qualifiedFolderPath
                        group.addTask { [weak self] in
                            let didStart = url.startAccessingSecurityScopedResource()
                            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                            guard let pattern = bayerPattern,
                                  let device  = ImageStretcher.metalDevice,
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
                        active += 1
                    }
                    // Drain remaining results and fire any outstanding colour tasks.
                    for await taskResult in group {
                        if let path = taskResult, let fEntries = folderEntriesMap[path] {
                            let t = Task(priority: .utility) { [weak self] in
                                guard let self else { return }
                                await self.renderFolderInColour(fEntries,
                                                               maxDisplaySize: maxDisplaySize,
                                                               maxThumbnailSize: maxThumbnailSize)
                            }
                            colourTasks.append(t)
                        }
                    }
                }
                // Wait for all per-folder colour renders to finish.
                for task in colourTasks { await task.value }
            } else {
                // Re-render Bayer images as greyscale; metrics and histogram are unchanged.
                // Use cached greyscale renders if available to avoid file re-reads.
                let needsRender = bayerEntries.filter { $0.cachedGreyscaleDisplay == nil }
                if !needsRender.isEmpty {
                    restretchingMessage = "Rendering greyscale…"
                    defer { restretchingMessage = nil }
                    let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
                    await withTaskGroup(of: Void.self) { group in
                        var active = 0
                        for entry in needsRender {
                            if active >= concurrency { await group.next(); active -= 1 }
                            let url = entry.url
                            group.addTask {
                                let didStart = url.startAccessingSecurityScopedResource()
                                defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                                guard let device = ImageStretcher.metalDevice,
                                      let result = try? FITSReader.readIntoBuffer(from: url, device: device)
                                else { return }
                                let display = await ImageStretcher.createImage(
                                    inputBuffer: result.metalBuffer,
                                    width: result.metadata.width, height: result.metadata.height,
                                    maxDisplaySize: maxDisplaySize)
                                let thumb = display.flatMap {
                                    ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize)
                                }
                                await MainActor.run {
                                    entry.cachedGreyscaleDisplay = display
                                    entry.cachedGreyscaleThumb   = thumb
                                    if let d = display { entry.displayImage = d }
                                    if let t = thumb   { entry.thumbnail    = t }
                                }
                            }
                            active += 1
                        }
                    }
                }
                // Apply cached renders for entries that already had them.
                for entry in bayerEntries where entry.cachedGreyscaleDisplay != nil && !needsRender.contains(where: { $0 === entry }) {
                    entry.displayImage = entry.cachedGreyscaleDisplay
                    entry.thumbnail    = entry.cachedGreyscaleThumb
                }
            }
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
        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)
        await withTaskGroup(of: Void.self) { group in
            var active = 0
            for entry in entries {
                if active >= concurrency { await group.next(); active -= 1 }
                let url     = entry.url
                let bayerPattern = entry.bayerPattern
                group.addTask {
                    let didStart = url.startAccessingSecurityScopedResource()
                    defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                    guard let device = ImageStretcher.metalDevice,
                          let result = try? FITSReader.readIntoBuffer(from: url, device: device)
                    else { return }
                    let display = await ImageStretcher.createImage(
                        inputBuffer: result.metalBuffer,
                        width: result.metadata.width, height: result.metadata.height,
                        clips: clips, maxDisplaySize: maxDisplaySize,
                        bayerPattern: bayerPattern)
                    let thumb = display.flatMap {
                        ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize)
                    }
                    await MainActor.run {
                        if let d = display { entry.displayImage = d }
                        if let t = thumb   { entry.thumbnail    = t }
                    }
                }
                active += 1
            }
        }
    }

    /// Renders one folder group's Bayer images in colour using the per-channel median of
    /// the individual `bayerClips` already computed during Phase A or sampling.
    ///
    /// Called from `processParallel` and `recolorImages` as soon as all entries in a
    /// folder complete their clip computation, while FITS pages are still warm in cache.
    /// Updates `batchRestretchCount` so the Restretching bar advances smoothly.
    /// `batchRestretchTotal` must be set to the full entry count by the caller upfront.
    private func renderFolderInColour(_ entries: [ImageEntry],
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
        if let selected = store?.selectedEntry,
           bayerEntries.contains(where: { $0 === selected }),
           selected.cachedColourDisplay == nil,
           let pattern = selected.bayerPattern,
           let (display, thumb) = await FrameLoading.recolorBayerEntry(
               url: selected.url, rOffset: pattern.rOffset, clips: sharedClips,
               maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize) {
            selected.cachedColourDisplay = display
            selected.cachedColourThumb   = thumb
            selected.displayImage        = display
            selected.thumbnail           = thumb
            batchRestretchCount += 1
        }

        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0
            for entry in bayerEntries {
                // Apply a cached colour render (e.g. the priority pass above) without a task.
                if entry.cachedColourDisplay != nil {
                    entry.displayImage = entry.cachedColourDisplay
                    entry.thumbnail    = entry.cachedColourThumb
                    batchRestretchCount += 1
                    continue
                }
                if activeCount >= concurrency { await group.next(); activeCount -= 1 }
                let url     = entry.url
                let bayerPattern = entry.bayerPattern
                group.addTask {
                    guard let pattern = bayerPattern,
                          let (display, thumb) = await FrameLoading.recolorBayerEntry(
                              url: url, rOffset: pattern.rOffset, clips: sharedClips,
                              maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize
                          ) else {
                        await MainActor.run { self.batchRestretchCount += 1 }
                        return
                    }
                    await MainActor.run {
                        entry.cachedColourDisplay = display
                        entry.cachedColourThumb   = thumb
                        entry.displayImage        = display
                        entry.thumbnail           = thumb
                        self.batchRestretchCount += 1
                    }
                }
                activeCount += 1
            }
        }
    }
}
