//
//  AppLinks.swift
//  FITS Blaster
//
//  The web addresses the app opens or reads (step 15c, CODE_AUDIT §9.14).
//

import Foundation

enum AppLinks {
    /// The Ko-fi page in the About box's credits.
    static let kofi = "https://ko-fi.com/tomvp"
    /// Help → FITS Blaster Help.
    static let faq = "https://astrophoto-app.com/faq.html"
    /// Help → Ask Support: a new GitHub issue from the bug-report template.
    static let bugReport = "https://github.com/tvanpeer/FITS-Blaster/issues/new?template=bug_report.md"

    #if !APPSTORE
    /// The stable update feed: Info.plist's `SUFeedURL`, the one place it is written down
    /// (Sparkle reads it from there too). Empty only if the key were missing, and then the
    /// update check reports an error.
    static var stableFeed: String {
        Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? ""
    }

    /// The beta update feed: betas, and the stable releases too (issue #11).
    static let betaFeed = "https://astrophoto-app.com/appcast-beta.xml"
    #endif
}
