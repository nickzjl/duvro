//
//  FinalReviewView.swift
//  duvro
//
//  Phase 6, "the final touches" (BUILD_ROADMAP Phase 6, prd.md §4 step 8,
//  UI_NOTES fixes 5/9/10 + §3/§6). Lands here DIRECTLY after the last Phase
//  5 edit -- no "ready to post? / take another look" branch, no restart
//  invitation (UI_NOTES §3). Layout follows the approved mockup
//  (design/12_carousel + runner-ups.png): carousel, reorderable thumbnail
//  strip, "what we left out" row.
//

import SwiftUI

struct FinalReviewView: View {
    var sessionStore: SessionStore
    let pack: VibePack
    /// "add a caption" (UI_NOTES §6 -- not "save the collection"). A dead
    /// end this session by design -- the caption screen is Phase 9, out of
    /// scope. The hook exists so real navigation is a one-line change later.
    var onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    /// photoID -> the ONE rendered image for that photo's committed pick
    /// (not 3 variants like Phase 5 -- Final Review only ever shows the
    /// picked variant). Caching all of the post's photos at once is fine
    /// here: at most ~7-9 photos x one render each, nowhere near Phase 5's
    /// current+next-only budget, which existed specifically because that
    /// screen holds 3 LIVE variants per photo for comparison.
    @State private var renderCache: [UUID: UIImage] = [:]
    @State private var carouselSelectionID: UUID?
    @State private var draggingID: UUID?
    @State private var pendingRunnerUp: PendingRunnerUp?

    private struct PendingRunnerUp: Identifiable {
        let id: UUID
        let score: PhotoScore
        /// Photo ID to remove once this one joins, if adding would exceed
        /// the target post size. nil = plain append.
        let replacing: UUID?
    }

