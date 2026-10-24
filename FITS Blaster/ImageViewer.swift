//
//  ImageViewer.swift
//  FITS Blaster
//

import SwiftUI

/// Displays a stretched FITS image inside a scroll view with pinch-to-zoom support.
///
/// Scroll position is preserved across image navigation: `entryID` changes trigger
/// a programmatic scroll to the stored center fraction in `ImageStore`.
/// Zoom from the slider keeps the viewport center fixed by adjusting the scroll offset
/// proportionally before the next layout pass.
struct ImageViewer: View {
    let entryID: UUID
    let displayImage: NSImage
    let isFlipped: Bool

    @Environment(ImageStore.self) private var store
    @Environment(AppSettings.self) private var settings

    @GestureState private var gestureScale: Double = 1.0
    @State private var scrollPos = ScrollPosition(x: 0, y: 0)
    @State private var lastGeo: ViewportGeometry? = nil
    @State private var pendingFitToContainer = false

    private var effectiveZoom: Double { settings.zoomScale * gestureScale }

    private func adjustScroll(to newZoom: Double, geo: ViewportGeometry) {
        let fx: Double
        let fy: Double
        if let anchor = store.zoomAnchor {
            fx = anchor.x
            fy = anchor.y
        } else {
            guard geo.contentSize.width > 0 else { return }
            fx = (geo.contentOffset.x + geo.containerSize.width  / 2) / geo.contentSize.width
            fy = (geo.contentOffset.y + geo.containerSize.height / 2) / geo.contentSize.height
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
                .contrast(store.displayStretch)
                .overlay {
                    if let anchor = store.zoomAnchor {
                        GeometryReader { geo in
                            ZoomAnchorIndicator()
                                .position(
                                    x: anchor.x * geo.size.width,
                                    y: anchor.y * geo.size.height
                                )
                        }
                    }
                }
                .onTapGesture { location in
                    let w = displayImage.size.width  * effectiveZoom
                    let h = displayImage.size.height * effectiveZoom
                    guard w > 0, h > 0 else { return }
                    let norm = CGPoint(x: location.x / w, y: location.y / h)
                    if let existing = store.zoomAnchor {
                        let dx = (norm.x - existing.x) * w
                        let dy = (norm.y - existing.y) * h
                        if dx * dx + dy * dy < 400 {
                            store.zoomAnchor = nil
                            return
                        }
                    }
                    store.zoomAnchor = norm
                }
                // The tap needs its location, so it can't be a Button; tell VoiceOver instead.
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Frame")
                .accessibilityHint("Sets the zoom anchor at the clicked point, or clears it when clicked again")
        }
        .scrollPosition($scrollPos)
        .scrollIndicators(.automatic)
        .onScrollGeometryChange(for: ViewportGeometry.self, of: ViewportGeometry.init) { _, geo in
            lastGeo = geo
            let cw = geo.contentSize.width, ch = geo.contentSize.height
            guard cw > 0, ch > 0 else { return }
            store.viewportFraction = CGRect(
                x: max(0, geo.contentOffset.x / cw),
                y: max(0, geo.contentOffset.y / ch),
                width:  min(1, geo.containerSize.width  / cw),
                height: min(1, geo.containerSize.height / ch)
            )
            store.viewportCenter = CGPoint(
                x: (geo.contentOffset.x + geo.containerSize.width  / 2) / cw,
                y: (geo.contentOffset.y + geo.containerSize.height / 2) / ch
            )
            if pendingFitToContainer {
                pendingFitToContainer = false
                let imgW = displayImage.size.width
                let imgH = displayImage.size.height
                guard imgW > 0, imgH > 0,
                      geo.containerSize.width > 0, geo.containerSize.height > 0 else { return }
                let fitScale = min(geo.containerSize.width / imgW, geo.containerSize.height / imgH)
                settings.zoomScale = max(0.25, min(4.0, fitScale))
            }
        }
        .onChange(of: entryID) { _, _ in
            guard let geo = lastGeo else { return }
            let cw = displayImage.size.width  * settings.zoomScale
            let ch = displayImage.size.height * settings.zoomScale
            let x = store.viewportCenter.x * cw - geo.containerSize.width  / 2
            let y = store.viewportCenter.y * ch - geo.containerSize.height / 2
            scrollPos.scrollTo(x: max(0, x), y: max(0, y))
        }
        .onChange(of: gestureScale) { _, newGestureScale in
            guard let geo = lastGeo, geo.containerSize.width > 0 else { return }
            let zoom = newGestureScale != 1.0 ? settings.zoomScale * newGestureScale : settings.zoomScale
            adjustScroll(to: zoom, geo: geo)
        }
        .onChange(of: settings.zoomScale) { _, newZoom in
            guard let geo = lastGeo, geo.containerSize.width > 0 else { return }
            adjustScroll(to: newZoom, geo: geo)
        }
        .onChange(of: store.centerOnAnchorTrigger) { _, _ in
            guard let geo = lastGeo, geo.containerSize.width > 0 else { return }
            adjustScroll(to: settings.zoomScale, geo: geo)
        }
        .onChange(of: store.fitToContainerTrigger) { _, _ in
            guard let geo = lastGeo,
                  geo.containerSize.width > 0, geo.containerSize.height > 0,
                  displayImage.size.width > 0, displayImage.size.height > 0 else { return }
            let fitScale = min(geo.containerSize.width  / displayImage.size.width,
                               geo.containerSize.height / displayImage.size.height)
            settings.zoomScale = max(0.25, min(4.0, fitScale))
        }
        .onChange(of: settings.isSimpleMode) { _, _ in pendingFitToContainer = true }
        .onChange(of: settings.showInspector) { _, _ in pendingFitToContainer = true }
        .gesture(
            MagnificationGesture()
                .updating($gestureScale) { value, state, _ in state = value }
                .onEnded { value in
                    settings.zoomScale = max(0.25, min(4.0, settings.zoomScale * value))
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
}
