//
//  ClusteringService.swift
//  duvro
//
//  Phase 3, part 1: near-duplicate clustering. Runs as ONE pass over all
//  SURVIVING (non-rejected) photos, AFTER Stage 2 scoring has completed for
//  the whole set -- this is a cross-photo operation, not per-photo work, so
//  it deliberately does not live inside ScoringService's per-photo TaskGroup
//  (see that file's docblock: "no curation/selection/rejection-pass logic
//  here, that's Phase 3").
//
//  Callers MUST filter out rejected photos before calling `cluster(_:)` --
//  this file does not re-check `isHardRejected`. A rejected photo has no
//  feature print anyway (Stage 2's GenerateImageFeaturePrintRequest never
//  ran for it; see PhotoScore.featurePrint), so it couldn't be clustered
//  meaningfully even if passed in.
//
//  ALGORITHM: single-link agglomerative clustering, implemented as union-find
//  rather than a literal merge-closest-pair loop. For a FIXED distance
//  threshold (not a target cluster count), cutting a single-link dendrogram
//  at that threshold produces exactly the connected components of the graph
//  where an edge (i, j) exists whenever distance(i, j) < threshold -- that's
//  a standard equivalence, and it turns this into a flat O(n^2) pairwise
//  distance pass plus near-linear union-find, no dendrogram construction
//  needed. O(n^2) on 200 photos is ~20k distance computations -- fine per
//  BUILD_ROADMAP Phase 3; not optimized further.
//
//  DISTANCE API: the Swift-native `Vision.FeaturePrintObservation` (iOS 18+,
//  used throughout this codebase -- see ScoringService's docblock on API
//  choice) exposes `distance(to:) throws -> Double`, confirmed against the
//  iOS Simulator SDK's Vision.swiftinterface. This is NOT the legacy
//  Objective-C `VNFeaturePrintObservation.computeDistance(_:to:)` -- that
//  method belongs to the old VN-prefixed class this codebase does not use.
//

import Foundation
import Vision

/// Pure and stateless -- explicitly nonisolated so it can run off the main
/// actor if a future caller wants that (matches CompositeScoring's rationale
/// for the same annotation).
nonisolated enum ClusteringService {
    /// Starting point per BUILD_ROADMAP Phase 3, LOWERED after a real
    /// 134-photo device run at the original 0.55: single-link clustering
    /// chains transitively (A merges with C whenever both are within
    /// threshold of some B, even if A and C themselves are far apart), and
    /// 0.55 was loose enough to collapse 91 of 134 surviving photos into
    /// ONE cluster -- nothing close to a plausible burst. 0.35 is
    /// BUILD_ROADMAP's own next-value-to-try, not independently derived --
    /// there was no way to reason quantitatively about the right number
    /// without real feature-print distance data, which needs a device
    /// (Vision doesn't run in the Simulator). Tune this live from
    /// ShortlistDebugView's threshold stepper (DEBUG builds) rather than
    /// rebuilding -- see that view for how the override works.
    static let duplicateDistanceThreshold: Double = 0.35

    struct Result {
        /// clusterID for every photo passed in. A photo with no
        /// near-duplicates is a cluster of one.
        let clusterID: [UUID: Int]
        /// Cluster membership, keyed by clusterID. Every value has at least
        /// one element; singleton clusters have exactly one.
        let members: [Int: [UUID]]
        /// Count of pairwise `distance(to:)` calls that threw and were
        /// treated as "not a duplicate" rather than failing the whole pass
        /// (see the loop below). Silent otherwise -- surfaced here so a
        /// device with no console attached can still tell this happened,
        /// same reasoning as VibePackLoadError.
        let distanceFailureCount: Int
    }

    /// `scores` must already exclude rejected photos (see file header).
    /// `threshold` defaults to `duplicateDistanceThreshold` but can be
    /// overridden -- the parameter exists specifically so
    /// ShortlistDebugView's DEBUG stepper can re-run clustering at a
    /// different value without rebuilding, not because any other caller
    /// needs a non-default threshold today.
    static func cluster(_ scores: [PhotoScore], threshold: Double = duplicateDistanceThreshold) -> Result {
        let n = scores.count
        guard n > 0 else { return Result(clusterID: [:], members: [:], distanceFailureCount: 0) }

        var parent = Array(0..<n)
        var distanceFailureCount = 0

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]] // path halving
                x = parent[x]
            }
            return x
        }
        func union(_ a: Int, _ b: Int) {
            let rootA = find(a)
            let rootB = find(b)
            if rootA != rootB { parent[rootA] = rootB }
        }

        for i in 0..<n {
            guard let fingerprintI = scores[i].featurePrint else { continue }
            for j in (i + 1)..<n {
                guard let fingerprintJ = scores[j].featurePrint else { continue }
                guard let distance = try? fingerprintI.distance(to: fingerprintJ) else {
                    distanceFailureCount += 1
                    #if DEBUG
                    print("[clustering] distance computation failed for \(scores[i].id)/\(scores[j].id), treating as not-a-duplicate")
                    #endif
                    continue
                }
                if distance < threshold {
                    union(i, j)
                }
            }
        }

        // Dense, stable cluster IDs (0, 1, 2, ...) in first-seen order --
        // union-find root indices are internal implementation detail, not a
        // meaningful ID to expose.
        var rootToClusterID: [Int: Int] = [:]
        var clusterID: [UUID: Int] = [:]
        var members: [Int: [UUID]] = [:]
        for i in 0..<n {
            let root = find(i)
            let id: Int
            if let existing = rootToClusterID[root] {
                id = existing
            } else {
                id = rootToClusterID.count
                rootToClusterID[root] = id
            }
            clusterID[scores[i].id] = id
            members[id, default: []].append(scores[i].id)
        }

        return Result(clusterID: clusterID, members: members, distanceFailureCount: distanceFailureCount)
    }
}
