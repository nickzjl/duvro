//
//  CurationSequenceView.swift
//  duvro
//
//  Phase 9/10, prd.md §4 steps 5-6, UI_NOTES §4 "Curation progress" +
//  "Curation showcase". ONE continuous view with two phases
//  (.shuffling, .collage), not two screens with a navigation transition
//  between them -- UI_NOTES §4: "the progress screen and the showcase
//  are one continuous moment. Same card treatment, same photos; the
//  stack resolves into the collage rather than cutting to a new
//  screen." Card treatment (print-bordered, white border thin on
//  sides/top thicker at bottom) is WelcomeView's own printCard styling,
//  reused via PrintCard below rather than reinvented -- exact numbers
//  copied from WelcomeView.swift: inner photo corner radius 4pt, outer
//  card corner radius 10pt, side border 8pt, bottom border 26pt, card
//  background #FFFCF7, shadow black 10%/blur 14/y+6.
//
//  WHICH PHOTOS SHUFFLE (the product decision this screen turns on): at
//  the moment this view appears (i.e. the instant "use this vibe" was
//  tapped), it takes a ONE-TIME SNAPSHOT of sessionStore.scores --
//  whatever Vision has finished scoring so far -- ranked by
//  compositeScore, best first, filtered to non-rejected. That snapshot
//  is what shuffles. It does NOT grow live as more scores land (Task 1
//  runs scoring in the background, but this screen samples a single
//  instant rather than re-ranking continuously) -- "you are sampling
//  the ranking, not waiting for it or stopping it."
//
//  REAL WORK, separately: waits for sessionStore.isScoring to go false
//  (or, for every DEBUG launch path, it already is false -- those never
//  touch a live ScoringService, only DebugFixture's already-complete
//  scores), THEN runs the exact same ShortlistService ->
//  FallbackSelectionService -> RunnerUpService pipeline every other
//  entry point in this codebase already uses, against the FULL, by-then
//  -complete sessionStore.scores -- never a partial snapshot. This can
//  finish anywhere from ~0s (scoring already done by tap time, the
//  common case once Task 1 gives it a head start) up to however long
//  scoring takes.
//
//  DEBUG MINIMUM: debugMinimumDuration below is the ONE constant to
//  change to retime this screen for testing -- with no network call
//  yet, real work is usually near-instant, so without a floor this
//  screen would flash by (see its own doc comment). Release has NO
//  floor: "the screen lasts exactly as long as the real work takes."
//
//  STATUS COPY: settled -- UI_NOTES §4's 2nd line is "finding familiar
//  faces…". Two replacements were tried and rejected during this
//  screen's build ("sorting the moments…", "counting who's with you…"),
//  both more mechanically accurate to what Stage 2 actually runs now
//  that identity clustering is gone, but the product call is that warm
//  and reads-well beats literal accuracy here. See UI_NOTES §4's own
//  note for the same conclusion.
//
//  SHOWCASE VARIANT DECISION: renders showcase cards across ALL THREE
//  of the chosen pack's variants, cycling in finalSelection order
//  (card i -> pack.variants[i % pack.variants.count]) rather than
//  assigning randomly -- this guarantees every variant appears and none
//  clusters together regardless of n. Card 0 -- CollageLayout's
//  front-and-center, largest, top-z-order slot, and finalSelection's
//  strongest photo since it's composite-ranked -- always gets
//  pack.variants[0], the pack's signature look, so the most prominent
//  card leads with it. Reasoning: the collage is the hook, and variety
//  within one aesthetic (a Y2K date stamp next to a Polaroid frame next
//  to a light leak, for Digicam) is more compelling than n cards at the
//  same grade. PERFORMANCE: this is NOT 3x the render work -- each
//  photo still renders exactly once (in its assigned variant, not all
//  three), so the total render count is unchanged from the
//  single-variant version, still ~n renders at 8-17ms/render measured
//  elsewhere in this codebase, comfortably absorbed by the shuffle
//  phase's runway. Rendered off-thread as soon as the final selection
//  is known (well before the collage phase begins). Falls back to the
//  photo's own thumbnail (EditFlowView's same fail-safe pattern) for
//  any card whose render isn't ready yet.
//
//  CONTINUOUS TRANSITION (Task 4, the hard part): cards that are both
//  (a) in the shuffle snapshot's currently-visible window at resolve
//  time and (b) in the final selection carry through via
//  matchedGeometryEffect (one shared @Namespace, keyed by PhotoScore.id,
//  used in both phases) -- they animate from their shuffle position
//  straight into their collage slot rather than fading out and a new
//  card fading in. Every other final-selection card runs the normal
//  per-card reveal (1.2s ease-out, opacity 0->1, offset y+10->0,
//  UI_NOTES' own adaptive stagger).
//

