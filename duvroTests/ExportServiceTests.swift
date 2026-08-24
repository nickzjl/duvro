//
//  ExportServiceTests.swift
//  duvroTests
//
//  Phase 7, Task 1: verifies the full-res export pipeline's three
//  load-bearing guarantees WITHOUT needing Photos permission, a physical
//  device, or any hand-driving -- exactly the part of this phase that can
//  be verified in this environment (album writes/permission dialogs
//  cannot, per this phase's instruction, and aren't covered here):
//    1. centerCropRect actually produces a 4:5 rect for both a
//       relatively-wide and a relatively-tall source.
//    2. renderFullResJPEGData's OUTPUT is genuinely 4:5 (decodes the
//       returned JPEG back and checks pixel dimensions), not just "runs
//       without crashing" -- this is the "preview matches final export
//       1:1" acceptance criterion, checked at the pixel level.
//    3. ExportService.renderAll calls `handle` once per item, in order,
//       and tracks progress correctly.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import UIKit
@testable import duvro

struct ExportServiceTests {

    // MARK: - centerCropRect

    @Test func cropsARelativelyWideSourceOnTheSides() {
        // 200x100 (2:1) is much wider than 4:5 -- expect full height kept,
        // width reduced to height * 4/5.
        let extent = CGRect(x: 0, y: 0, width: 200, height: 100)
        let crop = EditEngine.centerCropRect(for: extent, aspectRatio: 4.0 / 5.0)
        #expect(crop.height == 100)
        #expect(crop.width == 80) // 100 * 4/5
        #expect(crop.origin.x == 60) // (200-80)/2, centered
        #expect(crop.origin.y == 0)
    }

    @Test func cropsARelativelyTallSourceTopAndBottom() {
        // 100x300 (1:3) is much taller than 4:5 -- expect full width kept,
        // height reduced to width / (4/5).
        let extent = CGRect(x: 0, y: 0, width: 100, height: 300)
        let crop = EditEngine.centerCropRect(for: extent, aspectRatio: 4.0 / 5.0)
        #expect(crop.width == 100)
        #expect(crop.height == 125) // 100 / (4/5)
        #expect(crop.origin.x == 0)
        #expect(crop.origin.y == 87.5) // (300-125)/2, centered
    }

    @Test func leavesAnAlreadyCorrectAspectRatioUntouched() {
        let extent = CGRect(x: 0, y: 0, width: 400, height: 500) // exactly 4:5
        let crop = EditEngine.centerCropRect(for: extent, aspectRatio: 4.0 / 5.0)
        #expect(crop == extent)
    }

    @Test func degenerateExtentReturnsExtentRatherThanNaN() {
        let extent = CGRect(x: 0, y: 0, width: 0, height: 0)
        let crop = EditEngine.centerCropRect(for: extent, aspectRatio: 4.0 / 5.0)
        #expect(crop == extent) // guard clause, not a divide-by-zero
    }

    // MARK: - renderFullResJPEGData: output is ACTUALLY 4:5, not just non-crashing

    @Test func fullResRenderProducesGenuinely4x5OutputFromAWideSource() throws {
        // Native 300x150 (2:1) -- if this function only ran the op chain
        // and skipped cropping, the output would still be 2:1.
        let photo = try Self.makeTestPhoto(width: 300, height: 150)
        let variant = EditVariant(name: "identity", ops: [])
        let data = EditEngine.renderFullResJPEGData(photo: photo, variant: variant)
        let image = try #require(data.flatMap { UIImage(data: $0) })
        let ratio = image.size.width / image.size.height
        #expect(abs(ratio - 0.8) < 0.02, "expected ~4:5 (0.8), got \(image.size) (ratio \(ratio))")
    }

    @Test func fullResRenderProducesGenuinely4x5OutputFromATallSource() throws {
        // Native 150x400 (much taller than 4:5).
        let photo = try Self.makeTestPhoto(width: 150, height: 400)
        let variant = EditVariant(name: "identity", ops: [])
        let data = EditEngine.renderFullResJPEGData(photo: photo, variant: variant)
        let image = try #require(data.flatMap { UIImage(data: $0) })
        let ratio = image.size.width / image.size.height
        #expect(abs(ratio - 0.8) < 0.02, "expected ~4:5 (0.8), got \(image.size) (ratio \(ratio))")
    }

