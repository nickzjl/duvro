//
//  DebugPackPreviewPhotos.swift
//  duvro
//
//  Phase 8, Task 3. PLACEHOLDER, DEBUG-only -- the ~18 real bundled sample
//  photos each Vibe Pack's preview sheet is meant to ship with don't exist
//  yet (nobody has shot them; BUILD_ROADMAP's Deferred work register).
//  Until they do, PackPreviewSheet borrows subsets of DebugFixture's 15
//  real photos so the three sheets have something to render and don't all
//  look identical to each other. Structured so dropping in real bundled
//  images later touches ONLY this file (or its Release-configuration
//  replacement) -- PackPreviewSheet itself takes a plain [Photo] and has
//  no idea these came from DebugFixture.
//
//  Same privacy note as DebugFixture.swift: these are real, identifiable
//  personal photos, DEBUG-only, never committed to git.
//

#if DEBUG
import Foundation

enum DebugPackPreviewPhotos {
    /// Different, non-overlapping offsets per pack so Golden Hour's,
    /// Digicam's, and Travel Film's preview sheets show different photos
    /// -- otherwise all three would render the exact same 5 images, which
    /// would defeat the point of comparing packs by eye. Wraps around
    /// (`% all.count`) so this stays safe if DebugFixture's photo count
    /// ever changes.
    private static let offsetByPackID: [String: Int] = [
        "golden_hour": 0,
        "digicam": 5,
        "travel_film": 10
    ]

    static func samplePhotos(for packID: String, from all: [Photo], count: Int = 5) -> [Photo] {
        guard !all.isEmpty else { return [] }
        let offset = offsetByPackID[packID] ?? 0
        return (0..<min(count, all.count)).map { all[(offset + $0) % all.count] }
    }
}
#endif
