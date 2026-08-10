//
//  DigicamOpsTests.swift
//  duvroTests
//
//  Phase 8, Task 1: unit tests for the three ops added for the Digicam
//  pack -- lightLeak, polaroidFrame, dateStamp. Same conventions as
//  VibePackTests.swift (Codable round-trip per op) and ExportServiceTests
//  (pixel-level, discriminating assertions -- NOT just "doesn't crash"):
//  each render test asserts something a broken-but-non-crashing
//  implementation could still fail, e.g. "the corner is actually a
//  different color than before" rather than just "returned an image."
//

import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import duvro

struct DigicamOpsTests {

    // MARK: - EditOp Codable

    @Test func decodesLightLeak() throws {
        let json = Data("""
        { "type": "lightLeak", "intensity": 0.5, "corner": "topTrailing" }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .lightLeak(let intensity, let corner) = op else {
            Issue.record("expected .lightLeak, got \(op)")
            return
        }
        #expect(intensity == 0.5)
        #expect(corner == "topTrailing")
    }

    @Test func decodesPolaroidFrame() throws {
        let json = Data("""
        { "type": "polaroidFrame", "borderWidth": 0.08, "bottomBorderMultiplier": 3.0 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .polaroidFrame(let borderWidth, let bottomBorderMultiplier) = op else {
            Issue.record("expected .polaroidFrame, got \(op)")
            return
        }
        #expect(borderWidth == 0.08)
        #expect(bottomBorderMultiplier == 3.0)
    }

    @Test func decodesDateStamp() throws {
        let json = Data("""
        { "type": "dateStamp", "corner": "bottomTrailing", "scale": 0.035 }
        """.utf8)
        let op = try JSONDecoder().decode(EditOp.self, from: json)
        guard case .dateStamp(let corner, let scale) = op else {
            Issue.record("expected .dateStamp, got \(op)")
            return
        }
        #expect(corner == "bottomTrailing")
        #expect(scale == 0.035)
    }

    @Test func newOpsRoundTripThroughEncodeDecode() throws {
        // Codable symmetry, not just decode -- a mistake in encode(to:)'s
        // key names wouldn't show up in the decode-only tests above.
        let ops: [EditOp] = [
            .lightLeak(intensity: 0.4, corner: "bottomLeading"),
            .polaroidFrame(borderWidth: 0.06, bottomBorderMultiplier: 2.5),
            .dateStamp(corner: "bottomLeading", scale: 0.03)
        ]
        for op in ops {
            let data = try JSONEncoder().encode(op)
            let decoded = try JSONDecoder().decode(EditOp.self, from: data)
            #expect(decoded == op, "round-trip mismatch for \(op)")
        }
    }

    // MARK: - lightLeak: discriminating render test

    @Test func lightLeakWarmsTheTargetCornerButNotTheOppositeOne() throws {
        // Solid neutral gray so a warm (red-up, blue-down) shift at the
        // target corner is unambiguous, and so the untouched opposite
        // corner has an obvious, exact expected value to compare against.
        let photo = try Self.makeTestPhoto(width: 200, height: 200, color: UIColor(white: 0.5, alpha: 1))
        let variant = EditVariant(name: "leak", ops: [.lightLeak(intensity: 0.9, corner: "bottomTrailing")])
        let rendered = EditEngine.render(photo: photo, variant: variant)
        let cgImage = try #require(rendered.cgImage)

        // bottomTrailing in CI space (Y up) is the image's bottom-right
        // corner in on-screen/UIKit terms -- UIKit CGImage rows run
        // top-to-bottom, so that's (maxX, maxY) in pixel-buffer coordinates.
        let width = cgImage.width, height = cgImage.height
        let leak = try Self.pixel(in: cgImage, x: width - 4, y: height - 4)
        let opposite = try Self.pixel(in: cgImage, x: 4, y: 4) // top-left on screen -- diagonally opposite bottomTrailing

        #expect(leak.r > opposite.r + 20, "expected the light-leak corner to read warmer (more red) than the untouched opposite corner -- leak r=\(leak.r) opposite r=\(opposite.r)")
        #expect(opposite.r > 100 && opposite.r < 150, "opposite corner should be close to the original 50% gray, got r=\(opposite.r)")
    }

    @Test func lightLeakWithZeroIntensityIsANoOp() throws {
        let photo = try Self.makeTestPhoto(width: 100, height: 100, color: UIColor(white: 0.5, alpha: 1))
        let identity = EditVariant(name: "identity", ops: [])
        let zeroLeak = EditVariant(name: "zero", ops: [.lightLeak(intensity: 0, corner: "topLeading")])
        let identityImage = EditEngine.render(photo: photo, variant: identity)
        let zeroImage = EditEngine.render(photo: photo, variant: zeroLeak)
        #expect(identityImage.pngData() == zeroImage.pngData())
    }

    @Test func lightLeakWithUnknownCornerFailsSafeToUnedited() throws {
        let photo = try Self.makeTestPhoto(width: 100, height: 100, color: UIColor(white: 0.5, alpha: 1))
        let identity = EditVariant(name: "identity", ops: [])
        let badCorner = EditVariant(name: "bad", ops: [.lightLeak(intensity: 0.8, corner: "middle")])
        let identityImage = EditEngine.render(photo: photo, variant: identity)
        let badImage = EditEngine.render(photo: photo, variant: badCorner)
        #expect(identityImage.pngData() == badImage.pngData(), "an unrecognized corner string must fail safe to the unedited image, not crash or apply a default")
    }

    // MARK: - polaroidFrame: discriminating render test (white border + genuinely 4:5)

    @Test func polaroidFrameProducesAWhiteBorderOnA4x5CanvasWithAThickerBottom() throws {
        // Deliberately non-4:5 (square) and deliberately non-white
        // (saturated blue) so both assertions below are unambiguous: a
        // white corner can only be the frame (the source has none), and a
        // 4:5 output can only come from the crop actually running.
        let photo = try Self.makeTestPhoto(width: 400, height: 400, color: .blue)
        let variant = EditVariant(name: "polaroid", ops: [.polaroidFrame(borderWidth: 0.08, bottomBorderMultiplier: 3.0)])
        let data = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: variant))
        let image = try #require(UIImage(data: data))
        let cgImage = try #require(image.cgImage)

        let ratio = image.size.width / image.size.height
        #expect(abs(ratio - 0.8) < 0.02, "polaroidFrame must still produce a genuinely 4:5 export, got \(image.size) (ratio \(ratio))")

        let width = cgImage.width, height = cgImage.height
        let topLeft = try Self.pixel(in: cgImage, x: 2, y: 2)
        let center = try Self.pixel(in: cgImage, x: width / 2, y: height / 2)
        #expect(topLeft.r > 230 && topLeft.g > 230 && topLeft.b > 230, "expected a white top-left border corner, got \(topLeft)")
        #expect(center.b > center.r + 40, "expected the photo's own blue to still be visible in the center, got \(center)")

        // Bottom border noticeably thicker than the top: walk inward from
        // each edge along the vertical centerline and count how many
        // consecutive rows stay white before hitting photo content. The
        // bottom run should be meaningfully longer than the top run.
        let x = width / 2
        var topRun = 0
        while topRun < height / 2, try Self.pixel(in: cgImage, x: x, y: topRun).isNearWhite { topRun += 1 }
        var bottomRun = 0
        while bottomRun < height / 2, try Self.pixel(in: cgImage, x: x, y: height - 1 - bottomRun).isNearWhite { bottomRun += 1 }
        #expect(bottomRun > topRun * 2, "expected the bottom border to be noticeably thicker than the top -- top run \(topRun)px, bottom run \(bottomRun)px")
    }

