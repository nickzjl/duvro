//
//  ImportView.swift
//  duvro
//

import SwiftUI

struct ImportView: View {
    /// Phase 8.5 (welcome screen): Import is no longer the app's root --
    /// welcome is (UI_NOTES §6: every screen after welcome gets a back
    /// control). Called by `topBar`'s chevron; RootFlowView supplies the
    /// real behavior (return to WelcomeView), matching every other
    /// closure-based navigation callback in this codebase.
    var onBack: () -> Void
    /// "see how it works" on the welcome screen sets this -- on appear,
    /// loads the same DEBUG fixture the "vibe select" button already
    /// proves works end-to-end and jumps straight to VibeSelectionView,
    /// skipping the need for a real 20-photo import. DEBUG-only
    /// functionally (see the .task below): the real bundled demo assets
    /// this is meant to use don't exist yet, so in Release this flag is
    /// accepted but does nothing -- flagged in the session report rather
    /// than faked.
    var startInDemoMode: Bool = false

    @State private var importService = PhotoImportService()
    @State private var isPickerPresented = false
    /// Owns photos/scores/shortlist/chosenSelection/runnerUps once they
    /// exist (SessionStore migration) -- importService/scoringService
    /// remain the computing services (and keep their own progress/telemetry
    /// state: isImporting, scoredCount, peakMemoryMB, etc.), but their
    /// OUTPUT is written into sessionStore rather than read from them
    /// directly, so Phase 5/6 screens have one place to read from.
    @State private var sessionStore = SessionStore()
    /// NOT #if DEBUG -- was, until this session (BUILD_ROADMAP Known
    /// gotchas item 9: a Release build imported photos but never scored
    /// them, since nothing outside the DEBUG "score photos" button ever
    /// called this). Kicked off automatically once import completes (see
    /// the .onChange(of: importService.isImporting) below); the DEBUG
    /// "score photos" button in debugScoringControls still works exactly
    /// as before, just against this same now-always-present instance.
    @State private var scoringService = ScoringService()
    /// Guards the auto-kickoff below against firing twice -- there's no
    /// current path back to ImportView with more photos to add after the
    /// first picker session, but this is cheap insurance against that
    /// changing later (same defensive spirit as continueButton's own
    /// comment on realFlowPack).
    @State private var hasStartedAutoScoring = false

    // MARK: - Phase 8, Task 4: the real (non-DEBUG) post-import flow
    /// ONE persistent fullScreenCover for the whole real flow -- shown
    /// once sessionStore.photos.count >= minimumPhotos (see `grid`'s
    /// safeAreaInset below) -- "wire into the real flow after import."
    ///
    /// Task 1 (white-screen bug) fix: this used to be FOUR separate
    /// fullScreenCover bindings (showVibeSelect, showEditFlowReal,
    /// showFinalReviewReal, showHandoffReal), and handleVibeSelected
    /// dismissed one (showVibeSelect = false) while presenting a sibling
    /// (showEditFlowReal = true) IN THE SAME synchronous callback that
    /// itself fired from inside PackPreviewSheet's own dismiss() call one
    /// frame earlier -- three presentation-layer transitions racing in
    /// one tick (sheet dismissing, fullScreenCover A dismissing,
    /// fullScreenCover B presenting, all from the same ImportView).
    /// UIKit does not crash on "present while dismissing," it silently
    /// drops or stalls the new presentation, which is exactly a white
    /// screen with the app still alive. showVibeSelect now stays TRUE for
    /// the entire real flow (vibe select through handoff); `realFlowPack`
    /// and the two flags below only change what `realFlowDestination()`
    /// renders INSIDE that one still-presented cover -- the exact pattern
    /// `vibeSelectDebugDestination()` below already used and the user
    /// confirmed works end-to-end on device.
    @State private var showVibeSelect = false
    @State private var realFlowPack: VibePack?
    @State private var showFinalReviewReal = false
    /// Phase 9: Final Review -> Caption -> Handoff. `realFlowCaption` is
    /// the user's final (possibly hand-edited) text, passed to Handoff.
    @State private var showCaptionReal = false
    @State private var realFlowCaption = ""
    @State private var showHandoffReal = false
    /// Set when "use this vibe" is tapped before any photo has been
    /// scored -- ScoringService itself is #if DEBUG-only today (a larger,
    /// pre-existing gap; wiring real on-device Vision scoring into the
    /// Release flow is out of scope for this task), so a Release build
    /// reaching this screen has nothing to curate from yet. Surfaced
    /// rather than silently doing nothing or crashing.
    @State private var vibeSelectBlockedMessage: String?

