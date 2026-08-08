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
/// requested screen. `editFlow`'s "keep this one" on the last photo
/// navigates on into the real Final Review screen (EditFlowView.onComplete),
/// matching the real app's one-way Phase 5 -> Phase 6 flow (UI_NOTES §3: no
/// "take another look" branch back). Falls back to ShortlistDebugView if
/// golden_hour.json itself fails to load -- the launch path stays
/// verifiable on its own even if a downstream pack/asset is broken.
struct DebugLaunchRootView: View {
    let screen: DebugLaunchScreen
    @State private var sessionStore = SessionStore()
    @State private var loaded = false
    /// editFlow starts in Phase 5; reaching the end of the post navigates
    /// forward into Phase 6, one-way, same as the real flow would.
    @State private var showFinalReview = false

    var body: some View {
        Group {
            if loaded, let shortlist = sessionStore.shortlist {
                if case .success(let pack) = VibePackLoader.load(named: "golden_hour") {
                    switch screen {
                    case .editFlow:
                        if showFinalReview {
                            FinalReviewView(sessionStore: sessionStore, pack: pack, onContinue: {})
                        } else {
                            EditFlowView(sessionStore: sessionStore, pack: pack) {
                                let updated = RunnerUpService.compute(shortlist: shortlist, chosen: sessionStore.post)
                                sessionStore.setRunnerUps(updated)
                                showFinalReview = true
                            }
                        }
                    case .finalReview:
                        FinalReviewView(sessionStore: sessionStore, pack: pack, onContinue: {})
                    }
                } else {
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
