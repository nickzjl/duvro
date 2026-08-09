//
//  DebugFixture.swift
//  duvro
//
//  DEBUG-only. Vision does not run in the Simulator (no neural-engine
//  runtime there), so ScoringService can never produce a real
//  chosenSelection when running under Simulator -- this loads 15 real
//  photos and fabricates plausible PhotoScore values so the rest of the
//  pipeline (ShortlistService -> FallbackSelectionService -> SessionStore
//  -> Phase 5/6 screens) can be built, run, and screenshotted without
//  Vision ever running.
//
//  BUNDLE RESOURCES, NOT A FILESYSTEM PATH. An earlier version of this file
//  read the photos from an absolute host-Mac path computed via #filePath.
//  That doesn't work: an app (Simulator or device) can't read an arbitrary
//  absolute path from outside its own container -- the fileExists check
//  failed every time, so `load()` always returned nil and every screen this
//  fixture fed was silently empty, undetected until an actual console log
//  was checked. The 15 images now live at duvro/DebugAssets/ -- real
//  members of the Xcode project's file-system-synchronized duvro/ folder --
//  and are loaded via Bundle.main, the only mechanism that's ever actually
//  correct for bundled resources, on-device or in the Simulator alike.
//
//  Being real bundle resources means they'd ship in EVERY configuration by
//  default (see golden_hour.json / CategoryMapping.json, which do). Keeping
//  them Debug-only is now the Release build configuration's
//  EXCLUDED_SOURCE_FILE_NAMES = ("DebugAssets/*") -- verify this, don't
//  assume it: a Release .app bundle inspection is how this file's Debug-only
//  claim gets confirmed, not just the #if DEBUG below (that guard keeps
//  this FILE's code out of Release; the build setting is what keeps the
//  IMAGES out, since they aren't Swift source and #if DEBUG can't touch them).
//
//  Never committed to git either way -- duvro/DebugAssets/ is in .gitignore.
//  Real, identifiable personal photos.
//

#if DEBUG
import Foundation
import UIKit

enum DebugFixture {
    struct FixtureBundle {
        let photos: [Photo]
        let scores: [PhotoScore]
    }

    /// One entry per DebugAssets file: a category assignment plus fabricated
    /// RAW Vision-shaped inputs (not a composite score directly -- composite
    /// is derived the same way ScoringService would, via PhotoScore's own
    /// init calling CompositeScoring.compute). Content assessed by eye
    /// against the actual 15 images (Aug 2026 session) -- see the handoff
    /// report for the category breakdown and reasoning. featurePrint is
    /// always nil (no Vision available): ClusteringService treats a nil
    /// feature print as "never merges with anything," so every fixture
    /// photo lands in its own singleton cluster for free -- exactly the
    /// distinct-clusterID requirement this fixture needs, without hand-
    /// rolling a fake cluster map.
    private struct Entry {
        let name: String
        let ext: String
        let category: PhotoCategory
        /// Vision's ImageAestheticsScoresObservation.overallScore range, -1...1.
        let rawAestheticScore: Float
        let faceCount: Int
        let humanCount: Int
        let bestFaceQuality: Float
    }

