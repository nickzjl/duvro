//
//  SessionStore.swift
//  duvro
//
//  The @Observable session object BUILD_ROADMAP's Project Structure
//  describes ("one @Observable SessionStore owning the flow: photos ->
//  scores -> selection -> picks/tweaks -> export"). Previously held only
//  chosenSelection; migrated (mechanically -- no scoring/clustering/
//  selection logic changed) to also own photos, scores, the shortlist, and
//  the runner-ups, so Phase 5/6 screens have one place to read from instead
//  of reaching into ImportView's local @State. This was the Deferred work
//  register's "SessionStore ownership" item -- removed from that register
//  in the same commit as this migration.
//
//  No persistence -- a session is ephemeral, per BUILD_ROADMAP.
//

import Foundation

@Observable
@MainActor
final class SessionStore {
    // MARK: - Pipeline data (Phase 1-3.5 outputs)

    private(set) var photos: [Photo] = []
    private(set) var scores: [PhotoScore] = []
    /// Mirrors ScoringService.isScoring (real flow only -- ImportView syncs
    /// it via .onChange, same pattern as `scores` itself). Stays false for
    /// every DEBUG launch path, which never touches a live ScoringService
    /// at all (DebugFixture's scores are already complete before the
    /// curation-progress screen even appears) -- so "not scoring" is the
    /// CORRECT default for those flows, not just an unset placeholder.
    /// This is what lets the curation-progress screen know when to stop
    /// waiting and run the real selection pipeline, since counting
    /// scores.count against photos.count is unreliable whenever even one
    /// photo fails to score (a failed photo never lands in `scores` at
    /// all -- see ScoringService's failedCount) -- which is EVERY photo,
    /// every time, in the Simulator.
    private(set) var isScoring: Bool = false
    /// Mirrors PhotoImportService.isImporting (real flow only), same
    /// pattern and same reason as `isScoring` above -- added when the
    /// picker's own dismiss started going straight to vibe selection
    /// instead of waiting behind the old grid/"choose your vibe" tap, so
    /// CurationSequenceView can now be reached while import itself is
    /// still running, before scoring has even been kicked off. Without
    /// this, its wait-for-scoring loop (which only checked isScoring)
    /// would see `false` during that window -- not because scoring had
    /// finished, but because it hadn't started yet -- and run selection
    /// against an empty score set.
    private(set) var isImporting: Bool = false
    private(set) var shortlist: ShortlistResult?
    /// The chosen post, as FallbackSelectionService (or, once it exists,
    /// the curation call) first proposed it -- immutable record of that
    /// proposal. `postOrder` below is the mutable working copy Phase 5/6
    /// edit; this is kept so "what did selection actually propose" stays
    /// answerable after the user starts reordering/removing/swapping.
    private(set) var chosenSelection: FallbackSelectionResult?
    private(set) var runnerUps: [PhotoScore] = []
    /// Phase 3.5: CurationService's per-photo role ("hero", "portrait",
    /// "outfit", "candid", "social", "place", "food", "detail",
    /// "atmosphere"), keyed by photo id. Empty when the fallback path
    /// ran instead -- FallbackSelectionService has no concept of role.
    /// Stored for the showcase/debug views to consume later; not read by
    /// either this session.
    private(set) var photoRoles: [UUID: String] = [:]
    /// Phase 3.5: the detail behind `runnerUps` above -- CurationService's
    /// alternates carry a type ("swap"/"extension"), which chosen photo a
    /// swap could replace, a role, and the model's own reason. `runnerUps`
    /// is what FinalReviewView's existing "what we left out" row already
    /// reads (same [PhotoScore] shape FallbackSelectionService's own
    /// runner-ups already produce); this is the richer data alongside it,
    /// for a future debug view. Empty when the fallback path ran.
    private(set) var alternateInfo: [UUID: CurationService.AlternateInfo] = [:]
    /// Phase 3.5/9: rank-ordered caption suggestions from the SAME
    /// curation call (the endpoint returns captions alongside the
    /// selection -- no separate network round-trip at the caption screen
    /// itself). Empty when the fallback path ran -- CaptionView's
    /// CurationCaptionService falls through to local templates in that
    /// case (see CaptionService.swift).
    private(set) var curationCaptions: [String] = []

    // MARK: - Phase 5/6 working state

