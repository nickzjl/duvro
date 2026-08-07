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
    let faceCount: Int
    /// 0 if no faces; else the best (highest) FaceObservation.CaptureQuality.score among faces.
    let bestFaceQuality: Float
    /// DetectHumanRectanglesRequest count -- catches mirror shots, distant, and
    /// back-turned subjects with no detectable face. Only affects categorization
    /// (see `category`); face count/quality/group bonus are unaffected.
    let humanCount: Int
    /// Top N classification labels above the confidence threshold, confidence-sorted descending.
    let classificationLabels: [ClassificationLabel]
    let category: PhotoCategory
    /// Stored for Phase 3 dedupe. Not consumed this phase.
    let featurePrint: FeaturePrintObservation?

    // MARK: - Derived

    let groupBonus: Float
    var sharpness: Float?
    let compositeScore: Float

    /// isUtility alone false-positives on ordinary photos that share visual
    /// traits with documents/screenshots -- observed on-device: a gym-bench
    /// photo and a laptop-on-desk photo were both flagged despite non-low
    /// aesthetic scores. True iff both isUtility AND the aesthetic score is
    /// also low, so a genuine utility image (which should score poorly on
    /// aesthetics too, since it's not a composed photograph) is still caught.
    var isHardRejected: Bool {
        CompositeScoring.isHardRejected(isUtility: isUtility, normalizedAesthetic: CompositeScoring.normalizeAesthetic(rawAestheticScore))
    }

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
        sharpness: Float? = nil
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
        self.groupBonus = faceCount >= 2 ? 1.0 : 0.0
        self.sharpness = sharpness
        self.compositeScore = CompositeScoring.compute(
            aesthetic: CompositeScoring.normalizeAesthetic(rawAestheticScore),
            faceQuality: bestFaceQuality,
            groupBonus: faceCount >= 2 ? 1.0 : 0.0,
            sharpness: sharpness ?? 1.0,
            isUtility: isUtility
        )
    }
}
