//
//  VibePackTests.swift
//  duvroTests
//
//  Phase 4 unit tests: pack parsing (EditOp's discriminated-union Codable,
//  VibePack's structural requirements), and the fail-safe contract --
//  missing/malformed/wrong-shaped packs never throw past VibePackLoader,
//  and a malformed op never blanks a render, it falls back toward the
//  original photo.
//

import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import duvro

struct VibePackTests {

    // MARK: - EditOp Codable (one positive case per op)

    @Test func decodesToneCurve() throws {
        // Points are [x, y] pairs -- CGPoint's actual Codable wire format
        // (an unkeyed 2-element array), NOT {"x":...,"y":...}. This fixture
        // originally used the object form and passed compilation without
        // ever being executed -- see goldenHourLoadsFromTheAppBundle's
        // comment for the device bug that shape mismatch caused.
        let json = Data("""
        { "type": "toneCurve", "points": [
            [0,0], [0.25,0.25], [0.5,0.5], [0.75,0.75], [1,1]
        ] }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .toneCurve(let points) = op else {
            Issue.record("expected .toneCurve, got \(op)")
            return
        }
        #expect(points.count == 5)
        #expect(points[2] == CGPoint(x: 0.5, y: 0.5))
    }

    @Test func decodesColorControls() throws {
        let json = Data("""
        { "type": "colorControls", "saturation": 1.2, "brightness": 0.05, "contrast": 1.1 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .colorControls(let saturation, let brightness, let contrast) = op else {
            Issue.record("expected .colorControls, got \(op)")
            return
        }
        #expect(saturation == 1.2)
        #expect(brightness == 0.05)
        #expect(contrast == 1.1)
    }

    @Test func decodesTemperatureTint() throws {
        let json = Data("""
        { "type": "temperatureTint", "temperature": 5200, "tint": 6 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .temperatureTint(let temperature, let tint) = op else {
            Issue.record("expected .temperatureTint, got \(op)")
            return
        }
        #expect(temperature == 5200)
        #expect(tint == 6)
    }

    @Test func decodesVignette() throws {
        let json = Data("""
        { "type": "vignette", "intensity": 0.3, "radius": 1.5 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .vignette(let intensity, let radius) = op else {
            Issue.record("expected .vignette, got \(op)")
            return
        }
        #expect(intensity == 0.3)
        #expect(radius == 1.5)
    }

    @Test func decodesBloom() throws {
        let json = Data("""
        { "type": "bloom", "radius": 8, "intensity": 0.4 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .bloom(let radius, let intensity) = op else {
            Issue.record("expected .bloom, got \(op)")
            return
        }
        #expect(radius == 8)
        #expect(intensity == 0.4)
    }

    @Test func decodesGrain() throws {
        let json = Data("""
        { "type": "grain", "intensity": 0.05, "size": 1.2 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .grain(let intensity, let size) = op else {
            Issue.record("expected .grain, got \(op)")
            return
        }
        #expect(intensity == 0.05)
        #expect(size == 1.2)
    }

    @Test func decodesFade() throws {
        let json = Data("""
        { "type": "fade", "amount": 0.15 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .fade(let amount) = op else {
            Issue.record("expected .fade, got \(op)")
            return
        }
        #expect(amount == 0.15)
    }

    @Test func unknownOpTypeFailsToDecode() {
        // "lightLeak" used to be the example here, back when it wasn't a
        // real case yet -- now that Phase 8 added it (see DigicamOpsTests),
        // reusing it would make this test pass for the wrong reason (a
        // missing `corner` field, not an unrecognized type). "halation" is
        // still genuinely unimplemented (EditOp.swift's header comment) --
        // swap this fixture again if that ever changes.
        let json = Data("""
        { "type": "halation", "intensity": 0.5 }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditOp.self, from: json)
        }
    }

    @Test func opMissingARequiredFieldFailsToDecode() {
        let json = Data("""
        { "type": "toneCurve" }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(EditOp.self, from: json)
        }
    }

    // MARK: - VibePack structural parsing

    @Test func decodesAWellFormedPack() throws {
        let json = Data("""
        {
          "id": "test_pack",
          "displayName": "Test Pack",
          "variants": [
            { "name": "A", "ops": [{ "type": "fade", "amount": 0.1 }] },
            { "name": "B", "ops": [{ "type": "fade", "amount": 0.2 }] },
            { "name": "C", "ops": [{ "type": "fade", "amount": 0.3 }] }
          ]
        }
        """.utf8)
        let pack = try JSONDecoder().decode(VibePack.self, from: json)
        #expect(pack.id == "test_pack")
        #expect(pack.variants.count == 3)
        #expect(pack.variants.map(\.name) == ["A", "B", "C"])
    }

    @Test func packMissingVariantsFailsToDecode() {
        let json = Data("""
        { "id": "broken", "displayName": "Broken" }
        """.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VibePack.self, from: json)
        }
    }

    // MARK: - VibePackLoader: fails safe (Result, never throws/crashes),
    // and each failure case carries a reason a caller can show without a
    // console attached.

    // Decodes the REAL shipped duvro/Packs/golden_hour.json, not a fixture --
    // this is what caught the {x,y}-vs-[x,y] CGPoint mismatch shipping to a
    // device (JSONDecoder is all-or-nothing: if this decodes to .success at
    // all, every op in every variant already decoded cleanly, since a
    // failure anywhere in the tree throws before VibePack ever exists). The
    // op-level assertions below exist for a sharper failure message and to
    // guard against a *wrong-but-decodable* shape, not because .success
    // alone would miss something -- the real gap that let the CGPoint bug
    // through wasn't test coverage, it was that this suite was compiled
    // (build-for-testing) but never actually executed before this session.
    @Test func goldenHourLoadsFromTheAppBundle() throws {
        // The unit test target is app-hosted (TEST_HOST/BUNDLE_LOADER in
        // the project settings), so Bundle.main here is the real running
        // duvro.app bundle, which ships golden_hour.json.
        let result = VibePackLoader.load(named: "golden_hour")
        guard case .success(let pack) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(pack.variants.count == 3)
        #expect(pack.variants.map(\.name) == ["Sun-kissed", "Warm Film", "Soft Glow"])

        // Every variant has the full 7-op Golden Hour chain, in order --
        // updated when Golden Hour was tuned from a hand-graded reference:
        // fade was dropped (its "faded blacks" value turned out to be the
        // same data as the tone curve's own black point, applying both
        // would double-lift shadows -- see golden_hour.json's own
        // _tuningNote) and vibrance was added (no colorControls equivalent
        // -- see EditOp.swift).
        let expectedOpOrder: [String] = ["temperatureTint", "toneCurve", "vibrance", "colorControls", "vignette", "bloom", "grain"]
        for variant in pack.variants {
            #expect(variant.ops.map(Self.opTypeName) == expectedOpOrder, "\(variant.name)'s op order")
        }

        // Spot-check the toneCurve op specifically -- 5 points, ascending
        // x, each point actually a 2-element [x, y] pair round-tripping
        // through CGPoint's Codable conformance (the exact thing that broke
        // on device when the JSON used {"x":...,"y":...} objects instead).
        // x-values are Sun-kissed's own tuned points (64/128/191 out of
        // 255, not the untuned pack's exact quarter-points) -- not [0,
        // 0.25, 0.5, 0.75, 1] anymore.
        guard case .toneCurve(let points) = pack.variants[0].ops[1] else {
            Issue.record("expected variants[0].ops[1] to be .toneCurve")
            return
        }
        #expect(points.count == 5)
        #expect(points.map(\.x) == [0, 0.251, 0.502, 0.749, 1])
    }

    // Phase 8, Task 2: same reasoning as goldenHourLoadsFromTheAppBundle
    // above -- decodes the REAL shipped duvro/Packs/digicam.json, not a
    // fixture. The incident that test's comment describes (a fixture-based
    // test passing while the real bundled golden_hour.json failed to
    // decode on device) is exactly the gap this guards against for the two
    // new packs.
    @Test func digicamLoadsFromTheAppBundle() throws {
        let result = VibePackLoader.load(named: "digicam")
        guard case .success(let pack) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(pack.variants.count == 3)
        // Exact names per prd.md §6 -- UI_NOTES fix 3 flags this as a
        // place mockups get wrong; the loaded pack is the one place that
        // actually matters.
        #expect(pack.variants.map(\.name) == ["Light Leak", "Polaroid", "Y2K Digicam"])

        // Each variant uses its namesake new op at least once -- a sharper
        // check than "decoded successfully," which a pack with the right
        // variant names but the wrong ops would still pass.
        let opNames = pack.variants.map { $0.ops.map(Self.opTypeName) }
        #expect(opNames[0].contains("lightLeak"), "expected \"Light Leak\" variant to contain a lightLeak op, got \(opNames[0])")
        #expect(opNames[1].contains("polaroidFrame"), "expected \"Polaroid\" variant to contain a polaroidFrame op, got \(opNames[1])")
        #expect(opNames[2].contains("dateStamp"), "expected \"Y2K Digicam\" variant to contain a dateStamp op, got \(opNames[2])")
    }

    @Test func travelFilmLoadsFromTheAppBundle() throws {
        let result = VibePackLoader.load(named: "travel_film")
        guard case .success(let pack) = result else {
            Issue.record("expected .success, got \(result)")
            return
        }
        #expect(pack.variants.count == 3)
        #expect(pack.variants.map(\.name) == ["Kodak Style", "Faded Postcard", "Deep Teal"])

        // Travel Film is spec'd to need none of the three Phase 8 ops --
        // built entirely from the original seven. A pack that accidentally
        // reached for lightLeak/polaroidFrame/dateStamp would still decode
        // fine (nothing forbids it structurally), so this checks it
        // explicitly rather than assuming.
        for variant in pack.variants {
            for op in variant.ops {
                switch op {
                case .lightLeak, .polaroidFrame, .dateStamp:
                    Issue.record("\(variant.name) unexpectedly uses a Digicam-only op: \(op)")
                default:
                    break
                }
            }
        }
    }

    @Test func missingPackReturnsMissingOrUnreadable() {
        let result = VibePackLoader.load(named: "does_not_exist_pack_xyz")
        guard case .failure(let error) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        guard case .missingOrUnreadable(let name, let searchedPaths) = error else {
            Issue.record("expected .missingOrUnreadable, got \(error)")
            return
        }
        #expect(name == "does_not_exist_pack_xyz")
        #expect(searchedPaths.count == 2) // Packs/ subdirectory, then bundle root
    }

    @Test func malformedJSONReturnsDecodeFailed() throws {
        let bundle = try Self.makeTestBundle(files: ["broken_pack.json": "{ this is not valid json"])
        let result = VibePackLoader.load(named: "broken_pack", bundle: bundle)
        guard case .failure(let error) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        guard case .decodeFailed(let path, _) = error else {
            Issue.record("expected .decodeFailed, got \(error)")
            return
        }
        #expect(path.hasSuffix("broken_pack.json"))
    }

    @Test func wrongVariantCountReturnsWrongVariantCount() throws {
        let json = """
        {
          "id": "two_variant_pack",
          "displayName": "Two",
          "variants": [
            { "name": "A", "ops": [] },
            { "name": "B", "ops": [] }
          ]
        }
        """
        let bundle = try Self.makeTestBundle(files: ["two_variant_pack.json": json])
        let result = VibePackLoader.load(named: "two_variant_pack", bundle: bundle)
        guard case .failure(let error) = result else {
            Issue.record("expected .failure, got \(result)")
            return
        }
        guard case .wrongVariantCount(let path, let found, let expected) = error else {
            Issue.record("expected .wrongVariantCount, got \(error)")
            return
        }
        #expect(path.hasSuffix("two_variant_pack.json"))
        #expect(found == 2)
        #expect(expected == 3)
    }

    // MARK: - EditEngine: a malformed op falls back to the original photo

    @Test func renderFallsBackToOriginalWhenTheOnlyOpIsMalformed() throws {
        let photo = try Self.makeTestPhoto()
        // toneCurve requires exactly 5 points (EditEngine.applyToneCurve);
        // zero points is the malformed case it explicitly guards against.
        // As the ONLY op in the chain, the whole chain is a no-op, so the
        // render should come back as the original image, not a blank frame.
        let variant = EditVariant(name: "broken", ops: [.toneCurve(points: [])])

        let rendered = EditEngine.render(photo: photo, variant: variant)
        let original = UIImage(contentsOfFile: photo.downsampledURL.path)

        #expect(original != nil)
        #expect(rendered.size == original?.size)
        #expect(rendered.size.width > 0 && rendered.size.height > 0)
    }

    @Test func renderNeverCrashesOnAnEmptyOpChain() throws {
        let photo = try Self.makeTestPhoto()
        let variant = EditVariant(name: "empty", ops: [])
        let rendered = EditEngine.render(photo: photo, variant: variant)
        #expect(rendered.size.width > 0 && rendered.size.height > 0)
    }

    // MARK: - Fixtures

    /// Test-only -- not added to EditOp itself, since nothing in the app
    /// needs an op's type as a bare string outside this assertion.
    private static func opTypeName(_ op: EditOp) -> String {
        switch op {
        case .toneCurve: return "toneCurve"
        case .colorControls: return "colorControls"
        case .vibrance: return "vibrance"
        case .temperatureTint: return "temperatureTint"
        case .vignette: return "vignette"
        case .bloom: return "bloom"
        case .grain: return "grain"
        case .fade: return "fade"
        case .lightLeak: return "lightLeak"
        case .polaroidFrame: return "polaroidFrame"
        case .dateStamp: return "dateStamp"
        }
    }

    /// A directory wrapped as a Bundle, so VibePackLoader's fail-safe paths
    /// can be exercised against controlled fixtures instead of relying on
    /// the shipped golden_hour.json happening to stay broken/fine.
    private static func makeTestBundle(files: [String: String]) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-pack-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, contents) in files {
            try contents.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        guard let bundle = Bundle(url: dir) else {
            struct BundleCreationFailed: Error {}
            throw BundleCreationFailed()
        }
        return bundle
    }

    /// A tiny solid-color JPEG on disk, wrapped as a Photo -- enough for
    /// EditEngine.render to have a real, decodable source image without a
    /// real camera-roll asset.
    private static func makeTestPhoto() throws -> Photo {
        let size = CGSize(width: 8, height: 8)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            UIColor.orange.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-test-photo-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: url)
        return Photo(id: UUID(), originalURL: url, downsampledURL: url, thumbnail: image)
    }
}