    private static let entries: [Entry] = [
        // People -- group shots (get the real groupBonus, faceCount >= 2)
        Entry(name: "IMG_5105", ext: "HEIC", category: .people, rawAestheticScore: 0.42, faceCount: 8, humanCount: 8, bestFaceQuality: 0.66),   // 8-person graduation, daylight, flowers
        Entry(name: "6B5ECB0F-1C78-4D89-B4E7-51E8DEC45290", ext: "JPG", category: .people, rawAestheticScore: 0.16, faceCount: 3, humanCount: 3, bestFaceQuality: 0.72), // 3 friends, classroom whiteboard, daylight
        Entry(name: "IMG_4338", ext: "HEIC", category: .people, rawAestheticScore: 0.30, faceCount: 3, humanCount: 3, bestFaceQuality: 0.58),    // 3 friends, Washington Monument, night
        Entry(name: "IMG_6448", ext: "HEIC", category: .people, rawAestheticScore: 0.26, faceCount: 3, humanCount: 5, bestFaceQuality: 0.58),    // graduation group + background people, night
        Entry(name: "IMG_4335", ext: "HEIC", category: .people, rawAestheticScore: -0.20, faceCount: 3, humanCount: 3, bestFaceQuality: 0.48),   // 3 friends, fountain, night, lower quality

        // Place / food -- the two non-people categories present in this set
        Entry(name: "IMG_7054", ext: "HEIC", category: .place, rawAestheticScore: 0.62, faceCount: 0, humanCount: 0, bestFaceQuality: 0),        // rock cairn, no people -- the one `place` photo
        Entry(name: "IMG_7259", ext: "HEIC", category: .food, rawAestheticScore: 0.50, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // noodle soup, well-lit

        // People -- selfies and physique (faceCount 1, no group bonus)
        Entry(name: "IMG_7133", ext: "HEIC", category: .people, rawAestheticScore: 0.02, faceCount: 1, humanCount: 1, bestFaceQuality: 0.42),    // physique, mirror selfie, clearer face
        Entry(name: "IMG_6355", ext: "HEIC", category: .people, rawAestheticScore: -0.02, faceCount: 1, humanCount: 1, bestFaceQuality: 0.46),   // selfie, profile, in car
        Entry(name: "IMG_7018", ext: "HEIC", category: .people, rawAestheticScore: -0.14, faceCount: 1, humanCount: 1, bestFaceQuality: 0.52),   // selfie, dark close-up
        Entry(name: "IMG_7285", ext: "HEIC", category: .people, rawAestheticScore: -0.20, faceCount: 1, humanCount: 1, bestFaceQuality: 0.38),   // selfie, shower, wet hair
        Entry(name: "IMG_7234", ext: "HEIC", category: .food, rawAestheticScore: 0.10, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // hot pot spread
        Entry(name: "IMG_7258", ext: "HEIC", category: .food, rawAestheticScore: 0.08, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // skewers
        Entry(name: "IMG_7286", ext: "HEIC", category: .people, rawAestheticScore: -0.26, faceCount: 1, humanCount: 1, bestFaceQuality: 0.34),   // selfie, shower, wet hair
        Entry(name: "IMG_7047", ext: "HEIC", category: .people, rawAestheticScore: -0.24, faceCount: 1, humanCount: 1, bestFaceQuality: 0.30)    // physique, mirror selfie, turned away
    ]

    /// Loads and decodes all 15 DebugAssets photos and fabricates their
    /// scores. nil (with a console print) if a resource can't be found --
    /// same dual-path lookup CategoryMapper/VibePackLoader use
    /// (`subdirectory: "DebugAssets"`, then bundle root), since file-system-
    /// synchronized groups have flattened resources to bundle root in this
    /// project every time that's been checked, but this doesn't assume that
    /// stays true.
    static func load(bundle: Foundation.Bundle = .main) -> FixtureBundle? {
        var photos: [Photo] = []
        var scores: [PhotoScore] = []

        for entry in entries {
            guard let sourceURL = bundle.url(forResource: entry.name, withExtension: entry.ext, subdirectory: "DebugAssets")
                ?? bundle.url(forResource: entry.name, withExtension: entry.ext)
            else {
                print("[debug-fixture] '\(entry.name).\(entry.ext)' not found in bundle \(bundle.bundlePath) -- skipping")
                continue
            }
            guard let photo = makePhoto(from: sourceURL) else {
                print("[debug-fixture] couldn't decode \(entry.name).\(entry.ext), skipping")
                continue
            }
            photos.append(photo)

            let score = PhotoScore(
                id: photo.id,
                rawAestheticScore: entry.rawAestheticScore,
                isUtility: false,
                faceCount: entry.faceCount,
                bestFaceQuality: entry.bestFaceQuality,
                humanCount: entry.humanCount,
                classificationLabels: [],
                category: entry.category,
                featurePrint: nil,
                rejectionReason: nil
            )
            scores.append(score)
        }

        print("[debug-fixture] loaded \(photos.count)/\(entries.count) debug photos")
        guard !photos.isEmpty else { return nil }
        return FixtureBundle(photos: photos, scores: scores)
    }

    /// Downsample + thumbnail exactly like a real import (PhotoImportService's
    /// own helpers, reused rather than duplicated) so the rest of the app
    /// sees a Photo indistinguishable in shape from a real one. `originalURL`
    /// points at the bundled source file -- fine since export (Phase 7) is
    /// out of scope this session and nothing reads it.
    private static func makePhoto(from sourceURL: URL) -> Photo? {
        let id = UUID()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("duvro-debug-fixture", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let downsampledURL = tempDir.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
        do {
            try PhotoImportService.downsample(imageAt: sourceURL, maxPixelSize: 1280, to: downsampledURL)
            let thumbnail = try PhotoImportService.thumbnailImage(from: downsampledURL, maxPixelSize: 200)
            return Photo(id: id, originalURL: sourceURL, downsampledURL: downsampledURL, thumbnail: thumbnail)
        } catch {
            print("[debug-fixture] failed to process \(sourceURL.lastPathComponent): \(error)")
            return nil
        }
    }
}
#endif
