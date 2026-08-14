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
//  clusters together regardless of n. Card 0 -- finalSelection's
//  strongest photo, since it's composite-ranked, and the first card
//  revealed in the bookend reveal order below -- always gets
//  pack.variants[0], the pack's signature look, so the sequence leads
//  with it. Reasoning: the collage is the hook, and variety within one
//  aesthetic (a Y2K date stamp next to a Polaroid frame next to a light
//  leak, for Digicam) is more compelling than n cards at the same
//  grade. PERFORMANCE: this is NOT 3x the render work -- each photo
//  still renders exactly once (in its assigned variant, not all three),
//  so the total render count is unchanged from the single-variant
//  version, still ~n renders at 8-17ms/render measured elsewhere in
//  this codebase, comfortably absorbed by the shuffle phase's runway.
//  Rendered off-thread as soon as the final selection is known (well
//  before the collage phase begins). Falls back to the photo's own
//  thumbnail (EditFlowView's same fail-safe pattern) for any card
//  whose render isn't ready yet.
//
//  REVEAL ORDER + STACKING (redesigned this session -- UI_NOTES §4
//  updated to match; this replaces the old rank-ordered, fixed-z-index
//  behavior described below under CONTINUOUS TRANSITION):
//
//  Each card now fades in ON TOP of whatever's already on screen --
//  zIndex follows ARRIVAL order (revealOrder below), not composite
//  rank, so the sequence reads as a genuine accumulation rather than
//  new cards vanishing behind the first one. That inverts the old
//  behavior, where index 0's fixed top z-order meant every later card
//  actually disappeared behind it.
//
//  Because arrival order now controls visibility, the strongest photo
//  (finalSelection[0], "rank 1") loses its old guarantee of staying on
//  top once later cards land over it -- so rank 1 OPENS the sequence
//  and rank 2 (finalSelection[1]) CLOSES it: revealed dead last, it
//  ends up the topmost, most visible card once the sequence settles,
//  giving the two strongest photos each a moment alone in the
//  spotlight, one at the start and one at the end. Both share
//  CollageLayout's single hero slot (dead center, largest) -- rank 2
//  visually "takes over" that slot from rank 1 at the very end, since
//  slot geometry is keyed by finalSelection index (0 and 1 both map to
//  the hero slot) while stacking is keyed by arrival order, not that
//  index. Every other selected photo reveals in between, in composite
//  order, filling CollageLayout's spiral slots (index 2+).
//
//  CONTINUITY (UI_NOTES §4's "one continuous moment") is preserved
//  ONLY for rank 1: if its card happens to be one of the shuffle
//  deck's currently-visible cards at the instant this phase resolves,
//  matchedGeometryEffect (one shared @Namespace, keyed by
//  PhotoScore.id, used in both phases) carries it straight into the
//  collage instead of fading in fresh -- since rank 1 is first in the
//  reveal order anyway, an instant start doesn't conflict with the
//  ordering guarantee above. No other card gets this treatment,
//  including rank 2: letting a middle-order card or rank 2 appear
//  early would break "rank 1 first, rank 2 last." Every card that
//  doesn't get this treatment runs the normal per-card reveal (opacity
//  0->1, offset y+10->0) at ShowcaseTiming's pacing.
//
//  TIMING: see ShowcaseTiming below -- THE constants to tune this
//  sequence's pacing.
//
//  REBALANCED A SECOND TIME (blur/wash-out fix): an earlier pass's
//  values (1.8s fade, 0.20-0.50s stagger) made the fade LONGER than the
//  stagger, so a card was still mid-fade when the next one landed on
//  top of it, reading as a blurry overlap. Fixed by making the fade
//  SHORT (0.2s) and pinning stagger to always be >= it.
//
//  REBALANCED A THIRD TIME (CHANGE 1 -- melting settle, not a pop):
//  0.2s fixed the blur but reads as cards popping in rather than
//  revealing. cardFadeInDuration is back up, to 0.7s, but NOT a return
//  to the earlier bug -- the fix this time is the CURVE, not just the
//  duration. cardFadeInCurve is a strong ease-out (ease-out-expo,
//  timing-curve control points (0.16, 1, 0.3, 1): monotonic, so it
//  never overshoots): opacity rises to substantially-opaque very early
//  in the 0.7s, then eases through a long, gentle tail. The next
//  card's arrival is still gated the same safe way it always has been
//  -- minStagger is pinned to cardFadeInDuration + 0.1s (unchanged
//  relationship, just following the new duration) -- so by the time
//  the next card lands, this one's nominal animation has already
//  fully finished, not merely "mostly opaque." A subtle scale settle
//  (1.06 -> 1.0, same curve/duration as opacity) rides alongside the
//  existing y-offset, so the card reads as easing into place rather
//  than just fading -- also monotonic, no overshoot, per §4.
//
//  THE DURATION TRADE-OFF THIS TIME, worth naming plainly: minStagger
//  following cardFadeInDuration means it grew from 0.3s to 0.8s, and
//  since n=20 has 19 gaps, that alone is 19 * 0.8s = 15.2s -- total
//  duration at n=20 is now ~16s, not the ~6s the previous pass
//  targeted. This is a direct, expected consequence of prioritizing a
//  genuine melting settle over a hard total-duration cap, not a bug --
//  flagged here and in the handoff so it's a visible trade-off, not a
//  silent regression. n=4-5 stay at the same ~4.45s total as before
//  the fade lengthened (unclamped stagger absorbs the difference);
//  n>=6 is where the floor's growth compounds across more gaps.
//
//  CHANGE 2 -- ROTATION: overrides UI_NOTES §4's earlier "Rotation:
//  0°" (written from the mockup, before the built version was judged
//  too orderly for a "collage"). Each card now gets a small,
//  deterministic tilt (CollageLayout.rotation(for:), seeded by index,
//  decorrelated from the size-jitter seed) within
//  CollageLayout.maxRotationDegrees -- named there rather than in
//  ShowcaseTiming since it's a spatial/layout constant, not a pacing
//  one (ShowcaseTiming is private to this struct; CollageLayout is a
//  sibling type in this file and needed its own visibility to the
//  constant either way). Gentler than the shuffle deck's own -10...+10
//  range, since the collage is the resting state, not mid-shuffle
//  motion -- but nonzero on purpose, so cards that carry through from
//  the deck (rank 1, when deck-visible) settle from a tilt into
//  ANOTHER tilt rather than into dead-upright, which reads more
//  coherent with where they came from. matchedGeometryEffect handles
//  this the same way it already handled the old shuffle-tilt ->
//  upright-0° transition: rotation isn't part of matchedGeometryEffect
//  itself, but changing it inside the same animated phase-swap
//  transaction animates smoothly regardless (confirmed on-device).
//
//  CHANGE 3 -- WIDER SPREAD, SAME CARD SIZE: CollageLayout's spiral
//  used to size its radius from min(bounds.width, bounds.height) --
//  whichever axis was smaller capped BOTH axes' spread, which is what
//  caused cards to cluster in the vertical-middle band instead of
//  using the frame's full height (previously flagged, not yet fixed).
//  Radius is now computed independently per axis (an ellipse sized to
//  the frame's own width/height, not a circle capped by the smaller
//  one) and grown by CollageLayout.collageAreaGrowth (~15% more area,
//  applied as its square root to each linear radius). Both axes are
//  HARD-CLAMPED to never let a card's own edge pass the frame boundary
//  -- a safety invariant, not a hopefully-tuned-conservatively-enough
//  guess -- so "must not clip, n=4 to 20" holds by construction across
//  whatever the real on-device frame size turns out to be, even if
//  collageAreaGrowth is tuned larger later.
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

    /// THE constants to tune the showcase reveal's pacing -- see file
    /// header's TIMING note. UI_NOTES §4 documents this exact formula;
    /// change values here AND there together so the doc and the code
    /// don't drift.
    private enum ShowcaseTiming {
        /// Per-card fade: opacity 0->1, offset y+10->0, scale 1.06->1.0.
        /// Lengthened from a snappy 0.2s into a genuine melting settle
        /// -- see file header CHANGE 1. cardFadeInCurve (below) is what
        /// keeps this safe despite the longer duration: a strong
        /// ease-out that's already substantially opaque well before
        /// this nominal duration ends.
        static let cardFadeInDuration: Double = 0.7
        /// Ease-out-expo: fast rise, long gentle tail. Monotonic
        /// control points (y never exceeds 1) -- never overshoots, per
        /// §4's "no bouncing." See file header CHANGE 1.
        static let cardFadeInCurve = Animation.timingCurve(0.16, 1, 0.3, 1, duration: cardFadeInDuration)
        /// Delay before the first (non-carried-through) card appears.
        static let firstCardDelay: Double = 0.15
        /// stagger = clamp(staggerNumerator / (n - 1), minStagger, maxStagger).
        static let staggerNumerator: Double = 3.6
        /// HARD FLOOR, not a target -- always == cardFadeInDuration +
        /// 0.1s, the same relationship as before cardFadeInDuration was
        /// lengthened this pass (a card must fully finish arriving and
        /// hold before the next lands). Grows automatically with
        /// cardFadeInDuration above -- change that one value, not this
        /// one, when retuning. See file header's DURATION TRADE-OFF
        /// note for what this costs at high n (~16s total at n=20).
        static let minStagger: Double = cardFadeInDuration + 0.1
        /// Unchanged from the previous pass: the per-card interval at
        /// the lowest n (4) stays ~4.45s total either way (this was
        /// 1.2s of pure stagger before; lengthening the fade above just
        /// converts what used to be dead hold time into visible
        /// settling motion, not additional wait). Revisit if the hold
        /// still feels long on-device once the fade is this slow.
        static let maxStagger: Double = 1.2
    }

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
    /// Arrival order, assigned as each card is revealed (0 = first) --
    /// drives z-index (CHANGE 1: cards land ON TOP, not behind -- see
    /// file header REVEAL ORDER + STACKING). Replaces the old
    /// rank-based zIndex that used to live on CollageLayout.Slot.
    @State private var revealOrder: [UUID: Int] = [:]

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
        .rotationEffect(.degrees(slot.rotation)) // CHANGE 2: varied per-card tilt -- see file header / CollageLayout
        .scaleEffect(revealed ? 1.0 : 1.06) // CHANGE 1: subtle scale settle alongside opacity -- see file header
        .position(x: slot.center.x, y: slot.center.y)
        .zIndex(Double(revealOrder[score.id] ?? -1)) // arrival order, not rank -- see file header REVEAL ORDER + STACKING
        .opacity(revealed ? 1 : 0)
        .offset(y: revealed ? 0 : 10)
        .animation(ShowcaseTiming.cardFadeInCurve, value: revealed)
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

    /// Builds the bookend reveal order (CHANGE 2 -- see file header):
    /// rank 1 first, rank 2 last, everything else in between in
    /// composite order. `n <= 2` degenerates naturally -- with no
    /// "everything else," it's just [rank 1] or [rank 1, rank 2].
    private func bookendOrder() -> [UUID] {
        let ids = finalSelection.map(\.id)
        guard ids.count > 2 else { return ids }
        return [ids[0]] + ids[2...] + [ids[1]]
    }

    /// Resolves the shuffle deck into the collage and starts the
    /// bookend reveal sequence -- see file header REVEAL ORDER +
    /// STACKING. Rank 1 carries through via matchedGeometryEffect if
    /// it's currently deck-visible (continuity); every other card,
    /// including rank 2, always runs the normal staggered fade so the
    /// "rank 1 first, rank 2 last" guarantee can't be short-circuited
    /// by shuffle-deck timing coincidence.
    private func resolveIntoCollage() {
        let orderedIDs = bookendOrder()
        phase = .collage

        guard !orderedIDs.isEmpty else {
            onComplete()
            return
        }

        var toReveal = orderedIDs
        if let rank1 = orderedIDs.first,
           ShuffleDeck.visibleIDs(snapshot: shuffleSnapshot, tick: shuffleTick).contains(rank1) {
            revealedCardIDs = [rank1]
            revealOrder[rank1] = 0
            toReveal.removeFirst()
        }

        let n = finalSelection.count
        guard n > 1 else {
            // Guard n=1 separately (UI_NOTES §4): no stagger to compute,
            // just the first card's own delay + animation.
            revealSequentially(ids: toReveal, firstDelay: ShowcaseTiming.firstCardDelay, stagger: 0)
            Task {
                try? await Task.sleep(for: .seconds(ShowcaseTiming.firstCardDelay + ShowcaseTiming.cardFadeInDuration))
                onComplete()
            }
            return
        }
        let stagger = min(max(ShowcaseTiming.staggerNumerator / Double(n - 1), ShowcaseTiming.minStagger), ShowcaseTiming.maxStagger)
        revealSequentially(ids: toReveal, firstDelay: ShowcaseTiming.firstCardDelay, stagger: stagger)

        // Always computed against the full n (per UI_NOTES §4's
        // formula), regardless of whether rank 1 carried through --
        // matches this codebase's existing convention (see git
        // history), so the doc's worked examples stay accurate no
        // matter what the shuffle deck happened to be showing.
        let total = ShowcaseTiming.firstCardDelay + Double(n - 1) * stagger + ShowcaseTiming.cardFadeInDuration
        Task {
            try? await Task.sleep(for: .seconds(total))
            onComplete()
        }
    }

    private func revealSequentially(ids: [UUID], firstDelay: Double, stagger: Double) {
        guard !ids.isEmpty else { return }
        let startingOrder = revealOrder.count
        Task {
            try? await Task.sleep(for: .seconds(firstDelay))
            for (offset, id) in ids.enumerated() {
                guard !Task.isCancelled else { return }
                revealedCardIDs.insert(id)
                revealOrder[id] = startingOrder + offset
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
    /// No zIndex here -- stacking is driven by reveal ARRIVAL order
    /// (CurationSequenceView.revealOrder), not by rank/index, since
    /// this session's redesign. See file header REVEAL ORDER + STACKING.
    struct Slot {
        let center: CGPoint
        let size: CGSize
        let rotation: Double
    }

    /// Grows the golden-angle spiral's spread -- CHANGE 3, see file
    /// header. THE constant to tune the spread by eye: expressed as
    /// "how much more AREA the collage covers" (matching how the
    /// product ask was framed -- "roughly 15% more of the screen"),
    /// not a linear radius multiplier, so tuning it stays intuitive
    /// (0.20 for ~20% more area, etc.). Applied to each axis's linear
    /// radius as its square root, since area for a spread scales
    /// roughly with radius^2.
    private static let collageAreaGrowth: Double = 1.15

    /// Small, varied per-card tilt so the resolved collage reads as a
    /// casually stacked pile, not a rigid presentation grid -- CHANGE
    /// 2, overriding UI_NOTES §4's earlier "Rotation: 0°" (updated to
    /// match). Named here rather than in ShowcaseTiming since it's a
    /// spatial/layout constant and this is the layout type -- see file
    /// header for the full reasoning, including why this is gentler
    /// than the shuffle deck's own -10...+10 range.
    private static let maxRotationDegrees: Double = 6.0

    /// Base card size at n=4 (largest) down to n=20 (smallest), linearly
    /// interpolated by count so every n in between scales continuously
    /// rather than jumping between hardcoded tiers.
    private static func baseCardSize(for total: Int, in bounds: CGSize) -> CGSize {
        let t = Double(max(0, min(total, 20) - 4)) / 16.0 // 0 at n=4, 1 at n=20
        let widthFraction = 0.62 - t * 0.22 // 62% of bounds width at n=4, down to 40% at n=20
        let width = bounds.width * widthFraction
        return CGSize(width: width, height: width * 5 / 4) // 4:5 photos throughout
    }

    /// Deterministic pseudo-random tilt in [-maxRotationDegrees,
    /// +maxRotationDegrees], decorrelated from the size jitter's own
    /// seed (12.9898) below via a different hash constant (78.233, the
    /// standard GLSL-idiom pairing) so rotation doesn't visibly track
    /// size. `index + 1` avoids index 0 landing on the trivial sin(0)=0
    /// case.
    private static func rotation(for index: Int) -> Double {
        let normalized = sin(Double(index + 1) * 78.233) // pseudo-random in [-1, 1]
        return normalized * maxRotationDegrees
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
            return Slot(center: center, size: base, rotation: 0)
        }

        // Rank 1 (index 0) and rank 2 (index 1) share the SAME
        // signature hero slot -- dead center, largest. Rank 1 opens
        // the reveal sequence there; rank 2 lands on top of it last
        // (arrival-order z-index, not this slot, decides who's on top
        // -- see CurationSequenceView.collageCard) and keeps that slot
        // once the sequence settles, visually "taking over" from rank
        // 1. See file header REVEAL ORDER + STACKING. Position/size are
        // untouched by CHANGE 3 (the hero slot has no radius to spread
        // in the first place); it still gets its own tilt from CHANGE 2.
        if index == 0 || index == 1 {
            let heroSize = CGSize(width: base.width * 1.18, height: base.height * 1.18)
            return Slot(center: center, size: heroSize, rotation: rotation(for: index))
        }

        // Every other card gets a mild per-index size jitter (varied
        // size, per UI_NOTES §4), computed before the spread below so
        // the clamp can account for each card's own half-size.
        let jitter = 0.85 + 0.3 * abs(sin(Double(index) * 12.9898))
        let size = CGSize(width: base.width * jitter, height: base.height * jitter)

        // Golden-angle spiral. CHANGE 3: radius is computed
        // independently per axis (an ellipse sized to the frame's own
        // width/height) rather than a single radius bounded by
        // min(width, height) -- the old circular spread was capped by
        // whichever dimension was smaller, which is what caused cards
        // to cluster in the vertical-middle band instead of using the
        // frame's full height. Both axes are then HARD-CLAMPED so a
        // card's own edge never passes the frame boundary -- "must not
        // clip" holds by construction, not by hoping collageAreaGrowth
        // was tuned conservatively enough.
        let goldenAngle = 137.5 * .pi / 180
        let angle = Double(index) * goldenAngle
        let maxRadiusFraction = 0.16 + 0.22 * (Double(total - 1) / 19.0) // grows with n
        let indexFactor = 0.35 + 0.65 * (Double(index) / Double(max(total - 1, 1)))
        let spreadScale = collageAreaGrowth.squareRoot()

        let desiredRadiusX = bounds.width * maxRadiusFraction * indexFactor * spreadScale
        let desiredRadiusY = bounds.height * maxRadiusFraction * indexFactor * spreadScale
        let radiusX = min(desiredRadiusX, max(bounds.width / 2 - size.width / 2, 0))
        let radiusY = min(desiredRadiusY, max(bounds.height / 2 - size.height / 2, 0))

        let x = center.x + radiusX * cos(angle)
        let y = center.y + radiusY * sin(angle)

        return Slot(center: CGPoint(x: x, y: y), size: size, rotation: rotation(for: index))
    }
}
