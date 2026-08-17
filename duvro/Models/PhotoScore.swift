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
    /// Orientation-corrected source photo dimensions in pixels, read once
    /// via ImageIO (metadata only, no decode) in ScoringService, FROM THE
    /// ORIGINAL -- not the <=1280px downsample: a pixel count needs the
    /// real resolution to mean anything (unlike a ratio, which is
    /// scale-invariant and would read the same off either file).
    /// Orientation-corrected because the raw stored buffer for an
    /// EXIF-rotated photo has width and height SWAPPED relative to how it
    /// actually displays -- the same bug class EditEngine's
    /// renderFullResJPEGData already guards against
    /// (.applyOrientationProperty) for the export path; ScoringService's
    /// own read applies the equivalent correction by hand, since ImageIO's
    /// metadata-only properties call has no transform option the way its
    /// thumbnail generator does. nil only if the dimensions couldn't be
    /// read at all.
    let width: Int?
    let height: Int?
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

    /// Derived from width/height rather than stored separately -- keeping
    /// a third field in sync by hand with the two it's entirely computable
    /// from is exactly the kind of redundancy that drifts. nil under the
    /// same condition width/height's own doc comment describes
    /// (dimensions unreadable, or a corrupt height of 0); clipPenalty's
    /// "nothing clipped" fallback below is unaffected by this being
    /// computed instead of stored -- it already treated nil the same way.
    /// Needed to know which axis the eventual 4:5 crop actually trims, and
    /// by how much, since Vision's face/human boxes are normalized to the
    /// photo's OWN aspect ratio, not to 4:5.
    nonisolated var sourceAspectRatio: Float? {
        guard let width, let height, height > 0 else { return nil }
        return Float(width) / Float(height)
    }

    // MARK: - Derived

    let groupBonus: Float
    /// How much the composite was docked for people clipped by the
    /// eventual 4:5 crop -- see CompositeScoring.clipPenalty. 0 when
    /// sourceAspectRatio is nil (dimensions unreadable) or nothing is
    /// clipped, same as every other photo.
    let clipPenalty: Float
    let compositeScore: Float
    /// Largest detected face's bounding box area as a fraction of the
    /// total image area, 0...1. Vision's face/human boxes are already
    /// normalized to the photo's own [0,1]x[0,1] extent (see faceBoxes'
    /// own doc comment), so box.width * box.height IS that fraction
    /// directly -- no aspect-ratio correction needed, unlike clipPenalty's
    /// crop-window math above. 0, not nil, when there are no faces --
    /// matching every sibling face-derived field already on this type
    /// (faceCount, bestFaceQuality, humanCount all use 0 as their own "no
    /// signal" value; nil would be the one inconsistent field here, and
    /// this is a plain Float everywhere it's read, same as those).
    /// Distinguishes "one small person in a landscape," "one close-up
    /// selfie," and "one full-body portrait" -- all faceCount 1, but very
    /// different largestFaceAreaRatio.
    let largestFaceAreaRatio: Float

    init(
        id: UUID,
        rawAestheticScore: Float,
        isUtility: Bool,
        faceCount: Int,
        bestFaceQuality: Float,
        humanCount: Int = 0,
        faceBoxes: [CGRect] = [],
        humanBoxes: [CGRect] = [],
        width: Int? = nil,
        height: Int? = nil,
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
        self.width = width
        self.height = height
        self.classificationLabels = classificationLabels
        self.category = category
        self.featurePrint = featurePrint
        self.textCoverage = textCoverage
        self.textBlockCount = textBlockCount
        self.rejectionReason = rejectionReason
        self.groupBonus = faceCount >= 2 ? 1.0 : 0.0
        self.largestFaceAreaRatio = faceBoxes.map { Float($0.width * $0.height) }.max() ?? 0
        if let width, let height, height > 0 {
            let cropWindow = CompositeScoring.normalizedCropWindow(sourceAspect: Float(width) / Float(height))
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