    @Test func fullResRenderAppliesEXIFOrientationBeforeCropping() throws {
        // The bug this catches: CIImage(contentsOf:) with no options
        // reads the raw, AS-STORED pixel buffer and ignores the image's
        // EXIF orientation tag entirely. iPhone photos taken in portrait
        // are commonly stored as a LANDSCAPE pixel buffer plus a tag
        // saying "rotate 90 CW to display upright" -- SwiftUI (and Image
        // I/O's own thumbnail generator, PhotoImportService.downsample's
        // kCGImageSourceCreateThumbnailWithTransform) honor that
        // automatically; plain CIImage(contentsOf:) does not, which is
        // why the preview (built from downsampledURL) was correct while
        // the export (built from originalURL) came out rotated.
        //
        // A pure aspect-ratio check (the other tests above) CANNOT catch
        // this: centerCropRect always forces exactly 4:5 regardless of
        // which dimension is "wrong," so a broken and a fixed render
        // both come out 0.8 ratio. This test instead fixes a source
        // orientation where "corrected" and "as-stored" give
        // DIFFERENT ABSOLUTE crop sizes, and checks the actual pixels:
        //
        // Stored buffer: 200x100 (landscape), tagged EXIF orientation 6
        // ("rotate 90 CW to display correctly") -- i.e. the TRUE,
        // corrected image is 100x200 (portrait).
        //   - Orientation HONORED: source extent 100x200, sourceAspect
        //     0.5 < 0.8 (target) -> centerCropRect keeps the full 100pt
        //     width, crops height to 100/0.8 = 125. Output: 100x125.
        //   - Orientation IGNORED (the bug): source extent stays the raw
        //     200x100, sourceAspect 2.0 > 0.8 -> keeps the full 100pt
        //     HEIGHT, crops width to 100*0.8 = 80. Output: 80x100.
        // 100x125 and 80x100 are unambiguously different sizes.
        let photo = try Self.makeOrientedTestPhoto(storedWidth: 200, storedHeight: 100, exifOrientation: 6)
        let variant = EditVariant(name: "identity", ops: [])
        let data = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: variant))
        let image = try #require(UIImage(data: data))
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        // Exact width (100), +/-1px tolerance on height (125) -- JPEG
        // encode/decode rounding, not a correctness question. The
        // discriminating signal is "close to 100x125," not "exactly" --
        // 80x100 (orientation ignored) isn't within 20px of either
        // number, so there's no risk of the tolerance masking the bug.
        #expect(width == 100, "expected width 100 (orientation honored), got \(width) (200 or 80 would mean orientation was ignored -- the bug)")
        #expect(abs(height - 125) <= 1, "expected height ~125 (100/0.8, orientation honored), got \(height) (100 would mean orientation was ignored -- the bug)")
    }

    @Test func fullResRenderProducesPortraitFromAnAlreadyLandscapeSource() throws {
        // Reproduces the exact reported scenario: a source that's
        // GENUINELY landscape (not portrait-stored-sideways) -- EXIF
        // orientation 1, no rotation flag, unlike the
        // orientation-6 test above. 400x300 mirrors 4032x3024's ~4:3
        // shape (scaled down for test speed). If the crop were being
        // skipped or mis-applied specifically for already-landscape,
        // no-rotation-needed sources, this is the case that would show
        // it -- checked via width < height directly (not just ratio),
        // since that's the literal, unambiguous signal for "exported
        // landscape instead of portrait."
        let photo = try Self.makeOrientedTestPhoto(storedWidth: 400, storedHeight: 300, exifOrientation: 1)
        let variant = EditVariant(name: "identity", ops: [])
        let data = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: variant))
        let image = try #require(UIImage(data: data))
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        #expect(width < height, "expected portrait output (width < height) per UI_NOTES §1's 4:5 everywhere, got \(width)x\(height)")
        #expect(width == 240 && abs(height - 300) <= 1, "expected ~240x300 (300 * 0.8 = 240, full height kept), got \(width)x\(height)")
    }

    @Test func maxExportPixelSizeIs2048() {
        // Pins the product decision (roughly 1.9x Instagram's own
        // carousel serving resolution, ~1080x1350) as a real test, not
        // just a comment -- a future accidental change to this constant
        // fails loudly instead of silently.
        #expect(EditEngine.maxExportPixelSize == 2048)
    }

    @Test func fullResRenderCapsResolutionBeforeCropping() throws {
        // The bug this catches: rendering a 24MP+ source at native
        // resolution measured 531MB peak against a 400MB ceiling on
        // device (97-123MB retained per 24MP photo, never released).
        // The fix downsamples via PhotoImportService.downsample BEFORE
        // the crop/op chain ever sees the pixels -- this test checks
        // that the crop actually runs against the CAPPED size, not the
        // original, by picking a maxPixelSize where the two cases
        // produce unambiguously different absolute output dimensions
        // (both already-passing 4:5-ratio tests can't tell them apart,
        // same reasoning as the orientation test above -- centerCropRect
        // always forces exactly 4:5 regardless of which size it's
        // handed).
        //
        // Source: 400x300 (4:3 landscape). maxPixelSize: 200.
        //   - Cap applied: downsamples to 200x150 (aspect preserved) --
        //     sourceAspect 1.333 > 0.8 -> centerCropRect keeps the full
        //     150pt height, crops width to 150*0.8 = 120. Output: 120x150.
        //   - Cap ignored (the bug): crop runs against the original
        //     400x300 (SAME aspect, since downsampling preserves it) --
        //     keeps the full 300pt height, crops width to 300*0.8 = 240.
        //     Output: 240x300 -- exactly double the capped case in both
        //     dimensions.
        let photo = try Self.makeOrientedTestPhoto(storedWidth: 400, storedHeight: 300, exifOrientation: 1)
        let variant = EditVariant(name: "identity", ops: [])
        let data = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: variant, maxPixelSize: 200))
        let image = try #require(UIImage(data: data))
        let width = Int(image.size.width.rounded())
        let height = Int(image.size.height.rounded())
        #expect(abs(width - 120) <= 2, "expected width ~120 (capped to 200x150, then 4:5 cropped), got \(width) (240 would mean the cap was ignored -- the bug)")
        #expect(abs(height - 150) <= 2, "expected height ~150 (full capped height kept), got \(height) (300 would mean the cap was ignored -- the bug)")
    }

    @Test func fullResRenderAppliesTheOpChainNotJustTheIdentity() throws {
        // A visible op (heavy fade) should change pixel data relative to
        // an empty chain -- sanity check that this function isn't
        // silently skipping the op chain and only cropping.
        let photo = try Self.makeTestPhoto(width: 200, height: 250, color: .blue)
        let identity = EditVariant(name: "identity", ops: [])
        let faded = EditVariant(name: "faded", ops: [.fade(amount: 1.0)])

        let identityData = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: identity))
        let fadedData = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: faded))
        #expect(identityData != fadedData)
    }

    @Test func fullResRenderReturnsNilForAnUnreadableOriginal() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-export-test-does-not-exist-\(UUID().uuidString).jpg")
        let photo = Photo(id: UUID(), originalURL: missingURL, downsampledURL: missingURL, thumbnail: UIImage())
        let variant = EditVariant(name: "identity", ops: [])
        #expect(EditEngine.renderFullResJPEGData(photo: photo, variant: variant) == nil)
    }

    // MARK: - ExportService.renderAll: order, progress, one-call-per-item

    @Test func rendersEveryItemExactlyOnceInOrder() async throws {
        let items = try [
            ExportService.Item(photo: Self.makeTestPhoto(width: 120, height: 150, color: .red), variant: EditVariant(name: "v", ops: [])),
            ExportService.Item(photo: Self.makeTestPhoto(width: 120, height: 150, color: .green), variant: EditVariant(name: "v", ops: [])),
            ExportService.Item(photo: Self.makeTestPhoto(width: 120, height: 150, color: .yellow), variant: EditVariant(name: "v", ops: []))
        ]

        let service = await ExportService()
        // Actor-isolated accumulator -- `handle` can be called from any
        // context renderAll chooses to await it from; a plain array
        // captured across concurrent access would be a data race.
        let recorder = Recorder()

        try await service.renderAll(items) { index, data in
            await recorder.record(index: index, byteCount: data.count)
        }

        let seen = await recorder.indices
        #expect(seen == [0, 1, 2]) // in order, once each -- not out of order, not skipped, not duplicated
        #expect(await service.exportedCount == 3)
        #expect(await service.totalCount == 3)
        #expect(await service.isExporting == false) // reset after completion
    }

    @Test func throwsOnFirstRenderFailureAndStopsRatherThanSkipping() async throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-export-test-missing-\(UUID().uuidString).jpg")
        let brokenPhoto = Photo(id: UUID(), originalURL: missingURL, downsampledURL: missingURL, thumbnail: UIImage())
        let items = try [
            ExportService.Item(photo: Self.makeTestPhoto(width: 100, height: 125), variant: EditVariant(name: "v", ops: [])),
            ExportService.Item(photo: brokenPhoto, variant: EditVariant(name: "v", ops: [])),
            ExportService.Item(photo: Self.makeTestPhoto(width: 100, height: 125), variant: EditVariant(name: "v", ops: []))
        ]

        let service = await ExportService()
        let recorder = Recorder()

        await #expect(throws: ExportService.RenderError.self) {
            try await service.renderAll(items) { index, data in
                await recorder.record(index: index, byteCount: data.count)
            }
        }

        let seen = await recorder.indices
        #expect(seen == [0]) // stopped at the failure -- item 2 (the good one after the bad one) never ran
    }

    // MARK: - ExportService.creationDate: which end of the batch is newest

    @Test func firstPhotoGetsTheOldestDateLastPhotoGetsTheNewest() {
        // This formula controls the PHOTOS APP's ordering, not
        // Instagram's -- Instagram's picker sorts by insertion order,
        // which is ExportService.saveAll's reversed loop, not this.
        // Two separate attempts to fix a picker-order bug by inverting
        // THIS formula both failed for exactly that reason; see
        // saveAll's doc comment. Pinned here so neither direction can be
        // flipped again without a test noticing, and so the next person
        // chasing picker order is pointed at the right mechanism.
        //
        // Photos lays the camera roll out oldest-first, so photo 1 being
        // the oldest is what makes the exported post read in carousel
        // order there.
        let now = Date()
        let count = 7

        // The reference date itself (0 seconds back) belongs to the
        // LAST index (6), not index 0.
        let first = ExportService.creationDate(forIndex: 0, count: count, referenceDate: now)
        let last = ExportService.creationDate(forIndex: count - 1, count: count, referenceDate: now)
        #expect(last == now, "the LAST photo should be the newest -- exactly referenceDate")
        #expect(first == now.addingTimeInterval(-6), "the FIRST photo should be the oldest -- (count-1) seconds before referenceDate")
        #expect(first < last, "chronologically, photo 1 must predate photo 7 -- that's what makes the post read in carousel order in the Photos app")

        // Strictly ascending, 1 second apart, for every index in between
        // too -- not just the two ends.
        let dates = (0..<count).map { ExportService.creationDate(forIndex: $0, count: count, referenceDate: now) }
        for index in 1..<count {
            let delta = dates[index].timeIntervalSince(dates[index - 1])
            #expect(abs(delta - 1) < 0.001, "expected exactly 1 second between consecutive photos, got \(delta)")
        }
    }

    @Test func creationDateHandlesASinglePhotoPost() {
        // count - 1 - index must never go negative -- a 1-photo post
        // (skip can shrink a dump this far) should just get
        // referenceDate itself, not crash or produce a nonsensical date.
        let now = Date()
        #expect(ExportService.creationDate(forIndex: 0, count: 1, referenceDate: now) == now)
    }

    // MARK: - Fixtures

    private actor Recorder {
        private(set) var indices: [Int] = []
        func record(index: Int, byteCount: Int) {
            indices.append(index)
        }
    }

    /// Same shape as VibePackTests.makeTestPhoto, but with a caller-chosen
    /// (often deliberately non-4:5) size, since these tests specifically
    /// need to exercise the crop math against wide/tall sources -- a
    /// synthetic 8x8 square (as VibePackTests uses) can't distinguish
    /// "cropped to 4:5" from "not cropped at all."
    private static func makeTestPhoto(width: Int, height: Int, color: UIColor = .orange) throws -> Photo {
        let size = CGSize(width: width, height: height)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-export-test-photo-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: url)
        // originalURL and downsampledURL both point at the same fixture --
        // renderFullResJPEGData only ever reads originalURL, but Photo
        // requires both.
        return Photo(id: UUID(), originalURL: url, downsampledURL: url, thumbnail: image)
    }

    /// Like makeTestPhoto, but writes the JPEG with an explicit
    /// kCGImagePropertyOrientation tag via CGImageDestination directly
    /// (UIImage.jpegData doesn't expose a way to set this) -- the ONLY
    /// way to construct a fixture that can actually distinguish
    /// "orientation applied" from "orientation ignored," which
    /// UIGraphicsImageRenderer-generated images (all orientation 1,
    /// "normal") cannot.
    private static func makeOrientedTestPhoto(storedWidth: Int, storedHeight: Int, exifOrientation: UInt32, color: UIColor = .orange) throws -> Photo {
        let size = CGSize(width: storedWidth, height: storedHeight)
        // scale = 1 explicitly -- UIGraphicsImageRenderer(size:) alone
        // defaults to the CURRENT TRAIT ENVIRONMENT's scale (3x on the
        // Simulator device this ran on), silently turning a requested
        // 200x100-POINT image into a 600x300-PIXEL one. This test's
        // whole point is asserting exact pixel dimensions, so an
        // uncontrolled scale factor makes it meaningless -- first run
        // produced 300x376 instead of the expected 100x125, which
        // (300 = 100 * 3, and the math otherwise checked out exactly)
        // confirmed the FIX was working correctly and the FIXTURE was
        // the one with the bug, not renderFullResJPEGData.
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        guard let cgImage = image.cgImage else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-export-test-oriented-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            struct DestinationCreationFailed: Error {}
            throw DestinationCreationFailed()
        }
        let properties: [CFString: Any] = [kCGImagePropertyOrientation: exifOrientation]
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            struct FinalizeFailed: Error {}
            throw FinalizeFailed()
        }
        return Photo(id: UUID(), originalURL: url, downsampledURL: url, thumbnail: image)
    }
}