import SwiftUI

struct CurationSequenceView: View {
    var sessionStore: SessionStore
    let pack: VibePack
    let count: Int
    /// Fires once the showcase's reveal sequence completes -- caller
    /// advances to the first edit screen (prd.md §4: "flow the user
    /// directly into editing... no accept/reject step here").
    var onComplete: () -> Void

    /// THE constant to change for DEBUG testing -- see file header.
    /// #if DEBUG only; Release has no floor at all.
    #if DEBUG
    private let debugMinimumDuration: Double = 6.0
    #endif

    private enum Phase {
        case shuffling
        case collage
    }

    @State private var phase: Phase = .shuffling
    @Namespace private var cardNamespace

    // MARK: - Shuffle snapshot + deck state

    /// Taken ONCE, in .task, at view-appear -- see file header.
    @State private var shuffleSnapshot: [PhotoScore] = []
    /// Advances every 1s (shuffleTick) -- see ShuffleDeck below for how
    /// this drives each visible card's rotation slot.
    @State private var shuffleTick = 0
    @State private var shuffleTimerTask: Task<Void, Never>?

    // MARK: - Status copy + progress line

    private static let statusLines = [
        "removing duplicates…",
        "finding familiar faces…", // settled -- see file header
        "analyzing visual composition…",
        "curating the narrative…"
    ]
    @State private var statusLineIndex = 0
    @State private var statusTimerTask: Task<Void, Never>?
    @State private var progressFraction: Double = 0
    @State private var progressTimerTask: Task<Void, Never>?

    // MARK: - Real work

    @State private var minimumElapsed = false
    @State private var realWorkDone = false
    @State private var finalSelection: [PhotoScore] = []
    @State private var renderedImages: [UUID: UIImage] = [:]

    // MARK: - Showcase reveal state

    @State private var revealedCardIDs: Set<UUID> = []
    /// Card IDs that carried through from the shuffle deck -- these
    /// start the collage phase ALREADY revealed (matched-geometry
    /// animates their position/rotation instead of fading in).
    @State private var carriedThroughIDs: Set<UUID> = []

    var body: some View {
        ZStack {
            Color(hex: "F7F4EE").ignoresSafeArea()

            if phase == .shuffling {
                shufflingPhase
                    .transition(.identity) // no separate screen transition -- see file header
            } else {
                collagePhase
            }
        }
        .task {
            startSequence()
        }
        .onDisappear {
            shuffleTimerTask?.cancel()
            statusTimerTask?.cancel()
            progressTimerTask?.cancel()
        }
    }

    // MARK: - Shuffling phase

