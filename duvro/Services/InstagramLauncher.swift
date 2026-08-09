//
//  InstagramLauncher.swift
//  duvro
//
//  Phase 7, Task 4 (prd.md §7 / BUILD_ROADMAP Phase 7): the handoff
//  screen's "open instagram" button tries instagram://library first (drops
//  the user straight into their photo library inside Instagram's
//  composer), falls back to instagram://app (just opens Instagram if the
//  library deep link isn't supported by the installed version), falls
//  back to the App Store listing if Instagram isn't installed at all.
//
//  GOTCHA (confirmed by reading Info-Additions.plist before writing this):
//  UIApplication.canOpenURL returns false for ANY scheme not declared in
//  LSApplicationQueriesSchemes, regardless of whether the app is actually
//  installed -- it was NOT present before this commit, so every path
//  would have silently fallen through to the App Store link even with
//  Instagram installed. Added "instagram" to Info-Additions.plist in this
//  same commit; this file is useless without that entry.
//

import UIKit

nonisolated enum InstagramLauncher {
    private static let libraryURL = URL(string: "instagram://library")!
    private static let appURL = URL(string: "instagram://app")!
    /// Instagram's real App Store numeric id -- stable, not duvro-specific.
    private static let appStoreURL = URL(string: "https://apps.apple.com/app/instagram/id389801252")!

    @MainActor
    static func open() {
        let application = UIApplication.shared
        let target: URL
        if application.canOpenURL(libraryURL) {
            target = libraryURL
        } else if application.canOpenURL(appURL) {
            target = appURL
        } else {
            target = appStoreURL
        }
        application.open(target, options: [:], completionHandler: nil)
    }
}
