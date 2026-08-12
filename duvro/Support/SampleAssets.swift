//
//  SampleAssets.swift
//  duvro
//
//  Real, bundled PRODUCT CONTENT for three placeholder surfaces that
//  previously had none: the welcome screen's card stack, the three pack
//  preview sheets, and the vibe-select cards' small thumbnails. Unlike
//  DebugAssets (DEBUG-only, gitignored, never shipped -- see
//  DebugFixture.swift), everything in SampleAssets/ is meant to be in
//  EVERY build configuration, including Release: this file carries no
//  `#if DEBUG` guard, and SampleAssets/ carries no EXCLUDED_SOURCE_FILE_NAMES
//  entry. It lives at `duvro/SampleAssets/` (moved there from the project
//  root where it was first added) specifically so it's picked up by the
//  same PBXFileSystemSynchronizedRootGroup that already syncs the whole
//  `duvro/` tree -- zero project-file surgery needed, same mechanism
//  DebugAssets already relies on, minus that file's Release exclusion.
//
//  Replaces DebugWelcomePhotos.swift and DebugPackPreviewPhotos.swift,
//  both deleted -- nothing else used them.
//

import UIKit

enum SampleAssets {

    // MARK: - Welcome card stack (design/01_welcome.png)

    struct WelcomePhotos {
        let front: UIImage?
        let back: UIImage?
        let middle: UIImage?
    }

    /// Slot assignment, matched by eye against design/01_welcome.png (per
    /// the session's own matching rule: a close content match goes in
    /// that slot; leftovers fill what's left).
    /// - front: "ab5ca9e1…" -- a near-exact match to the mockup's front
    ///   (largest, centered) card: a woman in a white dress, seen from
    ///   behind, standing in ocean waves at sunset.
    /// - back / middle: NEITHER remaining photo matches the mockup's back
    ///   card (a shadow-dance-on-a-wall photo, arms raised) or its middle
    ///   card (a dark, mostly-obscured interior shot) in CONTENT -- both
    ///   are true leftovers. Split between the two slots by overall tone
    ///   only, since that's the only signal available: "5a9affaf…"
    ///   (bright, warm, sunlit forest) reads closer to the back card's
    ///   brighter warm tone; "7b337418…" (darker ocean-silhouette
    ///   close-up) reads closer to the middle card's moodier, lower-key
    ///   tone. Weak reasoning, flagged for correction in the session report.
    static func welcomePhotos() -> WelcomePhotos {
        WelcomePhotos(
            front: image(subdirectory: welcomeSubdirectory, named: "ab5ca9e19d5b3d5f0aff16ead2a70219"),
            back: image(subdirectory: welcomeSubdirectory, named: "5a9affaf0db487d3e60c759db04f7e8a"),
            middle: image(subdirectory: welcomeSubdirectory, named: "7b3374183d029651d8cd29361e992973")
        )
    }

    private static let welcomeSubdirectory = "SampleAssets/Welcome"

    // MARK: - Pack preview grid (design/04-06)

    /// 5 filenames per pack, in the GRID's OWN slot order --
    /// [large, topRightSmall, bottomRightSmall, row2Left, row2Right] --
    /// matching PackPreviewSheet.tile(_:)'s index convention (0...4).
    /// Matched by eye against each pack's own mockup; see inline notes.
    /// All 15 are exact content matches EXCEPT Digicam's top-right slot
    /// (marked below), which is a leftover: nothing in that pack's 5
    /// photos shows the mockup's "sunlit forest through trees" image.
    private static let packPreviewFilenames: [String: (subfolder: String, order: [String])] = [
        "golden_hour": ("GoldenHour", [
            "b72fd9821e13c1531b1c3a3a6cba2fc1", // large: woman silhouette in profile at sunset
            "169fce4927f65cd741ea34a046528444", // top-right small: birds flying low over the beach at golden hour
            "606f55a9606047dfea92149c14d4d958", // bottom-right small: girl backlit by sun through trees
            "6eb2c84edbc34f4569df48b34261b8f7", // row2 left: car dashboard / rearview mirror, road through trees
            "ffab83862bd3639c59df2f1a234fcc55"  // row2 right: a dancer's shadow on a wall, arms raised
        ]),
        "digicam": ("Digicam", [
            "09f32700c4c9d8c351c7545104c66c1f", // large: profile silhouette, warm red backlit sunset flare
            "110e8b687e160f508cc58f345af9f8d2", // top-right small: LEFTOVER -- mockup shows sunlit forest through trees; nothing here matches that, so the other subway/train photo (not used elsewhere in this pack) fills the slot instead
            "f7cc2f9c5add73af71597b51dacda4a7", // bottom-right small: woman on a subway platform, sunglasses -- confirmed against the mockup by zooming in, not just a family resemblance
            "ec76e51f632470bb3a88f3fc98aebfd6", // row2 left: flash-lit selfie with a visible "MAR 15 '04"-style date stamp
            "8ef884a2f50d477a3bdbbce6ae0f5301"  // row2 right: two silhouetted heads in the water, warm sunset lens flare
        ]),
        "travel_film": ("TravelFilm", [
            "1269111ece538ab2ece13f97fe1a691e", // large: woman on a boat looking at a lake/mountain view (Lake Como-style)
            "633e54cf0b02a660f4a49dbfebe025ae", // top-right small: arm out a car window, "FALLEN ROCKS" road sign -- confirmed against the mockup by zooming in
            "205abe8bc7aa55b6ea4a37f4abdcb4a8", // bottom-right small: someone with binoculars/a camera in a mountain-lake landscape
            "0bb4803f6613c76db07b8a17de52c1d8", // row2 left: Cinque-Terre-style coastal town from above, sunset
            "447c32e2887f690fe9c2638559a684d4"  // row2 right: reflection in a car's side mirror
        ])
    ]

