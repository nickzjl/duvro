//
//  ScoringService.swift
//  duvro
//
//  Phase 2: scores and categorizes photos. Produces scores and categories
//  ONLY -- no curation/selection/rejection-pass logic here, that's Phase 3.
//
//  Vision API choice: the new Swift-native async API introduced in iOS 18
//  (ImageRequestHandler + {Calculate,Detect,Generate,Classify}...Request,
//  all `async throws`, confirmed against the actual iOS SDK's
//  Vision.swiftinterface -- not the legacy VNImageRequestHandler/VNRequest
//  completion-handler API). Reasons: it's literally new in iOS 18, our
//  exact minimum deployment target; it's natively async/await, matching
//  every other service in this codebase (PhotoImportService included);
//  and ImageRequestHandler.perform can run several request types in one
//  call. Not mixed with the legacy API anywhere in this file.
//
//  Runs on the <=1280px downsamples from Phase 1, never originals.
//
//  CONFIRMED: VNCalculateImageAestheticsScoresRequest (and friends) do not
//  work in the iOS Simulator -- the neural-inference runtime it needs isn't
//  available there, so every request throws and every photo used to fail
//  silently. Verification for this phase happens on a physical device only.
//

import Foundation
import Vision
import UIKit

@Observable
@MainActor
final class ScoringService {
    private(set) var scores: [PhotoScore] = []
    private(set) var isScoring = false
    private(set) var scoredCount = 0
    private(set) var totalCount = 0
    private(set) var peakMemoryMB: Double = 0
    private(set) var elapsedSeconds: Double = 0

    /// How many photos threw during scoring (Vision failure, not "no faces" or
    /// similar -- those are legitimate results, not failures). A UI showing
    /// `scores` alone can't tell "nothing good in this roll" from "scoring
    /// broke"; this is what makes that distinction possible.
    private(set) var failedCount = 0
    /// Unique failure descriptions (not one per photo -- a systemic failure
    /// like the Simulator's missing neural-inference runtime produces the same
    /// error for every photo, and a list of 200 identical lines isn't useful).
    private(set) var failureReasons: [String] = []

    /// Research spike (item 4) -- computed and displayed, not wired into the composite score.
    private(set) var personClusters: [PersonClusterDisplay] = []

    private static let maxConcurrent = 4
    /// nonisolated: read from scorePhoto, which runs off the main actor.
    nonisolated private static let classificationConfidenceThreshold: Float = 0.1
    nonisolated private static let classificationTopN = 5

    /// Faces below this capture-quality score are excluded from clustering
    /// entirely (item 1a). A face too small, dim, or off-angle to see clearly
    /// carries no reliable identity signal, and on-device testing showed
    /// exactly these faces manufacturing spurious clusters split by lighting/
    /// framing rather than by person. Starting point pending further tuning.
    nonisolated private static let clusteringMinFaceQuality: Float = 0.25

