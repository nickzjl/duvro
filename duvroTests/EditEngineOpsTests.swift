//
//  EditEngineOpsTests.swift
//  duvroTests
//
//  General (not pack-specific) EditEngine op behavior -- as opposed to
//  DigicamOpsTests.swift (Digicam's own three ops) and VibePackTests.swift
//  (Codable + pack-loading). Same discriminating-assertion convention as
//  both: assert something a broken-but-non-crashing implementation could
//  still fail, not just "returned an image."
//

import Testing
import Foundation
import CoreGraphics
import UIKit
@testable import duvro

struct EditEngineOpsTests {

    // MARK: - bloom: must not grow the chain's extent past its input's

    @Test func bloomDoesNotLeakRawGrainNoiseAtTheEdgesInPreview() throws {
        // CIBloom (like other blur-family CIFilters) reports an output
        // extent PADDED beyond its input's own bounds -- it needs to
        // sample past the edges to compute the glow. Uncropped, that
        // padded extent becomes the WHOLE chain's extent from there on,
        // and render() rasterizes at the chain's own FINAL extent (by
        // design, so ops like polaroidFrame that legitimately shrink
        // extent still preview correctly) -- so an uncropped bloom makes
        // the previewed image itself grow. Any op running after bloom
        // (here: grain) then composites into that padding too, but with
        // nothing real underneath to blend against, so it shows up as
        // raw, unblended, GRAYSCALE noise (grain desaturates itself
        // before blending) instead of grain-over-photo. A distinctly
        // colored (orange, high R vs G/B) source makes that unambiguous.
        let photo = try Self.makeTestPhoto(width: 240, height: 300, color: UIColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1))
        let variant = EditVariant(name: "bloom-then-grain", ops: [
            .bloom(radius: 20, intensity: 0.6),
            .grain(intensity: 0.6, size: 1.0)
        ])
        let rendered = EditEngine.render(photo: photo, variant: variant)
        let cgImage = try #require(rendered.cgImage)

        #expect(cgImage.width == 240, "bloom should not grow the chain's extent past the source's own width -- got \(cgImage.width)")
        #expect(cgImage.height == 300, "bloom should not grow the chain's extent past the source's own height -- got \(cgImage.height)")

        let width = cgImage.width, height = cgImage.height
        let edgePoints = [(2, height / 2), (width - 3, height / 2), (width / 2, 2), (width / 2, height - 3)]
        for (x, y) in edgePoints {
            let p = try Self.pixel(in: cgImage, x: x, y: y)
            let isGrayscale = abs(p.r - p.g) < 8 && abs(p.g - p.b) < 8
            #expect(!isGrayscale, "pixel at (\(x),\(y)) reads as grayscale noise (r=\(p.r) g=\(p.g) b=\(p.b)) -- bloom's padded extent is leaking raw, unblended grain into the edge instead of the photo's own orange")
        }
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
            .appendingPathComponent("duvro-editengine-op-test-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        try data.write(to: url)
        return Photo(id: UUID(), originalURL: url, downsampledURL: url, thumbnail: image)
    }

    private struct RGBA {
        let r: Int, g: Int, b: Int, a: Int
    }

    /// Same byte-order handling as DigicamOpsTests.swift's own `pixel` --
    /// CGImage's component order depends on `alphaInfo`, not a fixed RGBA
    /// layout, so this must check it rather than assume.
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
        return RGBA(r: Int(bytes[0]), g: Int(bytes.count > 1 ? bytes[1] : bytes[0]), b: Int(bytes.count > 2 ? bytes[2] : bytes[0]), a: 255)
    }
}
