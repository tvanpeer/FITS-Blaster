//
//  AppSettings.swift
//  FITS Blaster
//
//  Created by Tom van Peer on 01/03/2026.
//

import SwiftUI

/// User-configurable settings for key bindings, image sizes, and quality metrics.
/// All properties auto-save to UserDefaults on every change.
@Observable
@MainActor
final class AppSettings {

    // MARK: - Navigation & Action Key Bindings

    var prevImageKey: String = "↑" {
        didSet { UserDefaults.standard.set(prevImageKey, forKey: "prevImageKey") }
    }
    var nextImageKey: String = "↓" {
        didSet { UserDefaults.standard.set(nextImageKey, forKey: "nextImageKey") }
    }
    var rejectKey: String = "x" {
        didSet { UserDefaults.standard.set(rejectKey, forKey: "rejectKey") }
    }
    var undoKey: String = "u" {
        didSet { UserDefaults.standard.set(undoKey, forKey: "undoKey") }
    }
    /// When true, the reject key acts as a toggle: rejects non-rejected frames and
    /// undoes rejection for already-rejected frames. The separate undo key is then unused.
    var useToggleReject: Bool = false {
        didSet { UserDefaults.standard.set(useToggleReject, forKey: "useToggleReject") }
    }
    var firstImageKey: String = "⇱" {
        didSet { UserDefaults.standard.set(firstImageKey, forKey: "firstImageKey") }
    }
    var lastImageKey: String = "⇲" {
        didSet { UserDefaults.standard.set(lastImageKey, forKey: "lastImageKey") }
    }
    var toggleModeKey: String = "g" {
        didSet { UserDefaults.standard.set(toggleModeKey, forKey: "toggleModeKey") }
    }
    var removeKey: String = "r" {
        didSet { UserDefaults.standard.set(removeKey, forKey: "removeKey") }
    }
    var debayerKey: String = "c" {
        didSet { UserDefaults.standard.set(debayerKey, forKey: "debayerKey") }
    }
    var flagKey: String = "f" {
        didSet { UserDefaults.standard.set(flagKey, forKey: "flagKey") }
    }
    var deflagAllKey: String = "d" {
        didSet { UserDefaults.standard.set(deflagAllKey, forKey: "deflagAllKey") }
    }
    var playPauseKey: String = "p" {
        didSet { UserDefaults.standard.set(playPauseKey, forKey: "playPauseKey") }
    }
    var flipKey: String = "v" {
        didSet { UserDefaults.standard.set(flipKey, forKey: "flipKey") }
    }

    // MARK: - Selection Key Bindings (combined with ⌘ ± ⇧)

    var selectAllKey: String = "a" {
        didSet { UserDefaults.standard.set(selectAllKey, forKey: "selectAllKey") }
    }
    var selectAllShift: Bool = false {
        didSet { UserDefaults.standard.set(selectAllShift, forKey: "selectAllShift") }
    }

    var deselectAllKey: String = "d" {
        didSet { UserDefaults.standard.set(deselectAllKey, forKey: "deselectAllKey") }
    }
    var deselectAllShift: Bool = false {
        didSet { UserDefaults.standard.set(deselectAllShift, forKey: "deselectAllShift") }
    }

    var invertSelectionKey: String = "i" {
        didSet { UserDefaults.standard.set(invertSelectionKey, forKey: "invertSelectionKey") }
    }
    var invertSelectionShift: Bool = false {
        didSet { UserDefaults.standard.set(invertSelectionShift, forKey: "invertSelectionShift") }
    }

    var selectAllRejectedKey: String = "r" {
        didSet { UserDefaults.standard.set(selectAllRejectedKey, forKey: "selectAllRejectedKey") }
    }
    var selectAllRejectedShift: Bool = false {
        didSet { UserDefaults.standard.set(selectAllRejectedShift, forKey: "selectAllRejectedShift") }
    }

    // MARK: - Chart Dot Brightness

    /// Whether to use bars instead of dots in the session chart.
    var chartUseBars: Bool = false {
        didSet { UserDefaults.standard.set(chartUseBars, forKey: "chartUseBars") }
    }

    /// Opacity of rejected-frame dots in the session chart (0–1).
    var rejectedDotOpacity: Double = 0.15 {
        didSet { UserDefaults.standard.set(rejectedDotOpacity, forKey: "rejectedDotOpacity") }
    }
    /// Opacity of non-flagged dots when a flagged set is active (0–1).
    var dimmedDotOpacity: Double = 0.50 {
        didSet { UserDefaults.standard.set(dimmedDotOpacity, forKey: "dimmedDotOpacity") }
    }

