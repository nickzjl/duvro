//
//  CaptionServiceTests.swift
//  duvroTests
//
//  Phase 9's offline fallback (BUILD_ROADMAP Phase 9) is real shipping
//  code, not a throwaway stub -- same test-coverage bar as every other
//  service in this codebase.
//

import Testing
@testable import duvro

struct CaptionServiceTests {
    private let service = TemplateCaptionService()

    @Test func returnsANonEmptyCaptionForEachKnownPack() async {
        for packID in ["golden_hour", "digicam", "travel_film"] {
            let caption = await service.caption(packID: packID, excluding: [])
            #expect(!caption.isEmpty, "expected a non-empty caption for \(packID)")
        }
    }

    @Test func unrecognizedPackFallsBackToGoldenHour() async {
        let goldenHourBank = await Self.allCaptions(for: "golden_hour", service: service)
        let fallback = await service.caption(packID: "not_a_real_pack", excluding: [])
        #expect(goldenHourBank.contains(fallback), "expected an unrecognized pack id to fall back to golden_hour's bank, got \(fallback)")
    }

    @Test func excludingAllButOneOptionAlwaysReturnsThatOne() async {
        // Deterministic, not flaky: with every other line in the bank
        // excluded, the ONLY fresh option left must be what comes back.
        let digicamBank = await Self.allCaptions(for: "digicam", service: service)
        #expect(digicamBank.count > 1, "need at least 2 templates to test exclusion meaningfully")
        let allButOne = Set(digicamBank.dropFirst())
        let result = await service.caption(packID: "digicam", excluding: allButOne)
        #expect(result == digicamBank.first)
    }

    @Test func excludingTheEntireBankStillReturnsSomethingFromIt() async {
        let bank = await Self.allCaptions(for: "travel_film", service: service)
        let result = await service.caption(packID: "travel_film", excluding: Set(bank))
        #expect(bank.contains(result), "expected a fallback-to-full-bank pick, got something outside it entirely: \(result)")
    }

    // MARK: - Fixtures

    /// Repeatedly samples (excluding what's already been seen) until no
    /// new caption appears for several consecutive draws -- a simple,
    /// good-enough way to recover the full template bank for a pack
    /// without hardcoding it a second time in this test file (which would
    /// silently drift from CaptionService.swift's own bank).
    private static func allCaptions(for packID: String, service: TemplateCaptionService) async -> [String] {
        var seen: Set<String> = []
        var stableRounds = 0
        while stableRounds < 8 {
            let next = await service.caption(packID: packID, excluding: seen)
            if seen.contains(next) {
                stableRounds += 1
            } else {
                seen.insert(next)
                stableRounds = 0
            }
        }
        return Array(seen)
    }
}
