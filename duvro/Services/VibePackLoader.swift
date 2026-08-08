//
//  VibePackLoader.swift
//  duvro
//
//  Phase 4: loads a bundled Vibe Pack JSON (duvro/Packs/<name>.json) into a
//  VibePack. FAILS SAFE in every build configuration -- Debug, Release, and
//  under the test host alike: a missing file, unreadable data, malformed
//  JSON, or a pack with the wrong variant count returns .failure rather
//  than throwing or crashing. EditEngine's contract is that a load failure
//  (or a pack it otherwise can't use) means "render the original, unedited
//  photo," never a blank frame.
//
//  Returns Result<VibePack, VibePackLoadError>, not a bare Optional: a nil
//  can't say WHICH of the three fail-safe cases fired, and on a physical
//  device with no console attached ("see console" is a dead end) the
//  caller needs the reason to show in-UI, not just the fact that it failed.
//
//  Deliberately NOT `assertionFailure`, unlike CategoryMapper.loadMapping's
//  otherwise-similar pattern: `assertionFailure` traps (aborts the process)
//  whenever assertions are enabled, which includes ordinary Debug builds
//  and the hosted unit test target -- that would make it impossible to
//  write a passing test for "malformed pack fails gracefully" (Phase 4's
//  unit test requirement), since the test process would abort before any
//  assertion in the test itself ran. `print` still fires too, for when a
//  console IS attached, but it's not the only place the reason goes.
//

import Foundation

enum VibePackLoadError: Error {
    /// Neither `subdirectory: "Packs"` nor the bundle root had a readable
    /// `<name>.json` in `bundle`. `searchedPaths` are the exact locations
    /// checked, for display without a console.
    case missingOrUnreadable(name: String, searchedPaths: [String])
    /// Found and read the file at `path`, but it isn't valid VibePack JSON.
    case decodeFailed(path: String, underlying: String)
    /// Found and decoded the file at `path`, but it doesn't have exactly
    /// `expected` variants.
    case wrongVariantCount(path: String, found: Int, expected: Int)

    /// One line, safe to put directly in UI -- no console required.
    var diagnosticDescription: String {
        switch self {
        case .missingOrUnreadable(let name, let searchedPaths):
            return "missing/unreadable -- looked for '\(name).json' at: \(searchedPaths.joined(separator: " , "))"
        case .decodeFailed(let path, let underlying):
            return "decode failed at \(path) -- \(underlying)"
        case .wrongVariantCount(let path, let found, let expected):
            return "wrong variant count at \(path) -- found \(found), expected \(expected)"
        }
    }
}

enum VibePackLoader {
    /// A pack is meaningless with anything other than exactly 3 variants --
    /// prd.md §6 and the 3-way edit screen both assume exactly 3.
    static let expectedVariantCount = 3

    /// `name` is the JSON filename without extension, e.g. "golden_hour".
    static func load(named name: String, bundle: Bundle = .main) -> Result<VibePack, VibePackLoadError> {
        // Mirrors the two lookups actually attempted below -- shown in the
        // missing/unreadable case so the failure reason is diagnosable from
        // the path alone, without Xcode attached.
        let searchedPaths = [
            "\(bundle.bundlePath)/Packs/\(name).json",
            "\(bundle.bundlePath)/\(name).json"
        ]

        guard
            let url = bundle.url(forResource: name, withExtension: "json", subdirectory: "Packs")
                ?? bundle.url(forResource: name, withExtension: "json"),
            let data = try? Data(contentsOf: url)
        else {
            let error = VibePackLoadError.missingOrUnreadable(name: name, searchedPaths: searchedPaths)
            print("[vibepack] \(error.diagnosticDescription) -- EditEngine will render originals for it")
            return .failure(error)
        }

        do {
            let pack = try JSONDecoder().decode(VibePack.self, from: data)
            guard pack.variants.count == expectedVariantCount else {
                let error = VibePackLoadError.wrongVariantCount(path: url.path, found: pack.variants.count, expected: expectedVariantCount)
                print("[vibepack] \(error.diagnosticDescription) -- EditEngine will render originals for it")
                return .failure(error)
            }
            return .success(pack)
        } catch {
            let loadError = VibePackLoadError.decodeFailed(path: url.path, underlying: String(describing: error))
            print("[vibepack] \(loadError.diagnosticDescription) -- EditEngine will render originals for it")
            return .failure(loadError)
        }
    }
}
