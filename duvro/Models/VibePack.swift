//
//  VibePack.swift
//  duvro
//
//  Phase 4: a Vibe Pack is a JSON-defined set of exactly 3 named edit
//  variants (prd.md §6 -- "3 named, handcrafted Core Image pipelines").
//  Loaded via VibePackLoader; rendered via EditEngine. See EditOp.swift for
//  what a variant's ops actually are.
//

import Foundation

struct VibePack: Codable, Sendable {
    let id: String
    let displayName: String
    let variants: [EditVariant]
}

struct EditVariant: Codable, Sendable, Identifiable {
    var id: String { name }
    /// e.g. "Sun-kissed" -- the terracotta-accented name shown under the
    /// pill in the 3-way edit screen (UI_NOTES §1). Not localized in v1.
    let name: String
    /// Applied in array order -- this is a chain, not an unordered set of
    /// adjustments.
    let ops: [EditOp]
}
