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
//  NOTE: this file previously also cropped faces, feature-printed the crops,
//  and clustered them across the session to detect recurring people. That
//  was removed -- not because it was buggy, but because the approach is
//  wrong at the design level: a general Vision feature print encodes
//  lighting/framing/composition, not identity, and on-device testing showed
//  same-person and different-person distances overlapping completely.
//  Vision exposes no public face-recognition API. See git history
//  (pre-removal) if this is ever revisited with a different approach.

import Foundation
import Vision

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

    private static let maxConcurrent = 4
    /// nonisolated: read from scorePhoto, which runs off the main actor.
    nonisolated private static let classificationConfidenceThreshold: Float = 0.1
    nonisolated private static let classificationTopN = 5

    func score(photos: [Photo]) async {
        isScoring = true
        scores = []
        scoredCount = 0
        totalCount = photos.count
        failedCount = 0
        failureReasons = []
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

        // Assemble final scores.
        var assembled: [PhotoScore] = []
        assembled.reserveCapacity(rawResults.count)
        for raw in rawResults {
            let hasFaces = !raw.faceObservations.isEmpty
            let hasHumans = raw.humanCount > 0
            let labels = raw.classificationLabels.map(\.identifier)
            let category = CategoryMapper.shared.category(hasFaces: hasFaces, hasHumans: hasHumans, labels: labels)
            let bestQuality = raw.faceObservations.compactMap { $0.captureQuality?.score }.max() ?? 0

            let score = PhotoScore(
                id: raw.photoID,
                rawAestheticScore: raw.rawAestheticScore,
                isUtility: raw.isUtility,
                faceCount: raw.faceObservations.count,
                bestFaceQuality: bestQuality,
                humanCount: raw.humanCount,
                classificationLabels: raw.classificationLabels,
                category: category,
                featurePrint: raw.featurePrint
            )
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

    // MARK: - Per-photo Vision pipeline (off the main actor)

    private struct RawPhotoScore: Sendable {
        let photoID: UUID
        let rawAestheticScore: Float
        let isUtility: Bool
        let faceObservations: [FaceObservation]
        let humanCount: Int
        let classificationLabels: [ClassificationLabel]
        let featurePrint: FeaturePrintObservation?
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
                featurePrint: featurePrint
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
}