    @Test func polaroidFrameWithOutOfBoundsParamsFailsSafeToUnedited() throws {
        let photo = try Self.makeTestPhoto(width: 100, height: 100, color: .blue)
        let identity = EditVariant(name: "identity", ops: [])
        // borderWidth 0.5 exceeds the < 0.3 sanity bound.
        let broken = EditVariant(name: "broken", ops: [.polaroidFrame(borderWidth: 0.5, bottomBorderMultiplier: 3.0)])
        let identityData = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: identity))
        let brokenData = try #require(EditEngine.renderFullResJPEGData(photo: photo, variant: broken))
        #expect(identityData == brokenData, "an out-of-bounds borderWidth must fail safe to the unedited (but still cropped) image, not crash or produce a degenerate frame")
    }

    // MARK: - dateStamp: discriminating render test

    @Test func dateStampPaintsYellowNearTheRequestedCornerOnly() throws {
        // Dark navy so a yellow stamp is unmistakable against it.
        let photo = try Self.makeTestPhoto(width: 300, height: 300, color: UIColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 1))
        let variant = EditVariant(name: "stamped", ops: [.dateStamp(corner: "bottomTrailing", scale: 0.05)])
        let rendered = EditEngine.render(photo: photo, variant: variant)
        let cgImage = try #require(rendered.cgImage)
        let width = cgImage.width, height = cgImage.height

        // Scan a patch near the bottom-right (bottomTrailing, on-screen
        // bottom edge) corner for any yellow-ish pixel (high R+G, low B).
        var foundYellowNearTarget = false
        for dx in stride(from: 0, to: min(80, width), by: 4) {
            for dy in stride(from: 0, to: min(40, height), by: 4) {
                let p = try Self.pixel(in: cgImage, x: width - 1 - dx, y: height - 1 - dy)
                if p.r > 180, p.g > 140, p.b < 140 {
                    foundYellowNearTarget = true
                }
            }
        }
        #expect(foundYellowNearTarget, "expected a yellow date-stamp glyph near the bottomTrailing corner")

        // Opposite (top-left) corner should have no such pixels -- the
        // stamp shouldn't bleed across the whole image.
        var foundYellowOpposite = false
        for dx in stride(from: 0, to: min(40, width), by: 4) {
            for dy in stride(from: 0, to: min(40, height), by: 4) {
                let p = try Self.pixel(in: cgImage, x: dx, y: dy)
                if p.r > 180, p.g > 140, p.b < 140 {
                    foundYellowOpposite = true
                }
            }
        }
        #expect(!foundYellowOpposite, "the date stamp should only appear near its target corner, not the opposite one")
    }

    @Test func dateStampWithUnknownCornerFailsSafeToUnedited() throws {
        let photo = try Self.makeTestPhoto(width: 100, height: 100, color: UIColor(red: 0.05, green: 0.05, blue: 0.2, alpha: 1))
        let identity = EditVariant(name: "identity", ops: [])
        let badCorner = EditVariant(name: "bad", ops: [.dateStamp(corner: "topTrailing", scale: 0.05)])
        let identityImage = EditEngine.render(photo: photo, variant: identity)
        let badImage = EditEngine.render(photo: photo, variant: badCorner)
        #expect(identityImage.pngData() == badImage.pngData(), "dateStamp only supports bottom corners -- an unsupported corner must fail safe to the unedited image, not crash")
    }

    // MARK: - Fixtures

    private static func makeTestPhoto(width: Int, height: Int, color: UIColor) throws -> Photo {
        let size = CGSize(width: width, height: height)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            color.setFill()
            UIRectFill(CGRect(origin: .zero, size: size))
        }
        guard let data = image.jpegData(compressionQuality: 0.95) else {
            struct TestImageCreationFailed: Error {}
            throw TestImageCreationFailed()
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-digicam-op-test-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: url)
        return Photo(id: UUID(), originalURL: url, downsampledURL: url, thumbnail: image)
    }

    private struct RGBA {
        let r: Int, g: Int, b: Int, a: Int
        var isNearWhite: Bool { r > 235 && g > 235 && b > 235 }
    }

    /// Reads one pixel's RGBA (0...255) from `cgImage` at pixel-buffer
    /// coordinates (x, y), where y=0 is the TOP row (matches CGImage's
    /// stored row order, which is what UIKit/PNG/JPEG all use -- NOT Core
    /// Image's own bottom-up coordinate convention).
    private static func pixel(in cgImage: CGImage, x: Int, y: Int) throws -> RGBA {
        guard let data = cgImage.dataProvider?.data as Data? else {
            struct NoPixelData: Error {}
            throw NoPixelData()
        }
        let bytesPerPixel = cgImage.bitsPerPixel / 8
        let bytesPerRow = cgImage.bytesPerRow
        let offset = y * bytesPerRow + x * bytesPerPixel
        guard offset + bytesPerPixel <= data.count else {
            struct OutOfBounds: Error {}
            throw OutOfBounds()
        }
        let alphaFirst = cgImage.alphaInfo == .premultipliedFirst || cgImage.alphaInfo == .first || cgImage.alphaInfo == .noneSkipFirst
        let bytes = [UInt8](data[offset..<(offset + bytesPerPixel)])
        if bytesPerPixel >= 4 {
            if alphaFirst {
                return RGBA(r: Int(bytes[1]), g: Int(bytes[2]), b: Int(bytes[3]), a: Int(bytes[0]))
            } else {
                return RGBA(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]), a: Int(bytes[3]))
            }
        }
        // 3 bytes/pixel (no alpha channel, e.g. a JPEG-backed CGImage).
        return RGBA(r: Int(bytes[0]), g: Int(bytes[1]), b: Int(bytes[2]), a: 255)
    }
}