    static func packPreviewPhotos(for packID: String) -> [Photo] {
        guard let entry = packPreviewFilenames[packID] else { return [] }
        let subdirectory = "SampleAssets/PackPreviews/\(entry.subfolder)"
        return entry.order.compactMap { makePhoto(subdirectory: subdirectory, basename: $0) }
    }

    // MARK: - Vibe-select card thumbnails

    /// The filenames here are content hashes, NOT pack-named as originally
    /// instructed -- verified directly (sips/mdls: no embedded title,
    /// description, or keyword metadata either). Matched instead by
    /// comparing each image's visible SUBJECT against the vibe-select
    /// mockup's (design/03) own per-pack thumbnail, the same
    /// content-matching approach used for the welcome stack and pack
    /// previews above. Flagged for correction in the session report.
    private static let thumbnailFilenames: [String: String] = [
        "golden_hour": "f797d01a02480e55a99fdb4b75c43fa2", // golden-hour sailboat silhouette on the water -- direct thematic match ("golden hour")
        "digicam": "5148e632739c5542568f1435072cda11",     // beach sunset with vertical light-leak-style color streaks -- LEFTOVER (mockup's own reference is a nighttime flash street photo; this doesn't match that, but at least echoes Digicam's "Light Leak" variant by the streaks visible in the photo itself)
        "travel_film": "a4096fcf7ae9e2d29541f768deb456f0"  // train winding through a mountain range -- direct thematic match ("travel")
    ]

    static func packThumbnail(for packID: String) -> UIImage? {
        guard let basename = thumbnailFilenames[packID] else { return nil }
        return image(subdirectory: "SampleAssets/PackThumbnails", named: basename)
    }

    // MARK: - Bundle lookup

    /// Dual-path lookup -- subdirectory first, then bundle root -- same
    /// pattern CategoryMapper/VibePackLoader/DebugFixture already use,
    /// since file-system-synchronized groups have flattened resources to
    /// bundle root in this project every time that's been checked, but
    /// this doesn't assume that stays true.
    private static func url(subdirectory: String, named basename: String) -> URL? {
        Bundle.main.url(forResource: basename, withExtension: "jpg", subdirectory: subdirectory)
            ?? Bundle.main.url(forResource: basename, withExtension: "jpg")
    }

    private static func image(subdirectory: String, named basename: String) -> UIImage? {
        guard let url = url(subdirectory: subdirectory, named: basename) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// Downsample + thumbnail exactly like a real import (PhotoImportService's
    /// own helpers, reused rather than duplicated) so PackPreviewSheet's
    /// EditEngine.render call sees a Photo indistinguishable in shape from
    /// a real one -- same pattern DebugFixture.makePhoto uses for its own
    /// real photos.
    private static func makePhoto(subdirectory: String, basename: String) -> Photo? {
        guard let sourceURL = url(subdirectory: subdirectory, named: basename) else { return nil }
        let id = UUID()
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("duvro-sample-assets", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let downsampledURL = tempDir.appendingPathComponent(id.uuidString).appendingPathExtension("jpg")
        do {
            try PhotoImportService.downsample(imageAt: sourceURL, maxPixelSize: 1280, to: downsampledURL)
            let thumbnail = try PhotoImportService.thumbnailImage(from: downsampledURL, maxPixelSize: 200)
            let captureDate = PhotoImportService.captureDate(from: sourceURL)
            return Photo(id: id, originalURL: sourceURL, downsampledURL: downsampledURL, thumbnail: thumbnail, captureDate: captureDate)
        } catch {
            return nil
        }
    }
}
