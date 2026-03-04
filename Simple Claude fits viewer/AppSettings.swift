//
//  AppSettings.swift
//  Simple Claude fits viewer
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
    var firstImageKey: String = "⇱" {
        didSet { UserDefaults.standard.set(firstImageKey, forKey: "firstImageKey") }
    }
    var lastImageKey: String = "⇲" {
        didSet { UserDefaults.standard.set(lastImageKey, forKey: "lastImageKey") }
    }

    // MARK: - Rating Key Bindings

    var rating1Key: String = "1" {
        didSet { UserDefaults.standard.set(rating1Key, forKey: "rating1Key") }
    }
    var rating2Key: String = "2" {
        didSet { UserDefaults.standard.set(rating2Key, forKey: "rating2Key") }
    }
    var rating3Key: String = "3" {
        didSet { UserDefaults.standard.set(rating3Key, forKey: "rating3Key") }
    }
    var rating4Key: String = "4" {
        didSet { UserDefaults.standard.set(rating4Key, forKey: "rating4Key") }
    }
    var rating5Key: String = "5" {
        didSet { UserDefaults.standard.set(rating5Key, forKey: "rating5Key") }
    }
    var clearRatingKey: String = "0" {
        didSet { UserDefaults.standard.set(clearRatingKey, forKey: "clearRatingKey") }
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

    var appearanceMode: AppearanceMode = .system {
        didSet { UserDefaults.standard.set(appearanceMode.rawValue, forKey: "appearanceMode") }
    }

    // MARK: - Init

    init() {
        // Navigation keys
        if let v = UserDefaults.standard.string(forKey: "prevImageKey")  { prevImageKey  = v }
        if let v = UserDefaults.standard.string(forKey: "nextImageKey")  { nextImageKey  = v }
        if let v = UserDefaults.standard.string(forKey: "rejectKey")     { rejectKey     = v }
        if let v = UserDefaults.standard.string(forKey: "undoKey")       { undoKey       = v }
        if let v = UserDefaults.standard.string(forKey: "firstImageKey") { firstImageKey = v }
        if let v = UserDefaults.standard.string(forKey: "lastImageKey")  { lastImageKey  = v }
        // Rating keys
        if let v = UserDefaults.standard.string(forKey: "rating1Key")    { rating1Key    = v }
        if let v = UserDefaults.standard.string(forKey: "rating2Key")    { rating2Key    = v }
        if let v = UserDefaults.standard.string(forKey: "rating3Key")    { rating3Key    = v }
        if let v = UserDefaults.standard.string(forKey: "rating4Key")    { rating4Key    = v }
        if let v = UserDefaults.standard.string(forKey: "rating5Key")    { rating5Key    = v }
        if let v = UserDefaults.standard.string(forKey: "clearRatingKey"){ clearRatingKey = v }
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
        if let raw = UserDefaults.standard.string(forKey: "appearanceMode"),
           let mode = AppearanceMode(rawValue: raw) { appearanceMode = mode }
    }

    // MARK: - Key Equivalents: navigation & actions

    var prevKeyEquivalent:   KeyEquivalent { keyEquivalent(for: prevImageKey,  fallback: .upArrow) }
    var nextKeyEquivalent:   KeyEquivalent { keyEquivalent(for: nextImageKey,  fallback: .downArrow) }
    var rejectKeyEquivalent: KeyEquivalent { keyEquivalent(for: rejectKey,     fallback: KeyEquivalent("x")) }
    var undoKeyEquivalent:   KeyEquivalent { keyEquivalent(for: undoKey,       fallback: KeyEquivalent("u")) }
    var firstImageKeyEquivalent: KeyEquivalent { keyEquivalent(for: firstImageKey, fallback: .home) }
    var lastImageKeyEquivalent:  KeyEquivalent { keyEquivalent(for: lastImageKey,  fallback: .end) }

    // MARK: - Key Equivalents: rating

    var rating1KeyEquivalent:    KeyEquivalent { keyEquivalent(for: rating1Key,    fallback: KeyEquivalent("1")) }
    var rating2KeyEquivalent:    KeyEquivalent { keyEquivalent(for: rating2Key,    fallback: KeyEquivalent("2")) }
    var rating3KeyEquivalent:    KeyEquivalent { keyEquivalent(for: rating3Key,    fallback: KeyEquivalent("3")) }
    var rating4KeyEquivalent:    KeyEquivalent { keyEquivalent(for: rating4Key,    fallback: KeyEquivalent("4")) }
    var rating5KeyEquivalent:    KeyEquivalent { keyEquivalent(for: rating5Key,    fallback: KeyEquivalent("5")) }
    var clearRatingKeyEquivalent: KeyEquivalent { keyEquivalent(for: clearRatingKey, fallback: KeyEquivalent("0")) }

    // MARK: - Appearance helper

    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }

    // MARK: - Metrics config helper

    var metricsConfig: MetricsConfig {
        MetricsConfig(computeFWHM: computeFWHM, computeEccentricity: computeEccentricity,
                      computeSNR: computeSNR, computeStarCount: computeStarCount)
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
        default: return keyString.uppercased()
        }
    }
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
