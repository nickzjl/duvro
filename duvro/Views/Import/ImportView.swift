//
//  ImportView.swift
//  duvro
//

import SwiftUI

struct ImportView: View {
    @State private var importService = PhotoImportService()
    @State private var isPickerPresented = false

    #if DEBUG
    @State private var scoringService = ScoringService()
    @State private var sessionStore = SessionStore()
    @State private var showScoringGrid = false
    @State private var shortlistResult: ShortlistResult?
    @State private var showShortlistDebug = false
    #endif

    private let minimumPhotos = 20
    private let maximumPhotos = 200

    var body: some View {
        ZStack(alignment: .top) {
            Color(hex: "F7F4EE").ignoresSafeArea()

            if importService.photos.isEmpty && !importService.isImporting {
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
        #if DEBUG
        .sheet(isPresented: $showScoringGrid) {
            ScoringDebugGridView(
                photos: importService.photos,
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
            if let shortlistResult {
                ShortlistDebugView(
                    photos: importService.photos,
                    result: shortlistResult,
                    selection: sessionStore.chosenSelection
                )
            }
        }
        #endif
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
                    ForEach(importService.photos) { photo in
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
        let count = importService.photos.count
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
            HStack(spacing: 8) {
                Button(scoringService.isScoring ? "scoring…" : "score photos") {
                    Task { await scoringService.score(photos: importService.photos) }
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
                    // calls the services and stores what they return
                    // (locally for the shortlist, on the session for the
                    // chosen selection, per BUILD_ROADMAP's SessionStore).
                    Button("shortlist") {
                        let shortlist = ShortlistService.buildShortlist(from: scoringService.scores)
                        shortlistResult = shortlist
                        sessionStore.setChosenSelection(FallbackSelectionService.select(from: shortlist))
                        showShortlistDebug = true
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
    #endif
}

#Preview {
    ImportView()
}
