//
//  PhotoScore.swift
//  duvro
//
//  Phase 2 scoring output, kept separate from Photo.swift (the import
//  model) so scoring can be unit-tested with plain values and doesn't
//  entangle the import pipeline with Vision types.
//

import Foundation
import Vision

enum PhotoCategory: String, Codable, CaseIterable, Sendable {
    case people, place, food, detail
}

struct ClassificationLabel: Sendable, Equatable {
    let identifier: String
    let confidence: Float
}

struct PhotoScore: Identifiable, Sendable {
    /// Matches the originating Photo.id.
    let id: UUID

    // MARK: - Raw Vision output (kept for the debug grid, not all used in composite yet)

    /// Vision's raw ImageAestheticsScoresObservation.overallScore.
    let rawAestheticScore: Float
    let isUtility: Bool
    /// 0 for a rejected photo -- Stage 2 (face detection) never ran, this
    /// isn't "zero faces found."
    let faceCount: Int
    /// 0 if no faces (including: rejected, Stage 2 skipped); else the best
    /// (highest) FaceObservation.CaptureQuality.score among faces.
    let bestFaceQuality: Float
    /// 0 for a rejected photo -- Stage 2 (DetectHumanRectanglesRequest)
    /// never ran. Otherwise catches mirror shots, distant, and back-turned
    /// subjects with no detectable face. Only affects categorization (see
    /// `category`); face count/quality/group bonus are unaffected.
    let humanCount: Int
    /// Normalized (0...1, Vision's own coordinate convention) bounding
    /// boxes from DetectFaceRectanglesRequest/DetectHumanRectanglesRequest
    /// -- kept (not just counted) so `clipPenalty` below can test them
    /// against the eventual 4:5 crop window. [] for a rejected photo.
    let faceBoxes: [CGRect]
    let humanBoxes: [CGRect]
    /// Source photo's width/height, read once via ImageIO (metadata only,
    /// no decode) in ScoringService -- needed to know which axis the 4:5
    /// crop actually trims, and by how much, since Vision's boxes are
    /// normalized to the photo's OWN aspect ratio, not to 4:5. nil only if
    /// the dimensions couldn't be read; `clipPenalty` treats that the same
    /// as "nothing clipped" rather than guessing.
    let sourceAspectRatio: Float?
    /// Top N classification labels above the confidence threshold, confidence-sorted descending.
    /// Computed in Stage 1, so present even for a rejected photo.
    let classificationLabels: [ClassificationLabel]
    let category: PhotoCategory
    /// Stored for Phase 3 dedupe. nil for a rejected photo -- Stage 2
    /// (GenerateImageFeaturePrintRequest) never ran. Not consumed this phase.
    let featurePrint: FeaturePrintObservation?

    // MARK: - Text coverage (measurement only -- see ScoringService.textCoverage)

    /// Fraction (0...1) of the frame covered by RecognizeTextRequest bounding
    /// boxes, deduplicated via a coarse grid so overlapping boxes don't
    /// double-count. Computed in Stage 1 for EVERY photo, including rejected
    /// ones -- this is data collection for a future cutoff, not a signal
    /// anything reads yet.
    let textCoverage: Float
    /// Number of RecognizeTextRequest observations (a receipt and a road
    /// sign can have similar coverage but very different block counts).
    let textBlockCount: Int

    // MARK: - Rejection

    /// Set once, in Stage 1 (ScoringService.scorePhoto), before Stage 2 ever
    /// runs -- this is the single source of truth for whether a photo was
    /// rejected and why. Not re-derived here.
    let rejectionReason: CompositeScoring.RejectionReason?

    /// nonisolated: pure computation over an already-captured immutable
    /// value, called from ShortlistService's nonisolated clustering/shortlist
    /// pass (SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor otherwise isolates
    /// this by default -- same pattern as CompositeScoring, see that file).
    nonisolated var isHardRejected: Bool { rejectionReason != nil }

    // MARK: - Derived

    let groupBonus: Float
    /// How much the composite was docked for people clipped by the
    /// eventual 4:5 crop -- see CompositeScoring.clipPenalty. 0 when
    /// sourceAspectRatio is nil (dimensions unreadable) or nothing is
    /// clipped, same as every other photo.
    let clipPenalty: Float
    let compositeScore: Float

    init(
        id: UUID,
        rawAestheticScore: Float,
        isUtility: Bool,
        faceCount: Int,
        bestFaceQuality: Float,
        humanCount: Int = 0,
        faceBoxes: [CGRect] = [],
        humanBoxes: [CGRect] = [],
        sourceAspectRatio: Float? = nil,
        classificationLabels: [ClassificationLabel],
        category: PhotoCategory,
        featurePrint: FeaturePrintObservation?,
        textCoverage: Float = 0,
        textBlockCount: Int = 0,
        rejectionReason: CompositeScoring.RejectionReason? = nil
    ) {
        self.id = id
        self.rawAestheticScore = rawAestheticScore
        self.isUtility = isUtility
        self.faceCount = faceCount
        self.bestFaceQuality = bestFaceQuality
        self.humanCount = humanCount
        self.faceBoxes = faceBoxes
        self.humanBoxes = humanBoxes
        self.sourceAspectRatio = sourceAspectRatio
        self.classificationLabels = classificationLabels
        self.category = category
        self.featurePrint = featurePrint
        self.textCoverage = textCoverage
        self.textBlockCount = textBlockCount
        self.rejectionReason = rejectionReason
        self.groupBonus = faceCount >= 2 ? 1.0 : 0.0
        if let sourceAspectRatio {
            let cropWindow = CompositeScoring.normalizedCropWindow(sourceAspect: sourceAspectRatio)
            self.clipPenalty = CompositeScoring.clipPenalty(faceBoxes: faceBoxes, humanBoxes: humanBoxes, cropWindow: cropWindow)
        } else {
            self.clipPenalty = 0
        }
        self.compositeScore = CompositeScoring.compute(
            aesthetic: CompositeScoring.normalizeAesthetic(rawAestheticScore),
            faceQuality: bestFaceQuality,
            groupBonus: faceCount >= 2 ? 1.0 : 0.0,
            clipPenalty: self.clipPenalty,
            rejectionReason: rejectionReason
        )
    }
}
