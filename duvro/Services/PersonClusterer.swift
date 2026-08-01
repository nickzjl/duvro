//
//  PersonClusterer.swift
//  duvro
//
//  Greedy nearest-neighbor clustering of face feature prints across a
//  session. Deliberately isolated from Vision I/O so it's a pure function
//  over already-computed distances -- easy to unit test and easy to
//  re-tune the threshold without re-running Vision.
//
//  IMPORTANT CAVEAT (see item 4 in the Phase 2 brief): GenerateImageFeaturePrintRequest
//  is a general-purpose image similarity embedding, not a face-identity
//  embedding -- Vision exposes no public face recognition API. Clustering
//  general feature prints on face crops may group by lighting, angle, or
//  background rather than by person. This is a research spike; see
//  ScoringService's cluster-quality report.
//

import Foundation
import Vision

struct FaceFeaturePrint: Sendable {
    let photoID: UUID
    let faceIndex: Int
    let featurePrint: FeaturePrintObservation
}

struct PersonCluster: Identifiable, Sendable {
    let id: Int
    var members: [(photoID: UUID, faceIndex: Int)]
    var size: Int { members.count }
}

enum PersonClusterer {
    /// Starting point pending empirical tuning against real face-crop distances
    /// (see the cluster-quality report). Smaller = stricter (fewer, tighter
    /// clusters); larger = looser (more false merges).
    static let defaultDistanceThreshold: Double = 0.6

    /// Greedy nearest-neighbor: each print joins the cluster containing its
    /// single nearest existing member, if that distance is under the
    /// threshold; otherwise it starts a new cluster. Order-dependent (a known
    /// limitation of greedy online clustering) but simple and fast enough for
    /// a few hundred faces.
    static func cluster(_ prints: [FaceFeaturePrint], distanceThreshold: Double = defaultDistanceThreshold) -> [PersonCluster] {
        var clusters: [[FaceFeaturePrint]] = []

        for print in prints {
            var bestClusterIndex: Int?
            var bestDistance = Double.greatestFiniteMagnitude

            for (index, cluster) in clusters.enumerated() {
                for member in cluster {
                    guard let distance = try? member.featurePrint.distance(to: print.featurePrint) else { continue }
                    if distance < bestDistance {
                        bestDistance = distance
                        bestClusterIndex = index
                    }
                }
            }

            if let bestClusterIndex, bestDistance < distanceThreshold {
                clusters[bestClusterIndex].append(print)
            } else {
                clusters.append([print])
            }
        }

        return clusters.enumerated().map { index, members in
            PersonCluster(id: index, members: members.map { ($0.photoID, $0.faceIndex) })
        }
    }
}
