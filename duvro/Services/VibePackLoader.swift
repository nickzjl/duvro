//
//  VibePackLoader.swift
//  duvro
//
//  Phase 4: loads a bundled Vibe Pack JSON (duvro/Packs/<name>.json) into a
//  VibePack. FAILS SAFE, same pattern as CategoryMapper.loadMapping: a
//  missing file, unreadable data, malformed JSON, or a pack with the wrong
//  variant count returns nil rather than throwing or crashing.
//  `assertionFailure` fires loudly in DEBUG/test builds (so a broken pack
//  is caught immediately) but is a no-op in Release, so a shipped app never
//  crashes over it -- EditEngine's contract is that a nil pack (or a pack
//  it otherwise can't use) means "render the original, unedited photo,"
//  never a blank frame.
//

import Foundation

enum VibePackLoader {
    /// A pack is meaningless with anything other than exactly 3 variants --
    /// prd.md §6 and the 3-way edit screen both assume exactly 3.
    static let expectedVariantCount = 3

    /// `name` is the JSON filename without extension, e.g. "golden_hour".
    static func load(named name: String, bundle: Bundle = .main) -> VibePack? {
        guard
            let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Packs")
                ?? bundle.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            assertionFailure("Vibe Pack '\(name)' missing or unreadable -- EditEngine will render originals for it")
            return nil
        }

        do {
            let pack = try JSONDecoder().decode(VibePack.self, from: data)
            guard pack.variants.count == expectedVariantCount else {
                assertionFailure("Vibe Pack '\(name)' has \(pack.variants.count) variants, expected \(expectedVariantCount) -- EditEngine will render originals for it")
                return nil
            }
            return pack
        } catch {
            assertionFailure("Vibe Pack '\(name)' failed to decode: \(error) -- EditEngine will render originals for it")
            return nil
        }
    }
}
