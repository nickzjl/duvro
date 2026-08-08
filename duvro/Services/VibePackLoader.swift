//
//  VibePackLoader.swift
//  duvro
//
//  Phase 4: loads a bundled Vibe Pack JSON (duvro/Packs/<name>.json) into a
//  VibePack. FAILS SAFE in every build configuration -- Debug, Release, and
//  under the test host alike: a missing file, unreadable data, malformed
//  JSON, or a pack with the wrong variant count returns nil rather than
//  throwing or crashing. EditEngine's contract is that a nil pack (or a
//  pack it otherwise can't use) means "render the original, unedited
//  photo," never a blank frame.
//
//  Deliberately NOT `assertionFailure`, unlike CategoryMapper.loadMapping's
//  otherwise-similar pattern: `assertionFailure` traps (aborts the process)
//  whenever assertions are enabled, which includes ordinary Debug builds
//  and the hosted unit test target -- that would make it impossible to
//  write a passing test for "malformed pack fails gracefully" (Phase 4's
//  unit test requirement), since the test process would abort before any
//  assertion in the test itself ran. A `print` is loud enough to notice in
//  a console/log without taking the process down.
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
            print("[vibepack] '\(name)' missing or unreadable -- EditEngine will render originals for it")
            return nil
        }

        do {
            let pack = try JSONDecoder().decode(VibePack.self, from: data)
            guard pack.variants.count == expectedVariantCount else {
                print("[vibepack] '\(name)' has \(pack.variants.count) variants, expected \(expectedVariantCount) -- EditEngine will render originals for it")
                return nil
            }
            return pack
        } catch {
            print("[vibepack] '\(name)' failed to decode: \(error) -- EditEngine will render originals for it")
            return nil
        }
    }
}
