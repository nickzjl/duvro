//
//  CategoryMapper.swift
//  duvro
//
//  Maps a photo to one of the four dump categories (people/place/food/
//  detail). `people` is decided by face detection, never by classification
//  labels -- classifiers are unreliable at distinguishing "photo with a
//  person in it" from context, and face count is ground truth we already
//  have from Vision's face detector. place/food come from an explicit,
//  hand-editable table (Resources/Data/CategoryMapping.json); anything
//  unmapped falls to `detail`.
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

    /// `labels` should already be confidence-sorted, highest first. The category of the
    /// first label that matches either table wins, so a lower-confidence "place" label
    /// doesn't override a higher-confidence "food" label just because place is checked first.
    func category(hasFaces: Bool, labels: [String]) -> PhotoCategory {
        if hasFaces { return .people }
        for label in labels {
            if placeIdentifiers.contains(label) { return .place }
            if foodIdentifiers.contains(label) { return .food }
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
