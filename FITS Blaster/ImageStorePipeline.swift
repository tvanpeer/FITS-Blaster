//
//  ImageStorePipeline.swift
//  FITS Blaster
//
//  Loading pipeline: openFiles, reprocessAll, recomputeMetrics, processParallel,
//  recolorImages, renderFolderInColour, and the nonisolated fast-load helpers.
//

import Foundation
import AppKit
import Metal

extension ImageStore {

    // MARK: - Loading

    /// Convenience wrapper for callers that provide a flat list without subfolder info.
    func openFiles(_ urls: [URL], rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "", directoryBookmark: Data? = nil,
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false) {
        openFiles(urls.map { (url: $0, subfolderPath: "") },
                  rejectedURLs: rejectedURLs,
                  rootFolderName: rootFolderName,
                  directoryBookmark: directoryBookmark,
                  maxDisplaySize: maxDisplaySize,
                  maxThumbnailSize: maxThumbnailSize,
                  metricsConfig: metricsConfig,
                  debayerColorImages: debayerColorImages)
    }

    func openFiles(_ urlsWithPaths: [(url: URL, subfolderPath: String)],
                   rejectedURLs: Set<URL> = [],
                   rootFolderName: String = "",
                   directoryBookmark: Data? = nil,
                   maxDisplaySize: Int = 1024, maxThumbnailSize: Int = 120,
                   metricsConfig: MetricsConfig = MetricsConfig(),
                   debayerColorImages: Bool = false) {
        let selectFirst = (selectedEntry == nil)

        // Snapshot existing URLs now, on the main actor, before handing off to the task.
        let existingURLs = Set(entries.map { $0.originalURL })

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }

            // Phase 0: validate files off the main thread.
            //
            // peekBitpix does a synchronous FileHandle.read — moving it here via a
            // nonisolated function ensures the main thread is never blocked by slow
            // I/O (iCloud materialisation, SMB mounts, heavy disk pressure, etc.).
            let (validItems, skippedFloat) = await Self.filterItems(
                urlsWithPaths, existingURLs: existingURLs)

            // Add entries on the main actor so the sidebar shows loading spinners.
            var newEntries: [ImageEntry] = []
            for item in validItems {
                let isRejected = rejectedURLs.contains(item.url)
                let computedOriginalURL: URL? = isRejected
                    ? item.url.deletingLastPathComponent()  // …/Ha/REJECTED/
                               .deletingLastPathComponent() // …/Ha/
                               .appending(component: item.url.lastPathComponent) // …/Ha/image.fits
                    : nil
                let entry = ImageEntry(url: item.url, originalURL: computedOriginalURL, directoryBookmark: directoryBookmark)
                entry.subfolderPath = item.subfolderPath
                entry.rootFolderName = rootFolderName
                if isRejected {
                    entry.isRejected = true
                    rejectedEntryIDs.insert(entry.id)
                }
                entries.append(entry)
                newEntries.append(entry)
            }
            if !skippedFloat.isEmpty {
                let preview = skippedFloat.prefix(5).joined(separator: ", ")
                let suffix  = skippedFloat.count > 5 ? " and \(skippedFloat.count - 5) more" : ""
                errorMessage = "Skipped \(skippedFloat.count) floating-point FITS file\(skippedFloat.count == 1 ? "" : "s") (not supported): \(preview)\(suffix)"
            }
            guard !newEntries.isEmpty else {
                isBatchProcessing = false
                processingTask = nil
                return
            }

            if selectFirst { selectedEntry = newEntries[0] }

            // Populate the sort/filter cache so the sidebar renders immediately.
            updateActiveFilterGroups()
            updateCachedSort()

