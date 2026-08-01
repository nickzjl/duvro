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

    /// Research spike (item 4) -- computed and displayed, not wired into the composite score.
    private(set) var personClusters: [PersonClusterDisplay] = []

    private static let maxConcurrent = 4
    private static let classificationConfidenceThreshold: Float = 0.1
    private static let classificationTopN = 5

    func score(photos: [Photo]) async {
        isScoring = true
        scores = []
        scoredCount = 0
        totalCount = photos.count
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

        await withTaskGroup(of: RawPhotoScore?.self) { group in
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
            while let result = await group.next() {
                scoredCount += 1
                if let result {
                    rawResults.append(result)
                }
                startNext()
            }
        }

        // Pass 2: cluster face feature prints across the whole session (research
        // spike, item 4). Pure post-processing over already-computed feature
        // prints -- no further Vision calls.
        var allFacePrints: [FaceFeaturePrint] = []
        for raw in rawResults {
            for crop in raw.faceCrops {
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

        // Build display data for the cluster inspector: crop thumbnails per cluster.
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
                let thumbnails = cluster.members.compactMap { cropsByFace[FaceKey(photoID: $0.photoID, faceIndex: $0.faceIndex)] }
                return PersonClusterDisplay(id: cluster.id, size: cluster.size, thumbnails: thumbnails)
            }

        // Assemble final scores. importantPersonBoost is computed (a provisional
        // heuristic -- cluster size scaled to 0...1) so it's visible in the debug
        // grid, but CompositeScoring's importantPersonWeight is 0, so it does not
        // affect ranking yet (item 4c).
        var assembled: [PhotoScore] = []
        assembled.reserveCapacity(rawResults.count)
        for raw in rawResults {
            let hasFaces = !raw.faceObservations.isEmpty
            let labels = raw.classificationLabels.map(\.identifier)
            let category = CategoryMapper.shared.category(hasFaces: hasFaces, labels: labels)
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

        print("[scoring] \(assembled.count)/\(photos.count) photos scored in \(String(format: "%.2f", elapsedSeconds))s, peak resident memory \(String(format: "%.1f", peakMemoryMB)) MB")
    }

    // MARK: - Per-photo Vision pipeline (off the main actor)

    private struct FaceKey: Hashable {
        let photoID: UUID
        let faceIndex: Int
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
        let classificationLabels: [ClassificationLabel]
        let featurePrint: FeaturePrintObservation?
        let faceCrops: [FaceCropData]
    }

    nonisolated private static func scorePhoto(_ photo: Photo) async -> RawPhotoScore? {
        do {
            let handler = ImageRequestHandler(photo.downsampledURL)

            async let aestheticsResult = handler.perform(CalculateImageAestheticsScoresRequest())
            async let featurePrintResult = handler.perform(GenerateImageFeaturePrintRequest())
            async let faceRectResult = handler.perform(DetectFaceRectanglesRequest())
            async let classifyResult = handler.perform(ClassifyImageRequest())

            let aesthetics = try await aestheticsResult
            let featurePrint = try await featurePrintResult
            var faces = try await faceRectResult
            let classifications = try await classifyResult

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

            return RawPhotoScore(
                photoID: photo.id,
                rawAestheticScore: aesthetics.overallScore,
                isUtility: aesthetics.isUtility,
                faceObservations: faces,
                classificationLabels: Array(topLabels),
                featurePrint: featurePrint,
                faceCrops: faceCrops
            )
        } catch {
            return nil
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
    let thumbnails: [UIImage]
}
