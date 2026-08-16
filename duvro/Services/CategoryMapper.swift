//
//  CategoryMapper.swift
//  duvro
//
//  Maps a photo to one of the four dump categories (people/place/food/
//  detail). `people` is decided by face detection OR body detection, never
//  by classification labels -- classifiers are unreliable at distinguishing
//  "photo with a person in it" from context, and face/body detection is
//  ground truth we already have from Vision. Face-only detection misses
//  distant, small, and back-turned subjects (mirror shots, someone walking
//  away) -- DetectHumanRectanglesRequest catches those too. Bodies only
//  affect categorization; face count/quality/group bonus still come only
//  from face detection. place/food come from an explicit, hand-editable
//  table (Resources/Data/CategoryMapping.json); anything unmapped falls to
//  `detail`.
//

import Foundation

struct CategoryMapper {
    private let placeIdentifiers: Set<String>
    private let foodIdentifiers: Set<String>

    static let shared = CategoryMapper()

    init(bundle: Bundle = .main) {
        let (place, food) = Self.loadMapping(from: bundle)
        self.placeIdentifiers = place
        self.foodIdentifiers = food
    }

    /// For unit tests / callers that want to inject a mapping directly rather than load from the bundle.
    init(placeIdentifiers: Set<String>, foodIdentifiers: Set<String>) {
        self.placeIdentifiers = placeIdentifiers
        self.foodIdentifiers = foodIdentifiers
    }

    /// Below this, a label is treated as noise for categorization purposes,
    /// not a real signal -- distinct from (and higher than) ScoringService's
    /// own classificationConfidenceThreshold (0.1), which only gates "is
    /// this label worth keeping at all" for the top-5 list stored on
    /// PhotoScore/shown in the debug grid. Diagnosed against a real 134-
    /// photo device run: at the 0.1 floor, a photo's top label can go
    /// unmatched (nothing in either table) while a coincidental ~0.1-0.2
    /// confidence label two or three slots down DOES match, and used to win
    /// by virtue of being first in confidence-sorted order to match
    /// anything at all -- e.g. a toilet photo landing in `food` off a weak
    /// secondary label, not its actual top classification. Requiring a
    /// real confidence floor for a category MATCH specifically (independent
    /// of the floor for a label being worth showing/keeping) means an
    /// unmapped-but-strong top label is now correctly preferred over a
    /// mapped-but-weak one: iteration still stops at the first sufficiently
    /// confident match, so it doesn't skip PAST a strong match looking for
    /// something stronger -- it just refuses to accept a weak one. 0.3 is a
    /// judgment call, not derived from data -- there was no way to inspect
    /// real confidence distributions without a device (Vision doesn't run
    /// in the Simulator); tune from the debug grid's now-visible per-label
    /// confidences if 0.3 turns out wrong in either direction.
    static let categoryMatchConfidenceThreshold: Float = 0.3

    /// `labels` should already be confidence-sorted, highest first (see
    /// ScoringService). The category of the first SUFFICIENTLY CONFIDENT
    /// label that matches either table wins -- a low-confidence match is
    /// skipped rather than accepted, so a coincidental weak label further
    /// down the list can't win just because a stronger, unmapped label
    /// earlier in the list didn't match anything (see
    /// categoryMatchConfidenceThreshold's own doc comment for the device
    /// finding this fixes). A lower-confidence "place" label still can't
    /// override a higher-confidence "food" label just because place is
    /// checked first for a given label -- confidence order across labels is
    /// what decides, not table order. A photo with no sufficiently
    /// confident match in either table -- whether because nothing matched
    /// at all, or every match was too weak -- falls to `.detail`, same as
    /// always; that's an intentional, explicit fallback (see this file's
    /// header), not a bug to route elsewhere.
    func category(hasFaces: Bool, hasHumans: Bool, labels: [ClassificationLabel]) -> PhotoCategory {
        if hasFaces || hasHumans { return .people }
        for label in labels where label.confidence >= Self.categoryMatchConfidenceThreshold {
            if placeIdentifiers.contains(label.identifier) { return .place }
            if foodIdentifiers.contains(label.identifier) { return .food }
        }
        return .detail
    }

    private static func loadMapping(from bundle: Bundle) -> (place: Set<String>, food: Set<String>) {
        guard
            let url = bundle.url(forResource: "CategoryMapping", withExtension: "json", subdirectory: "Data")
                ?? bundle.url(forResource: "CategoryMapping", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            assertionFailure("CategoryMapping.json missing or malformed -- falling back to empty tables (everything not a face will read as `detail`)")
            return ([], [])
        }
        let place = Set(json["place"] as? [String] ?? [])
        let food = Set(json["food"] as? [String] ?? [])
        return (place, food)
    }
}
