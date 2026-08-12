//
//  CompositeScoringTests.swift
//  duvroTests
//
//  Task 5 (crop-clip penalty): CompositeScoring had zero test coverage
//  before this -- these tests cover only what this session added
//  (normalizedCropWindow, clipPenalty, and compute's new clipPenalty
//  term), not a backfill of the whole pre-existing scoring engine.
//  Same "discriminating test" bar as ExportServiceTests/DigicamOpsTests:
//  assert something a broken-but-non-crashing implementation could
//  still fail, not just "returned a number."
//

import Testing
import CoreGraphics
@testable import duvro

struct CompositeScoringTests {

    // MARK: - normalizedCropWindow

    @Test func landscapeSourceCropsSidesSymmetrically() {
        // 4:3 (1.333) is wider than 4:5 (0.8) -- expect the sides trimmed,
        // full height kept.
        let window = CompositeScoring.normalizedCropWindow(sourceAspect: 4.0 / 3.0)
        #expect(window.minY == 0 && window.height == 1, "a wider-than-4:5 source should keep the full height")
        #expect(window.minX > 0, "expected a positive left margin")
        #expect(abs(window.minX - (1 - window.width - window.minX)) < 0.0001, "left and right margins should be equal (centered crop)")
    }

    @Test func portraitSourceCropsTopAndBottomSymmetrically() {
        // 1:2 (0.5) is taller/narrower than 4:5 (0.8) -- expect top/bottom trimmed.
        let window = CompositeScoring.normalizedCropWindow(sourceAspect: 0.5)
        #expect(window.minX == 0 && window.width == 1, "a taller-than-4:5 source should keep the full width")
        #expect(window.minY > 0, "expected a positive top margin")
    }

    @Test func exactly4x5SourceCropsNothing() {
        let window = CompositeScoring.normalizedCropWindow(sourceAspect: 0.8)
        #expect(window == CGRect(x: 0, y: 0, width: 1, height: 1), "a source already at 4:5 needs no crop at all")
    }

    // MARK: - clipPenalty

    @Test func aFullyContainedFaceGetsNoPenalty() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1) // landscape crop, symmetric side margins
        let centeredFace = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        #expect(CompositeScoring.clipPenalty(faceBoxes: [centeredFace], humanBoxes: [], cropWindow: window) == 0)
    }

    @Test func aFullyClippedFaceIsPenalizedAtTheFaceWeight() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        // Entirely in the trimmed left margin -- zero overlap with the window.
        let clippedFace = CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2)
        let penalty = CompositeScoring.clipPenalty(faceBoxes: [clippedFace], humanBoxes: [], cropWindow: window)
        #expect(abs(penalty - CompositeScoring.faceClipPenaltyWeight) < 0.0001, "a fully-outside-the-window face should cost exactly faceClipPenaltyWeight, got \(penalty)")
    }

    @Test func aHalfClippedFacePenalizesHalfAsMuchAsAFullyClippedOne() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        // Straddles the window's left edge (x=0.1): half inside, half outside.
        let halfClippedFace = CGRect(x: 0.05, y: 0.4, width: 0.1, height: 0.2)
        let penalty = CompositeScoring.clipPenalty(faceBoxes: [halfClippedFace], humanBoxes: [], cropWindow: window)
        #expect(abs(penalty - CompositeScoring.faceClipPenaltyWeight * 0.5) < 0.01, "a half-clipped face should cost roughly half of a fully-clipped one, got \(penalty)")
    }

    @Test func faceClippingIsWeightedMoreHeavilyThanBodyClipping() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        let clippedBox = CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2) // fully outside, same geometry either way
        let facePenalty = CompositeScoring.clipPenalty(faceBoxes: [clippedBox], humanBoxes: [], cropWindow: window)
        let bodyPenalty = CompositeScoring.clipPenalty(faceBoxes: [], humanBoxes: [clippedBox], cropWindow: window)
        #expect(facePenalty > bodyPenalty, "an identically-clipped face should penalize more than an identically-clipped body -- face \(facePenalty), body \(bodyPenalty)")
        #expect(CompositeScoring.faceClipPenaltyWeight > CompositeScoring.bodyClipPenaltyWeight, "face weight must be set heavier than body weight")
    }

    @Test func twoClippedFacesPenalizeMoreThanOne() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        let clippedFace = CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2)
        let onePenalty = CompositeScoring.clipPenalty(faceBoxes: [clippedFace], humanBoxes: [], cropWindow: window)
        let twoPenalty = CompositeScoring.clipPenalty(faceBoxes: [clippedFace, clippedFace], humanBoxes: [], cropWindow: window)
        #expect(twoPenalty > onePenalty, "more clipped people should penalize more, not the same amount -- one \(onePenalty), two \(twoPenalty)")
    }

    @Test func penaltyNeverExceedsMaxClipPenaltyRegardlessOfHowManyPeopleAreClipped() {
        let window = CGRect(x: 0.1, y: 0, width: 0.8, height: 1)
        let clippedFace = CGRect(x: 0, y: 0.4, width: 0.05, height: 0.2)
        let manyClippedFaces = Array(repeating: clippedFace, count: 20)
        let penalty = CompositeScoring.clipPenalty(faceBoxes: manyClippedFaces, humanBoxes: [], cropWindow: window)
        #expect(penalty <= CompositeScoring.maxClipPenalty, "PENALIZE, not reject -- this must stay capped even for a busy, badly-clipped group shot, got \(penalty)")
    }

    // MARK: - compute(...) with clipPenalty

    @Test func computeSubtractsClipPenaltyFromTheWeightedSum() {
        let withoutPenalty = CompositeScoring.compute(aesthetic: 0.8, faceQuality: 0.8, groupBonus: 1.0, clipPenalty: 0, rejectionReason: nil)
        let withPenalty = CompositeScoring.compute(aesthetic: 0.8, faceQuality: 0.8, groupBonus: 1.0, clipPenalty: 0.2, rejectionReason: nil)
        #expect(abs((withoutPenalty - withPenalty) - 0.2) < 0.0001, "a 0.2 clip penalty should reduce the composite by exactly 0.2 (before the final 0...1 clamp)")
    }

    @Test func computeNeverGoesNegativeEvenWithALargePenalty() {
        let score = CompositeScoring.compute(aesthetic: 0.1, faceQuality: 0.1, groupBonus: 0, clipPenalty: 1.0, rejectionReason: nil)
        #expect(score == 0)
    }

    @Test func rejectionStillForcesZeroRegardlessOfClipPenalty() {
        let score = CompositeScoring.compute(aesthetic: 1.0, faceQuality: 1.0, groupBonus: 1.0, clipPenalty: 0, rejectionReason: .utility(normalizedAesthetic: 0.1))
        #expect(score == 0, "rejection must still short-circuit to 0 -- the clip penalty is irrelevant for a photo that's rejected outright")
    }

    @Test func defaultClipPenaltyIsZeroForCallersThatDontPassOne() {
        // Existing call sites (and anything that predates this parameter)
        // must be unaffected -- the default keeps compute()'s prior
        // behavior exactly.
        let a = CompositeScoring.compute(aesthetic: 0.5, faceQuality: 0.5, groupBonus: 0.5, rejectionReason: nil)
        let b = CompositeScoring.compute(aesthetic: 0.5, faceQuality: 0.5, groupBonus: 0.5, clipPenalty: 0, rejectionReason: nil)
        #expect(a == b)
    }
}
