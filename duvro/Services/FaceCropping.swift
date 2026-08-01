//
//  FaceCropping.swift
//  duvro
//
//  Crops a face out of a downsampled photo for feature-printing. Vision's
//  NormalizedRect is bottom-left-origin (0...1); CGImage pixel cropping is
//  top-left-origin -- that mismatch is exactly BUILD_ROADMAP gotcha #3.
//  We don't hand-roll the flip: NormalizedRect.toImageCoordinates(_:origin:)
//  does it, given the right CoordinateOrigin.
//

import CoreGraphics
import Vision

enum FaceCropping {
    /// Fraction of the face bounding box's width/height added as margin on
    /// every side before cropping (hair/ears/context, not just the face
    /// interior -- helps the feature print capture more than skin tone).
    static let paddingFraction: CGFloat = 0.4

    /// Square, so feature-printing sees a consistent aspect ratio regardless
    /// of the source face's bounding box shape.
    static let normalizedCropSize = CGSize(width: 256, height: 256)

    /// Returns nil if the padded box falls entirely outside the image or the
    /// crop/scale fails -- callers should just skip that face.
    static func crop(face boundingBox: Vision.NormalizedRect, from image: CGImage) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)

        let paddedWidth = rect.width * (1 + 2 * paddingFraction)
        let paddedHeight = rect.height * (1 + 2 * paddingFraction)
        let paddedRect = CGRect(
            x: rect.midX - paddedWidth / 2,
            y: rect.midY - paddedHeight / 2,
            width: paddedWidth,
            height: paddedHeight
        )

        let imageBounds = CGRect(x: 0, y: 0, width: imageSize.width, height: imageSize.height)
        let clampedRect = paddedRect.intersection(imageBounds)
        guard !clampedRect.isNull, clampedRect.width > 1, clampedRect.height > 1 else { return nil }

        guard let cropped = image.cropping(to: clampedRect) else { return nil }
        return normalize(cropped, to: normalizedCropSize)
    }

    private static func normalize(_ image: CGImage, to size: CGSize) -> CGImage? {
        guard let colorSpace = image.colorSpace else { return image }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: size))
        return context.makeImage()
    }
}