    // MARK: - Image Sizes

    var maxDisplaySize: Int = 1024 {
        didSet { UserDefaults.standard.set(maxDisplaySize, forKey: "maxDisplaySize") }
    }
    var maxThumbnailSize: Int = 120 {
        didSet { UserDefaults.standard.set(maxThumbnailSize, forKey: "maxThumbnailSize") }
    }

    // MARK: - Quality Metric Toggles

    var computeFWHM: Bool = true {
        didSet { UserDefaults.standard.set(computeFWHM, forKey: "computeFWHM") }
    }
    var computeEccentricity: Bool = true {
        didSet { UserDefaults.standard.set(computeEccentricity, forKey: "computeEccentricity") }
    }
    var computeSNR: Bool = true {
        didSet { UserDefaults.standard.set(computeSNR, forKey: "computeSNR") }
    }
    var computeStarCount: Bool = true {
        didSet { UserDefaults.standard.set(computeStarCount, forKey: "computeStarCount") }
    }

    // MARK: - UI State

    var showInspector: Bool = true {
        didSet { UserDefaults.standard.set(showInspector, forKey: "showInspector") }
    }

    /// When true the app shows a stripped-down UI and skips all metrics computation.
    var isSimpleMode: Bool = false {
        didSet { UserDefaults.standard.set(isSimpleMode, forKey: "isSimpleMode") }
    }

    var appearanceMode: AppearanceMode = .dark {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }

    // MARK: - Text Size

    /// The subset of DynamicTypeSize values exposed in Settings, from smallest to largest.
    static let availableTypeSizes: [DynamicTypeSize] = [
        .xSmall, .small, .medium, .large, .xLarge, .xxLarge, .xxxLarge
    ]

    var dynamicTypeSize: DynamicTypeSize = .medium {
        didSet {
            let idx = Self.availableTypeSizes.firstIndex(of: dynamicTypeSize) ?? 2
            UserDefaults.standard.set(idx, forKey: "dynamicTypeSize")
        }
    }

    /// Scale multiplier derived from the current step. Used by `scaledFont(size:)` throughout the UI
    /// because macOS does not scale semantic SwiftUI fonts via `dynamicTypeSize`.
    var fontSizeMultiplier: CGFloat {
        switch dynamicTypeSize {
        case .xSmall:   return 0.75
        case .small:    return 0.875
        case .medium:   return 1.0
        case .large:    return 1.15
        case .xLarge:   return 1.30
        case .xxLarge:  return 1.50
        case .xxxLarge: return 1.75
        default:        return 1.0
        }
    }

    // MARK: - Subfolder Settings

    /// When true, opening a folder also recursively loads FITS files from subfolders.
    var includeSubfolders: Bool = false {
        didSet { UserDefaults.standard.set(includeSubfolders, forKey: "includeSubfolders") }
    }

    /// When true, opening a folder also scans the REJECTED subdirectory and
    /// pre-marks those images as rejected.
    var includeRejectedFolder: Bool = false {
        didSet { UserDefaults.standard.set(includeRejectedFolder, forKey: "includeRejectedFolder") }
    }

    // MARK: - Image Viewer Adjustments

    /// Display zoom factor for the main image viewer (1.0 = render size, 0.25–4.0).
    /// Persisted so the user's preferred zoom level survives app restarts.
    var zoomScale: Double = 1.0 {
        didSet { UserDefaults.standard.set(zoomScale, forKey: "zoomScale") }
    }

    /// Seconds per frame during playback (0.2–5.0).
    var playbackSpeed: Double = 1.0 {
        didSet { UserDefaults.standard.set(playbackSpeed, forKey: "playbackSpeed") }
    }

    // MARK: - Colour Settings

    /// When true, colour FITS images with a BAYERPAT/COLORTYP/CFA_PAT header are
    /// debayered using the GPU (bilinear interpolation) and displayed in colour.
    /// When false, Bayer images are displayed as greyscale (raw sensor data).
    var debayerColorImages: Bool = false {
        didSet { UserDefaults.standard.set(debayerColorImages, forKey: "debayerColorImages") }
    }

    /// Subfolder names (case-insensitive, exact match) that are never recursed into.
    var excludedSubfolderNames: [String] = ["FLAT", "DARK", "BIAS", "CALIB"] {
        didSet { UserDefaults.standard.set(excludedSubfolderNames, forKey: "excludedSubfolderNames") }
    }

    // MARK: - Export Defaults