    /// The working post: ordered photo IDs. Seeded from chosenSelection the
    /// moment it's set; mutated from there by skip (Phase 5), and reorder/
    /// remove/add-runner-up (Phase 6). This -- not chosenSelection.selected
    /// -- is what Phase 5/6 screens should read for "the post," since it's
    /// the one that reflects user edits.
    private(set) var postOrder: [UUID] = []
    /// Which variant (EditVariant.name, e.g. "Sun-kissed") the user has
    /// committed for each photo ID in postOrder, via "keep this one".
    /// Absent = not yet committed -- Phase 5 pre-selects variant 1 visually
    /// on arrival, but that's a display default, not a commit.
    private(set) var pickedVariantName: [UUID: String] = [:]
    /// Per-photo advanced-sheet tweaks (intensity/brightness/contrast) on
    /// top of the picked variant's own look. Same photo-ID-keyed-dictionary
    /// pattern as pickedVariantName above, for the same reason: a plain map
    /// lookup naturally survives variant switches, photo navigation, and
    /// sheet dismiss/reopen without any view-lifecycle bookkeeping. Absent
    /// = PhotoAdjustments() (the no-op default), same absent-means-default
    /// convention as pickedVariantName being absent meaning "not yet
    /// committed."
    private(set) var adjustments: [UUID: PhotoAdjustments] = [:]

    // MARK: - Setters (Phase 1-3.5 outputs)

    func setPhotos(_ photos: [Photo]) {
        self.photos = photos
    }

    func setScores(_ scores: [PhotoScore]) {
        self.scores = scores
    }

    func setScoring(_ inProgress: Bool) {
        isScoring = inProgress
    }

    func setImporting(_ inProgress: Bool) {
        isImporting = inProgress
    }

    func setShortlist(_ shortlist: ShortlistResult) {
        self.shortlist = shortlist
    }

    func setChosenSelection(_ result: FallbackSelectionResult) {
        chosenSelection = result
        postOrder = result.selected.map(\.id)
        pickedVariantName = [:]
        adjustments = [:]
    }

    func setRunnerUps(_ runnerUps: [PhotoScore]) {
        self.runnerUps = runnerUps
    }

    func setPhotoRoles(_ roles: [UUID: String]) {
        photoRoles = roles
    }

    func setAlternateInfo(_ info: [UUID: CurationService.AlternateInfo]) {
        alternateInfo = info
    }

    func setCurationCaptions(_ captions: [String]) {
        curationCaptions = captions
    }

    // MARK: - Lookups

    private var photosByID: [UUID: Photo] {
        Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
    }

    private var scoresByID: [UUID: PhotoScore] {
        Dictionary(uniqueKeysWithValues: scores.map { ($0.id, $0) })
    }

    func photo(for id: UUID) -> Photo? {
        photosByID[id]
    }

    func score(for id: UUID) -> PhotoScore? {
        scoresByID[id] ?? runnerUps.first { $0.id == id }
    }

    /// `postOrder` resolved to PhotoScores, in post order. Drops any ID that
    /// no longer resolves (shouldn't happen -- defensive, not load-bearing).
    var post: [PhotoScore] {
        postOrder.compactMap { score(for: $0) }
    }

    // MARK: - Phase 5: per-photo edit commits

    func pickVariant(_ variantName: String, forPhotoID id: UUID) {
        pickedVariantName[id] = variantName
    }

    /// Absent -> PhotoAdjustments() (the no-op default), never nil-checked
    /// at call sites -- mirrors score(for:)/photo(for:)'s own
    /// dictionary-lookup-with-fallback shape.
    func adjustments(for id: UUID) -> PhotoAdjustments {
        adjustments[id] ?? PhotoAdjustments()
    }

    func setAdjustments(_ value: PhotoAdjustments, forPhotoID id: UUID) {
        adjustments[id] = value
    }

