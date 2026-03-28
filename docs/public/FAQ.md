# FITS Blaster — Frequently Asked Questions

---

## Getting Started

### What macOS version is required?
macOS 15.0 (Sequoia) or later.

### Does FITS Blaster run on Intel Macs?
It will run, but performance will be significantly lower. FITS Blaster uses Apple's Metal GPU framework for stretching, star detection, and metrics computation. Metal works best on Apple silicon (M1 and later). Intel Macs with integrated graphics lack the GPU memory bandwidth to keep up with large image sets; loading times will be several times slower.

### Is there a Windows or Linux version?
No. FITS Blaster is a native macOS application and uses macOS-specific frameworks (Metal, Accelerate, AppKit). There are no plans for a Windows or Linux port.

### Does FITS Blaster require an internet connection?
Only to validate your subscription (handled automatically by the App Store). Image loading, stretching, and all quality measurements work entirely offline.

---

## Loading Images

### How do I open images?
There are four ways to load images into FITS Blaster:

1. **Menu / keyboard shortcut** — use **File → Open Folder… (⌘O)** to open an entire folder, or **File → Open File(s)… (⌘⇧O)** to pick individual files.
2. **Open buttons** — when no images are loaded, the main screen shows Open Folder and Open File(s) buttons you can click directly.
3. **Drag & drop onto the window** — drag a folder or any number of FITS files from Finder and drop them onto the FITS Blaster window.
4. **Drag & drop onto the app icon** — drag files or a folder onto the FITS Blaster icon in the Dock or in Finder to open them directly, even if the app is not running yet.

### What FITS formats are supported?
FITS files with integer pixel data: BITPIX 8 (8-bit), BITPIX 16 (16-bit), and BITPIX 32 (32-bit). Floating-point FITS (BITPIX −32 or −64) are not supported and will be skipped with an error message. The supported extensions are `.fits`, `.fit`, and `.fts`.

### Will you support other image formats, like Canon RAW?
Not at this time. FITS Blaster is purpose-built for FITS files as used in astrophotography. RAW camera formats (CR3, NEF, ARW, etc.) are not on the roadmap.

### How many images can FITS Blaster load?
In practice, as many as your RAM allows. It has been tested with up to 592 images without issues on a MacBook Air M1 with 16 GB — see the Speed section below for details.

### Can I open images from subfolders?
Yes. When opening a folder, check "Include files from subfolders" in the open panel. FITS Blaster will scan recursively and display each subfolder as a separate section in the sidebar. By default, calibration folders (FLAT, DARK, BIAS, CALIB) are skipped automatically; you can customise the exclusion list in Settings → Files & Folders.

### What are filter groups?
When FITS Blaster loads images from a session with multiple filters (for example Ha, OIII, and broadband frames in the same folder), it reads the filter name from the FITS header and automatically groups frames by filter in the sidebar. Each group gets its own colour-coded section. This makes it easy to assess quality separately per filter — a frame that is fine for Ha may still be worth rejecting for OIII.

If no filter information is present in the headers, all frames appear in a single group.

### Should I use colour or greyscale display?
**Greyscale** loads and renders much faster and is usually all you need for judging star shape, focus, and trailing. FITS Blaster always loads greyscale first, so you can start culling immediately regardless of display mode.

**Colour** mode debayers OSC (one-shot colour) images and shows them in full colour, which can be useful for checking gradients, satellite trails, or colour artefacts. Colour rendering takes roughly 2–3× longer per image. Both the colour and greyscale versions are kept in memory once loaded, so switching between them is instant.

Mono (greyscale) cameras are always displayed in greyscale regardless of the display setting.

### Does FITS Blaster modify my images?
Never. FITS Blaster is strictly read-only. Pixel data is loaded into a separate display buffer; the original files are never written to. The only file operation FITS Blaster performs is moving rejected frames into a `REJECTED/` subfolder — and that move is fully undoable.

### What happens when I press Reset?
Reset clears the current session and restores the full free-tier frame allowance, so you can immediately open a new folder. It does not delete or move any files.

---

## Image Quality Metrics

### What does the Score badge mean?
Each frame receives a coloured badge based on how its metrics compare to the rest of the session:

- **Green** — the frame is within normal range for this session
- **Amber** — one metric is noticeably worse than average (trailing, focus drift, low star count)
- **Red** — the frame is significantly below average and is a candidate for rejection
- **Grey** — metrics could not be computed (no stars detected, or saturated field)

The badge priority is: trailing stars → focus failure → low star count.

### What is FWHM?
Full Width at Half Maximum — a measure of how sharp (tightly focused) the stars are. It is the diameter of a star profile at half its peak brightness, in sensor pixels. Lower is better: a well-focused session might have FWHM 3–5 px, while a poorly-focused or turbulent frame might be 8–10 px or more.