    /// Default export format used to pre-select the format picker in the export sheet.
    var defaultExportFormat: ExportFormat = .plainText {
        didSet { UserDefaults.standard.set(defaultExportFormat.rawValue, forKey: "defaultExportFormat") }
    }

    /// Whether rejected frames are included in exports by default.
    /// In plain text mode, rejected lines are suffixed with " # REJECTED".
    /// In CSV/TSV modes, a `status` column is emitted with values "kept" or "rejected".
    var includeRejectedInExport: Bool = false {
        didSet { UserDefaults.standard.set(includeRejectedInExport, forKey: "includeRejectedInExport") }
    }

    /// How file paths are rendered in exports. Relative mode strips the longest
    /// common ancestor of all exported frames, so a single-folder session
    /// collapses to bare filenames automatically.
    var exportPathStyle: PathStyle = .absolute {
        didSet { UserDefaults.standard.set(exportPathStyle.rawValue, forKey: "exportPathStyle") }
    }

    /// FITS header keys to include as additional columns in CSV/TSV exports.
    /// Defaults to a curated session-report set covering acquisition, focus, weather,
    /// and pointing fields commonly written by Boltwood, ASCOM, and Indi drivers.
    var exportHeaderKeys: [String] = [
        "OBJECT", "DATE-OBS", "EXPTIME", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP",
        "FOCUSPOS", "AIRMASS", "OBJCTALT",
        "AMBTEMP", "HUMIDITY"
    ] {
        didSet { UserDefaults.standard.set(exportHeaderKeys, forKey: "exportHeaderKeys") }
    }

    /// Reasonable starter set of header keys to offer in Settings even before any
    /// FITS files are loaded. The picker also unions in keys from currently-loaded
    /// entries so rig-specific keys (e.g. FOCUSER, ROTATOR, DEWPOINT) become available.
    static let knownExportHeaderKeys: [String] = [
        "OBJECT", "DATE-OBS", "DATE-LOC", "EXPTIME", "EXPOSURE", "FILTER",
        "GAIN", "OFFSET", "CCD-TEMP", "SET-TEMP",
        "XBINNING", "YBINNING", "XPIXSZ", "YPIXSZ",
        "TELESCOP", "INSTRUME", "FOCALLEN", "FOCRATIO", "APERTURE",
        "FOCUSPOS", "FOCTEMP", "FOCUSER",
        "RA", "DEC", "OBJCTRA", "OBJCTDEC", "OBJCTALT", "OBJCTAZ",
        "AIRMASS", "PIERSIDE", "ROTATOR", "ROTANGLE",
        "AMBTEMP", "HUMIDITY", "DEWPOINT", "PRESSURE",
        "CLOUDCVR", "WINDSPD", "WINDDIR", "SKYBRIGHT", "SKYTEMP",
        "IMAGETYP", "FRAMETYP",
        "SITELAT", "SITELONG", "SITEELEV"
    ]

    // MARK: - Init

    init() {
        // Navigation & action key bindings
        prevImageKey            = UD.string("prevImageKey",            default: prevImageKey)
        nextImageKey            = UD.string("nextImageKey",            default: nextImageKey)
        rejectKey               = UD.string("rejectKey",               default: rejectKey)
        undoKey                 = UD.string("undoKey",                 default: undoKey)
        useToggleReject         = UD.bool(  "useToggleReject",         default: useToggleReject)
        firstImageKey           = UD.string("firstImageKey",           default: firstImageKey)
        lastImageKey            = UD.string("lastImageKey",            default: lastImageKey)
        toggleModeKey           = UD.string("toggleModeKey",           default: toggleModeKey)
        removeKey               = UD.string("removeKey",               default: removeKey)
        debayerKey              = UD.string("debayerKey",              default: debayerKey)
        flagKey                 = UD.string("flagKey",                 default: flagKey)
        deflagAllKey            = UD.string("deflagAllKey",            default: deflagAllKey)
        playPauseKey            = UD.string("playPauseKey",            default: playPauseKey)
        flipKey                 = UD.string("flipKey",                 default: flipKey)

        // Selection key bindings
        selectAllKey            = UD.string("selectAllKey",            default: selectAllKey)
        selectAllShift          = UD.bool(  "selectAllShift",          default: selectAllShift)
        deselectAllKey          = UD.string("deselectAllKey",          default: deselectAllKey)
        deselectAllShift        = UD.bool(  "deselectAllShift",        default: deselectAllShift)
        invertSelectionKey      = UD.string("invertSelectionKey",      default: invertSelectionKey)
        invertSelectionShift    = UD.bool(  "invertSelectionShift",    default: invertSelectionShift)
        selectAllRejectedKey    = UD.string("selectAllRejectedKey",    default: selectAllRejectedKey)
        selectAllRejectedShift  = UD.bool(  "selectAllRejectedShift",  default: selectAllRejectedShift)

        // Sizes
        maxDisplaySize          = UD.positiveInt("maxDisplaySize",     default: maxDisplaySize)
        maxThumbnailSize        = UD.positiveInt("maxThumbnailSize",   default: maxThumbnailSize)

        // Metric toggles — UD.bool uses object(forKey:) to distinguish never-set from false
        computeFWHM             = UD.bool("computeFWHM",               default: computeFWHM)
        computeEccentricity     = UD.bool("computeEccentricity",       default: computeEccentricity)
        computeSNR              = UD.bool("computeSNR",                default: computeSNR)
        computeStarCount        = UD.bool("computeStarCount",          default: computeStarCount)

        // Chart dot brightness
        chartUseBars            = UD.bool(  "chartUseBars",             default: chartUseBars)
        rejectedDotOpacity      = UD.double("rejectedDotOpacity",      default: rejectedDotOpacity)
        dimmedDotOpacity        = UD.double("dimmedDotOpacity",        default: dimmedDotOpacity)

        // UI state
        showInspector           = UD.bool("showInspector",             default: showInspector)
        isSimpleMode            = UD.bool("isSimpleMode",              default: isSimpleMode)
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) { appearanceMode = mode }