    #if DEBUG
    @State private var showScoringGrid = false
    @State private var showShortlistDebug = false
    @State private var showEditDebug = false
    /// "edit"/"review": push the REAL Phase 5/6 screens with the fixture
    /// loaded, so interactions (tap/swipe/drag/skip/runner-up-add) can be
    /// tested by hand on device -- distinct from "render" (Phase 4's
    /// EditDebugView: one photo, 3 variants side by side, render times)
    /// and "fixture"/"shortlist" (ShortlistDebugView: inspect the pipeline's
    /// data, not the real screens). All three debug screens stay -- these
    /// are additions, not replacements.
    @State private var showEditFlowDebug = false
    @State private var showFinalReviewDebug = false
    /// Phase 6 -> Phase 9 -> Phase 7.
    @State private var showCaptionDebug = false
    @State private var handoffDebugCaption = ""
    @State private var showHandoffDebug = false
    @State private var loadedPack: VibePack?
    @State private var packLoadError: VibePackLoadError?
    /// "caption": jumps straight to CaptionView (golden_hour, same
    /// convention as "edit"/"review"/"preview") for testing that screen
    /// in isolation, previously only reachable via `-duvroDebugScreen
    /// caption`.
    @State private var showCaptionDebugStandalone = false
    /// "vibe select"/"preview": the same gap the edit/review buttons above
    /// closed for EditFlowView/FinalReviewView a few sessions ago --
    /// VibeSelectionView and PackPreviewSheet were previously reachable
    /// ONLY via `-duvroDebugScreen vibeSelect`/`packPreview`, which can't
    /// be typed from the phone itself. "vibe select" pushes the real
    /// screen with the fixture loaded, chaining into editFlow ->
    /// finalReview -> handoff on "use this vibe" (its OWN chain, separate
    /// from "edit"/"review"'s, since the pack is chosen dynamically here
    /// rather than always golden_hour). "preview" jumps straight to
    /// PackPreviewSheet (golden_hour, same as "edit"/"review") for
    /// testing that screen in isolation.
    @State private var showVibeSelectDebug = false
    @State private var vibeSelectDebugResult: (pack: VibePack, count: Int)?
    @State private var showVibeSelectDebugFinalReview = false
    @State private var showVibeSelectDebugCaption = false
    @State private var vibeSelectDebugCaption = ""
    @State private var showVibeSelectDebugHandoff = false
    @State private var showPackPreviewDebug = false
    #endif

