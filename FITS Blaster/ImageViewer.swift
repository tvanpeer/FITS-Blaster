//
//  ImageViewer.swift
//  FITS Blaster
//

import SwiftUI

/// Displays a stretched FITS image inside a scroll view with pinch-to-zoom support.
///
/// Scroll position is preserved across image navigation: `entryID` changes trigger
/// a programmatic scroll to the stored center fraction in `ViewerState`.
/// Zoom from the slider keeps the viewport center fixed by adjusting the scroll offset
/// proportionally before the next layout pass.
struct ImageViewer: View {
    let entryID: UUID
    let displayImage: NSImage
    let isFlipped: Bool
    /// VoiceOver's label for the image: "Frame, <file name>" plus flagged / rejected (step 10d).
    let accessibilityLabel: String

    @Environment(ViewerState.self) private var viewer
    @Environment(AppSettings.self) private var settings

    @GestureState private var gestureScale: Double = 1.0
    @State private var scrollPos = ScrollPosition(x: 0, y: 0)
    @State private var lastGeo: ViewportGeometry? = nil
    @State private var pendingFitToContainer = false

    private var effectiveZoom: Double { settings.zoomScale * gestureScale }

    /// Scrolls so the zoom anchor, or else the point in the middle of the view, stays where
    /// it is when the shown zoom goes from `oldZoom` to `newZoom`.
    private func adjustScroll(to newZoom: Double, from oldZoom: Double, geo: ViewportGeometry) {
        let fx: Double
        let fy: Double
        if let anchor = viewer.zoomAnchor {
            fx = anchor.x
            fy = anchor.y
        } else {
            // The image's size at the old zoom, not the geometry's content size: the geometry
            // can already have the new size while the scroll offset is still the old one, and
            // then the middle of the view moved on every zoom step (Tom, 2026-10-31).
            let oldW = displayImage.size.width  * oldZoom
            let oldH = displayImage.size.height * oldZoom
            guard oldW > 0, oldH > 0 else { return }
            fx = (geo.contentOffset.x + geo.containerSize.width  / 2) / oldW
            fy = (geo.contentOffset.y + geo.containerSize.height / 2) / oldH
        }
        let newCW = displayImage.size.width  * newZoom
        let newCH = displayImage.size.height * newZoom
        let x = fx * newCW - geo.containerSize.width  / 2
        let y = fy * newCH - geo.containerSize.height / 2
        scrollPos.scrollTo(x: max(0, x), y: max(0, y))
    }

    var body: some View {
        @Bindable var settings = settings

        ScrollView([.horizontal, .vertical]) {
            Image(nsImage: displayImage)
                .resizable()
                .frame(
                    width:  displayImage.size.width  * effectiveZoom,
                    height: displayImage.size.height * effectiveZoom
                )
                .rotationEffect(isFlipped ? .degrees(180) : .zero)
                .brightness(settings.targetBackground - 0.25)
                .contrast(viewer.displayStretch)
                .overlay {
                    // The overlay has the image's frame, so the anchor is placed from the
                    // known size × zoom (CODE_AUDIT §8.6).
                    if let anchor = viewer.zoomAnchor {
                        ZoomAnchorIndicator()
                            .position(
                                x: anchor.x * displayImage.size.width  * effectiveZoom,
                                y: anchor.y * displayImage.size.height * effectiveZoom
                            )
                    }
                }
                .onTapGesture { location in
                    let w = displayImage.size.width  * effectiveZoom
                    let h = displayImage.size.height * effectiveZoom
                    guard w > 0, h > 0 else { return }
                    let norm = CGPoint(x: location.x / w, y: location.y / h)
                    if let existing = viewer.zoomAnchor {
                        let dx = (norm.x - existing.x) * w
                        let dy = (norm.y - existing.y) * h
                        if dx * dx + dy * dy < 400 {
                            viewer.zoomAnchor = nil
                            return
                        }
                    }
                    viewer.zoomAnchor = norm
                }
                // The tap needs its location, so it can't be a Button; tell VoiceOver instead.
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel(accessibilityLabel)
                .accessibilityHint("Sets the zoom anchor at the clicked point, or clears it when clicked again")
        }
        .scrollPosition($scrollPos)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: ViewportGeometry.self, of: ViewportGeometry.init) { _, geo in
            lastGeo = geo
            let cw = geo.contentSize.width, ch = geo.contentSize.height
            guard cw > 0, ch > 0 else { return }
            viewer.updateViewport(geo)
            if pendingFitToContainer {
                pendingFitToContainer = false
                if let fit = ViewerZoom.fitScale(image: displayImage.size, container: geo.containerSize) {
                    settings.zoomScale = fit
                }
            }
        }
        .onChange(of: entryID) { _, _ in
            guard let geo = lastGeo else { return }
            let cw = displayImage.size.width  * settings.zoomScale
            let ch = displayImage.size.height * settings.zoomScale
            let x = viewer.viewportCenter.x * cw - geo.containerSize.width  / 2
            let y = viewer.viewportCenter.y * ch - geo.containerSize.height / 2
            scrollPos.scrollTo(x: max(0, x), y: max(0, y))
        }
        // The shown zoom (slider, keys and pinch): at the end of a pinch the slider takes
        // over the gesture's zoom in the same update, so nothing moves then.
        .onChange(of: effectiveZoom) { oldZoom, newZoom in
            guard let geo = lastGeo, geo.containerSize.width > 0 else { return }
            adjustScroll(to: newZoom, from: oldZoom, geo: geo)
        }
        .onChange(of: viewer.centerOnAnchorTrigger) { _, _ in
            guard let geo = lastGeo, geo.containerSize.width > 0 else { return }
            adjustScroll(to: settings.zoomScale, from: settings.zoomScale, geo: geo)
        }
        .onChange(of: viewer.fitToContainerTrigger) { _, _ in
            guard let geo = lastGeo,
                  let fit = ViewerZoom.fitScale(image: displayImage.size, container: geo.containerSize) else { return }
            settings.zoomScale = fit
        }
        .onChange(of: viewer.panRequest) { _, request in
            guard let request, let geo = lastGeo else { return }
            let offset = ViewerZoom.pannedOffset(geo.contentOffset, contentSize: geo.contentSize,
                                                 containerSize: geo.containerSize,
                                                 direction: request.direction, share: request.share)
            scrollPos.scrollTo(x: offset.x, y: offset.y)
        }
        .onChange(of: settings.isSimpleMode) { _, _ in pendingFitToContainer = true }
        .onChange(of: settings.showInspector) { _, _ in pendingFitToContainer = true }
        .gesture(
            MagnificationGesture()
                .updating($gestureScale) { value, state, _ in state = value }
                .onEnded { value in
                    settings.zoomScale = ViewerZoom.clamped(settings.zoomScale * value)
                }
        )
    }
}

/// Equatable snapshot of `ScrollGeometry` for use with `onScrollGeometryChange`.
struct ViewportGeometry: Equatable {
    let contentOffset: CGPoint
    let contentSize: CGSize
    let containerSize: CGSize

    init(_ geometry: ScrollGeometry) {
        contentOffset  = geometry.contentOffset
        contentSize    = geometry.contentSize
        containerSize  = geometry.containerSize
    }

    init(contentOffset: CGPoint, contentSize: CGSize, containerSize: CGSize) {
        self.contentOffset = contentOffset
        self.contentSize   = contentSize
        self.containerSize = containerSize
    }
}