        // Files & folders
        includeSubfolders       = UD.bool(   "includeSubfolders",      default: includeSubfolders)
        includeRejectedFolder   = UD.bool(   "includeRejectedFolder",  default: includeRejectedFolder)
        excludedSubfolderNames  = UD.strings("excludedSubfolderNames", default: excludedSubfolderNames)
        debayerColorImages      = UD.bool(   "debayerColorImages",     default: debayerColorImages)
        zoomScale               = UD.double( "zoomScale",              default: zoomScale)
        playbackSpeed           = UD.double( "playbackSpeed",          default: playbackSpeed)

        // Export defaults
        if let raw = UserDefaults.standard.string(forKey: "defaultExportFormat"),
           let fmt = ExportFormat(rawValue: raw) { defaultExportFormat = fmt }
        includeRejectedInExport = UD.bool(   "includeRejectedInExport", default: includeRejectedInExport)
        exportHeaderKeys        = UD.strings("exportHeaderKeys",        default: exportHeaderKeys)
        if let raw = UserDefaults.standard.string(forKey: "exportPathStyle"),
           let style = PathStyle(rawValue: raw) { exportPathStyle = style }

        // Text size (stored as index into availableTypeSizes)
        if let idx = UserDefaults.standard.object(forKey: "dynamicTypeSize") as? Int,
           Self.availableTypeSizes.indices.contains(idx) { dynamicTypeSize = Self.availableTypeSizes[idx] }
    }

    // MARK: - Key Equivalents: navigation & actions

    var prevKeyEquivalent:   KeyEquivalent { keyEquivalent(for: prevImageKey,  fallback: .upArrow) }
    var nextKeyEquivalent:   KeyEquivalent { keyEquivalent(for: nextImageKey,  fallback: .downArrow) }
    var rejectKeyEquivalent: KeyEquivalent { keyEquivalent(for: rejectKey,     fallback: KeyEquivalent("x")) }
    var undoKeyEquivalent:   KeyEquivalent { keyEquivalent(for: undoKey,       fallback: KeyEquivalent("u")) }
    var firstImageKeyEquivalent:  KeyEquivalent { keyEquivalent(for: firstImageKey,  fallback: .home) }
    var lastImageKeyEquivalent:   KeyEquivalent { keyEquivalent(for: lastImageKey,   fallback: .end) }
    var toggleModeKeyEquivalent:  KeyEquivalent { keyEquivalent(for: toggleModeKey,  fallback: KeyEquivalent("g")) }
    var removeKeyEquivalent:      KeyEquivalent { keyEquivalent(for: removeKey,      fallback: KeyEquivalent("r")) }
    var debayerKeyEquivalent:     KeyEquivalent { keyEquivalent(for: debayerKey,     fallback: KeyEquivalent("c")) }
    var flagKeyEquivalent:        KeyEquivalent { keyEquivalent(for: flagKey,      fallback: KeyEquivalent("f")) }
    var deflagAllKeyEquivalent:   KeyEquivalent { keyEquivalent(for: deflagAllKey, fallback: KeyEquivalent("d")) }
    var playPauseKeyEquivalent:   KeyEquivalent { keyEquivalent(for: playPauseKey, fallback: KeyEquivalent(" ")) }
    var flipKeyEquivalent:        KeyEquivalent { keyEquivalent(for: flipKey, fallback: KeyEquivalent("v")) }
    var selectAllKeyEquivalent:       KeyEquivalent { keyEquivalent(for: selectAllKey,       fallback: KeyEquivalent("a")) }
    var deselectAllKeyEquivalent:     KeyEquivalent { keyEquivalent(for: deselectAllKey,     fallback: KeyEquivalent("a")) }
    var invertSelectionKeyEquivalent: KeyEquivalent { keyEquivalent(for: invertSelectionKey, fallback: KeyEquivalent("i")) }
    var selectAllRejectedKeyEquivalent: KeyEquivalent { keyEquivalent(for: selectAllRejectedKey, fallback: KeyEquivalent("r")) }

    // MARK: - Appearance helper

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    // MARK: - Metrics config helpers

    var metricsConfig: MetricsConfig {
        MetricsConfig(computeFWHM: computeFWHM, computeEccentricity: computeEccentricity,
                      computeSNR: computeSNR, computeStarCount: computeStarCount)
    }

    /// Returns an all-disabled config in Simple mode so no star detection is triggered.
    var effectiveMetricsConfig: MetricsConfig {
        isSimpleMode
            ? MetricsConfig(computeFWHM: false, computeEccentricity: false,
                            computeSNR: false, computeStarCount: false)
            : metricsConfig
    }

    // MARK: - Helpers

    private func keyEquivalent(for string: String, fallback: KeyEquivalent) -> KeyEquivalent {
        switch string {
        case "↑": return .upArrow
        case "↓": return .downArrow
        case "←": return .leftArrow
        case "→": return .rightArrow
        case "⇱": return .home
        case "⇲": return .end
        case " ": return KeyEquivalent(" ")
        default:
            if let char = string.first { return KeyEquivalent(char) }
            return fallback
        }
    }

    static func displayString(for keyString: String) -> String {
        switch keyString {
        case "↑", "↓", "←", "→": return keyString
        case "⇱": return "Home"
        case "⇲": return "End"
        case " ":  return "Space"
        default: return keyString.uppercased()
        }
    }
}

