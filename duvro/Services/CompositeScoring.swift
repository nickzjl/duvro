//
//  CompositeScoring.swift
//  duvro
//
//  Pure, testable composite-score math. No Vision imports, no I/O -- kept
//  this way specifically so unit tests can exercise it with plain values.
//
//  BUILD_ROADMAP Phase 2 starting weights: 0.4 aesthetic + 0.25
//  importantPerson + 0.2 faceQuality + 0.1 groupBonus + 0.05 sharpness.
//
//  importantPerson is forced to a 0 weight this phase (see item 4: the
//  recurring-person clusters aren't validated yet, so nothing should rank
//  on them). The remaining four weights are RENORMALIZED to sum to 1.0
//  (divided by 0.75, the sum of the other four) rather than left with a
//  0.25 gap. Rationale: composite score is read directly off the debug
//  grid for tuning, and a permanent 0.25 ceiling under 1.0 would make
//  every photo look uniformly "worse than expected" while eyeballing --
//  pure noise for a human tuning the weights. Renormalizing is a linear
//  rescale applied identically to every photo, so it changes none of the
//  relative ordering Phase 3's selection will actually use.
//
//  When importantPerson is re-enabled (after cluster quality is
//  validated), these weights need to shift back toward the original
//  0.4/0.25/0.2/0.1/0.05 split.
//
//  isUtility ALONE over-fires on ordinary photos (observed on-device: a
//  gym-bench photo and a laptop-on-desk photo were both flagged, despite
//  non-low aesthetic scores -- Vision's utility classifier reads flat
//  surfaces/screen content as document-like even when the photo isn't one).
//  Hard reject therefore requires isUtility AND a low aesthetic score. A
//  genuine screenshot/receipt/document isn't a composed photograph at all
//  and should score poorly on aesthetics too, so this still catches the
//  real case while sparing a merely-misclassified ordinary photo.
//

import Foundation

enum CompositeScoring {
    private static let renormalizationFactor: Float = 1.0 / 0.75

    static let aestheticWeight: Float = 0.4 * renormalizationFactor
    static let importantPersonWeight: Float = 0.0 // forced off -- see item 4
    static let faceQualityWeight: Float = 0.2 * renormalizationFactor
    static let groupBonusWeight: Float = 0.1 * renormalizationFactor
    static let sharpnessWeight: Float = 0.05 * renormalizationFactor

    /// Normalized (0...1) aesthetic ceiling below which an isUtility flag is
    /// trusted enough to hard-reject. Starting point pending tuning: the
    /// observed false-positive (gym bench) normalized to ~0.63, comfortably
    /// above this, so it would now be spared.
    static let utilityAestheticGate: Float = 0.35

    /// Vision's ImageAestheticsScoresObservation.overallScore is documented
    /// in the range -1...1 (more positive = more pleasing). Normalize to
    /// 0...1 so it combines sensibly with the other 0...1 terms.
    static func normalizeAesthetic(_ raw: Float) -> Float {
        ((raw + 1) / 2).clamped(to: 0...1)
    }

    static func isHardRejected(isUtility: Bool, normalizedAesthetic: Float) -> Bool {
        isUtility && normalizedAesthetic.clamped(to: 0...1) < utilityAestheticGate
    }

    static func compute(
        aesthetic: Float,
        importantPerson: Float,
        faceQuality: Float,
        groupBonus: Float,
        sharpness: Float,
        isUtility: Bool
    ) -> Float {
        let normalizedAesthetic = aesthetic.clamped(to: 0...1)
        guard !isHardRejected(isUtility: isUtility, normalizedAesthetic: normalizedAesthetic) else { return 0 }
        let score = aestheticWeight * normalizedAesthetic
            + importantPersonWeight * importantPerson.clamped(to: 0...1)
            + faceQualityWeight * faceQuality.clamped(to: 0...1)
            + groupBonusWeight * groupBonus.clamped(to: 0...1)
            + sharpnessWeight * sharpness.clamped(to: 0...1)
        return score.clamped(to: 0...1)
    }
}

extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