FITS Blaster fits a Moffat β=4 profile (the same default as PixInsight's SubframeSelector) independently along the X and Y axes, then reports the geometric mean. Results agree with PixInsight Moffat4 within ±10% under typical conditions.

### What is Eccentricity?
Eccentricity measures how elongated the stars are (0 = perfectly round, 1 = infinitely elongated). A value above ~0.5 usually indicates trailing from poor polar alignment, wind shake, or a mechanical issue. FITS Blaster reports the eccentricity of the median star candidate.

### What is SNR?
Signal-to-Noise Ratio — the peak star signal divided by the background noise level. Higher is better. SNR depends heavily on exposure length, sky background, and seeing conditions. It is most useful for comparing frames within the same session rather than between different nights or setups.

### Why are FITS Blaster's FWHM values different from my other tools?
FWHM is not a standardised measurement — every tool makes different choices about the PSF model, fitting method, and unit convention. Agreement within ~10% is normal. The most common causes of larger differences are:

- **Different PSF models:** FITS Blaster and PixInsight use Moffat β=4; Siril fits β as a free parameter (typically 3–4). When β < 4, Siril's free-β fit finds a tighter core and reports a lower FWHM.
- **Gaussian vs Moffat:** A Gaussian PSF has lighter wings than a Moffat profile, so Gaussian FWHM estimates are often slightly larger.
- **Units:** Siril reports FWHM in arcseconds by default. To convert: `FWHM (px) = FWHM (") / plate_scale`, where `plate_scale = 206.265 × pixel_size_µm / focal_length_mm`.
- **1D vs 2D fitting:** FITS Blaster fits two independent 1D profiles and takes their geometric mean. PixInsight and Siril fit a full 2D PSF simultaneously.

For frame *ranking* (the primary use case), absolute accuracy matters less than consistency. FITS Blaster is self-consistent within a session and correlates reliably with actual image quality.

See `FWHM-comparison.md` for a detailed comparison with measured data from PixInsight, Siril, and AstroPixelProcessor.

### Does FITS Blaster correct FWHM for Bayer (OSC) cameras?
No correction is applied, and none is needed. Empirical tests with both narrowband and broadband OSC images show agreement with PixInsight Moffat4 within ±10% without any Bayer scaling factor. An earlier version applied a ÷√2 correction; this was reverted after testing showed it made results worse.

---

## Culling Frames

### What does a typical culling session look like?
1. **Open your folder** — use ⌘O or drag it onto the window. FITS Blaster starts loading and measuring quality metrics immediately; you can begin reviewing before the full set has loaded.
2. **Scan the session chart** — the horizontal strip across the bottom of the window plots all frames in time order, coloured by quality. A cluster of red or amber dots usually points to a specific problem period (clouds rolling in, a focus drift, a gust of wind).
3. **Review suspect frames** — click a dot in the chart to jump to that frame, or step through the sidebar with the arrow keys. The main view shows the stretched image; the inspector on the right shows the exact metric values.
4. **Reject bad frames** — press your reject key (default: X, or spacebar if you use toggle mode) to move a frame to the `REJECTED/` subfolder. Use drag-selection in the chart to reject a whole run of bad frames at once.
5. **Use Auto-Reject for bulk cleanup** — set a threshold (e.g. FWHM > 7 px) and preview the result before committing.
6. **Hand off to your stacking tool** — point PixInsight, Siril, or AstroPixelProcessor at the same folder. The rejected frames are now in `REJECTED/` and will not be picked up by a folder scan.

### What is the session chart?
The session chart is a horizontal strip showing one dot per frame, in the order they were captured. The dot colour matches the quality badge (green / amber / red / grey). You can:

- **Click** a dot to select and display that frame
- **Drag** across a range of dots to select multiple frames, then reject them all with one keypress
- **Filter by folder or filter group** using the pill buttons above the chart, to focus on one subset at a time

The chart makes it easy to spot patterns — a run of red dots typically means a passing cloud, a focus shift, or a tracking problem at a specific point in the session.

### How do I reject a frame?
Select a frame in the sidebar or session chart and press the reject key (default: **X**). You can customise this and all other key bindings in Settings → Keyboard.

### Can I reject multiple frames at once?
Yes. Hold **⌘** or **⇧** to build a multi-selection in the sidebar, then press the reject key. You can also drag across the session chart to select and reject a range of frames in one gesture.

### What happens to rejected frames?
They are moved into a `REJECTED/` subfolder inside the folder they came from. No files are deleted. You can undo a rejection at any time.

### How do I undo a rejection?
It depends on the **Single key reject/undo (toggle)** setting in Settings → Keyboard:

- **Toggle on (recommended):** The same key both rejects and un-rejects. Press it once to reject a frame, press it again to undo. This is the simplest workflow — many users assign the spacebar.
- **Toggle off:** Reject and undo are separate key bindings, each configurable independently.

In either case, if the `REJECTED/` folder becomes empty after an undo, it is removed automatically.

### How do I sort the sidebar?
Use the sort dropdown in the sidebar toolbar to choose between **filename** (the default, reflecting capture order) or any quality metric: **FWHM**, **eccentricity**, **SNR**, **star count**, or **quality score**. The up/down arrow button next to it reverses the sort direction. Sorting by quality score with the worst frames at the bottom makes it quick to select and reject the tail of the list as a group.

### What is Simple mode vs Geek mode?
**Simple mode** hides all numeric metrics and shows only the visual quality badge. It is useful for a quick pass or for users who prefer not to interpret numbers. **Geek mode** shows FWHM, eccentricity, SNR, and star count alongside each frame. Toggle between modes with **⌘⇧M** or the toolbar button.

### What is Auto-Reject?
Auto-reject lets you set thresholds (e.g. "reject all frames with FWHM > 7 px") and preview how many frames would be affected before committing. Access it from the toolbar.

### What do I do after culling?
Point your stacking tool (PixInsight, Siril, AstroPixelProcessor, etc.) at the same folder you opened in FITS Blaster. Rejected frames have been moved to a `REJECTED/` subfolder and will not appear in a normal folder scan. No additional steps are needed — your stacking tool will see only the frames you kept.

If you change your mind, reopen the folder in FITS Blaster, select the rejected frames, and undo the rejection before you start stacking.

---

## Speed & Performance

Tests run on a MacBook Air M1, 16 GB, images on internal SSD. FITS Blaster was restarted before each test.

**Test set 1 — 592 colour images (IMX571 OSC), 51.9 MB each, 30.72 GB total:**

| Mode | Time | Memory |
|---|---|---|
| Greyscale + Geek mode | 71.6 s | 668 MB |
| Greyscale + Simple mode | 53.1 s | 583 MB |
| Colour + Geek mode | 184.6 s | 2.28 GB |
| Colour + Simple mode | 168.7 s | 2.17 GB |

**Test set 2 — 55 greyscale images (IMX585 mono), 16.8 MB each, 975 MB total:**

| Mode | Time | Memory |
|---|---|---|
| Greyscale + Geek mode | 1.9 s | 151 MB |
| Greyscale + Simple mode | 1.2 s | 130 MB |

You can start working immediately once loading begins — you do not need to wait for the entire set. In colour mode, FITS Blaster renders the full set in greyscale first so you can start culling straight away; both the colour and greyscale versions are kept in memory so switching between them is instant.

---

## Tips for Power Users

### What is the fastest way to cull a large set?
1. Load the folder in **greyscale + geek mode**. Greyscale loads faster than colour; geek mode computes quality metrics and populates the session chart.
2. Glance at the session chart — drag-select any obvious bad runs and reject them in one go.
3. Switch the sidebar sort to **quality score**. Your worst frames are now grouped at one end; select them as a block and reject.
4. Step through remaining amber frames with the **arrow keys**, rejecting with a single keypress. You rarely need to look at every frame individually.

If you only want a quick visual pass without metrics, **simple mode** loads faster but the session chart is not available.

### Can I use the keyboard for everything?
Almost. Arrow keys navigate the sidebar; your configured reject key rejects or toggles; the chart is keyboard-accessible for navigation. The only things that require the mouse are drag-selecting a range in the chart and clicking filter pills.

### Can I have FITS Blaster open while my stacking tool is running?
Yes — FITS Blaster holds no locks on your files. However, avoid undoing rejections while a stacking tool is actively reading the same folder, as moving files mid-stack may confuse the stacking tool.

---

## Subscription

### Is FITS Blaster free?
FITS Blaster is free to use with up to 50 frames per session. An annual subscription unlocks unlimited frames. All features — metrics, auto-reject, session chart, subfolders — are available in the free tier.

### What does a subscription cost?
See the App Store listing for current pricing. The subscription is annual and auto-renews.

### How do I subscribe?
When you load more than 50 frames, the subscription sheet appears automatically. You can also subscribe at any time via Settings → Subscription.

### I already subscribed — how do I restore on a new Mac?
Go to Settings → Subscription and tap "Restore Purchases". Your App Store account is used to verify the subscription; no account registration with us is required.

### How do I manage or cancel my subscription?
Open Settings → Subscription and tap "Manage Subscription". This opens the App Store subscription management page where you can cancel or change your plan at any time.

---

## Privacy & Data

### Does FITS Blaster send my images anywhere?
No. All processing happens on your Mac. Your image files never leave your device.

### What data does FITS Blaster collect?
None. FITS Blaster does not collect analytics, telemetry, or usage data. The only network requests are to the App Store for subscription validation, handled entirely by Apple.

### Does FITS Blaster require access to my entire disk?
No. FITS Blaster is sandboxed and can only access folders you explicitly open via the open panel or drag & drop. It stores a security-scoped bookmark so it can reopen the same folder without asking again in future sessions.
