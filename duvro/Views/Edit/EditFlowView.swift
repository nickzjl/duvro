//
//  EditFlowView.swift
//  duvro
//
//  Phase 5, "the signature interaction" (BUILD_ROADMAP Phase 5, prd.md §4
//  step 7, UI_NOTES fixes 1/2/11/14 + §6). Layout is the approved mockup
//  layout (design/09_three_way_edit_1.png) -- ONE large 4:5 photo, three
//  variant pills below, not a three-up grid.
//
//  ADVANCE MECHANIC (the part to get exactly right, per UI_NOTES fix 1):
//  tapping a pill or swiping the photo only changes which variant is
//  DISPLAYED -- pill and photo stay in sync, neither action advances to
//  the next photo. Only "keep this one" commits the displayed variant and
//  advances. "skip this photo" removes the current pick and backfills
//  (SessionStore.skipPhoto). Back returns to the previous photo with its
//  pick intact and re-editable (displayedVariantIndex re-seeds from
//  SessionStore.pickedVariantName, not reset to 0).
//
//  The "advanced" control (intensity/brightness/contrast/crop sheet) is
//  explicitly OUT OF SCOPE this session -- UI_NOTES §5's no-dimming/no-blur
//  requirement has an unverified open question
//  (.presentationBackgroundInteraction(.enabled) actually removing
//  SwiftUI's default sheet dimming) that needs verifying awake, not guessed
//  at 5am. DECISION (flagged, not asked): omitted entirely rather than
//  shown-but-inert -- a visibly dead control reads as broken; no control at
//  all reads as "not built yet," which is the truth this session.
//

import SwiftUI

struct EditFlowView: View {
    var sessionStore: SessionStore
    let pack: VibePack
    /// When set, edits ONLY this one photo instead of the whole session
    /// post -- Final Review's "newly added runner-ups route through the
    /// 3-way edit before joining the post" requirement (UI_NOTES/
    /// BUILD_ROADMAP Phase 6) reuses this same screen/interaction rather
    /// than a second implementation, scoped to a single photo. Back and
    /// skip don't make sense for a photo that isn't in the post yet, so
    /// they're hidden in this mode (see topBar/utilityRow).
    var scopedTo: PhotoScore? = nil
    /// Called once every photo in scope has a committed pick. For the main
    /// flow: Phase 6 (final review) is where this should navigate. For a
    /// scoped single-photo edit: the caller is expected to splice the photo
    /// into the post (SessionStore.addRunnerUp) here.
    var onComplete: () -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var currentIndex = 0
    @State private var displayedVariantIndex = 0
    /// photoID -> [rendered variant 0, 1, 2], in pack.variants order.
    /// Populated for current + next photo ONLY (see pre-render policy in
    /// the handoff report) -- pruned every time currentIndex changes.
    @State private var renderCache: [UUID: [UIImage]] = [:]
    @State private var dragTranslation: CGFloat = 0
    @State private var usedHeadlines: Set<String> = []
    @State private var currentHeadline = ""

    private let swipeThreshold: CGFloat = 60

    private var isScoped: Bool { scopedTo != nil }
    private var post: [PhotoScore] { scopedTo.map { [$0] } ?? sessionStore.post }
    private var currentScore: PhotoScore? {
        guard post.indices.contains(currentIndex) else { return nil }
        return post[currentIndex]
    }
    private var currentPhoto: Photo? {
        currentScore.flatMap { sessionStore.photo(for: $0.id) }
    }
    private var nextScore: PhotoScore? {
        post.indices.contains(currentIndex + 1) ? post[currentIndex + 1] : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            if let currentPhoto, let currentScore {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        headlineBlock
                        photoStage(photo: currentPhoto, score: currentScore)
                        pillRow
                        if !isScoped {
                            utilityRow
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                // .safeAreaInset (not a fixed padding guess) reserves exactly
                // the sticky CTA's real height + the device's safe area,
                // whatever that is on a given device -- UI_NOTES fix 5's
                // requirement, satisfied structurally rather than with a
                // hand-tuned magic number that could drift out of sync with
                // the button's actual size.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    primaryButton
                }
            } else {
                completeState
            }
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .onAppear { enterPhoto(resetVariant: true) }
        .onChange(of: currentIndex) { _, _ in enterPhoto(resetVariant: true) }
    }

    // MARK: - Top bar (back control + progress, UI_NOTES fix 2 + §6)

