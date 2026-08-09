//
//  ImportView.swift
//  duvro
//

import SwiftUI

struct ImportView: View {
    @State private var importService = PhotoImportService()
    @State private var isPickerPresented = false
    /// Owns photos/scores/shortlist/chosenSelection/runnerUps once they
    /// exist (SessionStore migration) -- importService/scoringService
    /// remain the computing services (and keep their own progress/telemetry
    /// state: isImporting, scoredCount, peakMemoryMB, etc.), but their
    /// OUTPUT is written into sessionStore rather than read from them
    /// directly, so Phase 5/6 screens have one place to read from.
    @State private var sessionStore = SessionStore()

    #if DEBUG
    @State private var scoringService = ScoringService()
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
    @State private var loadedPack: VibePack?
    @State private var packLoadError: VibePackLoadError?
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
        }
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
        #if DEBUG
        .onChange(of: scoringService.scores.count) {
            sessionStore.setScores(scoringService.scores)
        }
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
                FinalReviewView(sessionStore: sessionStore, pack: $0, onContinue: {})
            }
        }
        #endif
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
    #endif

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
            if !importService.photos.isEmpty {
                debugScoringControls
            }
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
    ImportView()
}