    private let minimumPhotos = 20
    private let maximumPhotos = 200

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: "F7F4EE").ignoresSafeArea()

            if sessionStore.photos.isEmpty && !importService.isImporting {
                emptyState
            } else {
                grid
            }

            #if DEBUG
            debugOverlay
            #endif

            topBar
        }
        #if DEBUG
        .task {
            // "see how it works" (welcome screen) -- same real pipeline
            // the "vibe select" debug button already proves works
            // end-to-end, just triggered on appear instead of by a tap.
            guard startInDemoMode else { return }
            guard loadFixtureIntoSessionStore() != nil else { return }
            showVibeSelectDebug = true
        }
        #endif
        .sheet(isPresented: $isPickerPresented) {
            PhotoPicker(selectionLimit: maximumPhotos) { results in
                isPickerPresented = false
                Task {
                    await importService.process(results: results)
                }
            }
            .ignoresSafeArea()
        }
        // Mirrors importService.photos into sessionStore as it grows, so
        // the grid stays live/progressive during import (Photo isn't
        // Equatable, hence watching .count rather than the array itself)
        // while sessionStore -- not importService -- is what the rest of
        // the app (and Phase 5/6 screens) reads from. SessionStore
        // migration; no import behavior changed.
        .onChange(of: importService.photos.count) {
            sessionStore.setPhotos(importService.photos)
        }
        // scoringService.scores now grows INCREMENTALLY, one photo at a
        // time (ScoringService change, this session) -- syncing on every
        // .count change is what lets the curation-progress screen read
        // "whatever's scored so far" via sessionStore, not just the
        // final batch. Was #if DEBUG-only; scoringService itself no
        // longer is (see its own doc comment above).
        .onChange(of: scoringService.scores.count) {
            sessionStore.setScores(scoringService.scores)
        }
        .onChange(of: scoringService.isScoring) { _, inProgress in
            sessionStore.setScoring(inProgress)
        }
        // Task 1 (BUILD_ROADMAP Known gotchas item 9): scoring starts on
        // its own, in the background, the moment import finishes -- the
        // user goes straight to vibe selection and browses pack previews
        // while Vision works, so by the time "use this vibe" is tapped
        // most or all of it is already done. Fires once (hasStartedAutoScoring)
        // on the wasImporting-true -> isImportingNow-false transition,
        // the same "import is complete enough" condition continueButton's
        // own gate already uses (minimumPhotos reached, not mid-import).
        // Scores importService.photos directly, not sessionStore.photos --
        // both are updated from the same source, but importService's own
        // copy has no cross-object sync timing to reason about.
        .onChange(of: importService.isImporting) { wasImporting, isImportingNow in
            guard wasImporting, !isImportingNow else { return }
            guard importService.photos.count >= minimumPhotos, !hasStartedAutoScoring else { return }
            hasStartedAutoScoring = true
            Task { await scoringService.score(photos: importService.photos) }
        }
        #if DEBUG
        .sheet(isPresented: $showScoringGrid) {
            ScoringDebugGridView(
                photos: sessionStore.photos,
                scores: scoringService.scores,
                failedCount: scoringService.failedCount,
                failureReasons: scoringService.failureReasons
            )
        }
        .onChange(of: scoringService.isScoring) { wasScoring, isScoringNow in
            // Auto-present the grid the moment a scoring pass finishes, whether
            // it produced results or not -- an empty grid is itself a signal
            // something's wrong, and shouldn't be hidden behind a manual tap.
            if wasScoring && !isScoringNow {
                showScoringGrid = true
            }
        }
        .sheet(isPresented: $showShortlistDebug) {
            if let shortlist = sessionStore.shortlist {
                ShortlistDebugView(
                    photos: sessionStore.photos,
                    result: shortlist,
                    selection: sessionStore.chosenSelection,
                    runnerUps: sessionStore.runnerUps
                )
            }
        }
        .sheet(isPresented: $showEditDebug) {
            EditDebugView(
                photos: sessionStore.photos,
                scores: sessionStore.scores,
                chosenSelection: sessionStore.chosenSelection
            )
        }
        .fullScreenCover(isPresented: $showEditFlowDebug) {
            debugFlowDestination {
                EditFlowView(sessionStore: sessionStore, pack: $0) {
                    // Chains into Final Review on completion, same as the
                    // real one-way Phase 5 -> Phase 6 flow (and matching
                    // duvroApp's -duvroDebugScreen editFlow launch path) --
                    // "edit" tests both screens in sequence; "review" below
                    // is the independent, jump-straight-there path.
                    showEditFlowDebug = false
                    showFinalReviewDebug = true
                }
            }
        }
        .fullScreenCover(isPresented: $showFinalReviewDebug) {
            debugFlowDestination {
                FinalReviewView(sessionStore: sessionStore, pack: $0) {
                    // Final Review -> Caption -> Handoff, per prd.md §4's
                    // canonical step order (9 then 10).
                    showFinalReviewDebug = false
                    showCaptionDebug = true
                }
            }
        }
        .fullScreenCover(isPresented: $showCaptionDebug) {
            debugFlowDestination { pack in
                CaptionView(sessionStore: sessionStore, pack: pack) {
                    showCaptionDebug = false
                    showFinalReviewDebug = true
                } onContinue: { text in
                    handoffDebugCaption = text
                    showCaptionDebug = false
                    showHandoffDebug = true
                }
            }
        }
        .fullScreenCover(isPresented: $showHandoffDebug) {
            debugFlowDestination {
                HandoffView(sessionStore: sessionStore, pack: $0, caption: handoffDebugCaption)
            }
        }
        .fullScreenCover(isPresented: $showCaptionDebugStandalone) {
            debugFlowDestination { pack in
                CaptionView(sessionStore: sessionStore, pack: pack, onBack: { showCaptionDebugStandalone = false }, onContinue: { _ in })
            }
        }
        .fullScreenCover(isPresented: $showVibeSelectDebug) {
            vibeSelectDebugDestination()
        }
        .sheet(isPresented: $showPackPreviewDebug) {
            debugFlowDestination { pack in
                PackPreviewSheet(
                    pack: pack,
                    samplePhotos: SampleAssets.packPreviewPhotos(for: pack.id),
                    onUseThisVibe: {}
                )
                .presentationCornerRadius(28) // UI_NOTES §1: "sheets 28pt radius"
            }
        }
        #endif
        // MARK: Phase 8, Task 4: real (non-DEBUG) flow -- compiled in every
        // configuration, unlike the block above. ONE fullScreenCover for
        // the whole flow (Task 1 fix -- see showVibeSelect's doc comment).
        .fullScreenCover(isPresented: $showVibeSelect) {
            realFlowDestination()
                // Attached HERE, inside the presented cover's own content,
                // not on ImportView's outer body -- an .alert modifier on
                // an ancestor that's currently COVERED by a fullScreenCover
                // presents from a view controller that isn't topmost, which
                // is the same "present from underneath an active
                // presentation" problem this task's fix addresses above.
                // Verified by reasoning (matches SwiftUI's own guidance:
                // attach presentation modifiers to the view that's actually
                // visible when they fire), not by an interactive repro --
                // see the session report.
                .alert("can't curate yet", isPresented: Binding(
                    get: { vibeSelectBlockedMessage != nil },
                    set: { if !$0 { vibeSelectBlockedMessage = nil } }
                )) {
                    Button("ok") {}
                } message: {
                    Text(vibeSelectBlockedMessage ?? "")
                }
        }
    }

    /// Content of the real flow's ONE fullScreenCover. `realFlowPack ==
    /// nil`: still showing VibeSelectionView itself. Once set ("use this
    /// vibe" fired), chains forward into editFlow -> finalReview ->
    /// handoff by swapping THIS function's output -- the cover itself
    /// (showVibeSelect) never toggles again until the user backs all the
    /// way out. Exact same structure as vibeSelectDebugDestination()
    /// below, which the user confirmed already works end-to-end on
    /// device; this is that pattern applied to the real (non-DEBUG) path,
    /// which previously used four separate fullScreenCovers instead (the
    /// Task 1 bug).
    @ViewBuilder
    private func realFlowDestination() -> some View {
        if let realFlowPack {
            if showHandoffReal {
                HandoffView(sessionStore: sessionStore, pack: realFlowPack, caption: realFlowCaption)
            } else if showCaptionReal {
                CaptionView(sessionStore: sessionStore, pack: realFlowPack) {
                    showCaptionReal = false
                } onContinue: { text in
                    realFlowCaption = text
                    showCaptionReal = false
                    showHandoffReal = true
                }
            } else if showFinalReviewReal {
                FinalReviewView(sessionStore: sessionStore, pack: realFlowPack) {
                    // Final Review -> Caption -> Handoff, per prd.md §4's
                    // canonical step order (9 then 10).
                    showFinalReviewReal = false
                    showCaptionReal = true
                }
            } else {
                EditFlowView(sessionStore: sessionStore, pack: realFlowPack) {
                    showFinalReviewReal = true
                }
            }
        } else {
            VibeSelectionView(
                sessionStore: sessionStore,
                samplePhotos: { pack in SampleAssets.packPreviewPhotos(for: pack.id) },
                packThumbnail: { pack in SampleAssets.packThumbnail(for: pack.id) },
                onVibeSelected: handleVibeSelected
            )
        }
    }

    /// The real (non-DEBUG) "use this vibe" hand-off -- Task 4 spec:
    /// "vibe selection hands off to the existing shortlist/fallback path
    /// for now." Mirrors loadFixtureIntoSessionStore's exact pipeline call
    /// order (ShortlistService -> FallbackSelectionService -> RunnerUpService),
    /// just against sessionStore.scores (real Vision output, once
    /// something produces it) instead of DebugFixture's fabricated ones,
    /// and with the user's own resolved count rather than the default 7.
    ///
    /// PHASE 9/10 CURATION INSERTION POINT: prd.md §4 steps 5-6 ("curation
    /// progress" / "curation showcase") aren't built this session --
    /// EditFlowView opens directly instead of passing through them first.
    ///
    /// Task 1 fix: only sets `realFlowPack` now -- does NOT touch
    /// showVibeSelect. The cover stays presented; realFlowDestination()
    /// reacts to realFlowPack changing and swaps its content. Previously
    /// this also set showVibeSelect = false (dismiss) and a separate
    /// showEditFlowReal = true (present) in the same call, which raced
    /// against PackPreviewSheet's own dismiss() one frame earlier -- see
    /// showVibeSelect's doc comment for the full diagnosis.
    private func handleVibeSelected(pack: VibePack, count: Int) {
        guard !sessionStore.scores.isEmpty else {
            // Expected today outside DEBUG tooling: ScoringService is #if
            // DEBUG-only (see the state vars above), so a Release build
            // reaching this screen has no Vision scores to shortlist from
            // yet. Fail safe -- surface why, don't crash or silently no-op.
            vibeSelectBlockedMessage = "add some photos and score them first — there's nothing to curate yet."
            return
        }
        let shortlist = ShortlistService.buildShortlist(from: sessionStore.scores)
        sessionStore.setShortlist(shortlist)
        let chosen = FallbackSelectionService.select(from: shortlist, count: count)
        sessionStore.setChosenSelection(chosen)
        sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
        realFlowPack = pack
    }

    #if DEBUG
    /// Shared failure surface for the "edit"/"review" debug buttons: if
    /// golden_hour.json itself fails to load, show why instead of a blank
    /// cover -- same VibePackLoadError.diagnosticDescription EditDebugView
    /// already surfaces, not a new failure path.
    @ViewBuilder
    private func debugFlowDestination<Content: View>(@ViewBuilder content: (VibePack) -> Content) -> some View {
        if let loadedPack {
            content(loadedPack)
        } else if let packLoadError {
            VStack(spacing: 8) {
                Text("golden_hour pack failed to load")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                Text(packLoadError.diagnosticDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 20)
            }
        } else {
            ProgressView()
        }
    }

    /// "vibe select" button's destination. `vibeSelectDebugResult == nil`:
    /// still showing VibeSelectionView itself. Once set (its "use this
    /// vibe" fired), chains into editFlow -> finalReview -> handoff --
    /// same one-way pattern as duvroApp's own vibeSelectDestination and
    /// this file's "edit"/"review" chain, just with dedicated state so it
    /// doesn't collide with either of those (this one's pack is whatever
    /// the user actually tapped, not always golden_hour).
    @ViewBuilder
    private func vibeSelectDebugDestination() -> some View {
        if let vibeSelectDebugResult {
            if showVibeSelectDebugHandoff {
                HandoffView(sessionStore: sessionStore, pack: vibeSelectDebugResult.pack, caption: vibeSelectDebugCaption)
            } else if showVibeSelectDebugCaption {
                CaptionView(sessionStore: sessionStore, pack: vibeSelectDebugResult.pack) {
                    showVibeSelectDebugCaption = false
                } onContinue: { text in
                    vibeSelectDebugCaption = text
                    showVibeSelectDebugCaption = false
                    showVibeSelectDebugHandoff = true
                }
            } else if showVibeSelectDebugFinalReview {
                FinalReviewView(sessionStore: sessionStore, pack: vibeSelectDebugResult.pack) {
                    showVibeSelectDebugCaption = true
                }
            } else {
                EditFlowView(sessionStore: sessionStore, pack: vibeSelectDebugResult.pack) {
                    showVibeSelectDebugFinalReview = true
                }
            }
        } else {
            VibeSelectionView(
                sessionStore: sessionStore,
                samplePhotos: { pack in SampleAssets.packPreviewPhotos(for: pack.id) },
                packThumbnail: { pack in SampleAssets.packThumbnail(for: pack.id) },
                onVibeSelected: { pack, count in
                    // Same real pipeline as loadFixtureIntoSessionStore's
                    // own calls, just against the user's resolved count
                    // instead of the default 7 -- sessionStore.scores is
                    // already the fixture's fabricated scores by this
                    // point ("vibe select" calls loadFixtureIntoSessionStore
                    // before presenting this view).
                    let shortlist = ShortlistService.buildShortlist(from: sessionStore.scores)
                    sessionStore.setShortlist(shortlist)
                    let chosen = FallbackSelectionService.select(from: shortlist, count: count)
                    sessionStore.setChosenSelection(chosen)
                    sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
                    vibeSelectDebugResult = (pack, count)
                }
            )
        }
    }
    #endif

    /// UI_NOTES §6: every screen after welcome gets a back control.
    /// Present regardless of emptyState/grid -- same 44x44 chevron
    /// treatment EditFlowView/VibeSelectionView already use.
    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "171614"))
                    .frame(width: 44, height: 44)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()
            Text("pick your favorites")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text("select 20–200 photos to start")
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
            Spacer()
            Button {
                isPickerPresented = true
            } label: {
                Text("select photos")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
        }
    }

    private var grid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(sessionStore.photos) { photo in
                        Image(uiImage: photo.thumbnail)
                            .resizable()
                            .aspectRatio(4 / 5, contentMode: .fill)
                            .frame(maxWidth: .infinity)
                            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                            .clipped()
                    }
                }
                .padding(.horizontal, 20)
            }
            .padding(.top, 64)
            .padding(.bottom, 40)
        }
        #if DEBUG
        // Layering fix: debugScoringControls used to live in debugOverlay,
        // a separate ZStack layer painted AFTER (on top of) grid -- which
        // put it in the exact same bottom screen region as continueButton
        // below and fully covered it, in any DEBUG build with 20+ photos
        // imported (confirmed on-device). Chaining it as its OWN
        // safeAreaInset here, applied BEFORE continueButton's, stacks it
        // just above the CTA instead of on top of it -- chained
        // safeAreaInsets compose outward, so the LAST one applied
        // (continueButton, below) ends up closest to the true bottom
        // edge, matching every other primary CTA in the app.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !importService.photos.isEmpty {
                debugScoringControls
                    .preferredColorScheme(.light) // same scoped light-lock debugOverlay used to apply
            }
        }
        #endif
        // Phase 8, Task 4: "wire into the real flow after import" -- the
        // only way to reach VibeSelectionView outside DEBUG launch
        // arguments/buttons. safeAreaInset (not a fixed padding guess)
        // reserves exactly the button's real height + safe area, same
        // fix-5 pattern as EditFlowView's primaryButton.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if sessionStore.photos.count >= minimumPhotos, !importService.isImporting {
                continueButton
            }
        }
    }

    private var continueButton: some View {
        Button {
            // Defensive reset -- not currently reachable (nothing lets a
            // user get back to ImportView from deeper in the real flow
            // yet), but cheap insurance against a stale realFlowPack from
            // a prior run if that ever changes.
            realFlowPack = nil
            showFinalReviewReal = false
            showHandoffReal = false
            showVibeSelect = true
        } label: {
            Text("choose your vibe")
                .font(.duvroButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "171614"))
                .clipShape(Capsule())
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("your photos")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text(countLabel)
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
        }
        .padding(.horizontal, 20)
    }

    private var countLabel: String {
        if importService.isImporting {
            return "\(importService.importedCount) of \(importService.totalCount) processed…"
        }
        let count = sessionStore.photos.count
        if count < minimumPhotos {
            return "\(count) selected — add a few more, 20 is the minimum for a good curation"
        }
        return "\(count) photos selected"
    }

    #if DEBUG
    /// Memory badge only now -- debugScoringControls moved to `grid`'s own
    /// safeAreaInset chain (see the layering-fix comment there) so it no
    /// longer paints over continueButton. This layer still spans the full
    /// screen (VStack + Spacer), but only the top-right badge has visible
    /// content, same as before.
    private var debugOverlay: some View {
        VStack {
            HStack {
                Spacer()
                Text(String(format: "peak %.0fMB · %d/%d", importService.peakMemoryMB, importService.photos.count, importService.totalCount))
                    .font(.system(size: 11, design: .monospaced))
                    .padding(6)
                    .background(.black.opacity(0.7))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(.top, 8)
                    .padding(.trailing, 8)
            }
            Spacer()
        }
        .preferredColorScheme(.light)
    }

    private var debugScoringControls: some View {
        VStack(spacing: 8) {
            if scoringService.isScoring {
                Text(String(format: "scoring %d/%d · peak %.0fMB", scoringService.scoredCount, scoringService.totalCount, scoringService.peakMemoryMB))
                    .font(.system(size: 11, design: .monospaced))
            } else if scoringService.failedCount > 0 {
                Text(String(format: "scored %d ok, %d FAILED, in %.2fs · peak %.0fMB", scoringService.scores.count, scoringService.failedCount, scoringService.elapsedSeconds, scoringService.peakMemoryMB))
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)
            } else if !scoringService.scores.isEmpty {
                Text(String(format: "scored %d in %.2fs · peak %.0fMB", scoringService.scores.count, scoringService.elapsedSeconds, scoringService.peakMemoryMB))
                    .font(.system(size: 11, design: .monospaced))
            }
            // Horizontal scroll, not a fixed HStack -- 7 buttons is already
            // tight on a real device width, and this row is only going to
            // grow as more debug tooling gets added. Cut off, untappable
            // buttons would defeat the entire point of this row.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Button(scoringService.isScoring ? "scoring…" : "score photos") {
                        Task { await scoringService.score(photos: sessionStore.photos) }
                    }
                    .disabled(scoringService.isScoring)

                    if !scoringService.scores.isEmpty || scoringService.failedCount > 0 {
                        Button("grid") { showScoringGrid = true }
                    }

                    if !scoringService.scores.isEmpty {
                        // Two services, two results: ShortlistService produces
                        // the candidate shortlist; FallbackSelectionService
                        // (Phase 3.5's offline/no-network branch) then chooses
                        // from it. Neither is computed here -- the view only
                        // calls the services and stores what they return, on
                        // sessionStore (SessionStore migration -- previously
                        // the shortlist was View-local state). Uses YOUR real
                        // imported + Vision-scored photos, NOT the fixture --
                        // "fixture" below is a separate, unrelated data source,
                        // never meant to match this button's output.
                        Button("shortlist") {
                            let shortlist = ShortlistService.buildShortlist(from: scoringService.scores)
                            sessionStore.setShortlist(shortlist)
                            sessionStore.setChosenSelection(FallbackSelectionService.select(from: shortlist))
                            showShortlistDebug = true
                        }

                        // Doesn't require "shortlist" to have been tapped first --
                        // EditDebugView falls back to any scored photo when
                        // sessionStore.chosenSelection is empty/unavailable, so
                        // Phase 4's render pipeline can be checked independently
                        // of Phase 3's selection. Phase 4's tool (one photo, 3
                        // variants + render times) -- NOT the real edit screen;
                        // "edit" below is that.
                        Button("render") {
                            showEditDebug = true
                        }
                    }

                    // Vision doesn't run in the Simulator -- this is the manual
                    // (button-driven) path to the same DebugFixture the
                    // -duvroDebugScreen launch args use, so the fixture's output
                    // is inspectable via the existing debug views too, not just
                    // by launching straight into Phase 5/6.
                    Button("fixture") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        showShortlistDebug = true
                    }

                    // Push the REAL Phase 5/6 screens with the fixture loaded --
                    // "fixture"/"shortlist" only show ShortlistDebugView's data
                    // inspection, not the actual interactive screens, and those
                    // are otherwise only reachable via -duvroDebugScreen launch
                    // arguments, which don't exist from the phone itself.
                    Button("edit") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        loadPackAndShow { showEditFlowDebug = true }
                    }

                    Button("review") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        loadPackAndShow { showFinalReviewDebug = true }
                    }

                    // Pushes the REAL VibeSelectionView (photo count + all
                    // 3 pack cards) with the fixture loaded -- previously
                    // only reachable via `-duvroDebugScreen vibeSelect`.
                    // "use this vibe" inside its pack-preview sheet chains
                    // into editFlow -> finalReview -> handoff, same as
                    // "edit" above, but with whichever pack was actually
                    // tapped rather than always golden_hour.
                    Button("vibe select") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        showVibeSelectDebug = true
                    }

                    // Jumps straight to PackPreviewSheet (golden_hour) --
                    // previously only reachable via `-duvroDebugScreen
                    // packPreview`. For testing the sheet itself (sample
                    // grid, quote, "use this vibe"/"cancel") in isolation,
                    // without going through the vibe-select screen first.
                    Button("preview") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        loadPackAndShow { showPackPreviewDebug = true }
                    }

                    // Jumps straight to CaptionView (golden_hour) --
                    // previously only reachable via `-duvroDebugScreen
                    // caption`. For testing the caption suggestion +
                    // regenerate in isolation, without going through
                    // edit/final review first.
                    Button("caption") {
                        guard loadFixtureIntoSessionStore() != nil else { return }
                        loadPackAndShow { showCaptionDebugStandalone = true }
                    }
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .monospaced))
        }
        .padding(10)
        .background(.black.opacity(0.8))
        .foregroundStyle(.white)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .padding(.bottom, 12)
    }

    /// Shared by "fixture"/"edit"/"review": loads DebugFixture and runs it
    /// through the exact same real pipeline calls (ShortlistService ->
    /// FallbackSelectionService -> RunnerUpService), storing each stage on
    /// sessionStore. Returns the chosen selection so callers can bail out
    /// (button no-ops) if the fixture failed to load, without duplicating
    /// the pipeline calls three times.
    @discardableResult
    private func loadFixtureIntoSessionStore() -> FallbackSelectionResult? {
        guard let bundle = DebugFixture.load() else { return nil }
        sessionStore.setPhotos(bundle.photos)
        sessionStore.setScores(bundle.scores)
        let shortlist = ShortlistService.buildShortlist(from: bundle.scores)
        sessionStore.setShortlist(shortlist)
        let chosen = FallbackSelectionService.select(from: shortlist)
        sessionStore.setChosenSelection(chosen)
        sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
        return chosen
    }

    /// Shared by "edit"/"review": resolves golden_hour.json once (cached in
    /// loadedPack so repeated taps don't re-decode the JSON) and only then
    /// flips the presentation flag -- avoids a cover opening onto a blank
    /// screen if the pack load is slow, and surfaces a real reason via
    /// packLoadError/debugFlowDestination if it fails outright.
    private func loadPackAndShow(_ present: () -> Void) {
        if loadedPack == nil {
            switch VibePackLoader.load(named: "golden_hour") {
            case .success(let pack):
                loadedPack = pack
                packLoadError = nil
            case .failure(let error):
                packLoadError = error
            }
        }
        present()
    }
    #endif
}

#Preview {
    ImportView(onBack: {})
}
