//
//  UpdaterDelegate.swift
//  FITS Blaster
//
//  Gives Sparkle the feed for each update check: the beta feed for beta builds and for
//  stable builds with "Receive beta releases" on, otherwise the stable feed (UpdateChannel).
//  Without this, Sparkle uses the SUFeedURL from Info.plist, the stable feed.
//

#if !APPSTORE
import Foundation
import Sparkle

/// Main-actor isolated, as Sparkle calls its delegate on the main thread (step 14d, CODE_AUDIT §4.6).
@MainActor
final class BetaChannelUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    /// Sparkle calls this on every update check. It reads the stored choice at that moment,
    /// the same value the Settings switch shows, so the two can't disagree (issue #11).
    func feedURLString(for updater: SPUUpdater) -> String? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return UpdateChannel.feedURL(version: version, defaults: .standard)
    }
}
#endif
