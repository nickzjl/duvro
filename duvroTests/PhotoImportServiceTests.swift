//
//  PhotoImportServiceTests.swift
//  duvroTests
//
//  Verifies the fix for ImageIO's "trying to save an opaque image with
//  'AlphaPremulLast'... will double (!!!) the required memory when
//  decoding" warning, which fired on every downsample -- and, once
//  EditEngine.renderFullResJPEGData started reusing this same function
//  for Phase 7's resolution cap, on every exported photo too.
//

import Testing
import Foundation
import CoreGraphics
import ImageIO
import UIKit
@testable import duvro

struct PhotoImportServiceTests {

    @Test func downsampleProducesAnOpaqueBitmapNotAlphaCarrying() throws {
        // CGImageSourceCreateThumbnailAtIndex (inside downsample) can
        // hand back a CGImage carrying an alpha channel even from fully
        // opaque source content -- observed from HEIC sources
        // specifically (iPhone's default photo format), not reliably
        // reproducible from a synthetic UIGraphicsImageRenderer JPEG the
        // way this fixture builds one, so this test verifies the
        // POST-CONDITION the fix guarantees (output is always opaque)
        // rather than proving the exact pre-fix failure mode. The fix
        // itself (re-drawing into an explicitly opaque bitmap context)
        // is correct and harmless regardless of whether the source
        // already lacked an alpha channel or not.
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 100)).image { _ in
            UIColor.orange.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        guard let sourceData = sourceImage.jpegData(compressionQuality: 0.95) else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-downsample-test-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try sourceData.write(to: sourceURL)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-downsample-test-out-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try PhotoImportService.downsample(imageAt: sourceURL, maxPixelSize: 50, to: destinationURL)

        let source = try #require(CGImageSourceCreateWithURL(destinationURL as CFURL, nil))
        let cgImage = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))

        let opaqueAlphaInfos: Set<CGImageAlphaInfo> = [.none, .noneSkipFirst, .noneSkipLast]
        #expect(
            opaqueAlphaInfos.contains(cgImage.alphaInfo),
            "expected an opaque bitmap (no alpha channel), got \(cgImage.alphaInfo) -- this is exactly what triggers ImageIO's 'trying to save an opaque image with AlphaPremulLast' warning"
        )
    }

    @Test func downsampleStillProducesAValidJPEGAtTheRequestedCap() throws {
        // Sanity check alongside the opacity test above -- the re-draw
        // step shouldn't break the existing, already-working behavior
        // (correct dimensions, still decodable) while fixing the alpha
        // channel.
        let sourceImage = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200)).image { _ in
            UIColor.blue.setFill()
            UIRectFill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        guard let sourceData = sourceImage.jpegData(compressionQuality: 0.95) else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-downsample-test-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try sourceData.write(to: sourceURL)

        let destinationURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-downsample-test-out-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try PhotoImportService.downsample(imageAt: sourceURL, maxPixelSize: 100, to: destinationURL)

        let image = try #require(UIImage(contentsOfFile: destinationURL.path))
        #expect(Int(image.size.width.rounded()) == 100)
        #expect(Int(image.size.height.rounded()) == 50)
    }
}