    private var shufflingPhase: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            ShuffleDeck(snapshot: shuffleSnapshot, tick: shuffleTick, namespace: cardNamespace, photoLookup: { sessionStore.photo(for: $0)?.thumbnail })
                .frame(height: 380)
            Spacer(minLength: 32)
            VStack(spacing: 20) {
                Text("finding the moments that belong together.")
                    .font(.duvroHeadline)
                    .foregroundStyle(Color(hex: "171614"))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                Text(Self.statusLines[statusLineIndex])
                    .font(.duvroSubheadline)
                    .foregroundStyle(Color(hex: "777169"))
                    .id(statusLineIndex)
                    .transition(.opacity.animation(.easeInOut(duration: 0.5)))

                progressLine
            }
            Spacer(minLength: 60)
        }
    }

    private var progressLine: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color(hex: "DDD6CA"))
                    .frame(height: 3)
                Capsule()
                    .fill(Color(hex: "A04021"))
                    .frame(width: geo.size.width * progressFraction, height: 3)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(width: 160, height: 3)
    }

    // MARK: - Collage phase

    private var collagePhase: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text("our favorites")
                .font(.duvroDisplay)
                .foregroundStyle(Color(hex: "171614"))
            Spacer(minLength: 12)
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(finalSelection.enumerated()), id: \.element.id) { index, score in
                        let slot = CollageLayout.slot(index: index, total: finalSelection.count, in: geo.size)
                        collageCard(score: score, slot: slot)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 40)
        }
    }

    private func collageCard(score: PhotoScore, slot: CollageLayout.Slot) -> some View {
        let revealed = revealedCardIDs.contains(score.id)
        let image = renderedImages[score.id] ?? sessionStore.photo(for: score.id)?.thumbnail
        return Group {
            if let image {
                PrintCard(image: image, size: slot.size)
            } else {
                PrintCard(image: nil, size: slot.size)
            }
        }
        .matchedGeometryEffect(id: score.id, in: cardNamespace)
        .rotationEffect(.degrees(0)) // UI_NOTES §4: showcase rotation is 0°, unlike the shuffle deck
        .position(x: slot.center.x, y: slot.center.y)
        .zIndex(slot.zIndex)
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 10)
        .animation(.easeOut(duration: 1.2), value: revealed)
    }

    // MARK: - Sequencing

    private func startSequence() {
        // Snapshot: whatever's scored RIGHT NOW, ranked, non-rejected --
        // see file header. Taken once; never re-read after this.
        shuffleSnapshot = sessionStore.scores
            .filter { !$0.isHardRejected }
            .sorted { $0.compositeScore > $1.compositeScore }

        startShuffleTimer()
        startStatusTimer()
        startProgressCreep()

        #if DEBUG
        Task {
            try? await Task.sleep(for: .seconds(debugMinimumDuration))
            minimumElapsed = true
            checkReadyToResolve()
        }
        #else
        minimumElapsed = true // no floor in Release -- see file header
        #endif

        Task {
            await runRealWork()
        }
    }

    private func startShuffleTimer() {
        shuffleTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 1.0)) {
                    shuffleTick += 1
                }
            }
        }
    }

    private func startStatusTimer() {
        statusTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    statusLineIndex = (statusLineIndex + 1) % Self.statusLines.count
                }
            }
        }
    }

    /// Self-pacing asymptotic creep toward 92% -- no fixed target
    /// duration assumed (Release's real duration is unknown ahead of
    /// time), so this just keeps nudging toward the ceiling for as long
    /// as `checkReadyToResolve` hasn't fired the final 100% + resolve.
    /// In DEBUG this naturally paces to debugMinimumDuration, since the
    /// loop only stops once BOTH gates (real work done AND the minimum
    /// elapsed) are true -- real work alone finishing early (the
    /// typical DEBUG case) doesn't stop it. See file header.
    private func startProgressCreep() {
        progressTimerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(600))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.6)) {
                    progressFraction += (0.92 - progressFraction) * 0.3
                }
            }
        }
    }

    private func runRealWork() async {
        // Wait for scoring to actually finish (or, every DEBUG launch
        // path: it already has -- see file header) before running
        // selection against the FULL score set, never a partial one.
        while sessionStore.isScoring {
            try? await Task.sleep(for: .milliseconds(100))
        }

        let shortlist = ShortlistService.buildShortlist(from: sessionStore.scores)
        sessionStore.setShortlist(shortlist)
        let chosen = FallbackSelectionService.select(from: shortlist, count: count)
        sessionStore.setChosenSelection(chosen)
        sessionStore.setRunnerUps(RunnerUpService.compute(shortlist: shortlist, chosen: chosen.selected))
        finalSelection = chosen.selected

        // Kick off rendering immediately, off-thread, so it's ready (or
        // close to it) by the time the collage phase actually reveals
        // each card. Cycles through all three of the pack's variants in
        // finalSelection order -- card 0 (front-and-center) gets
        // variants[0], the signature look -- rather than rendering every
        // card in the same one. See file header's SHOWCASE VARIANT
        // DECISION for why, and its PERFORMANCE note for why this is
        // still ~n renders total, not 3n.
        if !pack.variants.isEmpty {
            let assignments = finalSelection.enumerated().compactMap { index, score -> (UUID, Photo, EditVariant)? in
                guard let photo = sessionStore.photo(for: score.id) else { return nil }
                return (score.id, photo, pack.variants[index % pack.variants.count])
            }
            let rendered = await Task.detached(priority: .userInitiated) {
                Dictionary(uniqueKeysWithValues: assignments.map { id, photo, variant in
                    (id, EditEngine.render(photo: photo, variant: variant))
                })
            }.value
            renderedImages = rendered
        }

        realWorkDone = true
        checkReadyToResolve()
    }

    private func checkReadyToResolve() {
        guard realWorkDone, minimumElapsed, phase == .shuffling else { return }
        shuffleTimerTask?.cancel()
        statusTimerTask?.cancel()
        progressTimerTask?.cancel()
        withAnimation(.easeOut(duration: 0.3)) {
            progressFraction = 1.0
        }
        resolveIntoCollage()
    }

    /// Cards visible in the shuffle deck's current window AND present in
    /// finalSelection carry through (matchedGeometryEffect handles the
    /// actual animation, since both phases key the same view by
    /// PhotoScore.id in the same @Namespace) -- everything else in
    /// finalSelection runs the adaptive-stagger reveal from file
    /// header/UI_NOTES §4's exact formula.
    private func resolveIntoCollage() {
        let visibleInDeck = Set(ShuffleDeck.visibleIDs(snapshot: shuffleSnapshot, tick: shuffleTick))
        let finalIDs = Set(finalSelection.map(\.id))
        carriedThroughIDs = visibleInDeck.intersection(finalIDs)
        revealedCardIDs = carriedThroughIDs

        phase = .collage

        let n = finalSelection.count
        guard n > 0 else {
            onComplete()
            return
        }

        let toReveal = finalSelection.map(\.id).filter { !carriedThroughIDs.contains($0) }
        guard n > 1 else {
            // Guard n=1 separately (UI_NOTES §4): no stagger to compute,
            // just the first card's own delay + animation.
            revealSequentially(ids: toReveal, firstDelay: 0.1, stagger: 0, cardAnimation: 1.2)
            return
        }
        let stagger = min(max((3.4 - 1.3) / Double(n - 1), 0.10), 0.28)
        revealSequentially(ids: toReveal, firstDelay: 0.1, stagger: stagger, cardAnimation: 1.2)

        let total = 0.1 + Double(n - 1) * stagger + 1.2
        Task {
            try? await Task.sleep(for: .seconds(total))
            onComplete()
        }
    }

    private func revealSequentially(ids: [UUID], firstDelay: Double, stagger: Double, cardAnimation: Double) {
        guard !ids.isEmpty else { return }
        Task {
            try? await Task.sleep(for: .seconds(firstDelay))
            for id in ids {
                guard !Task.isCancelled else { return }
                revealedCardIDs.insert(id)
                try? await Task.sleep(for: .seconds(stagger))
            }
        }
    }
}

