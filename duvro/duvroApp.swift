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
/// requested screen. `finalReview` still falls back to ShortlistDebugView
/// until the Phase 6 commit swaps it in. If golden_hour.json itself fails
/// to load, falls back the same way -- the launch path stays verifiable on
/// its own even if a downstream pack/asset is broken.
struct DebugLaunchRootView: View {
    let screen: DebugLaunchScreen
    @State private var sessionStore = SessionStore()
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded, let shortlist = sessionStore.shortlist {
                switch screen {
                case .editFlow:
                    if case .success(let pack) = VibePackLoader.load(named: "golden_hour") {
                        EditFlowView(sessionStore: sessionStore, pack: pack, onComplete: {})
                    } else {
                        fallback(shortlist)
                    }
                case .finalReview:
                    // Swapped for the real Phase 6 screen in that commit.
                    fallback(shortlist)
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
            let chosen = FallbackSelectionService.select(from: shortlist)
            sessionStore.setChosenSelection(chosen)
            sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
            loaded = true
        }
    }

    private func fallback(_ shortlist: ShortlistResult) -> some View {
        ShortlistDebugView(
            photos: sessionStore.photos,
            result: shortlist,
            selection: sessionStore.chosenSelection,
            runnerUps: sessionStore.runnerUps
        )
    }
}
#endif
