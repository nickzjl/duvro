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
    private(set) var shortlist: ShortlistResult?
    /// The chosen post, as FallbackSelectionService (or, once it exists,
    /// the curation call) first proposed it -- immutable record of that
    /// proposal. `postOrder` below is the mutable working copy Phase 5/6
    /// edit; this is kept so "what did selection actually propose" stays
    /// answerable after the user starts reordering/removing/swapping.
    private(set) var chosenSelection: FallbackSelectionResult?
    private(set) var runnerUps: [PhotoScore] = []

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
    /// Every photo ID the user has explicitly skipped this session (Phase
    /// 5's "skip this photo"). Permanent, unlike postOrder membership --
    /// once removed from the post via a skip, a photo must never be
    /// selected as a LATER skip's backfill candidate. Without this, a
    /// skipped-then-removed photo becomes eligible again the moment it's no
    /// longer in postOrder, and since it was likely one of the highest-
    /// composite candidates in the shortlist (that's why it was chosen in
    /// the first place), it tends to get immediately re-picked as the next
    /// backfill -- producing exactly the "skip shows the same photos in a
    /// loop" bug this field fixes. See skipPhoto below.
    private(set) var skippedPhotoIDs: Set<UUID> = []

    // MARK: - Setters (Phase 1-3.5 outputs)

    func setPhotos(_ photos: [Photo]) {
        self.photos = photos
    }

    func setScores(_ scores: [PhotoScore]) {
        self.scores = scores
    }

    func setShortlist(_ shortlist: ShortlistResult) {
        self.shortlist = shortlist
    }

    func setChosenSelection(_ result: FallbackSelectionResult) {
        chosenSelection = result
        postOrder = result.selected.map(\.id)
        pickedVariantName = [:]
        skippedPhotoIDs = []
    }

    func setRunnerUps(_ runnerUps: [PhotoScore]) {
        self.runnerUps = runnerUps
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

    /// "skip this photo" (BUILD_ROADMAP Phase 5): removes `id` from the
    /// post and backfills, IN THE SAME SLOT, with the next-best available
    /// candidate from the shortlist remainder (ranked by composite,
    /// respecting the same one-photo-per-cluster rule FallbackSelectionService
    /// itself uses -- duplicated narrowly here rather than reaching back
    /// into that service, since this is "one more slot," not a full
    /// re-selection). If nothing viable remains, the post just shrinks by
    /// one, per BUILD_ROADMAP Phase 5's own fallback.
    ///
    /// Two things this used to get wrong (found by hand-testing: repeated
    /// skips cycled through the same photos instead of producing fresh
    /// ones each time):
    ///
    /// 1. The backfill candidate was APPENDED to the end of postOrder
    ///    rather than inserted where the skipped photo used to be. The
    ///    caller (EditFlowView.skip) deliberately keeps `currentIndex`
    ///    unchanged after a skip -- on the assumption the same slot now
    ///    holds something new -- so appending to the end meant the very
    ///    next photo shown was just whatever ALREADY occupied the next
    ///    index (an untouched original pick, not the backfill), and the
    ///    real backfill sat unseen at the tail until every other photo in
    ///    the post had also been skipped past.
    /// 2. A skipped photo was only excluded from candidacy via its CURRENT
    ///    postOrder membership (`alreadyInPost`), which stops applying the
    ///    instant it's removed. Skipped photos are usually high-composite
    ///    (that's why they were chosen originally), so once removed they'd
    ///    immediately win the `.max` below again on some LATER skip and
    ///    get backfilled right back in -- the actual "loop" the user saw.
    ///    skippedPhotoIDs makes a skip permanent for the rest of the
    ///    session, independent of postOrder membership.
    func skipPhoto(_ id: UUID) {
        guard let removalIndex = postOrder.firstIndex(of: id) else { return }
        postOrder.remove(at: removalIndex)
        pickedVariantName[id] = nil
        skippedPhotoIDs.insert(id)

        guard let shortlist else { return }
        let usedClusterIDs = Set(postOrder.compactMap { shortlist.clusterID[$0] })
        let alreadyInPost = Set(postOrder)
        let candidate = shortlist.shortlisted
            .filter { !alreadyInPost.contains($0.id) && !skippedPhotoIDs.contains($0.id) }
            .filter { score in
                guard let clusterID = shortlist.clusterID[score.id] else { return true }
                return !usedClusterIDs.contains(clusterID)
            }
            .max { $0.compositeScore < $1.compositeScore }

        if let candidate {
            let insertionIndex = min(removalIndex, postOrder.count)
            postOrder.insert(candidate.id, at: insertionIndex)
            runnerUps.removeAll { $0.id == candidate.id }
        }
    }

    // MARK: - Phase 6: reorder / remove / add runner-up

    func removeFromPost(_ id: UUID) {
        postOrder.removeAll { $0 == id }
        pickedVariantName[id] = nil
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
