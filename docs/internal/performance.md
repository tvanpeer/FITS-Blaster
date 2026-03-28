# FITS Blaster — Loading Pipeline Performance

## Test environment

- Machine: M1 Air (8 performance cores)
- App restarted before each test

---

## Test set A — 592 colour images (IMX571 OSC), 51.9 MB each, 30.72 GB total

### Results by version

| Mode | v1.12.2 (baseline) | v1.12.3 (GPU downscale) | v1.12.4 (Phase A/B decouple) | v1.12.5 (fix regressions) |
|---|---|---|---|---|
| Grey + Simple | 53 s | **28 s** | **27 s** | **28 s** |
| Grey + Geek | — | **62 s** | 100 s ❌ | **62 s** ✅ |
| Colour + Simple | 168 s | **82 s** | **82 s** | **82 s** |
| Colour + Geek | 184 s | **115 s** | 161 s ❌ | **121 s** ✅ |

---

## Test set B — 290 greyscale images (IMX585 mono), 16.8 MB each, 4.88 GB total

### Results at v1.14

| Mode | Time | Memory | SSD throughput |
|---|---|---|---|
| Grey + Simple | 4.79 s | 318 MB | ~1.0 GB/s |
| Grey + Geek | 15.38 s | 346 MB | ~330 MB/s |

### Observations

- **Grey + Simple** saturates the SSD at ~1 GB/s — consistent with the 592-image colour result and confirming Phase A (I/O + GPU stretch only) is not CPU-bound.
- **Grey + Geek** drops to ~330 MB/s. Phase B (GPU detection + Moffat fitting) is the bottleneck; the pattern matches the 592-image colour observations where Geek mode runs at roughly ¼–½ of Simple throughput on this machine.
- Memory delta between Simple and Geek is small (318 → 346 MB), reflecting the limited number of live MTLBuffers held by the Phase B semaphore at any one time.

---

## SSD throughput observations

### v1.12.4

| Mode | SSD throughput | Interpretation |
|---|---|---|
| Grey + Simple | 1.2 GB/s | SSD fully saturated — Phase A (I/O + GPU stretch only) is not bottlenecked |
| Grey + Geek | 580 MB/s | Phase A runs at ~half throughput — GPU detection adds serialised GPU load |
| Colour + Simple | 580 MB/s → 1.2 GB/s | Two phases visible: greyscale pass (580 MB/s) then Bayer re-render (1.2 GB/s) |
| Colour + Geek | 380 MB/s | Both Phase A GPU overhead and Phase B semaphore bottleneck compound |

### v1.12.5

| Mode | SSD throughput | Interpretation |
|---|---|---|
| Grey + Simple | 1.12 GB/s | SSD fully saturated — Phase A is I/O + stretch only |
| Grey + Geek | 500 MB/s | Phase B is the bottleneck (~630 ms/image); at steady state only ~2 Phase A tasks run concurrently (8 − 6 semaphore slots), giving ~2 × 250 MB/s |
| Colour + Simple | 580 MB/s → 1.2 GB/s | Two phases: greyscale + bayerClips pass (580 MB/s) then colour re-render (1.2 GB/s) |
| Colour + Geek | 350 MB/s → 1.2 GB/s | BayerClips adds Phase A work, further reducing concurrent I/O; colour re-render at 1.2 GB/s once metrics finish |

---

## Root-cause analysis

### Problem 1 — Phase B semaphore too restrictive

`phaseBSemaphore = max(2, cpuCount/4)` = **2** on M1 Air.

Each Phase B task runs `measureFromCrops` with an inner 4-wide `withTaskGroup`, so
2 outer × 4 inner = **8 CPU threads** — exactly filling 8 cores. Individually efficient,
but the throughput is only 2 images / 345 ms ≈ **5.8 img/s**.

In v1.12.3, 6 coupled slots each ran Phase B concurrently (6 × 4 = 24 threads, 3× over-subscribed),
giving an effective throughput of 592 / 62 s ≈ **9.5 img/s**.

Result: Phase B in v1.12.4 is ~40% slower than v1.12.3, turning a 62 s batch into ~100 s.

### Problem 2 — GPU detection now in Phase A, serialising on the GPU

In v1.12.3, GPU detection ran in Phase B (inside the coupled slot). In v1.12.4 it moved
to Phase A (`extractStarData` called from `loadFast`). With 8 concurrent Phase A tasks
each submitting detection command buffers to the same command queue, the GPU must
process them serially.

Derived from measurements:
- Simple Phase A (no detection): 27 s × 8 / 592 = **365 ms/image**
- Geek Phase A (with detection): 580 MB/s implies ~**762 ms/image** per slot
- GPU detection overhead per slot: 762 − 365 = **~400 ms** (8 detections queued serially)
- Per-image detection time: ~50 ms (reasonable), but × 8 queued = 400 ms wall time

This halves Phase A SSD throughput in Geek mode (1.2 GB/s → 580 MB/s).

---

## What v1.12.4 did correctly

- **Grey + Simple**: 28 s → 27 s. ioConcurrency 6→8 gave a modest gain; SSD is now
  fully saturated at 1.2 GB/s — the theoretical ceiling for pure I/O work.
- **Colour + Simple**: unchanged at 82 s (Bayer re-render pass dominates; unchanged).
- **Progressive display**: images appear faster in Geek mode. Each image is shown as
  soon as Phase A finishes (~365–760 ms), without waiting for the 629 ms coupled slot
  of v1.12.3 to drain.
- **Memory**: MTLBuffers released after crop extraction — sustained memory during
  the Phase B drain is ~10–120 MB vs the previous ~600 MB.

---

## v1.12.5 fixes applied

### Fix 1 — `phaseBSemaphore` raised

Changed `max(2, cpuCount/4)` → `max(4, cpuCount-2)`.
On M1 Air: 2 → **6**. Six concurrent Phase B tasks (each using `compute(metalBuffer:)` which runs
GPU detection + Moffat fits internally) restore Phase B throughput to ~15 img/s.

### Fix 2 — GPU detection moved back to Phase B

Phase A now does I/O + GPU stretch only (no `extractStarData` call).
The `MTLBuffer` is retained in `FastLoadResult` and passed to the detached Phase B task,
which calls `MetricsCalculator.compute(metalBuffer:device:width:height:config:)` directly.

Memory bound: phaseBSemaphore is acquired in the group task (after image shown, before
group slot freed), so at most 6 MTLBuffers are live simultaneously = ~600 MB peak.

### Expected results

| Mode | v1.12.3 | v1.12.4 (regression) | v1.12.5 (expected) |
|---|---|---|---|
| Grey + Simple | 28 s | 27 s | ~27 s |
| Grey + Geek | 62 s | 100 s ❌ | ~55–65 s |
| Colour + Simple | 82 s | 82 s | ~82 s |
| Colour + Geek | 115 s | 161 s ❌ | ~100–115 s |

SSD throughput in Geek mode should return to ~1.2 GB/s (Phase A no longer runs GPU detection).
