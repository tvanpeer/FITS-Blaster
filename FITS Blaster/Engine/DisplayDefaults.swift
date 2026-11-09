//
//  DisplayDefaults.swift
//  FITS Blaster
//
//  The default image sizes (step 15c, CODE_AUDIT §9.14). Shared with the Quick Look
//  extensions, which compile ImageStretcher+CPU.
//

enum DisplayDefaults {
    /// The longest side of a display image, in pixels: the "Max display size" setting's
    /// default, and the size the Quick Look preview renders.
    static let displaySize = 1024

    /// The longest side of a thumbnail, in pixels, for loads that don't pass the setting
    /// (the command line and tests). The app renders thumbnails at the "Thumbnail size"
    /// setting × the screen scale (`AppSettings.thumbnailRenderSize`).
    static let thumbnailPixelSize = 120
}
