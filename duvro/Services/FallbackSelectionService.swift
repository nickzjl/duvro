//
//  FallbackSelectionService.swift
//  duvro
//
//  Phase 3.5's offline / endpoint-failure fallback path (BUILD_ROADMAP
//  Phase 3.5, "Offline / endpoint-failure fallback" bullet) -- NOT a
//  temporary placeholder standing in for the curation call. Once the Stage 2
//  API call exists, this stays exactly as the no-network branch: on success
//  the curation call's result overwrites SessionStore.chosenSelection, and
//  this service still runs whenever that call fails or the device is
//  offline, so a post is always produced.
//
//  Deliberately minimal, matching this session's product decision recorded
//  in BUILD_ROADMAP Phase 3 ("no hardcoded composition quotas in
//  selection"): no category quotas, no per-category minimums, no people
//  cap. Composite ranking plus de-duplication by cluster, nothing else --
//  the model gets to make taste calls; this fallback only exists so an
//  offline user isn't left with zero post.
//

import Foundation

struct FallbackSelectionResult {
    /// The chosen photos, in final display/post order.
    let selected: [PhotoScore]
    /// true if `selected` is ordered by capture timestamp (chronological --
    /// the intended order for a post). false means there was no timestamp
    /// to order by and `selected` is in composite-score order instead. See
    /// `FallbackSelectionService.select` for why this is currently always
    /// false.
    let orderedByTimestamp: Bool
}

nonisolated enum FallbackSelectionService {
    /// Phase 8, Task 4 CLOSED this gap: the vibe screen's photo-count text
    /// input (VibeSelectionView) now exists, and `select(from:count:)`
    /// below reads the user-supplied, already-validated count instead of
    /// a constant. `fallbackCount` stays only as the DEFAULT for `count`
    /// (prd.md's "7 is the sweet spot") and because a couple of debug
    /// views (EditDebugView, ShortlistDebugView) still display it as a
    /// label for their own hardcoded-7 debug runs -- see those call sites.
    static let fallbackCount = 7

    /// At most one photo per near-duplicate cluster in the final selection.
    /// This is de-duplication, not a taste constraint -- distinct from
    /// ShortlistService.maxPerCluster (3), which governs what's even
    /// eligible to be judged. Without this, two near-identical frames of
    /// the same moment could both land in a 7-photo post.
    static let maxPerCluster = 1

    /// `shortlist` is ShortlistService's output -- this never re-derives a
    /// shortlist itself. No category quotas: candidates are ranked purely
    /// by composite score across the whole shortlist, categories be
    /// damned. If fewer than `count` candidates survive the per-cluster
    /// rule, `selected` is just shorter -- no backfill.
    ///
    /// `count` defaults to `fallbackCount` (7) so every EXISTING call site
    /// (debug buttons, duvroApp's debug launch path, all written before
    /// the vibe screen's photo-count input existed) keeps behaving
    /// identically without being touched. VibeSelectionView is the one
    /// real caller that passes something else -- the user's own,
    /// already-validated (4...20, defaulted to 7 if empty/invalid) count.
    static func select(from shortlist: ShortlistResult, count: Int = fallbackCount) -> FallbackSelectionResult {
        let ranked = shortlist.shortlisted.sorted { $0.compositeScore > $1.compositeScore }

        var clusterCount: [Int: Int] = [:]
        var chosen: [PhotoScore] = []
        for candidate in ranked {
            guard chosen.count < count else { break }
            // Every shortlisted photo has a clusterID (it came from
            // ShortlistService, which only ever emits photos it got a
            // clusterID for); the fallback here only matters if that
            // invariant is ever broken.
            let clusterID = shortlist.clusterID[candidate.id] ?? candidate.id.hashValue
            let countSoFar = clusterCount[clusterID] ?? 0
            guard countSoFar < maxPerCluster else { continue } // skip, keep walking
            chosen.append(candidate)
            clusterCount[clusterID] = countSoFar + 1
        }

        #if DEBUG
        print("[fallback-select] \(chosen.count)/\(count) chosen from \(shortlist.shortlisted.count) shortlisted")
        #endif

        // `timestamp` is one of the five metrics in the Phase 3.5 payload
        // contract (prd.md P0.3), but nothing captures a capture timestamp
        // today: Photo.swift has id/originalURL/downsampledURL/thumbnail
        // only, and PhotoImportService never reads EXIF DateTimeOriginal or
        // a PHAsset creationDate. `chosen` is already in composite-
        // descending order (built by walking `ranked` above) -- that's the
        // fallback order, so the post has SOME defined sequence rather than
        // none. Once a timestamp exists on Photo/PhotoScore, sort `chosen`
        // by it here and flip `orderedByTimestamp` to true.
        return FallbackSelectionResult(selected: chosen, orderedByTimestamp: false)
    }
}