// MARK: - Print-bordered card (WelcomeView's exact treatment, reused)

private struct PrintCard: View {
    let image: UIImage?
    let size: CGSize

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(hex: "EEE9DF")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 26)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 14, x: 0, y: 6)
    }
}

// MARK: - Shuffle deck (curation progress)

/// 4-slot carousel: -10°/-5°/0°(front, upright)/+10°(exiting). Every
/// `tick`, the front card rotates out to +10° and fades, each stacked
/// card advances one slot toward the front, and a new card enters at
/// -10° -- see this file's own header for the full reasoning. Keyed by
/// snapshot INDEX (`.id`), not by tick, so the same card view animates
/// smoothly between rotation slots as `tick` advances rather than
/// teleporting between separately-identified views.
private struct ShuffleDeck: View {
    let snapshot: [PhotoScore]
    let tick: Int
    let namespace: Namespace.ID
    /// ShuffleDeck only has PhotoScore (id + metrics) to work with --
    /// this resolves the actual thumbnail to render, same lookup
    /// SessionStore.photo(for:) already provides, passed in rather than
    /// handing this view a whole SessionStore dependency for one lookup.
    let photoLookup: (UUID) -> UIImage?

    /// slotsAgo -> rotation degrees. 0 = just entered (back), 3 = exiting.
    private static let rotationBySlot: [Int: Double] = [0: -10, 1: -5, 2: 0, 3: 10]
    private static let scaleBySlot: [Int: Double] = [0: 0.9, 1: 0.95, 2: 1.0, 3: 0.95]