            await processParallel(newEntries, selectFirst: selectFirst,
                                  maxDisplaySize: maxDisplaySize,
                                  maxThumbnailSize: maxThumbnailSize,
                                  metricsConfig: metricsConfig,
                                  debayerColorImages: debayerColorImages)
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    /// Filters a list of candidate URLs off the main thread: strips unsupported
    /// extensions, removes duplicates, and reads the first header block of each
    /// remaining file to detect and reject floating-point FITS.
    ///
    /// This function is `nonisolated` so Swift runs it on the cooperative thread
    /// pool rather than the main actor, keeping the UI responsive even when files
    /// are stored on iCloud Drive, SMB mounts, or a loaded SSD.
    @concurrent static func filterItems(
        _ items: [(url: URL, subfolderPath: String)],
        existingURLs: Set<URL>
    ) async -> (valid: [(url: URL, subfolderPath: String)], skippedFloat: [String]) {
        var valid: [(url: URL, subfolderPath: String)] = []
        var skippedFloat: [String] = []
        for item in items {
            let url = item.url
            guard ["fits", "fit", "fts"].contains(url.pathExtension.lowercased()) else { continue }
            guard !existingURLs.contains(url) else { continue }
            if let bitpix = FITSReader.peekBitpix(url: url), ![8, 16, 32].contains(bitpix) {
                skippedFloat.append(url.lastPathComponent)
                continue
            }
            valid.append(item)
        }
        return (valid, skippedFloat)
    }

    /// Reprocesses all currently loaded images with updated settings.
    func reprocessAll(settings: AppSettings) {
        let entriesToProcess = entries
        for entry in entriesToProcess {
            entry.isProcessing    = true
            entry.displayImage    = nil
            entry.thumbnail       = nil
            entry.metrics         = nil
            entry.cachedMetrics   = nil
            entry.histogram       = nil
        }

        let accessedDirs = entriesToProcess.compactMap { accessDirectory(for: $0) }

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task { [weak self] in
            guard let self else { return }
            await processParallel(entriesToProcess, selectFirst: false,
                                  maxDisplaySize: settings.maxDisplaySize,
                                  maxThumbnailSize: settings.maxThumbnailSize,
                                  metricsConfig: settings.metricsConfig,
                                  debayerColorImages: settings.debayerColorImages)
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    /// Re-renders display images and thumbnails at new sizes without touching metrics.
    ///
    /// Unlike `reprocessAll`, this never runs Phase B (star detection). After Phase A
    /// completes, each entry's `metrics` is restored from its `cachedMetrics` so the
    /// displayed values remain unchanged throughout.
    func regenerateSizes(settings: AppSettings) {
        let entriesToProcess = entries
        let metricsConfig    = settings.metricsConfig
        for entry in entriesToProcess {
            entry.isProcessing = true
            entry.displayImage = nil
            entry.thumbnail    = nil
            entry.histogram    = nil
            // Intentionally leave entry.metrics and entry.cachedMetrics intact.
        }

        let accessedDirs = entriesToProcess.compactMap { accessDirectory(for: $0) }

        batchElapsed = nil
        isBatchProcessing = true
        let startTime = CFAbsoluteTimeGetCurrent()

        processingTask = Task { [weak self] in
            guard let self else { return }
            // Pass an all-disabled MetricsConfig so processParallel skips Phase B entirely.
            await processParallel(entriesToProcess, selectFirst: false,
                                  maxDisplaySize: settings.maxDisplaySize,
                                  maxThumbnailSize: settings.maxThumbnailSize,
                                  metricsConfig: MetricsConfig(computeFWHM: false,
                                                               computeEccentricity: false,
                                                               computeSNR: false,
                                                               computeStarCount: false),
                                  debayerColorImages: settings.debayerColorImages)
            // Restore metric values from cache now that Phase A is done.
            for entry in entriesToProcess {
                if let cached = entry.cachedMetrics {
                    entry.metrics = cached.filtered(by: metricsConfig)
                }
            }
            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
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
        let entriesToProcess = entries.filter { !$0.isProcessing }
        guard !entriesToProcess.isEmpty, !isBatchProcessing else { return }

        // Pass 1 (synchronous, no I/O): restore from cache for everything we already have.
        for entry in entriesToProcess {
            if let cached = entry.cachedMetrics {
                entry.metrics = cached.filtered(by: metricsConfig)
            }
        }

        // Refresh the sort cache now that cached metrics have been restored synchronously.
        updateCachedSort()

        // Pass 2: collect entries that still need at least one metric computed from disk.
        let needsRecompute = entriesToProcess.filter { entry in
            let c = entry.cachedMetrics
            if metricsConfig.computeFWHM         && c?.fwhm         == nil { return true }
            if metricsConfig.computeEccentricity && c?.eccentricity == nil { return true }
            if metricsConfig.computeSNR          && c?.snr          == nil { return true }
            if metricsConfig.computeStarCount    && c?.starCount    == nil { return true }
            return false
        }

        guard !needsRecompute.isEmpty else { return }

        let accessedDirs = needsRecompute.compactMap { accessDirectory(for: $0) }
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
                    // Only request the metrics that are actually missing from cache.
                    let c = entry.cachedMetrics
                    let missingConfig = MetricsConfig(
                        computeFWHM:         metricsConfig.computeFWHM         && c?.fwhm         == nil,
                        computeEccentricity: metricsConfig.computeEccentricity && c?.eccentricity == nil,
                        computeSNR:          metricsConfig.computeSNR          && c?.snr          == nil,
                        computeStarCount:    metricsConfig.computeStarCount    && c?.starCount    == nil
                    )
                    let url = entry.url
                    group.addTask {
                        let newMetrics = await Self.loadMetricsOnly(url: url, config: missingConfig)
                        await MainActor.run {
                            if let newMetrics {
                                let merged = (entry.cachedMetrics ?? newMetrics).merging(newMetrics)
                                entry.cachedMetrics = merged
                                entry.metrics = merged.filtered(by: metricsConfig)
                            }
                        }
                    }
                    activeCount += 1
                }
            }

            for dirURL in accessedDirs { dirURL.stopAccessingSecurityScopedResource() }
            guard !Task.isCancelled else { return }
            updateGroupStatistics()
            batchElapsed = CFAbsoluteTimeGetCurrent() - startTime
            isBatchProcessing = false
            processingTask = nil
        }
    }

