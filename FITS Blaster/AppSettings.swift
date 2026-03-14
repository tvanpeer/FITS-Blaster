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

    var appearanceMode: AppearanceMode = .system {
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

    // MARK: - Init

    init() {
        // Navigation keys
        if let v = UserDefaults.standard.string(forKey: "prevImageKey")  { prevImageKey  = v }
        if let v = UserDefaults.standard.string(forKey: "nextImageKey")  { nextImageKey  = v }
        if let v = UserDefaults.standard.string(forKey: "rejectKey")     { rejectKey     = v }
        if let v = UserDefaults.standard.string(forKey: "undoKey")       { undoKey       = v }
        if let v = UserDefaults.standard.object(forKey: "useToggleReject") as? Bool { useToggleReject = v }
        if let v = UserDefaults.standard.string(forKey: "firstImageKey") { firstImageKey = v }
        if let v = UserDefaults.standard.string(forKey: "lastImageKey")  { lastImageKey  = v }
        if let v = UserDefaults.standard.string(forKey: "toggleModeKey") { toggleModeKey = v }
        if let v = UserDefaults.standard.string(forKey: "removeKey")     { removeKey     = v }
        if let v = UserDefaults.standard.string(forKey: "debayerKey")    { debayerKey    = v }
        // Sizes
        let display = UserDefaults.standard.integer(forKey: "maxDisplaySize")
        if display > 0 { maxDisplaySize = display }
        let thumb = UserDefaults.standard.integer(forKey: "maxThumbnailSize")
        if thumb > 0 { maxThumbnailSize = thumb }
        // Metric toggles (object(forKey:) avoids false→false confusion for never-set keys)
        if let v = UserDefaults.standard.object(forKey: "computeFWHM")         as? Bool { computeFWHM         = v }
        if let v = UserDefaults.standard.object(forKey: "computeEccentricity") as? Bool { computeEccentricity = v }
        if let v = UserDefaults.standard.object(forKey: "computeSNR")          as? Bool { computeSNR          = v }
        if let v = UserDefaults.standard.object(forKey: "computeStarCount")    as? Bool { computeStarCount    = v }
        if let v = UserDefaults.standard.object(forKey: "showInspector")       as? Bool { showInspector       = v }
        if let v = UserDefaults.standard.object(forKey: "isSimpleMode")       as? Bool { isSimpleMode       = v }
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) { appearanceMode = mode }
        if let v = UserDefaults.standard.object(forKey: "includeSubfolders")  as? Bool { includeSubfolders  = v }
        if let v = UserDefaults.standard.stringArray(forKey: "excludedSubfolderNames") { excludedSubfolderNames = v }
        if let v = UserDefaults.standard.object(forKey: "debayerColorImages") as? Bool { debayerColorImages = v }
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
