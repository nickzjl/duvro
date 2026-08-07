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
    /// Top N classification labels above the confidence threshold, confidence-sorted descending.
    /// Computed in Stage 1, so present even for a rejected photo.
    let classificationLabels: [ClassificationLabel]
    let category: PhotoCategory
    /// Stored for Phase 3 dedupe. nil for a rejected photo -- Stage 2
    /// (GenerateImageFeaturePrintRequest) never ran. Not consumed this phase.
    let featurePrint: FeaturePrintObservation?

    // MARK: - Rejection

    /// Set once, in Stage 1 (ScoringService.scorePhoto), before Stage 2 ever
    /// runs -- this is the single source of truth for whether a photo was
    /// rejected and why. Not re-derived here.
    let rejectionReason: CompositeScoring.RejectionReason?

    var isHardRejected: Bool { rejectionReason != nil }

    // MARK: - Derived

    let groupBonus: Float
    let compositeScore: Float

    init(
        id: UUID,
        rawAestheticScore: Float,
        isUtility: Bool,
        faceCount: Int,
        bestFaceQuality: Float,
        humanCount: Int = 0,
        classificationLabels: [ClassificationLabel],
        category: PhotoCategory,
        featurePrint: FeaturePrintObservation?,
        rejectionReason: CompositeScoring.RejectionReason? = nil
    ) {
        self.id = id
        self.rawAestheticScore = rawAestheticScore
        self.isUtility = isUtility
        self.faceCount = faceCount
        self.bestFaceQuality = bestFaceQuality
        self.humanCount = humanCount
        self.classificationLabels = classificationLabels
        self.category = category
        self.featurePrint = featurePrint
        self.rejectionReason = rejectionReason
        self.groupBonus = faceCount >= 2 ? 1.0 : 0.0
        self.compositeScore = CompositeScoring.compute(
            aesthetic: CompositeScoring.normalizeAesthetic(rawAestheticScore),
            faceQuality: bestFaceQuality,
            groupBonus: faceCount >= 2 ? 1.0 : 0.0,
            rejectionReason: rejectionReason
        )
    }
}