    private var topBar: some View {
        HStack {
            Button {
                if isScoped {
                    dismiss()
                } else {
                    goBack()
                }
            } label: {
                Image(systemName: isScoped ? "xmark" : "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "171614"))
                    .frame(width: 44, height: 44)
            }
            .disabled(!isScoped && currentIndex == 0)
            .opacity(!isScoped && currentIndex == 0 ? 0.3 : 1)

            Spacer()

            if !isScoped, !post.isEmpty {
                Text("\(min(currentIndex + 1, post.count)) of \(post.count)")
                    .font(.duvroLabel)
                    .foregroundStyle(Color(hex: "777169"))
            }

            Spacer()

            // Balances the back control so the progress text stays centered.
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Headline (UI_NOTES fix 14/15: tied to category, no repeats this session)

    private var headlineBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(currentHeadline)
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text("how should we render it?")
                .font(.duvroSerifItalic)
                .foregroundStyle(Color(hex: "777169"))
        }
    }

    // MARK: - Photo stage: the single 4:5 photo + swipe-between-variants

    private func photoStage(photo: Photo, score: PhotoScore) -> some View {
        let displayedImage = renderCache[photo.id]?[safe: displayedVariantIndex]
        return ZStack {
            if let displayedImage {
                Image(uiImage: displayedImage)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
                    .id(displayedVariantIndex) // forces a crossfade on variant change
                    .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            } else {
                // Rendering hasn't finished yet -- show the thumbnail rather
                // than a blank frame, same fail-safe spirit as EditEngine.
                Image(uiImage: photo.thumbnail)
                    .resizable()
                    .aspectRatio(4 / 5, contentMode: .fill)
            }
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(4 / 5, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .offset(x: dragTranslation * 0.15) // subtle drag-follow, not a page-turn
        .gesture(
            DragGesture(minimumDistance: 10)
                .onChanged { value in dragTranslation = value.translation.width }
                .onEnded { value in
                    let translation = value.translation.width
                    dragTranslation = 0
                    if translation < -swipeThreshold {
                        selectVariant(min(displayedVariantIndex + 1, pack.variants.count - 1))
                    } else if translation > swipeThreshold {
                        selectVariant(max(displayedVariantIndex - 1, 0))
                    }
                }
        )
        .animation(.easeOut(duration: 0.2), value: dragTranslation)
    }

    // MARK: - Variant pills (UI_NOTES fix 11: terracotta selected state, never black)

    private var pillRow: some View {
        HStack(spacing: 8) {
            ForEach(Array(pack.variants.enumerated()), id: \.element.id) { index, variant in
                let isSelected = index == displayedVariantIndex
                Button {
                    selectVariant(index)
                } label: {
                    // `.lineLimit(2, reservesSpace: true)` alone reserved the
                    // right HEIGHT (every pill 2 lines tall regardless of
                    // whether its own name needs one or two -- "kodak
                    // style"/"deep teal" vs. "faded postcard") but Text pins
                    // its actual glyphs to the TOP of that reserved space,
                    // not the center -- single-line names read top-aligned.
                    // Fix: an invisible two-line reference Text sets the
                    // ZStack's height, and the real (possibly shorter) label
                    // is centered within it by ZStack's default alignment.
                    // Still never truncates (UI_NOTES fix 3): nothing today
                    // needs a 3rd line, and neither Text imposes a limit.
                    ZStack {
                        Text("A\nA")
                            .font(.duvroVariantLabel)
                            .opacity(0)
                            .accessibilityHidden(true)
                        Text(variant.name.lowercased())
                            .font(.duvroVariantLabel)
                            .foregroundStyle(isSelected ? Color(hex: "A04021") : Color(hex: "777169"))
                            .multilineTextAlignment(.center)
                    }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        .frame(maxWidth: .infinity)
                        .background(
                            Capsule()
                                .strokeBorder(isSelected ? Color(hex: "A04021") : Color(hex: "DDD6CA"), lineWidth: isSelected ? 1.5 : 1)
                        )
                        .background(Color(hex: "FFFCF7"), in: Capsule())
                }
                .buttonStyle(.plain)
                .scaleEffect(isSelected ? 1.03 : 1.0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: displayedVariantIndex)
            }
        }
    }

    // MARK: - Skip (advanced control intentionally omitted -- see file header)

    private var utilityRow: some View {
        HStack {
            Button("skip this photo") {
                skip()
            }
            .font(.duvroCaption)
            .foregroundStyle(Color(hex: "777169"))

            Spacer()
        }
    }

    // MARK: - Primary CTA (UI_NOTES §6: "keep this one", not "save and continue")

    private var primaryButton: some View {
        Button {
            keepThisOne()
        } label: {
            Text("keep this one")
                .font(.duvroButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "171614"))
                .clipShape(Capsule())
        }
        .disabled(renderCache[currentPhoto?.id ?? UUID()] == nil)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    private var completeState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text("all set.")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear { onComplete() }
    }

    // MARK: - Navigation

    private func goBack() {
        guard currentIndex > 0 else { return }
        currentIndex -= 1
    }

    private func keepThisOne() {
        guard let currentScore, let variantName = pack.variants[safe: displayedVariantIndex]?.name else { return }
        sessionStore.pickVariant(variantName, forPhotoID: currentScore.id)
        currentIndex += 1
    }

    private func skip() {
        guard let currentScore else { return }
        sessionStore.skipPhoto(currentScore.id)
        // postOrder just changed shape under us -- re-enter at the same
        // index (now either a backfilled photo or, if the post shrank, the
        // next one along) rather than incrementing, since nothing was kept.
        renderCache.removeValue(forKey: currentScore.id)
        enterPhoto(resetVariant: true)
    }

    private func selectVariant(_ index: Int) {
        guard index != displayedVariantIndex, pack.variants.indices.contains(index) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            displayedVariantIndex = index
        }
    }

    /// Re-seeds displayedVariantIndex (from any prior pick, else variant 0),
    /// picks this photo's headline, and kicks off pre-rendering for
    /// current + next while pruning everything else from the cache.
    private func enterPhoto(resetVariant: Bool) {
        guard let currentScore else { return }
        if resetVariant {
            if let pickedName = sessionStore.pickedVariantName[currentScore.id],
               let index = pack.variants.firstIndex(where: { $0.name == pickedName }) {
                displayedVariantIndex = index
            } else {
                displayedVariantIndex = 0
            }
        }
        currentHeadline = Self.headline(for: currentScore.category, excluding: usedHeadlines)
        usedHeadlines.insert(currentHeadline)

        // Diagnostic, not a fix: pairs with the print in
        // SessionStore.skipPhoto -- that one reports what the DATA layer
        // computed for a given skip; this one reports what this SCREEN is
        // actually about to display for the same skip (this fires right
        // after skip() calls sessionStore.skipPhoto then enterPhoto). If
        // the two disagree -- e.g. skipPhoto logs a fresh backfill ID but
        // this logs the SAME currentScore.id as a prior entry -- the bug is
        // in this view's rendering, not the data. If they agree and still
        // don't match what's on screen, the running binary predates the
        // source currently in the repo.
        #if DEBUG
        print("[edit-flow] currentIndex=\(currentIndex), post.count=\(post.count), showing \(currentScore.id.uuidString.prefix(8))")
        #endif

        let currentID = currentScore.id
        let nextID = nextScore?.id
        Task {
            await ensureRendered(photoID: currentID)
            if let nextID {
                await ensureRendered(photoID: nextID)
            }
            let keep = Set([currentID, nextID].compactMap { $0 })
            renderCache = renderCache.filter { keep.contains($0.key) }
        }
    }

    /// Off the main actor (EditEngine is nonisolated/stateless) so a slow
    /// render never blocks scrolling/interaction, even though Golden Hour
    /// measured 8-17ms/variant on device (BUILD_ROADMAP Phase 4) -- this
    /// pack's speed isn't assumed to hold for every future pack.
    private func ensureRendered(photoID: UUID) async {
        guard renderCache[photoID] == nil, let photo = sessionStore.photo(for: photoID) else { return }
        let variants = pack.variants
        let rendered = await Task.detached(priority: .userInitiated) {
            variants.map { EditEngine.render(photo: photo, variant: $0) }
        }.value
        renderCache[photoID] = rendered
    }

    // MARK: - Headlines

    private static let headlinesByCategory: [PhotoCategory: [String]] = [
        .people: [
            "this one feels special.",
            "you all look good here.",
            "a moment worth keeping.",
            "this is the one you'll screenshot.",
            "caught you being happy.",
            "some things are worth freezing in time."
        ],
        .place: [
            "there's beauty in this.",
            "the view speaks for itself.",
            "worth the trip, clearly.",
            "a little postcard energy.",
            "you were there, and it shows.",
            "some places just hit different."
        ],
        .food: [
            "almost too good to post.",
            "this one earned its spot.",
            "you know exactly how good this tasted.",
            "worth the wait, apparently.",
            "a plate worth remembering.",
            "this is the flex, honestly."
        ],
        .detail: [
            "there's beauty in this.",
            "the little things, noticed.",
            "a detail worth a second look.",
            "sometimes it's the small stuff.",
            "you have a good eye.",
            "not everything needs a big moment."
        ]
    ]

    /// Random within category, no repeats this session as long as the bank
    /// isn't exhausted -- if a single dump has more photos of one category
    /// than this bank has lines (bank is 6 deep; dumps cap at 20), repeats
    /// rather than crashes.
    private static func headline(for category: PhotoCategory, excluding used: Set<String>) -> String {
        let bank = headlinesByCategory[category] ?? ["this one feels special."]
        let fresh = bank.filter { !used.contains($0) }
        return (fresh.isEmpty ? bank : fresh).randomElement() ?? bank[0]
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
