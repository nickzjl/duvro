//
//  CaptionService.swift
//  duvro
//
//  Phase 9's UI half (BUILD_ROADMAP Phase 9, prd.md §4 step 9 / P1). The
//  network call (Vercel endpoint + Claude API, shared infra with the
//  curation endpoint) needs a deployed API key that isn't available this
//  session -- CaptionServiceProtocol is the clean boundary it drops into
//  behind, later, without CaptionView changing at all.
//
//  TemplateCaptionService below is NOT a throwaway stub: it IS
//  BUILD_ROADMAP Phase 9's own required "offline fallback to canned
//  templates per vibe" acceptance line, built first because tonight it's
//  also the only implementation. Once the network version exists, it
//  degrades to this exact type on failure/offline -- this type doesn't
//  get deleted, it gets a sibling.
//
//  The protocol never throws, by design: whatever implementation is
//  live, CaptionView always gets a usable string back. A future
//  network-backed implementation owns catching its own failures and
//  falling back internally -- that contract is enforced by the
//  signature, not left to the caller to remember.
//

import Foundation

protocol CaptionServiceProtocol {
    /// `excluding`: captions already shown this session, so tapping
    /// "regenerate" visibly produces something different rather than the
    /// same line twice in a row. Best-effort, not a hard guarantee once
    /// every line in a pack's bank has already been shown.
    func caption(packID: String, excluding used: Set<String>) async -> String
}

/// BUILD_ROADMAP Phase 9's offline fallback (see the file header) --
/// lowercase-casual voice (CLAUDE.md), never surfaces "AI"/"algorithm"/
/// "optimized" (UI_NOTES fix 6). Falls back to Golden Hour's bank for an
/// unrecognized pack id rather than returning something empty.
struct TemplateCaptionService: CaptionServiceProtocol {
    func caption(packID: String, excluding used: Set<String>) async -> String {
        let bank = Self.templates[packID] ?? Self.templates["golden_hour"]!
        let fresh = bank.filter { !used.contains($0) }
        return (fresh.isEmpty ? bank : fresh).randomElement() ?? bank[0]
    }

    /// One bank per pack, written to match each pack's own character
    /// (matches the vibe-select screen's own per-pack blurbs in spirit --
    /// same ambiguous, made-alone-decision treatment: this copy isn't
    /// specified anywhere in prd.md/UI_NOTES, only that it must exist,
    /// be lowercase-casual, and never say "AI").
    private static let templates: [String: [String]] = [
        "golden_hour": [
            "golden hour, golden memories.",
            "chasing the last light of the day.",
            "warm light, warmer company.",
            "some afternoons just hit different.",
            "soaked in that late-afternoon glow."
        ],
        "digicam": [
            "found the old camera again.",
            "y2k brain, forever.",
            "flash on, filter off.",
            "raw, unbothered, in the moment.",
            "some nights deserve a grainy photo."
        ],
        "travel_film": [
            "not all who wander are lost.",
            "collecting moments, not things.",
            "the trip that didn't want to end.",
            "a little grain, a lot of memories.",
            "postcard-worthy, every time."
        ]
    ]
}

/// Phase 3.5: wraps captions the curation call ALREADY returned, rank-
/// ordered, alongside the selection itself (SessionStore.curationCaptions
/// -- see CurationService.Result.captions' own doc comment for why this
/// isn't a second network round-trip made from CaptionView). "regenerate"
/// walks the rank-ordered list -- `captions.filter { !used.contains($0) }`
/// preserves the array's own order, so the first not-yet-shown caption is
/// always the next-best-ranked one, not a random pick. Falls through to
/// TemplateCaptionService (BUILD_ROADMAP Phase 9's required offline
/// fallback, unchanged) once every returned caption has been shown, OR
/// immediately if `captions` is empty to begin with -- the same fallback
/// path this takes when the curation call itself failed and
/// FallbackSelectionService ran instead (SessionStore.curationCaptions
/// stays [] in that case).
struct CurationCaptionService: CaptionServiceProtocol {
    let captions: [String]
    private let fallback = TemplateCaptionService()

    func caption(packID: String, excluding used: Set<String>) async -> String {
        if let next = captions.first(where: { !used.contains($0) }) {
            return next
        }
        return await fallback.caption(packID: packID, excluding: used)
    }
}
