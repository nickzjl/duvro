//
//  DebugFixture.swift
//  duvro
//
//  DEBUG-only, Simulator-only. Vision does not run in the Simulator (no
//  neural-engine runtime there), so ScoringService can never produce a real
//  chosenSelection when running under Simulator -- this loads 15 real
//  photos from DebugAssets/ and fabricates plausible PhotoScore values so
//  the rest of the pipeline (ShortlistService -> FallbackSelectionService
//  -> SessionStore -> Phase 5/6 screens) can be built, run, and
//  screenshotted without Vision ever running.
//
//  DebugAssets/ lives at the REPO ROOT, one level above duvro/ -- outside
//  the Xcode project's file-system-synchronized target folder on purpose.
//  Everything under duvro/ gets auto-added to Copy Bundle Resources (see
//  git history: golden_hour.json and CategoryMapping.json both do, and a
//  Release-build bundle inspection is exactly how that was confirmed this
//  session). Keeping these real personal photos one level up means they
//  can never be swept into ANY app bundle, Debug or Release, by construction
//  -- not because of a #if DEBUG guard on the *files*, only on the *code*
//  that reads them from the host Mac's filesystem, which only works in the
//  Simulator anyway.
//

#if DEBUG
import Foundation
import UIKit

enum DebugFixture {
    struct Bundle {
        let photos: [Photo]
        let scores: [PhotoScore]
    }

    /// Absolute path to the repo's DebugAssets/ folder, computed from this
    /// source file's own compile-time path (#filePath) rather than
    /// hardcoded -- survives the repo living at a different path on a
    /// different machine, as long as this file's location relative to the
    /// repo root doesn't change: duvro/Support/DebugFixture.swift ->
    /// duvro/Support/ -> duvro/ -> repo root.
    private static var debugAssetsURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // DebugFixture.swift
            .deletingLastPathComponent() // Support/
            .deletingLastPathComponent() // duvro/
            .appendingPathComponent("DebugAssets", isDirectory: true)
    }

    /// One entry per DebugAssets file: a category assignment plus fabricated
    /// RAW Vision-shaped inputs (not a composite score directly -- composite
    /// is derived the same way ScoringService would, via PhotoScore's own
    /// init calling CompositeScoring.compute). Content assessed by eye
    /// against the actual 15 images (Aug 2026 session) -- see the handoff
    /// report for the category breakdown and reasoning. featurePrint is
    /// always nil (no Vision in the Simulator): ClusteringService treats a
    /// nil feature print as "never merges with anything," so every fixture
    /// photo lands in its own singleton cluster for free -- exactly the
    /// distinct-clusterID requirement this fixture needs, without hand-
    /// rolling a fake cluster map.
    private struct Entry {
        let filename: String
        let category: PhotoCategory
        /// Vision's ImageAestheticsScoresObservation.overallScore range, -1...1.
        let rawAestheticScore: Float
        let faceCount: Int
        let humanCount: Int
        let bestFaceQuality: Float
    }

    private static let entries: [Entry] = [
        // People -- group shots (get the real groupBonus, faceCount >= 2)
        Entry(filename: "IMG_5105.HEIC", category: .people, rawAestheticScore: 0.42, faceCount: 8, humanCount: 8, bestFaceQuality: 0.66),   // 8-person graduation, daylight, flowers
        Entry(filename: "6B5ECB0F-1C78-4D89-B4E7-51E8DEC45290.JPG", category: .people, rawAestheticScore: 0.16, faceCount: 3, humanCount: 3, bestFaceQuality: 0.72), // 3 friends, classroom whiteboard, daylight
        Entry(filename: "IMG_4338.HEIC", category: .people, rawAestheticScore: 0.30, faceCount: 3, humanCount: 3, bestFaceQuality: 0.58),    // 3 friends, Washington Monument, night
        Entry(filename: "IMG_6448.HEIC", category: .people, rawAestheticScore: 0.26, faceCount: 3, humanCount: 5, bestFaceQuality: 0.58),    // graduation group + background people, night
        Entry(filename: "IMG_4335.HEIC", category: .people, rawAestheticScore: -0.20, faceCount: 3, humanCount: 3, bestFaceQuality: 0.48),   // 3 friends, fountain, night, lower quality

        // Place / food -- the two non-people categories present in this set
        Entry(filename: "IMG_7054.HEIC", category: .place, rawAestheticScore: 0.62, faceCount: 0, humanCount: 0, bestFaceQuality: 0),        // rock cairn, no people -- the one `place` photo
        Entry(filename: "IMG_7259.HEIC", category: .food, rawAestheticScore: 0.50, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // noodle soup, well-lit

        // People -- selfies and physique (faceCount 1, no group bonus)
        Entry(filename: "IMG_7133.HEIC", category: .people, rawAestheticScore: 0.02, faceCount: 1, humanCount: 1, bestFaceQuality: 0.42),    // physique, mirror selfie, clearer face
        Entry(filename: "IMG_6355.HEIC", category: .people, rawAestheticScore: -0.02, faceCount: 1, humanCount: 1, bestFaceQuality: 0.46),   // selfie, profile, in car
        Entry(filename: "IMG_7018.HEIC", category: .people, rawAestheticScore: -0.14, faceCount: 1, humanCount: 1, bestFaceQuality: 0.52),   // selfie, dark close-up
        Entry(filename: "IMG_7285.HEIC", category: .people, rawAestheticScore: -0.20, faceCount: 1, humanCount: 1, bestFaceQuality: 0.38),   // selfie, shower, wet hair
        Entry(filename: "IMG_7234.HEIC", category: .food, rawAestheticScore: 0.10, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // hot pot spread
        Entry(filename: "IMG_7258.HEIC", category: .food, rawAestheticScore: 0.08, faceCount: 0, humanCount: 0, bestFaceQuality: 0),         // skewers
        Entry(filename: "IMG_7286.HEIC", category: .people, rawAestheticScore: -0.26, faceCount: 1, humanCount: 1, bestFaceQuality: 0.34),   // selfie, shower, wet hair
        Entry(filename: "IMG_7047.HEIC", category: .people, rawAestheticScore: -0.24, faceCount: 1, humanCount: 1, bestFaceQuality: 0.30)    // physique, mirror selfie, turned away
    ]

    /// Loads and decodes all 15 DebugAssets photos and fabricates their
    /// scores. nil (with a console print) if DebugAssets/ isn't found --
    /// only possible on a machine without this repo's working tree, since
    /// the path is derived from this very source file.
    static func load() -> Bundle? {
        guard FileManager.default.fileExists(atPath: debugAssetsURL.path) else {
            print("[debug-fixture] DebugAssets/ not found at \(debugAssetsURL.path) -- can't build the fixture")
            return nil
        }

        var photos: [Photo] = []
        var scores: [PhotoScore] = []

        for entry in entries {
            let sourceURL = debugAssetsURL.appendingPathComponent(entry.filename)
            guard let photo = makePhoto(from: sourceURL) else {
                print("[debug-fixture] couldn't decode \(entry.filename), skipping")
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
        return Bundle(photos: photos, scores: scores)
    }

    /// Downsample + thumbnail exactly like a real import (PhotoImportService's
    /// own helpers, reused rather than duplicated) so the rest of the app
    /// sees a Photo indistinguishable in shape from a real one. `originalURL`
    /// points directly at the source file in DebugAssets/ -- fine since
    /// export (Phase 7) is out of scope this session and nothing reads it.
    private static func makePhoto(from sourceURL: URL) -> Photo? {
        guard FileManager.default.fileExists(atPath: sourceURL.path) else { return nil }
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