// MARK: - Focused Values

extension FocusedValues {
    /// Exposes `AppSettings.isSimpleMode` as a Binding so menu commands can toggle it.
    @Entry var simpleModeBinding: Binding<Bool>? = nil

    /// Exposes `AppSettings.debayerColorImages` as a Binding so the View menu command
    /// can toggle it. ContentView watches this value and triggers reprocessAll on change.
    @Entry var debayerColorBinding: Binding<Bool>? = nil

    /// The raw key string for "Toggle Simple/Geek Mode", so the View menu command can
    /// display the correct user-configured shortcut.
    @Entry var toggleModeKeyString: String? = nil

    /// The raw key string for "Toggle Colour Images", so the View menu command can
    /// display the correct user-configured shortcut.
    @Entry var debayerKeyString: String? = nil

    /// Action for opening a folder, wired to the active window's ImageStore.
    @Entry var openFolderAction: (() -> Void)? = nil

    /// Selection actions wired to the active window's ImageStore.
    @Entry var selectAllAction: (() -> Void)? = nil
    @Entry var deselectAllAction: (() -> Void)? = nil
    @Entry var invertSelectionAction: (() -> Void)? = nil
    @Entry var selectAllRejectedAction: (() -> Void)? = nil
    @Entry var toggleFlagAction: (() -> Void)? = nil
    @Entry var deflagAllAction: (() -> Void)? = nil

    /// Key strings for the flag shortcuts, so menu commands show the correct letters.
    @Entry var flagKeyString: String? = nil
    @Entry var deflagAllKeyString: String? = nil

    /// Key strings for the selection shortcuts, so menu commands can show the correct letter.
    @Entry var selectAllKeyString: String? = nil
    @Entry var deselectAllKeyString: String? = nil
    @Entry var invertSelectionKeyString: String? = nil
    @Entry var selectAllRejectedKeyString: String? = nil

    /// Shift flags for the selection shortcuts (true = ⌘⇧, false = ⌘).
    @Entry var selectAllShiftFV: Bool? = nil
    @Entry var deselectAllShiftFV: Bool? = nil
    @Entry var invertSelectionShiftFV: Bool? = nil
    @Entry var selectAllRejectedShiftFV: Bool? = nil
}

// MARK: - AppearanceMode

enum AppearanceMode: String, CaseIterable {
    case system = "system"
    case light  = "light"
    case dark   = "dark"

    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
}