    var body: some View {
        ZStack {
            if !snapshot.isEmpty {
                ForEach(Self.visibleSlots(count: snapshot.count, tick: tick), id: \.snapshotIndex) { slot in
                    let score = snapshot[slot.snapshotIndex]
                    PrintCard(image: photoLookup(score.id), size: CGSize(width: 220, height: 275))
                        .matchedGeometryEffect(id: score.id, in: namespace)
                        .rotationEffect(.degrees(Self.rotationBySlot[slot.slotsAgo] ?? 0))
                        .scaleEffect(Self.scaleBySlot[slot.slotsAgo] ?? 1)
                        .opacity(slot.slotsAgo == 3 ? 0 : 1) // exiting card fades rather than popping out
                        .zIndex(Double(3 - slot.slotsAgo))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    struct VisibleSlot { let snapshotIndex: Int; let slotsAgo: Int }

    static func visibleSlots(count: Int, tick: Int) -> [VisibleSlot] {
        guard count > 0 else { return [] }
        return (0...3).compactMap { slotsAgo in
            let rawIndex = tick - slotsAgo
            guard rawIndex >= 0 else { return nil }
            let index = rawIndex % count
            return VisibleSlot(snapshotIndex: index, slotsAgo: slotsAgo)
        }
    }

    static func visibleIDs(snapshot: [PhotoScore], tick: Int) -> [UUID] {
        visibleSlots(count: snapshot.count, tick: tick).map { snapshot[$0.snapshotIndex].id }
    }
}

// MARK: - Collage layout (curation showcase)

/// Scales card size/overlap with `total` (4...20 per prd.md §4 step 3) --
/// n=4 gets large, heavily overlapped cards; n=20 gets smaller, denser
/// ones. Deliberately a fixed, hand-placed arrangement per count TIER
/// rather than a formula that degrades smoothly, since "fixed collage,
/// not a grid" (UI_NOTES §4) is itself the spec -- see `slot(index:total:in:)`.
private enum CollageLayout {
    struct Slot {
        let center: CGPoint
        let size: CGSize
        let zIndex: Double
    }

    /// Base card size at n=4 (largest) down to n=20 (smallest), linearly
    /// interpolated by count so every n in between scales continuously
    /// rather than jumping between hardcoded tiers.
    private static func baseCardSize(for total: Int, in bounds: CGSize) -> CGSize {
        let t = Double(max(0, min(total, 20) - 4)) / 16.0 // 0 at n=4, 1 at n=20
        let widthFraction = 0.62 - t * 0.22 // 62% of bounds width at n=4, down to 40% at n=20
        let width = bounds.width * widthFraction
        return CGSize(width: width, height: width * 5 / 4) // 4:5 photos throughout
    }

    /// Deterministic pseudo-scatter: golden-angle spiral for center
    /// offsets (even, non-repeating coverage of the frame without a
    /// literal grid) plus a small per-index size/z jitter so cards read
    /// as varied, overlapping, hand-placed -- not uniform. Seeded only by
    /// `index`/`total`, so the same selection always lays out the same
    /// way (no visible reshuffling if this is ever recomputed).
    static func slot(index: Int, total: Int, in bounds: CGSize) -> Slot {
        let base = baseCardSize(for: total, in: bounds)
        let center = CGPoint(x: bounds.width / 2, y: bounds.height / 2)
        guard total > 1 else {
            return Slot(center: center, size: base, zIndex: 0)
        }

        // Golden-angle spiral, radius scaled down so the whole spread
        // stays within bounds even at the largest (n=4) card size --
        // more cards (n=20) get a proportionally larger spread radius
        // since their cards are individually smaller.
        let goldenAngle = 137.5 * .pi / 180
        let angle = Double(index) * goldenAngle
        let maxRadiusFraction = 0.16 + 0.22 * (Double(total - 1) / 19.0) // grows with n
        let radius = min(bounds.width, bounds.height) * maxRadiusFraction * (0.35 + 0.65 * (Double(index) / Double(max(total - 1, 1))))

        let x = center.x + radius * cos(angle)
        let y = center.y + radius * sin(angle)

        // Front-and-center prominence for the strongest photo (index 0,
        // composite order today -- see file header / BUILD_ROADMAP Phase
        // 3.5 doc note for the ranking-input plan): largest size, dead
        // center, top z-order. Every other card gets a mild per-index
        // size jitter (varied size, per UI_NOTES §4) and descending
        // z-order (so earlier/stronger photos sit visually on top).
        if index == 0 {
            return Slot(center: center, size: CGSize(width: base.width * 1.18, height: base.height * 1.18), zIndex: Double(total))
        }
        let jitter = 0.85 + 0.3 * abs(sin(Double(index) * 12.9898))
        let size = CGSize(width: base.width * jitter, height: base.height * jitter)
        return Slot(center: CGPoint(x: x, y: y), size: size, zIndex: Double(total - index))
    }
}