    @concurrent static func loadMetricsOnly(url: URL,
                                            config: MetricsConfig) async -> FrameMetrics? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        // GPU path: read into a Metal shared buffer (same path as the initial load),
        // then run the GPU detection kernel. Much faster than the CPU fallback because
        // the Metal kernel uses the full frame, while the CPU path is limited to a crop.
        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta = bufferResult.metadata
            return await MetricsCalculator.compute(metalBuffer: bufferResult.metalBuffer,
                                                   device: device,
                                                   width: meta.width, height: meta.height,
                                                   config: config)
        }

        // CPU fallback when Metal is unavailable.
        guard let fits = try? FITSReader.read(from: url) else { return nil }
        return await MetricsCalculator.compute(pixels: fits.pixelValues,
                                               width: fits.width, height: fits.height,
                                               config: config)
    }

    // MARK: - Concurrent pipeline

    /// Two-phase pipeline per image:
    ///
    /// **Phase A** — I/O + GPU stretch + crop extraction (~100–300 ms total):
    /// image becomes visible immediately. Star crops are extracted from the
    /// MTLBuffer before it is released, so no second file read is needed.
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
        // Colour bar from a previous colour session. When debayering, set the total
        // upfront to the full entry count so the bar stays visible for the entire load
        // rather than flickering in/out as each folder completes.
        batchBayerTotal  = debayerColorImages ? entriesToProcess.count : 0
        batchColourCount = 0

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
                    let fast = await Self.loadFast(url: url,
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
                        // Pre-populate the greyscale cache so any toggle to grey is instant.
                        if BayerPattern.parse(from: fast.headers) != nil {
                            entry.cachedGreyscaleDisplay = fast.display
                            entry.cachedGreyscaleThumb   = fast.thumb
                        }
                        entry.isProcessing = false   // ← image visible now

                        if selectFirst, entry === entriesToProcess.first, fast.display != nil {
                            self?.selectedEntry = entry
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
                        if let buffer = fast.metalBuffer, let device = fast.metalDevice {
                            metrics = await MetricsCalculator.compute(
                                metalBuffer: buffer, device: device,
                                width: fast.width, height: fast.height, config: metricsConfig)
                        } else {
                            // CPU fallback: Metal was unavailable during Phase A.
                            metrics = await Self.loadMetricsOnly(url: url, config: metricsConfig)
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

        updateGroupStatistics()
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
        let bayerEntries     = entries.filter { $0.isBayer }
        guard !bayerEntries.isEmpty else { return }

        let accessedDirs = bayerEntries.compactMap { accessDirectory(for: $0) }

        Task { [weak self] in
            guard let self else { return }
            defer { for d in accessedDirs { d.stopAccessingSecurityScopedResource() } }

            if debayer {
                recolouringMessage = "Rendering colour…"
                defer { recolouringMessage = nil }

                let needsClips = bayerEntries.filter { $0.bayerClips == nil }
                // Set progress counters upfront so the bars are stable for the full run.
                batchSamplingTotal = bayerEntries.count
                batchSamplingCount = bayerEntries.count - needsClips.count
                batchBayerTotal    = bayerEntries.count
                batchColourCount   = 0

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
                        let headers = entry.headers
                        let path    = entry.qualifiedFolderPath
                        group.addTask { [weak self] in
                            let didStart = url.startAccessingSecurityScopedResource()
                            defer { if didStart { url.stopAccessingSecurityScopedResource() } }
                            guard let pattern = BayerPattern.parse(from: headers),
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
                    recolouringMessage = "Rendering greyscale…"
                    defer { recolouringMessage = nil }
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

    /// Renders one folder group's Bayer images in colour using the per-channel median of
    /// the individual `bayerClips` already computed during Phase A or sampling.
    ///
    /// Called from `processParallel` and `recolorImages` as soon as all entries in a
    /// folder complete their clip computation, while FITS pages are still warm in cache.
    /// Updates `batchColourCount` so the Colour bar advances smoothly.
    /// `batchBayerTotal` must be set to the full entry count by the caller upfront.
    private func renderFolderInColour(_ entries: [ImageEntry],
                                      maxDisplaySize: Int,
                                      maxThumbnailSize: Int) async {
        let bayerEntries = entries.filter { $0.bayerClips != nil }

        // Non-Bayer entries in this folder need no colour rendering — count them immediately
        // so progress advances correctly against the full batchBayerTotal.
        batchColourCount += entries.count - bayerEntries.count

        guard !bayerEntries.isEmpty else { return }

        let sharedClips = BayerClips.median(of: bayerEntries.compactMap(\.bayerClips))
        guard sharedClips.isValid else { return }

        // Render the selected entry first so the on-screen image switches to colour immediately.
        if let selected = selectedEntry,
           bayerEntries.contains(where: { $0 === selected }),
           selected.cachedColourDisplay == nil,
           let pattern = BayerPattern.parse(from: selected.headers),
           let (display, thumb) = await Self.recolorBayerEntry(
               url: selected.url, rOffset: pattern.rOffset, clips: sharedClips,
               maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize) {
            selected.cachedColourDisplay = display
            selected.cachedColourThumb   = thumb
            selected.displayImage        = display
            selected.thumbnail           = thumb
            batchColourCount += 1
        }

        let concurrency = max(4, ProcessInfo.processInfo.activeProcessorCount - 2)

        await withTaskGroup(of: Void.self) { group in
            var activeCount = 0
            for entry in bayerEntries {
                // Apply a cached colour render (e.g. the priority pass above) without a task.
                if entry.cachedColourDisplay != nil {
                    entry.displayImage = entry.cachedColourDisplay
                    entry.thumbnail    = entry.cachedColourThumb
                    batchColourCount += 1
                    continue
                }
                if activeCount >= concurrency { await group.next(); activeCount -= 1 }
                let url     = entry.url
                let headers = entry.headers
                group.addTask {
                    guard let pattern = BayerPattern.parse(from: headers),
                          let (display, thumb) = await Self.recolorBayerEntry(
                              url: url, rOffset: pattern.rOffset, clips: sharedClips,
                              maxDisplaySize: maxDisplaySize, maxThumbnailSize: maxThumbnailSize
                          ) else {
                        await MainActor.run { self.batchColourCount += 1 }
                        return
                    }
                    await MainActor.run {
                        entry.cachedColourDisplay = display
                        entry.cachedColourThumb   = thumb
                        entry.displayImage        = display
                        entry.thumbnail           = thumb
                        self.batchColourCount += 1
                    }
                }
                activeCount += 1
            }
        }
    }

    /// Re-reads a single FITS file and renders it in colour with the given shared clip bounds.
    /// Called by `normalizeBayerStretch` and `renderFolderInColour`.
    @concurrent static func recolorBayerEntry(
        url: URL, rOffset: UInt32, clips: BayerClips,
        maxDisplaySize: Int, maxThumbnailSize: Int
    ) async -> (display: NSImage, thumb: NSImage?)? {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        guard let device = ImageStretcher.metalDevice,
              let result = try? FITSReader.readIntoBuffer(from: url, device: device)
        else { return nil }

        guard let display = await ImageStretcher.createBayerImage(
            inputBuffer: result.metalBuffer,
            width: result.metadata.width, height: result.metadata.height,
            rOffset: rOffset, clips: clips, maxDisplaySize: maxDisplaySize
        ) else { return nil }

        let thumb = ImageStretcher.createThumbnail(from: display, maxSize: maxThumbnailSize)
        return (display, thumb)
    }

    /// Phase A of the loading pipeline: read the FITS file, compute the histogram,
    /// and GPU-stretch to produce the display image and thumbnail.
    ///
    /// The returned `FastLoadResult.metalBuffer` is retained so Phase B can run
    /// GPU star-detection on the same buffer without a second file read.
    @concurrent static func loadFast(url: URL,
                                     maxDisplaySize: Int = 1024,
                                     maxThumbnailSize: Int = 120,
                                     debayerColorImages: Bool = false) async -> FastLoadResult {
        let didStart = url.startAccessingSecurityScopedResource()
        defer { if didStart { url.stopAccessingSecurityScopedResource() } }

        if let device = ImageStretcher.metalDevice,
           let bufferResult = try? FITSReader.readIntoBuffer(from: url, device: device) {
            let meta     = bufferResult.metadata
            let floatPtr = bufferResult.metalBuffer.contents().assumingMemoryBound(to: Float.self)
            let histogram = MetricsCalculator.computeHistogram(ptr: floatPtr,
                                                               count: meta.width * meta.height,
                                                               minVal: meta.minValue,
                                                               maxVal: meta.maxValue)

            // Always render a greyscale image immediately so the UI shows something fast.
            // For Bayer images with debayering enabled, also compute per-channel clip bounds
            // so the post-batch normalise pass can re-render in colour with shared median clips.
            // Pass bayerPattern so the greyscale stretch applies 2×2 Bayer binning,
            // eliminating the screen-door effect on raw Bayer mosaic files.
            let display = await ImageStretcher.createImage(inputBuffer: bufferResult.metalBuffer,
                                                           width: meta.width, height: meta.height,
                                                           maxDisplaySize: maxDisplaySize,
                                                           bayerPattern: meta.bayerPattern)
            let bayerClips: BayerClips?
            if debayerColorImages, let pattern = BayerPattern.parse(from: meta.headers) {
                bayerClips = ImageStretcher.computeBayerClips(bufferResult.metalBuffer,
                                                              width: meta.width, height: meta.height,
                                                              rOffset: pattern.rOffset)
            } else {
                bayerClips = nil
            }

            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            // metalBuffer is retained in FastLoadResult so Phase B can use it.
            return FastLoadResult(
                display: display, thumb: thumb,
                info: "\(meta.width) × \(meta.height)  |  BITPIX: \(meta.bitpix)",
                error: nil, histogram: histogram, headers: meta.headers,
                metalBuffer: bufferResult.metalBuffer, metalDevice: device,
                width: meta.width, height: meta.height, bitpix: meta.bitpix,
                bayerClips: bayerClips)
        }

        do {
            var fits  = try FITSReader.read(from: url)
            let histogram = MetricsCalculator.computeHistogram(pixels: fits.pixelValues,
                                                               minVal: fits.minValue, maxVal: fits.maxValue)
            let display = ImageStretcher.createImage(from: &fits.pixelValues,
                                                     width: fits.width, height: fits.height,
                                                     maxDisplaySize: maxDisplaySize)
            let info    = "\(fits.width) × \(fits.height)  |  BITPIX: \(fits.bitpix)"
            let headers = fits.headers
            let w = fits.width, h = fits.height
            fits.pixelValues = []
            let thumb = display.flatMap { ImageStretcher.createThumbnail(from: $0, maxSize: maxThumbnailSize) }
            return FastLoadResult(display: display, thumb: thumb, info: info, error: nil,
                                  histogram: histogram, headers: headers,
                                  metalBuffer: nil, metalDevice: nil,
                                  width: w, height: h, bitpix: fits.bitpix,
                                  bayerClips: nil)
        } catch {
            return FastLoadResult(display: nil, thumb: nil, info: "", error: error.localizedDescription,
                                  histogram: nil, headers: [:],
                                  metalBuffer: nil, metalDevice: nil,
                                  width: 0, height: 0, bitpix: 0,
                                  bayerClips: nil)
        }
    }
}

// MARK: - Private result types

struct FastLoadResult {
    let display:     NSImage?
    let thumb:       NSImage?
    let info:        String
    let error:       String?
    let histogram:   [Int]?
    let headers:     [String: String]
    /// Raw FITS float pixels in a Metal shared buffer. Passed to Phase B so
    /// GPU detection and Moffat fitting can run without a second file read.
    /// Released when the Phase B task ends. `nil` when the CPU fallback path
    /// was used (Metal unavailable).
    let metalBuffer: MTLBuffer?
    let metalDevice: MTLDevice?
    let width:       Int
    let height:      Int
    /// Original FITS BITPIX value.
    let bitpix:      Int
    /// Per-channel Bayer clip bounds computed during the grey-pass.
    /// `nil` for non-Bayer images or when `debayerColorImages` is false.
    let bayerClips:  BayerClips?
}

// MARK: - FolderTracker

/// Tracks per-folder Phase A completion counts across concurrent tasks.
/// When all entries in a folder have completed Phase A, `complete(path:)` returns
/// `true` exactly once — the signal to fire that folder's colour normalisation task.
private actor FolderTracker {
    private var completions: [String: Int] = [:]
    private let totals: [String: Int]

    @MainActor
    init(grouping entries: [ImageEntry]) {
        totals = Dictionary(grouping: entries, by: { $0.qualifiedFolderPath })
            .mapValues(\.count)
    }

    /// Records one Phase A completion for `path`.
    /// Returns `true` if this call is the last completion for that folder.
    func complete(path: String) -> Bool {
        completions[path, default: 0] += 1
        return completions[path] == totals[path]
    }
}

// MARK: - AsyncSemaphore

/// Async-friendly counting semaphore. Callers that exceed the concurrency cap
/// are suspended and resumed in FIFO order as earlier callers call `signal()`.
actor AsyncSemaphore {
    private var count: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(count: Int) { self.count = count }

    func wait() async {
        if count > 0 {
            count -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
    }

    func signal() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            count += 1
        }
    }
}
