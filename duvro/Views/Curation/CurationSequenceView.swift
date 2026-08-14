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
//  early would break "rank 1 first, rank 2 last." Every other card
//  reveals as part of a BATCH (see below), at ShowcaseTiming's pacing.
//
//  TIMING: see ShowcaseTiming below -- THE constants to tune this
//  sequence's pacing. Retuned three times so far; history matters here
//  since two of the three fixes address problems that look superficially
//  similar (both are "the collage doesn't read right") but have opposite
//  causes and opposite fixes -- don't reach for the wrong lever:
//
//  PASS 2 (blur/wash-out): an earlier version's values (1.8s fade,
//  0.20-0.50s stagger) made the fade LONGER than the stagger, so a card
//  was still mid-fade when the next one landed on top of it -- multiple
//  translucent cards stacked at once reads as blurry. Fixed by making
//  the fade SHORT (0.2s) and pinning stagger to always be >= it.
//
//  PASS 3 (0.2s reads as popping in, not revealing): fixed by lengthening
//  the fade back up, but that alone would just reintroduce PASS 2's bug
//  -- see PASS 4 below for why duration wasn't actually the right lever
//  either.
//
//  PASS 4 (CURVE FIX, this session -- the duration in PASS 3 was never
//  the problem): cardFadeInDuration went back up to 0.7s in PASS 3, but
//  the curve at the time (ease-out-expo, control points (0.16, 1, 0.3,
//  1)) dumps ~90% of the opacity change into the first ~15% of ANY
//  duration it's given -- so a nominal 0.7s fade was only ever
//  perceptible for about 0.1-0.15s, no matter how long the duration was
//  set to. Lengthening duration further would not have fixed this (and
//  would have reintroduced something close to PASS 2's overlap problem
//  via a growing minStagger). The actual fix is cardFadeInCurve itself:
//  replaced with ease-out-sine (0.39, 0.575, 0.565, 1), the gentlest of
//  the standard ease-out curves -- close to linear, opacity climbs
//  steadily across the FULL nominal duration rather than front-loading
//  almost all of it. cardFadeInDuration is unchanged at 0.7s from PASS
//  3; only the curve changed. A subtle scale settle (1.06 -> 1.0) rides
//  the same curve/duration as opacity, so the card reads as easing into
//  place rather than just fading -- monotonic, no overshoot, per §4.
//
//  BATCHED REVEAL (this session, alongside the curve fix): cards used to
//  reveal strictly one at a time (bookend order, each on its own
//  stagger). Now: rank 1 opens ALONE, rank 2 closes ALONE (unchanged --
//  see REVEAL ORDER + STACKING above), and everything in between reveals
//  in BATCHES of 2-3 (more at high n -- see ShowcaseTiming), members
//  offset by ShowcaseTiming.intraBatchOffset (a few tens of ms, not
//  simultaneous) and positioned to overlap each other's corners/edges
//  (CollageLayout's batch-anchored jitter, below) -- the deliberate
//  messiness a collage needs. This is also what fixes the n=20 duration
//  problem PASS 3 introduced: with 20 cards as ~7-9 arrival EVENTS
//  instead of 20, and a shorter ShowcaseTiming.batchGap between events
//  (affordable now that the fade is actually visible instead of
//  invisible-until-suddenly-there), total duration drops from PASS 3's
//  ~16s back down to a few seconds -- without shrinking any single
//  card's own fade back below what's genuinely watchable. Batch sizes
//  growing at high n (not just a shrinking gap) is the main lever: a
//  tighter overlap within a bigger batch at n=20 is an accepted
//  trade-off; a 16-second collage was not.
//
//  ROTATION: overrides UI_NOTES §4's earlier "Rotation:
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
//  WIDER SPREAD, SAME CARD SIZE: CollageLayout's spiral
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
        /// Unchanged in DURATION from the previous pass -- what changed
        /// is cardFadeInCurve below, which is what actually controls
        /// how much of this duration is perceptible. See file header
        /// CHANGE 1 (CURVE FIX).
        static let cardFadeInDuration: Double = 0.7
        /// Gentle ease-out (ease-out-sine, timing-curve control points
        /// (0.39, 0.575, 0.565, 1) -- the mildest of the standard
        /// ease-out family, close to linear with only a slight
        /// deceleration at the very end). Monotonic, never overshoots.
        /// REPLACES ease-out-expo (0.16, 1, 0.3, 1): that curve dumped
        /// ~90% of the opacity change into the first ~15% of the
        /// duration, so a nominal 0.7s fade read as ~0.1-0.15s -- the
        /// duration number was correct, the curve made almost none of
        /// it visible. This curve spreads the climb across the full
        /// duration instead. See file header CHANGE 1.
        static let cardFadeInCurve = Animation.timingCurve(0.39, 0.575, 0.565, 1, duration: cardFadeInDuration)
        /// Delay before the first (non-carried-through) reveal.
        static let firstCardDelay: Double = 0.15
        /// "A few tens of milliseconds" offset between members of the
        /// same batch, so they don't land in the exact same instant --
        /// see file header CHANGE 2 (BATCHED REVEAL).
        static let intraBatchOffset: Double = 0.05
        /// Pause between one batch finishing and the next batch's first
        /// member landing. Shorter than the old per-card stagger
        /// (0.8-1.2s) on purpose -- with a real, visible fade (the
        /// curve fix above), the sequence can afford to feel more
        /// continuous. See file header CHANGE 2.
        static let batchGap: Double = 0.6
        /// Batch size range scales with n -- 2-3 at n=4, growing to 3-5
        /// by n=20 -- so a large post needs FEWER arrival events, not
        /// just smaller stagger gaps between many small ones. This is
        /// what brings n=20's total down from the ~16s the per-card
        /// design produced to a few seconds, without shrinking
        /// batchGap to something imperceptible. See file header CHANGE
        /// 2's DURATION note.
        static let minBatchSizeAtLowN: Int = 2
        static let maxBatchSizeAtLowN: Int = 3
        static let minBatchSizeAtHighN: Int = 3
        static let maxBatchSizeAtHighN: Int = 5
        /// Extra pause AFTER the last card has fully settled, before
        /// auto-advancing to the first edit screen -- without this the
        /// finished collage is never actually seen at rest, since
        /// onComplete() fires the instant the last card's own fade
        /// ends. Added once, at the end of totalRevealDuration, not
        /// per-batch.
        static let postSettleHold: Double = 0.7
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

    @ViewBuilder
    private var collagePhase: some View {
        // Computed once per render rather than per-card -- revealBatches()
        // is a pure function of finalSelection, but there's no reason to
        // re-partition it n times when every card needs the same result.
        // See CHANGE header BATCHED REVEAL.
        let placements = Self.batchPlacements(from: revealBatches())
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            Text("our favorites")
                .font(.duvroDisplay)
                .foregroundStyle(Color(hex: "171614"))
            Spacer(minLength: 12)
            GeometryReader { geo in
                ZStack {
                    ForEach(Array(finalSelection.enumerated()), id: \.element.id) { index, score in
                        let slot = CollageLayout.slot(cardIndex: index, total: finalSelection.count, placement: placements[score.id], in: geo.size)
                        collageCard(score: score, slot: slot)
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 40)
        }
    }

    /// Maps each middle-order (non-hero) card id to its position within
    /// the batch plan, for CollageLayout.slot to place it near its
    /// batch-mates. Rank 1 and rank 2 (the two solo endpoint batches)
    /// are absent from the result -- they always resolve to the hero
    /// slot regardless, keyed by identity in CollageLayout, not by batch.
    private static func batchPlacements(from batches: [RevealBatch]) -> [UUID: CollageLayout.BatchPlacement] {
        guard batches.count > 2 else { return [:] }
        let middleBatches = batches[1..<(batches.count - 1)]
        var result: [UUID: CollageLayout.BatchPlacement] = [:]
        for (batchIndex, batch) in middleBatches.enumerated() {
            for (position, id) in batch.ids.enumerated() {
                result[id] = CollageLayout.BatchPlacement(
                    batchIndex: batchIndex,
                    totalBatches: middleBatches.count,
                    positionInBatch: position,
                    batchSize: batch.ids.count
                )
            }
        }
        return result
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

    /// One reveal "wave" -- either a solo endpoint (rank 1 opening, rank
    /// 2 closing) or a batch of 2+ middle-order cards that arrive
    /// together. See file header BATCHED REVEAL.
    struct RevealBatch {
        let ids: [UUID]
    }

    /// Batch size range for a post of `n` photos -- linearly
    /// interpolated between ShowcaseTiming's low-n and high-n endpoints,
    /// same `t` normalization CollageLayout.baseCardSize already uses.
    private func batchSizeRange(for n: Int) -> ClosedRange<Int> {
        let t = Double(max(0, min(n, 20) - 4)) / 16.0
        let lo = Int((Double(ShowcaseTiming.minBatchSizeAtLowN) + t * Double(ShowcaseTiming.minBatchSizeAtHighN - ShowcaseTiming.minBatchSizeAtLowN)).rounded())
        let hi = Int((Double(ShowcaseTiming.maxBatchSizeAtLowN) + t * Double(ShowcaseTiming.maxBatchSizeAtHighN - ShowcaseTiming.maxBatchSizeAtLowN)).rounded())
        return lo...max(lo, hi)
    }

    /// Builds the bookend + batched reveal plan (see file header BATCHED
    /// REVEAL): rank 1 solo, then the middle-order cards (composite
    /// order) split into batches of varied size within batchSizeRange,
    /// then rank 2 solo. Batch sizes are picked deterministically (a
    /// seeded pseudo-random hash, same idiom as CollageLayout's size/
    /// rotation jitter) so the same selection always groups the same
    /// way -- "varied," not literally random. `n <= 2` degenerates
    /// naturally to solo-only batches -- no middle cards to group.
    private func revealBatches() -> [RevealBatch] {
        let ids = finalSelection.map(\.id)
        guard ids.count > 2 else { return ids.map { RevealBatch(ids: [$0]) } }
        let middle = Array(ids[2...])
        let range = batchSizeRange(for: ids.count)
        var batches: [RevealBatch] = [RevealBatch(ids: [ids[0]])]
        var i = 0
        var batchCounter = 0
        while i < middle.count {
            let remaining = middle.count - i
            let seed = abs(sin(Double(batchCounter + 1) * 45.164)) // deterministic pseudo-random in [0, 1)
            var size = range.lowerBound + Int(seed * Double(range.upperBound - range.lowerBound + 1))
            size = min(size, range.upperBound)
            if remaining - size == 1 { size = remaining } // absorb a lone straggler rather than leaving a solo middle batch
            size = max(1, min(size, remaining))
            batches.append(RevealBatch(ids: Array(middle[i..<(i + size)])))
            i += size
            batchCounter += 1
        }
        batches.append(RevealBatch(ids: [ids[1]]))
        return batches
    }

    /// Total time from resolve to onComplete for a given batch plan --
    /// mirrors revealBatchesSequentially's own timing exactly (see its
    /// doc comment), computed upfront so it can be scheduled as one
    /// sleep rather than awaiting the reveal loop itself. Always
    /// computed against the FULL batch plan, regardless of whether rank
    /// 1 carried through instantly -- same "always full n" convention
    /// this file has used since the per-card design (see git history).
    private func totalRevealDuration(for batches: [RevealBatch]) -> Double {
        let intraBatchTime = batches.reduce(0.0) { $0 + Double(max($1.ids.count - 1, 0)) * ShowcaseTiming.intraBatchOffset }
        let gapTime = Double(max(batches.count - 1, 0)) * ShowcaseTiming.batchGap
        return ShowcaseTiming.firstCardDelay + intraBatchTime + gapTime + ShowcaseTiming.cardFadeInDuration + ShowcaseTiming.postSettleHold
    }

    /// Resolves the shuffle deck into the collage and starts the
    /// batched reveal sequence -- see file header REVEAL ORDER +
    /// STACKING and BATCHED REVEAL. Rank 1 carries through via
    /// matchedGeometryEffect if it's currently deck-visible
    /// (continuity); every other card, including rank 2, always runs
    /// the normal batched reveal so the "rank 1 first, rank 2 last"
    /// guarantee can't be short-circuited by shuffle-deck timing
    /// coincidence.
    private func resolveIntoCollage() {
        let batches = revealBatches()
        phase = .collage

        guard !batches.isEmpty else {
            onComplete()
            return
        }

        var remainingBatches = batches
        if let firstBatch = batches.first, firstBatch.ids.count == 1,
           let rank1 = firstBatch.ids.first,
           ShuffleDeck.visibleIDs(snapshot: shuffleSnapshot, tick: shuffleTick).contains(rank1) {
            revealedCardIDs = [rank1]
            revealOrder[rank1] = 0
            remainingBatches.removeFirst()
        }

        revealBatchesSequentially(remainingBatches, firstDelay: ShowcaseTiming.firstCardDelay)

        let total = totalRevealDuration(for: batches)
        Task {
            try? await Task.sleep(for: .seconds(total))
            onComplete()
        }
    }

    /// Reveals each batch's members with a small intra-batch offset (not
    /// simultaneous), then pauses batchGap before the next batch starts.
    /// No trailing gap after the LAST batch -- resolveIntoCollage's own
    /// total (via totalRevealDuration) accounts for the final card's
    /// fade instead. See file header BATCHED REVEAL.
    private func revealBatchesSequentially(_ batches: [RevealBatch], firstDelay: Double) {
        guard !batches.isEmpty else { return }
        var order = revealOrder.count
        Task {
            try? await Task.sleep(for: .seconds(firstDelay))
            for (batchIndex, batch) in batches.enumerated() {
                guard !Task.isCancelled else { return }
                for (memberIndex, id) in batch.ids.enumerated() {
                    guard !Task.isCancelled else { return }
                    if memberIndex > 0 {
                        try? await Task.sleep(for: .seconds(ShowcaseTiming.intraBatchOffset))
                    }
                    revealedCardIDs.insert(id)
                    revealOrder[id] = order
                    order += 1
                }
                if batchIndex < batches.count - 1 {
                    try? await Task.sleep(for: .seconds(ShowcaseTiming.batchGap))
                }
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

    /// Where a middle-order card sits within CurationSequenceView's
    /// batch plan -- nil for rank 1/rank 2 (always the hero slot,
    /// unaffected by batching). See file header BATCHED REVEAL.
    struct BatchPlacement {
        let batchIndex: Int
        let totalBatches: Int
        let positionInBatch: Int
        let batchSize: Int
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

    /// How far a batch-mate's center sits from its batch's shared
    /// anchor point, as a fraction of ITS OWN size -- so members of the
    /// same reveal batch visibly overlap each other's corners/edges,
    /// the deliberate messiness a collage needs (see file header
    /// BATCHED REVEAL). Expressed as a fraction of card size (not frame
    /// size) so it scales naturally at every n, since card size already
    /// does. ~0.28 puts two batch-mates' centers about 56% of a card-
    /// width apart -- solid overlap without reading as a single blob.
    private static let intraBatchJitterFraction: Double = 0.28

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

    /// `cardIndex` is the card's own position in finalSelection (drives
    /// its SIZE and ROTATION -- unaffected by batching, so each card
    /// keeps its own varied look regardless of who it arrives with).
    /// `placement` is nil for rank 1/rank 2 (hero slot) and set for
    /// every middle-order card (drives its POSITION, batch-anchored --
    /// see file header BATCHED REVEAL). Seeded only by index/placement/
    /// total, so the same selection always lays out the same way (no
    /// visible reshuffling if this is ever recomputed).
    static func slot(cardIndex: Int, total: Int, placement: BatchPlacement?, in bounds: CGSize) -> Slot {
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
        // 1. See file header REVEAL ORDER + STACKING. Identity-keyed
        // (placement == nil), not batch-keyed -- rank 1/2 are always
        // solo reveal batches, so they'd never get a placement anyway.
        guard let placement else {
            let heroSize = CGSize(width: base.width * 1.18, height: base.height * 1.18)
            return Slot(center: center, size: heroSize, rotation: rotation(for: cardIndex))
        }

        // Size/rotation still driven by the card's OWN composite index
        // (varied size/tilt per UI_NOTES §4, independent of which batch
        // it landed in) -- computed before the spread below so the
        // clamp can account for each card's own half-size.
        let jitter = 0.85 + 0.3 * abs(sin(Double(cardIndex) * 12.9898))
        let size = CGSize(width: base.width * jitter, height: base.height * jitter)

        // BATCH ANCHOR: same golden-angle spiral as before, now keyed by
        // BATCH index/total rather than per-card index/total -- batches,
        // not individual cards, are what's evenly distributed around the
        // frame (see file header BATCHED REVEAL). Radius magnitude still
        // comes from the CARD count (total, 4...20) -- the collage's
        // overall footprint is unchanged from the wider-spread pass;
        // only which cards share a spiral point has changed. Ellipse
        // sized to the frame's own width/height (not a circle capped by
        // whichever axis is smaller) -- see WIDER SPREAD in the file
        // header for why.
        let goldenAngle = 137.5 * .pi / 180
        let anchorAngle = Double(placement.batchIndex) * goldenAngle
        let maxRadiusFraction = 0.16 + 0.22 * (Double(total - 1) / 19.0) // grows with n
        let anchorFactor = 0.35 + 0.65 * (Double(placement.batchIndex) / Double(max(placement.totalBatches - 1, 1)))
        let spreadScale = collageAreaGrowth.squareRoot()

        let anchorRadiusX = bounds.width * maxRadiusFraction * anchorFactor * spreadScale
        let anchorRadiusY = bounds.height * maxRadiusFraction * anchorFactor * spreadScale
        let anchorX = center.x + anchorRadiusX * cos(anchorAngle)
        let anchorY = center.y + anchorRadiusY * sin(anchorAngle)

        // INTRA-BATCH JITTER: a small offset from the anchor so batch-
        // mates visibly overlap each other's corners/edges. Members are
        // spaced evenly around the anchor (2π / batchSize apart); the
        // batchIndex-seeded phase keeps different batches from all
        // jittering in the same directions, which would look mechanical.
        let jitterAngle = Double(placement.positionInBatch) * (2 * .pi / Double(max(placement.batchSize, 1)))
            + Double(placement.batchIndex) * 0.7
        let jitterRadius = min(size.width, size.height) * intraBatchJitterFraction
        let desiredX = anchorX + jitterRadius * cos(jitterAngle)
        let desiredY = anchorY + jitterRadius * sin(jitterAngle)

        // HARD CLAMP on the FINAL position (anchor + jitter together) --
        // "must not clip" holds by construction across whatever the real
        // on-device frame size turns out to be, not by hoping
        // collageAreaGrowth/intraBatchJitterFraction were tuned
        // conservatively enough.
        let x = min(max(desiredX, size.width / 2), max(bounds.width - size.width / 2, size.width / 2))
        let y = min(max(desiredY, size.height / 2), max(bounds.height - size.height / 2, size.height / 2))

        return Slot(center: CGPoint(x: x, y: y), size: size, rotation: rotation(for: cardIndex))
    }
}