    /// "skip this photo" (BUILD_ROADMAP Phase 5): removes `id` from the
    /// post and, IN THE SAME SLOT (same index), immediately promotes the
    /// best available runner-up to replace it.
    ///
    /// SPEC, and why this is a behaviour change and not the earlier
    /// display-only patch it was mistaken for (product decision, momentum
    /// principle in CLAUDE.md's product thesis): the edit loop is EXACTLY
    /// the post, and nothing else. `runnerUps` -- the SAME "what we left
    /// out" pool Final Review shows -- is the ONLY source a skip draws
    /// from now, not a separately re-derived slice of the shortlist
    /// remainder (which is what the previous version of this function
    /// did, and which is how a skip could reach photos the user never saw
    /// offered anywhere). Sourcing from `runnerUps` directly makes three
    /// things true by construction, not by separately-tracked bookkeeping:
    ///   - the total universe a user can ever be asked to edit is bounded
    ///     -- post.count + runnerUps.count (e.g. 7 + 5 = 12 candidates
    ///     that could ever appear, not an unbounded walk through however
    ///     large the shortlist remainder happens to be)
    ///   - a promoted runner-up leaves the pool it came from automatically
    ///     (removeFirst() takes it OUT of runnerUps) -- it can't also
    ///     still show up in Final Review's "what we left out" row
    ///   - once runnerUps is empty, a skip has nothing left to offer and
    ///     the post genuinely, permanently shrinks -- the denominator
    ///     drops with it, since the loop IS the post ("3 of 7" means
    ///     exactly what it says, always)
    ///
    /// No cluster-uniqueness check needed here, unlike the previous
    /// version: RunnerUpService.compute already guarantees runnerUps is
    /// cluster-disjoint from `chosen` AND from itself at the moment it's
    /// computed -- ONCE, at selection time (see the callers, which no
    /// longer recompute it after skips; recomputing would pull in fresh
    /// shortlist-remainder candidates and break the bounded-12 invariant
    /// above). Every mutation from here on -- this function's promotion,
    /// or addRunnerUp/removeFromPost in Phase 6 -- only ever MOVES a
    /// photo between postOrder and runnerUps, or removes one outright; it
    /// never introduces a new photo into either set, so that initial
    /// disjointness holds for the life of the session without re-checking
    /// it here. `runnerUps` stays composite-sorted best-first throughout
    /// (removing elements doesn't reorder what's left), so "the best
    /// available runner-up" is simply its first element.
    func skipPhoto(_ id: UUID) {
        guard let removalIndex = postOrder.firstIndex(of: id) else { return }
        postOrder.remove(at: removalIndex)
        pickedVariantName[id] = nil
        adjustments[id] = nil

        let promoted = runnerUps.isEmpty ? nil : runnerUps.removeFirst()
        if let promoted {
            let insertionIndex = min(removalIndex, postOrder.count)
            postOrder.insert(promoted.id, at: insertionIndex)
        }

        // Diagnostic: confirms the invariant from the console on the next
        // on-device test -- postOrder.count should never exceed
        // chosenSelection.selected.count, and runnerUps.count should only
        // ever go down, never back up, across a whole skip session.
        #if DEBUG
        print("[skip] removed \(id.uuidString.prefix(8)) from postOrder[\(removalIndex)] -- \(promoted.map { "promoted \(String($0.id.uuidString.prefix(8))) from runnerUps" } ?? "no runner-ups left, post shrinks to \(postOrder.count)"); postOrder now \(postOrder.count): \(postOrder.map { String($0.uuidString.prefix(4)) }), runnerUps remaining: \(runnerUps.count)")
        #endif
    }

    // MARK: - Phase 6: reorder / remove / add runner-up

    func removeFromPost(_ id: UUID) {
        postOrder.removeAll { $0 == id }
        pickedVariantName[id] = nil
        adjustments[id] = nil
    }

    /// Same semantics as RangeReplaceableCollection.move(fromOffsets:toOffset:)
    /// (SwiftUI's .onMove callback signature), reimplemented with Foundation
    /// only rather than importing SwiftUI into a Models file for one method.
    func movePost(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        let moving = offsets.map { postOrder[$0] }
        var remaining = postOrder
        for index in offsets.sorted(by: >) {
            remaining.remove(at: index)
        }
        // Adjust the insertion point for however many moved elements sat
        // before it in the original array -- matches SwiftUI's own
        // fromOffsets/toOffset semantics for onMove.
        let removedBeforeDestination = offsets.count { $0 < destination }
        let insertionIndex = min(max(destination - removedBeforeDestination, 0), remaining.count)
        remaining.insert(contentsOf: moving, at: insertionIndex)
        postOrder = remaining
    }

    /// Runner-up "+": add if under the adaptive count's photo total, else
    /// replace `replacing`. Newly added photos route through the 3-way edit
    /// before joining (UI_NOTES fix in Phase 6) -- this only updates the
    /// data; the caller is responsible for sending the user through that
    /// flow before (or instead of) calling this, per that requirement.
    func addRunnerUp(_ id: UUID, replacing: UUID? = nil) {
        guard runnerUps.contains(where: { $0.id == id }) else { return }
        if let replacing {
            removeFromPost(replacing)
        }
        postOrder.append(id)
        runnerUps.removeAll { $0.id == id }
    }
}
