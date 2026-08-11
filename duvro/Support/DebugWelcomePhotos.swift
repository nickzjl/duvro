//
//  DebugWelcomePhotos.swift
//  duvro
//
//  Welcome screen's card stack -- PLACEHOLDER, DEBUG-only. The ~3 real
//  bundled sample photos this screen is meant to ship with don't exist
//  yet (nobody has shot them; BUILD_ROADMAP's Deferred work register --
//  same blocker as the pack preview sheet's sample images). Borrows
//  DebugFixture's real photos in the meantime. WelcomeView itself takes a
//  plain [UIImage] and has no idea these came from here -- dropping in
//  real bundled images later touches only this file (or its Release
//  answer, which is simply an empty array at the call site).
//
//  Same privacy note as DebugFixture.swift: real, identifiable personal
//  photos, DEBUG-only, never committed to git.
//

#if DEBUG
import UIKit

enum DebugWelcomePhotos {
    static func samplePhotos(count: Int = 3) -> [UIImage] {
        guard let bundle = DebugFixture.load() else { return [] }
        return Array(bundle.photos.prefix(count).map(\.thumbnail))
    }
}
#endif
