//
//  ScoringService.swift
//  duvro
//
//  Phase 2: scores and categorizes photos. Produces scores and categories
//  ONLY -- no curation/selection/rejection-pass logic here, that's Phase 3.
//  (Hard-reject at the individual-photo level, per CompositeScoring's
//  rejectionReason, is Phase 2's job -- it's Vision's own output disqualifying
//  a photo, not a cross-photo selection decision.)
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
//
//  PER-PHOTO PIPELINE is two stages with a gate between them:
//    Stage 1: aesthetics + classification + text recognition
//    GATE:    CompositeScoring.rejectionReason(...) -- if non-nil, return early
//    Stage 2: face rectangles, face capture quality, human rectangles,
//             whole-image feature print
//  A rejected photo's Stage 2 requests are never created, let alone awaited --
//  this is Vision nominating candidates cheaply before spending the more
//  expensive per-photo work on faces/bodies/features. See scorePhoto below.
//
//  Text recognition (RecognizeTextRequest, .fast level) runs for EVERY photo
//  in Stage 1, rejected or not -- it's measurement, not a gate. isUtility is
//  uninformative on real camera rolls (fires on receipts and game-stat
//  screenshots, but equally on plated food and gym POV shots); the working
//  hypothesis is that text coverage is what actually separates junk from
//  keepers, but that needs data before it becomes a rule. textCoverage/
//  textBlockCount are stored on PhotoScore and shown in the debug grid;
//  nothing reads them yet -- see CompositeScoring, untouched by this.
//

