//
//  CompositeScoring.swift
//  duvro
//
//  Pure, testable composite-score math. No Vision imports, no I/O -- kept
//  this way specifically so unit tests can exercise it with plain values.
//
//  BUILD_ROADMAP Phase 2's original starting weights were 0.4 aesthetic +
//  0.25 (a boost for photos containing a recurring person across the
//  session) + 0.2 faceQuality + 0.1 groupBonus + 0.05 sharpness.
//
//  The recurring-person term is gone entirely: the detection mechanism
//  behind it was a design-level dead end (a general Vision feature print
//  encodes lighting/framing, not identity), not a tuning problem, so
//  there's no weight to hold a place for. See git history for the removed
//  implementation.
//
//  sharpness is also gone: it was never computed (no Laplacian-variance
//  check was built), so it silently defaulted to 1.0 and contributed a
//  flat, uniform amount to every photo's composite regardless of actual
//  sharpness -- bookkeeping noise, not a real signal. A real sharpness
//  term can be added later (Laplacian variance via vImage, per
//  BUILD_ROADMAP Phase 2) if the aesthetic score proves insufficient at
//  catching blur on its own; nothing here rules that out.
//
//  The three remaining weights (aesthetic/faceQuality/groupBonus) are
//  RENORMALIZED to sum to 1.0 using their ORIGINAL relative proportions
//  (0.4 : 0.2 : 0.1, i.e. divided by 0.7, the sum of those three) --
//  their relative weighting against each other is unchanged, only the
//  absolute scale shifts. This is a monotone affine transform: relative
//  rankings are identical to before; only the absolute composite values
//  rise.
//
//  REJECTION is now a two-rule OR, not isUtility alone:
//
//  1. Classification-label reject (labelRejectThresholds). isUtility is
//     tuned for receipts and text-heavy captures; on-device testing found
//     it returns false for screenshots of photo grids (e.g. a camera-roll
//     screenshot), which read as photographic to that classifier. But
//     ClassifyImageRequest correctly labels those images `screenshot` at
//     high confidence -- the category mapper was just discarding that
//     label (unmapped to people/place/food/detail) and falling through to
//     a face-count-driven `people` categorization instead of using it as
//     a reject signal. This rule fires on the label directly, independent
//     of isUtility.
//
//  2. isUtility AND a low aesthetic score (unchanged from before) --
//     isUtility ALONE over-fires on ordinary photos (observed on-device: a
//     gym-bench photo and a laptop-on-desk photo were both flagged despite
//     non-low aesthetic scores). A genuine screenshot/receipt/document
//     isn't a composed photograph at all and should score poorly on
//     aesthetics too, so requiring both still catches the real case while
//     sparing a merely-misclassified ordinary photo.
//

import Foundation

/// Pure and stateless -- explicitly nonisolated so it can be called from
/// ScoringService's nonisolated per-photo Vision pipeline (the Stage 1/GATE
/// decision happens there) without an actor hop back to MainActor (the
/// project default per SWIFT_DEFAULT_ACTOR_ISOLATION).
nonisolated enum CompositeScoring {
    /// Sum of the three surviving original weights (0.4 + 0.2 + 0.1).
    private static let renormalizationFactor: Float = 1.0 / 0.7

    static let aestheticWeight: Float = 0.4 * renormalizationFactor
    static let faceQualityWeight: Float = 0.2 * renormalizationFactor
    static let groupBonusWeight: Float = 0.1 * renormalizationFactor

    /// Normalized (0...1) aesthetic ceiling below which an isUtility flag is
    /// trusted enough to hard-reject. Starting point pending tuning: the
    /// observed false-positive (gym bench) normalized to ~0.63, comfortably
    /// above this, so it would now be spared.
    static let utilityAestheticGate: Float = 0.35

    /// Classification labels that hard-reject a photo outright, independent
    /// of isUtility, with the minimum confidence required to trigger. One
    /// clearly-named place to tune both the label set and the threshold.
    ///
    /// `document` is deliberately NOT included. Unlike `screenshot`, it
    /// isn't a reliable "this isn't a real photo" signal -- it would also
    /// catch legitimate photos of menus, notes, signage, and books, which
    /// are valid `detail` picks. On the one on-device test image checked
    /// while building this, `document` and `screenshot` scored within
    /// 0.0001 of each other (0.6074 each) -- confirming they're too close
    /// in confidence to use as a shared signal; only `screenshot` is safe
    /// to reject on.
    static let labelRejectThresholds: [String: Float] = [
        "screenshot": 0.5
    ]

    enum RejectionReason: Equatable, Sendable {
        case label(String, confidence: Float)
        case utility(normalizedAesthetic: Float)

        var displayDescription: String {
            switch self {
            case .label(let identifier, let confidence):
                return "label: \(identifier) \(String(format: "%.3f", confidence))"
            case .utility(let normalizedAesthetic):
                return "utility: aesthetic \(String(format: "%.3f", normalizedAesthetic)) < \(utilityAestheticGate)"
            }
        }
    }

    /// Vision's ImageAestheticsScoresObservation.overallScore is documented
    /// in the range -1...1 (more positive = more pleasing). Normalize to
    /// 0...1 so it combines sensibly with the other 0...1 terms.
    static func normalizeAesthetic(_ raw: Float) -> Float {
        ((raw + 1) / 2).clamped(to: 0...1)
    }

    /// The single label (highest-confidence match, if more than one clears
    /// its threshold) that trips the label-reject rule, or nil.
    static func firstRejectedLabel(in labels: [ClassificationLabel]) -> ClassificationLabel? {
        labels
            .filter { label in
                guard let threshold = labelRejectThresholds[label.identifier] else { return false }
                return label.confidence >= threshold
            }
            .max { $0.confidence < $1.confidence }
    }

    /// The single source of truth for the reject decision: label rule OR
    /// (isUtility AND low aesthetic). nil means not rejected.
    static func rejectionReason(isUtility: Bool, normalizedAesthetic: Float, labels: [ClassificationLabel]) -> RejectionReason? {
        if let hit = firstRejectedLabel(in: labels) {
            return .label(hit.identifier, confidence: hit.confidence)
        }
        if isUtility && normalizedAesthetic.clamped(to: 0...1) < utilityAestheticGate {
            return .utility(normalizedAesthetic: normalizedAesthetic.clamped(to: 0...1))
        }
        return nil
    }

    static func compute(
        aesthetic: Float,
        faceQuality: Float,
        groupBonus: Float,
        rejectionReason: RejectionReason?
    ) -> Float {
        guard rejectionReason == nil else { return 0 }
        let normalizedAesthetic = aesthetic.clamped(to: 0...1)
        let score = aestheticWeight * normalizedAesthetic
            + faceQualityWeight * faceQuality.clamped(to: 0...1)
            + groupBonusWeight * groupBonus.clamped(to: 0...1)
        return score.clamped(to: 0...1)
    }
}

nonisolated extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
