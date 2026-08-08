//
//  duvroApp.swift
//  duvro
//
//  Created by Nick Zhao on 8/1/26.
//

import SwiftUI

@main
struct duvroApp: App {
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if let screen = DebugLaunch.screen {
                DebugLaunchRootView(screen: screen)
            } else {
                ImportView()
            }
            #else
            ImportView()
            #endif
        }
    }
}

#if DEBUG
/// Launch straight into a built screen with DebugFixture data, bypassing
/// import/scoring/Vision entirely -- Vision doesn't run in the Simulator,
/// and `simctl` can't tap, so this is how these screens get verified via
/// `xcrun simctl launch <device> app.duvro.duvro -duvroDebugScreen <case>`.
/// `-key value` launch arguments land in UserDefaults' argument domain
/// automatically; no custom argv parsing needed.
enum DebugLaunchScreen: String {
    case editFlow
    case finalReview
}

enum DebugLaunch {
    static var screen: DebugLaunchScreen? {
        guard let raw = UserDefaults.standard.string(forKey: "duvroDebugScreen") else { return nil }
        return DebugLaunchScreen(rawValue: raw)
    }
}

/// Builds the DebugFixture into a fresh SessionStore and shows the
/// requested screen. `editFlow`/`finalReview` are wired to their real
/// screens in the commits that build them (Phase 5, Phase 6 respectively);
/// until then (and as a fallback if the fixture can't load, e.g. run on a
/// machine without this repo's working tree) this falls back to
/// ShortlistDebugView so the launch path is still verifiable on its own.
struct DebugLaunchRootView: View {
    let screen: DebugLaunchScreen
    @State private var sessionStore = SessionStore()
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let shortlist = sessionStore.shortlist {
                switch screen {
                case .editFlow, .finalReview:
                    // Replaced with the real destination view as each phase
                    // lands -- see this file's history for the swap-in.
                    ShortlistDebugView(
                        photos: sessionStore.photos,
                        result: shortlist,
                        selection: sessionStore.chosenSelection
                    )
                }
            } else {
                ProgressView("loading debug fixture…")
            }
        }
        .task {
            guard let bundle = DebugFixture.load() else { return }
            sessionStore.setPhotos(bundle.photos)
            sessionStore.setScores(bundle.scores)
            let shortlist = ShortlistService.buildShortlist(from: bundle.scores)
            sessionStore.setShortlist(shortlist)
            sessionStore.setChosenSelection(FallbackSelectionService.select(from: shortlist))
            loaded = true
        }
    }
}
#endif