import Foundation
import ImageIO
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
                case .success(let raw):
                    // Appended to `scores` AS EACH PHOTO COMPLETES, not
                    // batched into a local array and assigned once at the
                    // end -- `scores` is @Observable, so a caller (the
                    // curation-progress screen) can read "whatever's
                    // scored so far" at any moment, not just after the
                    // whole pass finishes. Concurrent tasks finish in
                    // completion order, not `photos`' own order -- that
                    // was already true of the old batched-at-the-end
                    // array too, so nothing downstream that ranks by
                    // compositeScore rather than position is affected.
                    scores.append(Self.assemblePhotoScore(from: raw))
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

        peakTracker.cancel()
        peakMemoryMB = max(peakMemoryMB, MemoryMonitor.residentMB())
        elapsedSeconds = Date().timeIntervalSince(startTime)
        isScoring = false

        let rejectedCount = scores.count { $0.isHardRejected }
        print("[scoring] \(scores.count)/\(photos.count) scored (\(rejectedCount) rejected), \(failedCount) failed, in \(String(format: "%.2f", elapsedSeconds))s, peak resident memory \(String(format: "%.1f", peakMemoryMB)) MB")
        if !failureReasons.isEmpty {
            print("[scoring] failure reasons: \(failureReasons)")
        }
    }

    /// Factored out of the old end-of-pass assembly loop so a single
    /// completed photo can be converted the instant it arrives (see the
    /// `.success` case above) instead of waiting for the whole batch.
    nonisolated private static func assemblePhotoScore(from raw: RawPhotoScore) -> PhotoScore {
        let hasFaces = !raw.faceObservations.isEmpty
        let hasHumans = raw.humanCount > 0
        // Full ClassificationLabel objects, not just identifiers -- confidence
        // travels with each label now so CategoryMapper can apply its own,
        // higher-than-the-top-5-floor confidence bar for accepting a category
        // match (see CategoryMapper.categoryMatchConfidenceThreshold).
        let category = CategoryMapper.shared.category(hasFaces: hasFaces, hasHumans: hasHumans, labels: raw.classificationLabels)
        let bestQuality = raw.faceObservations.compactMap { $0.captureQuality?.score }.max() ?? 0

        return PhotoScore(
            id: raw.photoID,
            rawAestheticScore: raw.rawAestheticScore,
            isUtility: raw.isUtility,
            faceCount: raw.faceObservations.count,
            bestFaceQuality: bestQuality,
            humanCount: raw.humanCount,
            faceBoxes: raw.faceObservations.map { $0.boundingBox.cgRect },
            humanBoxes: raw.humanBoxes,
            width: raw.width,
            height: raw.height,
            classificationLabels: raw.classificationLabels,
            category: category,
            featurePrint: raw.featurePrint,
            textCoverage: raw.textCoverage,
            textBlockCount: raw.textBlockCount,
            rejectionReason: raw.rejectionReason
        )
    }

    // MARK: - Per-photo Vision pipeline (off the main actor)

    private struct RawPhotoScore: Sendable {
        let photoID: UUID
        let rawAestheticScore: Float
        let isUtility: Bool
        let faceObservations: [FaceObservation]
        let humanCount: Int
        /// DetectHumanRectanglesRequest's own boxes, kept (not just
        /// counted, unlike humanCount above) so the clip-penalty check has
        /// something to test against the eventual 4:5 crop.
        let humanBoxes: [CGRect]
        /// Orientation-corrected source photo dimensions (from
        /// photo.originalURL, NOT downsampledURL -- see imageDimensions'
        /// own doc comment for why the real, not scaled, resolution
        /// matters here). ImageIO metadata only -- no decode. nil if
        /// unreadable; the clip-penalty check then treats that the same
        /// as "nothing clipped" rather than guessing an aspect ratio.
        let width: Int?
        let height: Int?
        let classificationLabels: [ClassificationLabel]
        let featurePrint: FeaturePrintObservation?
        let textCoverage: Float
        let textBlockCount: Int
        let rejectionReason: CompositeScoring.RejectionReason?
    }

    private enum ScoreOutcome: Sendable {
        case success(RawPhotoScore)
        case failure(photoID: UUID, error: Error)
    }

    nonisolated private static func scorePhoto(_ photo: Photo) async -> ScoreOutcome {
        do {
            let handler = ImageRequestHandler(photo.downsampledURL)
            let dimensions = imageDimensions(at: photo.originalURL)

            // MARK: Stage 1 -- aesthetics + classification + text recognition.
            let textRequest: RecognizeTextRequest = {
                var request = RecognizeTextRequest()
                request.recognitionLevel = .fast // coverage, not transcription
                return request
            }()

            async let aestheticsResult = handler.perform(CalculateImageAestheticsScoresRequest())
            async let classifyResult = handler.perform(ClassifyImageRequest())
            async let textResult = handler.perform(textRequest)

            let aesthetics = try await aestheticsResult
            let classifications = try await classifyResult
            let textObservations = try await textResult

            let topLabels = classifications
                .filter { $0.confidence >= classificationConfidenceThreshold }
                .sorted { $0.confidence > $1.confidence }
                .prefix(classificationTopN)
                .map { ClassificationLabel(identifier: $0.identifier, confidence: $0.confidence) }
            let labels = Array(topLabels)

            let (textCoverage, textBlockCount) = computeTextCoverage(from: textObservations)

            // MARK: GATE.
            let normalizedAesthetic = CompositeScoring.normalizeAesthetic(aesthetics.overallScore)
            let rejection = CompositeScoring.rejectionReason(
                isUtility: aesthetics.isUtility,
                normalizedAesthetic: normalizedAesthetic,
                labels: labels
            )

            if let rejection {
                // Early return: Stage 2's requests are never created here, not
                // computed and discarded. No face/human/feature-print Vision
                // call happens for a rejected photo.
                #if DEBUG
                print("[scoring-debug] \(photo.id) REJECTED (\(rejection.displayDescription)) aesthetic=\(aesthetics.overallScore) isUtility=\(aesthetics.isUtility) textCoverage=\(textCoverage) textBlocks=\(textBlockCount)")
                #endif
                return .success(RawPhotoScore(
                    photoID: photo.id,
                    rawAestheticScore: aesthetics.overallScore,
                    isUtility: aesthetics.isUtility,
                    faceObservations: [],
                    humanCount: 0,
                    humanBoxes: [],
                    width: dimensions?.width,
                    height: dimensions?.height,
                    classificationLabels: labels,
                    featurePrint: nil,
                    textCoverage: textCoverage,
                    textBlockCount: textBlockCount,
                    rejectionReason: rejection
                ))
            }

            // MARK: Stage 2 -- face rectangles, face capture quality, human
            // rectangles, whole-image feature print. Only reached when Stage 1
            // did not reject the photo.
            async let featurePrintResult = handler.perform(GenerateImageFeaturePrintRequest())
            async let faceRectResult = handler.perform(DetectFaceRectanglesRequest())
            async let humanRectResult = handler.perform(DetectHumanRectanglesRequest())

            let featurePrint = try await featurePrintResult
            var faces = try await faceRectResult
            let humans = try await humanRectResult

            if !faces.isEmpty {
                var qualityRequest = DetectFaceCaptureQualityRequest()
                qualityRequest.inputFaceObservations = faces
                faces = try await handler.perform(qualityRequest)
            }

            let result = RawPhotoScore(
                photoID: photo.id,
                rawAestheticScore: aesthetics.overallScore,
                isUtility: aesthetics.isUtility,
                faceObservations: faces,
                humanCount: humans.count,
                humanBoxes: humans.map { $0.boundingBox.cgRect },
                width: dimensions?.width,
                height: dimensions?.height,
                classificationLabels: labels,
                featurePrint: featurePrint,
                textCoverage: textCoverage,
                textBlockCount: textBlockCount,
                rejectionReason: nil
            )
            #if DEBUG
            let labelDump = result.classificationLabels.map { "\($0.identifier):\(String(format: "%.2f", $0.confidence))" }.joined(separator: ", ")
            print("[scoring-debug] \(photo.id) aesthetic=\(result.rawAestheticScore) isUtility=\(result.isUtility) faces=\(result.faceObservations.count) humans=\(result.humanCount) featurePrint=\(result.featurePrint != nil) textCoverage=\(textCoverage) textBlocks=\(textBlockCount) labels=[\(labelDump)]")
            #endif
            return .success(result)
        } catch {
            return .failure(photoID: photo.id, error: error)
        }
    }

    /// Orientation-corrected width/height of the source photo, read from
    /// the ORIGINAL (not the <=1280px downsample -- see PhotoScore.width's
    /// own doc comment for why absolute pixel counts need the real file,
    /// unlike a ratio which is scale-invariant) via ImageIO metadata only
    /// (CGImageSourceCopyPropertiesAtIndex -- no decode). Same
    /// metadata-only technique already used elsewhere in the app
    /// (ExportService's diagnostic, PhotoImportService.captureDate) --
    /// cheap, no new decode cost added to the scoring pass.
    ///
    /// ORIENTATION: kCGImagePropertyPixelWidth/Height are the RAW stored
    /// buffer's dimensions, not what the photo actually displays as --
    /// for an EXIF-rotated photo (orientation 5-8: leftMirrored, right,
    /// rightMirrored, left -- CGImagePropertyOrientation's own raw
    /// values, confirmed against the actual enum, not assumed) the buffer
    /// is stored 90° rotated from its displayed orientation, so width and
    /// height are swapped relative to how the photo looks. This is the
    /// exact bug class that already bit the export path (EditEngine's
    /// renderFullResJPEGData needed .applyOrientationProperty for the
    /// same reason) -- unlike that path, ImageIO's metadata-only
    /// properties call has no transform option, so the swap is done here
    /// by hand rather than relying on a decode-time flag. Orientations
    /// 1-4 (normal, flipped, 180°, flipped+180°) never swap the axes.
    nonisolated private static func imageDimensions(at url: URL) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let rawWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let rawHeight = properties[kCGImagePropertyPixelHeight] as? Int else {
            return nil
        }
        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let swapped = (5...8).contains(orientation)
        return swapped ? (rawHeight, rawWidth) : (rawWidth, rawHeight)
    }

    /// Coverage = fraction of the frame covered by text bounding boxes,
    /// deduplicated so overlapping boxes don't double-count: rasterize the
    /// union onto a coarse 64x64 grid and count set cells. Deliberately
    /// simple -- this is a debug metric, not shipping geometry. Coordinates
    /// are Vision's normalized 0...1 space on both axes, so grid cells sum
    /// directly to a fraction of the frame with no pixel conversion needed.
    nonisolated private static func computeTextCoverage(from observations: [RecognizedTextObservation]) -> (coverage: Float, blockCount: Int) {
        let gridSize = 64
        var grid = [Bool](repeating: false, count: gridSize * gridSize)

        func gridIndex(_ normalized: CGFloat) -> Int {
            let clamped = min(max(normalized, 0), 1)
            return min(gridSize - 1, Int(clamped * CGFloat(gridSize)))
        }

        for observation in observations {
            let box = observation.boundingBox.cgRect
            let minX = gridIndex(box.minX)
            let maxX = gridIndex(box.maxX)
            let minY = gridIndex(box.minY)
            let maxY = gridIndex(box.maxY)
            guard minX <= maxX, minY <= maxY else { continue }
            for y in minY...maxY {
                for x in minX...maxX {
                    grid[y * gridSize + x] = true
                }
            }
        }

        let setCells = grid.reduce(0) { $0 + ($1 ? 1 : 0) }
        return (Float(setCells) / Float(gridSize * gridSize), observations.count)
    }
}
