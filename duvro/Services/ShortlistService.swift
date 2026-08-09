//
//  ShortlistService.swift
//  duvro
//
//  Phase 3, part 2: turns Stage-2-survived PhotoScores into the ~30-candidate
//  per-category shortlist that Phase 3.5's curation call consumes. This is
//  nomination, not final selection (see BUILD_ROADMAP Phase 3 / prd.md
//  P0.2) -- it does not touch the composite formula, the reject rules, or
//  CategoryMapper, and it produces data only. No selection logic lives in
//  the debug view that renders this; Phase 3.5 will consume the same
//  ShortlistResult.
//
//  Two passes: ClusteringService groups surviving photos into near-duplicate
//  clusters, then this file fills a fixed per-category quota by walking
//  each category's composite-ranked list and skipping any candidate that
//  would push its cluster over the per-cluster cap -- never truncating a
//  ranked list and filtering after, which would under-fill categories with
//  a lot of clustering (e.g. a 20-frame burst that would otherwise eat the
//  top N ranks of its category).
//

import Foundation

struct ShortlistResult {
    /// The shortlist itself: grouped by category (people, place, food,
    /// detail order), each group ranked by composite descending. Exactly
    /// what Phase 3.5 and the debug view consume.
    let shortlisted: [PhotoScore]
    /// clusterID for every SURVIVING photo, not just shortlisted ones -- the
    /// debug view's cluster-size distribution is computed over all
    /// survivors.
    let clusterID: [UUID: Int]
    /// Cluster membership, keyed by clusterID, over all survivors.
    let clusterMembers: [Int: [UUID]]
    /// All surviving (non-rejected) scores, unfiltered by shortlist status --
    /// kept alongside the shortlist so callers (the debug view in
    /// particular) don't need to re-derive "surviving" from the full score
    /// list themselves.
    let surviving: [PhotoScore]
    let rejectedCount: Int
    /// Wall-clock time for clustering + quota-fill, measured here since
    /// this is the number BUILD_ROADMAP Phase 3 needs to confirm the
    /// shortlist step doesn't meaningfully add to scoring time. Excludes
    /// ScoringService's own elapsed time.
    let elapsedSeconds: Double
    /// Passed through from ClusteringService.Result -- see its doc comment.
    /// Surfaced here too so the debug view doesn't need its own reference
    /// to ClusteringService's output.
    let clusteringDistanceFailureCount: Int
}

nonisolated enum ShortlistService {
    /// ~30 total, weighted toward people. BUILD_ROADMAP Phase 3's numbers --
    /// not re-derived here.
    static let quotas: [PhotoCategory: Int] = [
        .people: 12,
        .place: 8,
        .food: 5,
        .detail: 5
    ]

    /// At most this many photos from a single near-duplicate cluster may
    /// enter the shortlist. Deliberate departure from BUILD_ROADMAP's
    /// original "keep only the single strongest candidate per cluster": a
    /// 20-frame burst usually has more than one usable shot, and Phase 3.5
    /// is better placed to choose between them than a composite score is.
    static let maxPerCluster = 3

    /// Category fill order. Only matters if a cluster's members ever span
    /// more than one category (shouldn't happen in practice -- near
    /// duplicates are the same scene, hence the same category -- but the
    /// per-cluster cap below is tracked globally, not per category, so the
    /// order is pinned for determinism). People first matches
    /// BUILD_ROADMAP's "weighted toward people" and Phase 3.5's
    /// people-first composition.
    private static let categoryFillOrder: [PhotoCategory] = [.people, .place, .food, .detail]

    static func buildShortlist(from scores: [PhotoScore]) -> ShortlistResult {
        let startTime = Date()

        let surviving = scores.filter { !$0.isHardRejected }
        let rejectedCount = scores.count - surviving.count

        let clusters = ClusteringService.cluster(surviving)

        // Diagnostic, not a fix: ClusteringService.cluster assigns a
        // clusterID to every item it's given, unconditionally -- a missing
        // entry here should be structurally impossible. If this ever
        // prints, something upstream is passing `surviving` through a
        // DIFFERENT path than this function, or clusters.clusterID is
        // getting built against a different (stale) input -- worth knowing
        // immediately instead of discovering it as an unexplained "-1" in a
        // debug view three steps downstream.
        #if DEBUG
        let missingClusterIDs = surviving.filter { clusters.clusterID[$0.id] == nil }
        if !missingClusterIDs.isEmpty {
            print("[shortlist] WARNING: \(missingClusterIDs.count)/\(surviving.count) surviving photos have NO clusterID after ClusteringService.cluster -- this should be impossible. clusters.clusterID has \(clusters.clusterID.count) entries.")
        }
        #endif

        var clusterCountInShortlist: [Int: Int] = [:]
        var shortlisted: [PhotoScore] = []

        for category in categoryFillOrder {
            let quota = quotas[category] ?? 0
            guard quota > 0 else { continue }

            let ranked = surviving
                .filter { $0.category == category }
                .sorted { $0.compositeScore > $1.compositeScore }

            var takenForCategory = 0
            for candidate in ranked {
                guard takenForCategory < quota else { break }
                // Every surviving photo has a clusterID (ClusteringService
                // assigns one to every input); the fallback here only
                // matters if that invariant is ever broken, and treats an
                // unassigned photo as its own singleton so it isn't
                // silently dropped.
                let clusterID = clusters.clusterID[candidate.id] ?? candidate.id.hashValue
                let countSoFar = clusterCountInShortlist[clusterID] ?? 0
                guard countSoFar < maxPerCluster else { continue } // skip, keep walking -- do not stop early
                shortlisted.append(candidate)
                clusterCountInShortlist[clusterID] = countSoFar + 1
                takenForCategory += 1
            }
            // If `ranked` runs out before quota is met, that's the end of
            // this category's contribution -- no cross-category backfill.
        }

        let elapsed = Date().timeIntervalSince(startTime)
        #if DEBUG
        print("[shortlist] \(shortlisted.count) shortlisted from \(surviving.count) surviving (\(rejectedCount) rejected) in \(String(format: "%.3f", elapsed))s")
        #endif

        return ShortlistResult(
            shortlisted: shortlisted,
            clusterID: clusters.clusterID,
            clusterMembers: clusters.members,
            surviving: surviving,
            rejectedCount: rejectedCount,
            elapsedSeconds: elapsed,
            clusteringDistanceFailureCount: clusters.distanceFailureCount
        )
    }
}