    func score(photos: [Photo]) async {
        isScoring = true
        scores = []
        scoredCount = 0
        totalCount = photos.count
        failedCount = 0
        failureReasons = []
        personClusters = []
        peakMemoryMB = MemoryMonitor.residentMB()
        let startTime = Date()

        let peakTracker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.peakMemoryMB = max(self.peakMemoryMB, MemoryMonitor.residentMB())
                try? await Task.sleep(for: .milliseconds(200))
            }
        }

        var rawResults: [RawPhotoScore] = []
        rawResults.reserveCapacity(photos.count)

        await withTaskGroup(of: ScoreOutcome.self) { group in
            var nextIndex = 0
            func startNext() {
                guard nextIndex < photos.count else { return }
                let photo = photos[nextIndex]
                nextIndex += 1
                group.addTask {
                    await Self.scorePhoto(photo)
                }
            }
            for _ in 0..<min(Self.maxConcurrent, photos.count) { startNext() }
            while let outcome = await group.next() {
                scoredCount += 1
                switch outcome {
                case .success(let result):
                    rawResults.append(result)
                case .failure(let photoID, let error):
                    failedCount += 1
                    let description = String(describing: error)
                    if !failureReasons.contains(description) {
                        failureReasons.append(description)
                    }
                    // Always logged, not DEBUG-only: a Vision failure on a real
                    // device silently producing an empty curation with no
                    // explanation is exactly the bug this replaces.
                    print("[scoring] FAILED \(photoID): \(error)")
                }
                startNext()
            }
        }

        // Pass 2: cluster face feature prints across the whole session (research
        // spike, item 4). Pure post-processing over already-computed feature
        // prints -- no further Vision calls. Faces below the quality floor are
        // excluded entirely (item 1a) -- they don't even become singleton
        // clusters, since a low-quality face isn't reliable identity signal
        // one way or the other.
        var allFacePrints: [FaceFeaturePrint] = []
        for raw in rawResults {
            for crop in raw.faceCrops {
                guard raw.faceObservations.indices.contains(crop.faceIndex) else { continue }
                let quality = raw.faceObservations[crop.faceIndex].captureQuality?.score ?? 0
                guard quality >= Self.clusteringMinFaceQuality else { continue }
                if let fp = crop.featurePrint {
                    allFacePrints.append(FaceFeaturePrint(photoID: raw.photoID, faceIndex: crop.faceIndex, featurePrint: fp))
                }
            }
        }
        let clusters = PersonClusterer.cluster(allFacePrints)

        var clusterIDByFace: [FaceKey: Int] = [:]
        for cluster in clusters {
            for member in cluster.members {
                clusterIDByFace[FaceKey(photoID: member.photoID, faceIndex: member.faceIndex)] = cluster.id
            }
        }

        #if DEBUG
        Self.dumpPairwiseDistances(allFacePrints, clusterIDByFace: clusterIDByFace)
        #endif

        // Build display data for the cluster inspector: crop thumbnails per
        // cluster, each labeled with a short photoID-faceIndex key so it can
        // be cross-referenced against the pairwise-distance console dump.
        var cropsByFace: [FaceKey: UIImage] = [:]
        for raw in rawResults {
            for crop in raw.faceCrops {
                cropsByFace[FaceKey(photoID: raw.photoID, faceIndex: crop.faceIndex)] = UIImage(cgImage: crop.image)
            }
        }
        personClusters = clusters
            .filter { $0.size >= 2 } // singletons aren't "recurring" -- not interesting for the inspector
            .sorted { $0.size > $1.size }
            .map { cluster in
                let members: [ClusterMember] = cluster.members.compactMap { member in
                    let key = FaceKey(photoID: member.photoID, faceIndex: member.faceIndex)
                    guard let thumbnail = cropsByFace[key] else { return nil }
                    return ClusterMember(key: key.shortDescription, thumbnail: thumbnail)
                }
                return PersonClusterDisplay(id: cluster.id, size: cluster.size, members: members)
            }

        // Assemble final scores. importantPersonBoost is computed (a provisional
        // heuristic -- cluster size scaled to 0...1) so it's visible in the debug
        // grid, but CompositeScoring's importantPersonWeight is 0, so it does not
        // affect ranking yet (item 4c).
        var assembled: [PhotoScore] = []
        assembled.reserveCapacity(rawResults.count)
        for raw in rawResults {
            let hasFaces = !raw.faceObservations.isEmpty
            let hasHumans = raw.humanCount > 0
            let labels = raw.classificationLabels.map(\.identifier)
            let category = CategoryMapper.shared.category(hasFaces: hasFaces, hasHumans: hasHumans, labels: labels)
            let bestQuality = raw.faceObservations.compactMap { $0.captureQuality?.score }.max() ?? 0

            let largestClusterSize = raw.faceCrops
                .compactMap { clusterIDByFace[FaceKey(photoID: raw.photoID, faceIndex: $0.faceIndex)] }
                .compactMap { clusterID in clusters.first { $0.id == clusterID }?.size }
                .max() ?? 0
            let clusterID = raw.faceCrops
                .compactMap { clusterIDByFace[FaceKey(photoID: raw.photoID, faceIndex: $0.faceIndex)] }
                .first
            // Provisional scale: a person seen in 6+ photos this session maxes out at 1.0.
            let boost: Float = largestClusterSize >= 2 ? Float(min(1.0, Double(largestClusterSize - 1) / 5.0)) : 0

            var score = PhotoScore(
                id: raw.photoID,
                rawAestheticScore: raw.rawAestheticScore,
                isUtility: raw.isUtility,
                faceCount: raw.faceObservations.count,
                bestFaceQuality: bestQuality,
                humanCount: raw.humanCount,
                classificationLabels: raw.classificationLabels,
                category: category,
                featurePrint: raw.featurePrint,
                personClusterID: clusterID,
                importantPersonBoost: boost
            )
            score.recomputeComposite()
            assembled.append(score)
        }

        scores = assembled
        peakTracker.cancel()
        peakMemoryMB = max(peakMemoryMB, MemoryMonitor.residentMB())
        elapsedSeconds = Date().timeIntervalSince(startTime)
        isScoring = false

        print("[scoring] \(assembled.count)/\(photos.count) scored, \(failedCount) failed, in \(String(format: "%.2f", elapsedSeconds))s, peak resident memory \(String(format: "%.1f", peakMemoryMB)) MB")
        if !failureReasons.isEmpty {
            print("[scoring] failure reasons: \(failureReasons)")
        }
    }

    // MARK: - Cluster-quality diagnostics (item 1c)

    #if DEBUG
    /// Dumps every pairwise feature-print distance among the faces that passed
    /// the quality floor, annotated with which cluster each face landed in.
    /// Cross-reference the short keys here (photoID prefix-faceIndex) against
    /// the labels shown under each thumbnail in the cluster inspector to read
    /// off "same person, different cluster" vs. "different person, same
    /// cluster" distances directly, per item 1c.
    nonisolated private static func dumpPairwiseDistances(_ prints: [FaceFeaturePrint], clusterIDByFace: [FaceKey: Int]) {
        print("[clustering-debug] \(prints.count) faces passed the quality floor (>= \(clusteringMinFaceQuality)) and were clustered")
        guard prints.count > 1 else { return }
        for i in 0..<prints.count {
            for j in (i + 1)..<prints.count {
                let a = prints[i]
                let b = prints[j]
                guard let distance = try? a.featurePrint.distance(to: b.featurePrint) else { continue }
                let aKey = FaceKey(photoID: a.photoID, faceIndex: a.faceIndex)
                let bKey = FaceKey(photoID: b.photoID, faceIndex: b.faceIndex)
                let aCluster = clusterIDByFace[aKey].map(String.init) ?? "?"
                let bCluster = clusterIDByFace[bKey].map(String.init) ?? "?"
                let sameCluster = aCluster == bCluster ? "SAME" : "diff"
                print(String(
                    format: "[clustering-debug] %@ (C%@) <-> %@ (C%@): %.4f [%@]",
                    aKey.shortDescription, aCluster, bKey.shortDescription, bCluster, distance, sameCluster
                ))
            }
        }
    }
    #endif

    // MARK: - Per-photo Vision pipeline (off the main actor)

    nonisolated private struct FaceKey: Hashable {
        let photoID: UUID
        let faceIndex: Int

        /// e.g. "3F2A9C1D-0" -- short enough to eyeball in a console dump or
        /// under a thumbnail, unique enough in practice to cross-reference.
        var shortDescription: String {
            "\(photoID.uuidString.prefix(8))-\(faceIndex)"
        }
    }

    private struct FaceCropData: Sendable {
        let faceIndex: Int
        let image: CGImage
        let featurePrint: FeaturePrintObservation?
    }

    private struct RawPhotoScore: Sendable {
        let photoID: UUID
        let rawAestheticScore: Float
        let isUtility: Bool
        let faceObservations: [FaceObservation]
        let humanCount: Int
        let classificationLabels: [ClassificationLabel]
        let featurePrint: FeaturePrintObservation?
        let faceCrops: [FaceCropData]
    }

    private enum ScoreOutcome: Sendable {
        case success(RawPhotoScore)
        case failure(photoID: UUID, error: Error)
    }

    nonisolated private static func scorePhoto(_ photo: Photo) async -> ScoreOutcome {
        do {
            let handler = ImageRequestHandler(photo.downsampledURL)

            async let aestheticsResult = handler.perform(CalculateImageAestheticsScoresRequest())
            async let featurePrintResult = handler.perform(GenerateImageFeaturePrintRequest())
            async let faceRectResult = handler.perform(DetectFaceRectanglesRequest())
            async let classifyResult = handler.perform(ClassifyImageRequest())
            async let humanRectResult = handler.perform(DetectHumanRectanglesRequest())

            let aesthetics = try await aestheticsResult
            let featurePrint = try await featurePrintResult
            var faces = try await faceRectResult
            let classifications = try await classifyResult
            let humans = try await humanRectResult

            if !faces.isEmpty {
                var qualityRequest = DetectFaceCaptureQualityRequest()
                qualityRequest.inputFaceObservations = faces
                faces = try await handler.perform(qualityRequest)
            }

            var faceCrops: [FaceCropData] = []
            if !faces.isEmpty, let sourceImage = loadCGImage(photo.downsampledURL) {
                for (index, face) in faces.enumerated() {
                    guard let cropped = FaceCropping.crop(face: face.boundingBox, from: sourceImage) else { continue }
                    let cropPrint = try? await ImageRequestHandler(cropped).perform(GenerateImageFeaturePrintRequest())
                    faceCrops.append(FaceCropData(faceIndex: index, image: cropped, featurePrint: cropPrint))
                }
            }

            let topLabels = classifications
                .filter { $0.confidence >= classificationConfidenceThreshold }
                .sorted { $0.confidence > $1.confidence }
                .prefix(classificationTopN)
                .map { ClassificationLabel(identifier: $0.identifier, confidence: $0.confidence) }

            let result = RawPhotoScore(
                photoID: photo.id,
                rawAestheticScore: aesthetics.overallScore,
                isUtility: aesthetics.isUtility,
                faceObservations: faces,
                humanCount: humans.count,
                classificationLabels: Array(topLabels),
                featurePrint: featurePrint,
                faceCrops: faceCrops
            )
            #if DEBUG
            let labelDump = result.classificationLabels.map { "\($0.identifier):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
            print("[scoring-debug] \(photo.id) aesthetic=\(result.rawAestheticScore) isUtility=\(result.isUtility) faces=\(result.faceObservations.count) humans=\(result.humanCount) featurePrint=\(result.featurePrint != nil) labels=[\(labelDump)]")
            #endif
            return .success(result)
        } catch {
            return .failure(photoID: photo.id, error: error)
        }
    }

    nonisolated private static func loadCGImage(_ url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

struct PersonClusterDisplay: Identifiable {
    let id: Int
    let size: Int
    let members: [ClusterMember]
}

struct ClusterMember: Identifiable {
    var id: String { key }
    let key: String
    let thumbnail: UIImage
}
