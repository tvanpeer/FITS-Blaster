//
//  UpdaterDelegate.swift
//  FITS Blaster
//
//  Bridges AppSettings.useBetaUpdateChannel to Sparkle's appcast feed URL so
//  beta builds actually look at the beta appcast. Without this, Sparkle uses
//  the SUFeedURL from Info.plist (the stable feed) and beta users see "you're
//  up to date" comparing their build against the stable channel.
//

#if !APPSTORE
import Foundation
import Sparkle

final class BetaChannelUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    static let stableFeedURL = "https://astrophoto-app.com/appcast.xml"
    static let betaFeedURL   = "https://astrophoto-app.com/appcast-beta.xml"

    /// Sparkle calls this on every update check. Reading from UserDefaults
    /// directly (rather than holding an AppSettings reference) keeps the
    /// delegate stateless and avoids cross-actor isolation when the @Observable
    /// settings object lives on @MainActor.
    func feedURLString(for updater: SPUUpdater) -> String? {
        let useBeta = UserDefaults.standard.bool(forKey: "useBetaUpdateChannel")
        return useBeta ? Self.betaFeedURL : Self.stableFeedURL
    }
}
#endif
