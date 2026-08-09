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
}
