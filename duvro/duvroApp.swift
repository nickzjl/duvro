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
                RootFlowView()
            }
            #else
            RootFlowView()
            #endif
        }
    }
}

/// Phase 8.5 (welcome screen, fell through the phase checklist -- see
/// BUILD_ROADMAP's doc fix, same session): welcome is now the real root
/// (prd.md §4 step 1); "start a new chapter" advances to ImportView,
/// which gained a back control (UI_NOTES §6) to return here. Simple
/// state-driven swap, not a NavigationStack -- consistent with the rest
/// of this app, which doesn't use one anywhere else, for a single
/// transition that doesn't need one.
struct RootFlowView: View {
    @State private var showImport = false
    @State private var demoMode = false

    var body: some View {
        if showImport {
            ImportView(
                onBack: {
                    showImport = false
                    demoMode = false
                },
                startInDemoMode: demoMode
            )
        } else {
            WelcomeView(
                samplePhotos: SampleAssets.welcomePhotos(),
                onStartNewChapter: {
                    demoMode = false
                    showImport = true
                },
                onSeeHowItWorks: {
                    // DEBUG-only functional (see ImportView's
                    // startInDemoMode handling) -- the real bundled demo
                    // assets prd.md §4 step 1 specs for this button don't
                    // exist yet. In Release this still navigates to
                    // ImportView, but startInDemoMode does nothing there
                    // (no DEBUG fixture to load), so the button is
                    // effectively unwired in Release. Flagged in the
                    // session report rather than faked.
                    demoMode = true
                    showImport = true
                }
            )
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
    /// Phase 8, Task 3: lands on EditFlowView with the advanced adjustments
    /// sheet (Task 2) already OPEN -- simctl can't tap the real "advanced"
    /// control to reach it, same reasoning as .packPreview below.
    case advancedSheet
    case finalReview
    /// Phase 8, Task 3: lands directly on PackPreviewSheet -- simctl can't
    /// tap a pack card to reach it the real way, since a card (and the
    /// vibe selection screen it lives on, Task 4) is what normally opens
    /// this sheet.
    case packPreview
    /// Phase 8, Task 4: lands on the vibe selection screen itself (photo
    /// count + pack cards). "use this vibe" inside a pack's preview sheet
    /// chains forward into editFlow -> finalReview -> handoff, same
    /// one-way pattern as every other entry point in this file.
    case vibeSelect
    /// Phase 8.5: lands directly on WelcomeView, bypassing RootFlowView's
    /// state machine (its "start a new chapter"/"see how it works"
    /// closures are no-ops here, matching packPreview's onUseThisVibe
    /// convention) -- this is purely for screenshotting the screen
    /// itself.
    case welcome
    /// Phase 9: lands directly on CaptionView (golden_hour, same
    /// convention as editFlow/finalReview) -- simctl can't tap through
    /// Final Review's "add a caption" to reach it the real way.
    case caption
    /// Phase 9/10: lands directly on CurationSequenceView (shuffling
    /// progress -> showcase collage, one continuous view) using
    /// DebugFixture's scores -- so it can be replayed without a full
    /// import, matching every other entry point in this file.
    /// `-duvroDebugCount` (below) sets how many photos it resolves to,
    /// for testing the showcase's layout at both ends of prd.md §4 step
    /// 3's 4-20 range.
    case curationSequence
}

enum DebugLaunch {
    static var screen: DebugLaunchScreen? {
        guard let raw = UserDefaults.standard.string(forKey: "duvroDebugScreen") else { return nil }
        return DebugLaunchScreen(rawValue: raw)
    }

    /// Only consulted for `.packPreview` -- which of the three packs to
    /// preview, e.g. `-duvroDebugScreen packPreview -duvroDebugPack
    /// digicam`. Defaults to golden_hour (matching editFlow/finalReview's
    /// existing hardcoded choice) when unset or not a real pack id.
    static var packName: String {
        UserDefaults.standard.string(forKey: "duvroDebugPack") ?? "golden_hour"
    }

    /// Only consulted for `.curationSequence` -- how many photos the
    /// debug fixture's fallback selection resolves to, e.g.
    /// `-duvroDebugScreen curationSequence -duvroDebugCount 20`. Clamped
    /// to prd.md §4 step 3's own 4...20 range; defaults to 7
    /// (FallbackSelectionService.fallbackCount) when unset.
    static var count: Int {
        let raw = UserDefaults.standard.integer(forKey: "duvroDebugCount")
        guard raw > 0 else { return FallbackSelectionService.fallbackCount }
        return min(max(raw, 4), 20)
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
    /// Phase 6 -> Phase 9. Shared by .editFlow, .finalReview, and
    /// vibeSelectDestination() below, same as showFinalReview/showHandoff
    /// already are -- one caption step for the whole chain, not three.
    @State private var showCaption = false
    @State private var handoffCaption = ""
    /// Phase 9 -> Phase 7.
    @State private var showHandoff = false
    /// Set once vibeSelect's "use this vibe" hands off -- nil means "still
    /// showing VibeSelectionView itself," non-nil means "advance into the
    /// edit flow with this pack," reusing showFinalReview/showCaption/
    /// showHandoff above for the rest of the chain.
    @State private var vibeSelectResult: (pack: VibePack, count: Int)?
    /// vibeSelectDestination's own curation-progress/showcase gate --
    /// same role as ImportView's curationComplete.
    @State private var vibeSelectCurationComplete = false
    /// .curationSequence's own one-way gate, mirroring editFlow's
    /// showFinalReview -- CurationSequenceView's onComplete flips this,
    /// landing on EditFlowView, same one-way pattern as every other
    /// entry point in this file.
    @State private var curationSequenceComplete = false

    var body: some View {
        Group {
            if loaded, let shortlist = sessionStore.shortlist {
                if screen == .vibeSelect {
                    vibeSelectDestination()
                } else if screen == .welcome {
                    welcomeDestination()
                } else if case .success(let pack) = VibePackLoader.load(named: packNameToLoad) {
                    switch screen {
                    case .packPreview:
                        packPreviewDestination(pack: pack)
                    case .caption:
                        CaptionView(sessionStore: sessionStore, pack: pack, onBack: {}, onContinue: { _ in })
                    case .vibeSelect, .welcome:
                        EmptyView() // unreachable -- both handled above, before this branch is ever entered
                    case .advancedSheet:
                        // Purely for screenshotting the sheet's initial
                        // appearance (same convention as
                        // packPreviewDestination) -- no showFinalReview/
                        // showCaption/showHandoff chaining, since simctl
                        // can't tap "done" or drag to dismiss either.
                        EditFlowView(sessionStore: sessionStore, pack: pack, onComplete: {}, startWithAdvancedSheetOpen: true)
                    case .curationSequence:
                        if curationSequenceComplete {
                            EditFlowView(sessionStore: sessionStore, pack: pack) {
                                showFinalReview = true
                            }
                        } else {
                            CurationSequenceView(sessionStore: sessionStore, pack: pack, count: DebugLaunch.count) {
                                curationSequenceComplete = true
                            }
                        }
                    case .editFlow:
                        if showHandoff {
                            HandoffView(sessionStore: sessionStore, pack: pack, caption: handoffCaption)
                        } else if showCaption {
                            CaptionView(sessionStore: sessionStore, pack: pack) {
                                showCaption = false
                            } onContinue: { text in
                                handoffCaption = text
                                showCaption = false
                                showHandoff = true
                            }
                        } else if showFinalReview {
                            FinalReviewView(sessionStore: sessionStore, pack: pack) {
                                // Final Review -> Caption -> Handoff, per
                                // prd.md §4's canonical step order (9 then 10).
                                showCaption = true
                            }
                        } else {
                            EditFlowView(sessionStore: sessionStore, pack: pack) {
                                // NOT a RunnerUpService.compute() recompute --
                                // runnerUps is computed ONCE (below, in .task)
                                // and mutated incrementally by every skip
                                // since (SessionStore.skipPhoto promotes
                                // directly from it, removing what it takes).
                                // Recomputing here would re-derive fresh
                                // candidates from the shortlist remainder and
                                // break the "post.count + runnerUps.count is
                                // the whole bounded universe" invariant that's
                                // the entire point of that design -- see
                                // skipPhoto's doc comment.
                                showFinalReview = true
                            }
                        }
                    case .finalReview:
                        if showHandoff {
                            HandoffView(sessionStore: sessionStore, pack: pack, caption: handoffCaption)
                        } else if showCaption {
                            CaptionView(sessionStore: sessionStore, pack: pack) {
                                showCaption = false
                            } onContinue: { text in
                                handoffCaption = text
                                showCaption = false
                                showHandoff = true
                            }
                        } else {
                            FinalReviewView(sessionStore: sessionStore, pack: pack) {
                                // Same insertion point as .editFlow above.
                                showCaption = true
                            }
                        }
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
            // .curationSequence needs to test the showcase's layout at
            // BOTH ends of prd.md §4 step 3's 4-20 range, but
            // DebugFixture only has 15 real photos, all landing in their
            // own singleton clusters (no featurePrint -- see that file's
            // own doc comment), so 15 is this fixture's real ceiling.
            // Padded with CLONES (fresh UUID, same underlying image/
            // score content) only when testing above that -- clearly
            // synthetic/duplicated, flagged in the session report, and
            // ONLY for this one debug launch case; every other entry
            // point in this file keeps the real, unpadded 15.
            let photos = screen == .curationSequence ? Self.padded(bundle.photos, to: DebugLaunch.count) : bundle.photos
            let scores = screen == .curationSequence ? Self.padded(bundle.scores, photos: photos, from: bundle.photos) : bundle.scores
            sessionStore.setPhotos(photos)
            sessionStore.setScores(scores)
            let shortlist = ShortlistService.buildShortlist(from: scores)
            sessionStore.setShortlist(shortlist)
            let requestedCount = screen == .curationSequence ? DebugLaunch.count : FallbackSelectionService.fallbackCount
            let chosen = FallbackSelectionService.select(from: shortlist, count: requestedCount)
            sessionStore.setChosenSelection(chosen)
            sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
            loaded = true
        }
    }

    /// Clones `source` (cycling through it) with FRESH UUIDs until
    /// reaching `minimumCount`, if it's not already that long -- see the
    /// .task's own comment for why this exists (only ever used for
    /// .curationSequence's layout-scaling test, never any real content
    /// path). originalURL/downsampledURL/thumbnail are all reused as-is
    /// (same underlying image, new identity).
    private static func padded(_ source: [Photo], to minimumCount: Int) -> [Photo] {
        guard source.count < minimumCount, !source.isEmpty else { return source }
        var result = source
        var index = 0
        while result.count < minimumCount {
            let original = source[index % source.count]
            result.append(Photo(id: UUID(), originalURL: original.originalURL, downsampledURL: original.downsampledURL, thumbnail: original.thumbnail, captureDate: original.captureDate))
            index += 1
        }
        return result
    }

    /// Companion to `padded(_:to:)` above -- builds matching PhotoScore
    /// clones (new id, same metrics) for whatever new Photo entries that
    /// call appended, so every padded photo has a score to be shortlisted
    /// with. `photos`/`originalPhotos` must be in the same relative
    /// cycling order `padded(_:to:)` itself produced.
    private static func padded(_ originalScores: [PhotoScore], photos: [Photo], from originalPhotos: [Photo]) -> [PhotoScore] {
        guard photos.count > originalPhotos.count, !originalPhotos.isEmpty else { return originalScores }
        let scoreByOriginalID = Dictionary(uniqueKeysWithValues: zip(originalPhotos.map(\.id), originalScores))
        var result = originalScores
        for index in originalPhotos.count..<photos.count {
            let sourceOriginal = originalPhotos[(index - originalPhotos.count) % originalPhotos.count]
            guard let sourceScore = scoreByOriginalID[sourceOriginal.id] else { continue }
            result.append(PhotoScore(
                id: photos[index].id,
                rawAestheticScore: sourceScore.rawAestheticScore,
                isUtility: sourceScore.isUtility,
                faceCount: sourceScore.faceCount,
                bestFaceQuality: sourceScore.bestFaceQuality,
                humanCount: sourceScore.humanCount,
                classificationLabels: sourceScore.classificationLabels,
                category: sourceScore.category,
                featurePrint: nil,
                rejectionReason: nil
            ))
        }
        return result
    }

    /// editFlow/finalReview keep their EXACT prior hardcoded value
    /// ("golden_hour") -- only packPreview's choice is dynamic. Computed
    /// once here rather than duplicating the literal in two places.
    /// Never actually called for .vibeSelect or .welcome (both branches
    /// short-circuit in `body` before reaching this), but the switch
    /// still has to be exhaustive over DebugLaunchScreen.
    private var packNameToLoad: String {
        switch screen {
        case .editFlow, .advancedSheet, .finalReview, .caption: return "golden_hour"
        case .packPreview, .curationSequence: return DebugLaunch.packName
        case .vibeSelect, .welcome: return "golden_hour"
        }
    }

    /// Presented as a real `.sheet`, not shown unsheeted -- this is the
    /// only way to reproduce the actual on-device sheet chrome (drag
    /// handle, corner radius) for a screenshot. `.constant(true)`: this
    /// launch path exists to verify the sheet's INITIAL appearance, not
    /// its interactive dismissal (which needs a tap simctl can't send
    /// anyway) -- see PackPreviewSheet.swift's file header for the fuller
    /// reasoning.
    private func packPreviewDestination(pack: VibePack) -> some View {
        Color(hex: "F7F4EE").ignoresSafeArea()
            .sheet(isPresented: .constant(true)) {
                PackPreviewSheet(
                    pack: pack,
                    samplePhotos: SampleAssets.packPreviewPhotos(for: pack.id),
                    onUseThisVibe: {}
                )
                .presentationCornerRadius(28) // UI_NOTES §1: "sheets 28pt radius"
            }
    }

    /// Phase 8, Task 4. `vibeSelectResult == nil`: still showing
    /// VibeSelectionView itself. Once set (its "use this vibe" fired),
    /// chains forward into editFlow -> finalReview -> caption -> handoff
    /// -- the SAME one-way pattern every other entry point in this file
    /// uses, reusing showFinalReview/showCaption/showHandoff rather than
    /// duplicating them.
    private func vibeSelectDestination() -> some View {
        Group {
            if let vibeSelectResult {
                if showHandoff {
                    HandoffView(sessionStore: sessionStore, pack: vibeSelectResult.pack, caption: handoffCaption)
                } else if showCaption {
                    CaptionView(sessionStore: sessionStore, pack: vibeSelectResult.pack) {
                        showCaption = false
                    } onContinue: { text in
                        handoffCaption = text
                        showCaption = false
                        showHandoff = true
                    }
                } else if showFinalReview {
                    FinalReviewView(sessionStore: sessionStore, pack: vibeSelectResult.pack) {
                        showCaption = true
                    }
                } else if vibeSelectCurationComplete {
                    EditFlowView(sessionStore: sessionStore, pack: vibeSelectResult.pack) {
                        showFinalReview = true
                    }
                } else {
                    // PHASE 9/10 CURATION INSERTION POINT, closed: used to
                    // hand off directly to the on-device fallback path and
                    // jump straight to EditFlowView -- CurationSequenceView
                    // now owns that pipeline call, same as ImportView's own
                    // two "use this vibe" call sites.
                    CurationSequenceView(sessionStore: sessionStore, pack: vibeSelectResult.pack, count: vibeSelectResult.count) {
                        vibeSelectCurationComplete = true
                    }
                }
            } else {
                VibeSelectionView(
                    sessionStore: sessionStore,
                    samplePhotos: { pack in SampleAssets.packPreviewPhotos(for: pack.id) },
                    packThumbnail: { pack in SampleAssets.packThumbnail(for: pack.id) },
                    onVibeSelected: { pack, count in
                        vibeSelectCurationComplete = false
                        vibeSelectResult = (pack, count)
                    }
                )
            }
        }
    }

    /// Phase 8.5. Lands directly on WelcomeView -- the closures are
    /// no-ops, same convention as packPreviewDestination's
    /// `onUseThisVibe: {}`, since this launch path exists purely for
    /// screenshotting the screen's INITIAL appearance, not its
    /// interactive navigation (which needs a tap simctl can't send).
    private func welcomeDestination() -> some View {
        WelcomeView(
            samplePhotos: SampleAssets.welcomePhotos(),
            onStartNewChapter: {},
            onSeeHowItWorks: {}
        )
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