    private var post: [PhotoScore] { sessionStore.post }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    headlineBlock
                    if post.isEmpty {
                        emptyPostState
                    } else {
                        carousel
                        thumbnailStrip
                    }
                    if !sessionStore.runnerUps.isEmpty {
                        runnerUpRow
                    }
                }
                .padding(.top, 12)
            }
            // UI_NOTES fix 5: bottom content inset = sticky CTA height + safe
            // area, satisfied structurally (not a guessed constant) --
            // same pattern as EditFlowView.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                primaryButton
            }
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .onAppear {
            if carouselSelectionID == nil { carouselSelectionID = post.first?.id }
            renderMissing()
        }
        .onChange(of: post.map(\.id)) { _, _ in renderMissing() }
        .fullScreenCover(item: $pendingRunnerUp) { pending in
            // "Newly added photos route through the 3-way edit before
            // joining the post" (BUILD_ROADMAP Phase 6 / UI_NOTES) -- reuses
            // EditFlowView's own pill/swipe/crossfade interaction, scoped to
            // just this one photo, rather than a second implementation.
            EditFlowView(sessionStore: sessionStore, pack: pack, scopedTo: pending.score) {
                sessionStore.addRunnerUp(pending.id, replacing: pending.replacing)
                pendingRunnerUp = nil
            }
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
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

    // MARK: - Headline

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("the final touches.")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text("long-press and drag to reorder your post.")
                .font(.duvroSubheadline)
                .foregroundStyle(Color(hex: "777169"))
        }
        .padding(.horizontal, 20)
    }

    private var emptyPostState: some View {
        Text("everything's been removed — add one back from what we left out below.")
            .font(.duvroSubheadline)
            .foregroundStyle(Color(hex: "777169"))
            .padding(.horizontal, 20)
    }

    // MARK: - Carousel (Instagram-style, exact post order, uniform 4:5)

    private var carousel: some View {
        VStack(spacing: 10) {
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(post) { score in
                        carouselPage(score)
                            .containerRelativeFrame(.horizontal)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $carouselSelectionID)
            // aspectRatio BEFORE padding (inner, not outer): this sizes the
            // ScrollView itself to (screen width - 40) x that-width*5/4 --
            // i.e. the ratio is computed AFTER the page padding is already
            // accounted for -- then padding adds the 20pt margin back
            // around that already-correctly-sized box (UI_NOTES §1). Doing
            // it the other way (padding then aspectRatio) sizes height off
            // the FULL unpadded width while width itself is padded, so the
            // photo's real box isn't 4:5 at all -- two different widths
            // feeding one ratio calculation, which is what let the photo
            // bleed past its padding in some scroll states: each page's
            // width (from containerRelativeFrame, reading the ScrollView's
            // own width) now matches exactly what carouselPage's own 4:5
            // fill expects, with nothing left to disagree about.
            .aspectRatio(4 / 5, contentMode: .fit)
            .padding(.horizontal, 20)

            pageDots
        }
    }

    private func carouselPage(_ score: PhotoScore) -> some View {
        ZStack(alignment: .topTrailing) {
            pageImage(score)
                .aspectRatio(4 / 5, contentMode: .fill)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Button {
                remove(score.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(.black.opacity(0.55), in: Circle())
            }
            // Same 12pt-in-from-the-photo's-own-edge position as before --
            // the photo no longer carries its own internal padding (the
            // page padding moved to the ScrollView, above), so this no
            // longer needs the extra 20pt (32 total) to land in the same
            // visual spot.
            .padding(.trailing, 12)
            .padding(.top, 12)
        }
    }

    @ViewBuilder
    private func pageImage(_ score: PhotoScore) -> some View {
        if let image = renderCache[score.id] {
            Image(uiImage: image).resizable()
        } else if let photo = sessionStore.photo(for: score.id) {
            Image(uiImage: photo.thumbnail).resizable()
        } else {
            Color(hex: "EEE9DF")
        }
    }

    private var pageDots: some View {
        HStack(spacing: 6) {
            ForEach(post) { score in
                Circle()
                    .fill(score.id == carouselSelectionID ? Color(hex: "171614") : Color(hex: "DDD6CA"))
                    .frame(width: 6, height: 6)
            }
        }
    }

    // MARK: - Thumbnail strip: drag-to-reorder (native .draggable/.dropDestination)

    private var thumbnailStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(post) { score in
                    thumbnailCell(score)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func thumbnailCell(_ score: PhotoScore) -> some View {
        let isDragging = draggingID == score.id
        return Group {
            if let photo = sessionStore.photo(for: score.id) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(width: 48, height: 60)
                    .clipped()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(score.id == carouselSelectionID ? Color(hex: "A04021") : .clear, lineWidth: 2)
        )
        // "6pt card lift while dragging" (UI_NOTES §4).
        .offset(y: isDragging ? -6 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.18 : 0), radius: 6, y: 3)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isDragging)
        .onTapGesture {
            withAnimation { carouselSelectionID = score.id }
        }
        .draggable(score.id.uuidString) {
            if let photo = sessionStore.photo(for: score.id) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(width: 48, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
        .dropDestination(for: String.self) { items, _ in
            guard
                let draggedIDString = items.first,
                let draggedID = UUID(uuidString: draggedIDString),
                let fromIndex = post.firstIndex(where: { $0.id == draggedID }),
                let toIndex = post.firstIndex(where: { $0.id == score.id }),
                fromIndex != toIndex
            else { return false }
            let destination = toIndex > fromIndex ? toIndex + 1 : toIndex
            sessionStore.movePost(fromOffsets: IndexSet(integer: fromIndex), toOffset: destination)
            return true
        } isTargeted: { targeted in
            draggingID = targeted ? score.id : nil
        }
    }

    // MARK: - "what we left out" (UI_NOTES fix 9/10)

    private var runnerUpRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("what we left out")
                .font(.duvroLabel)
                .foregroundStyle(Color(hex: "171614"))
                .padding(.horizontal, 20)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(sessionStore.runnerUps) { score in
                        runnerUpCell(score)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }

    private func runnerUpCell(_ score: PhotoScore) -> some View {
        ZStack(alignment: .topTrailing) {
            if let photo = sessionStore.photo(for: score.id) {
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .frame(width: 72, height: 90)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            // Persistent, always-visible + -- the mockup reveals this on
            // hover, which doesn't exist on iOS (UI_NOTES fix 9). Inset
            // via padding, not offset -- an offset badge visually paints
            // outside this ZStack's own reported bounds (72x90, the
            // image's frame), and since this cell sits inside a horizontal
            // ScrollView, the badge got clipped by the scroll view's own
            // bounds and overlapped the row above (carouselPage's "x"
            // button already uses the same inset-padding pattern, safely).
            Button {
                addRunnerUp(score)
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(Color(hex: "A04021"), in: Circle())
            }
            .padding(4)
        }
    }

    // MARK: - Primary CTA (UI_NOTES §6: "add a caption", not "save the collection")

    private var primaryButton: some View {
        Button {
            onContinue()
        } label: {
            Text("add a caption")
                .font(.duvroButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "171614"))
                .clipShape(Capsule())
        }
        .disabled(post.isEmpty)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    // MARK: - Actions

    private func remove(_ id: UUID) {
        sessionStore.removeFromPost(id)
        if carouselSelectionID == id {
            carouselSelectionID = post.first(where: { $0.id != id })?.id
        }
    }

    /// Tap a runner-up's +: add if there's room, else replace whichever
    /// photo is currently centered in the carousel. DECISION (flagged, not
    /// asked): the spec says "add if under count, else replace" but doesn't
    /// say WHICH photo a replace targets. "Whatever you're currently
    /// looking at" is the most direct, discoverable choice without a
    /// separate picker UI. Either way, the incoming photo routes through
    /// the scoped 3-way edit before it joins -- see the fullScreenCover.
    private func addRunnerUp(_ score: PhotoScore) {
        if post.count < FallbackSelectionService.fallbackCount {
            pendingRunnerUp = PendingRunnerUp(id: score.id, score: score, replacing: nil)
        } else {
            let replacing = carouselSelectionID ?? post.last?.id
            pendingRunnerUp = PendingRunnerUp(id: score.id, score: score, replacing: replacing)
        }
    }

    private func renderMissing() {
        let variants = pack.variants
        for score in post {
            guard renderCache[score.id] == nil, let photo = sessionStore.photo(for: score.id) else { continue }
            // Falls back to variant 0 (Sun-kissed) if this photo has no
            // committed pick yet -- only reachable via the debug launch
            // path straight into Final Review, which skips Phase 5 entirely
            // (see duvroApp's DebugLaunchRootView). The real flow always
            // commits a pick in Phase 5 before a photo can reach here.
            let variantName = sessionStore.pickedVariantName[score.id]
            guard let variant = variants.first(where: { $0.name == variantName }) ?? variants.first else { continue }
            Task {
                let image = await Task.detached(priority: .userInitiated) {
                    EditEngine.render(photo: photo, variant: variant)
                }.value
                renderCache[score.id] = image
            }
        }
        let keep = Set(post.map(\.id))
        renderCache = renderCache.filter { keep.contains($0.key) }
    }
}
