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

/// Pure, stateless, thread-safe -- explicitly nonisolated so it can be called
/// from ScoringService's nonisolated per-photo Vision pipeline without an
/// actor hop back to MainActor (the project default per SWIFT_DEFAULT_ACTOR_ISOLATION).
nonisolated enum FaceCropping {
    /// Fraction of the face bounding box's width/height added as margin on
    /// every side before cropping (hair/ears/context, not just the face
    /// interior -- helps the feature print capture more than skin tone).
    static let paddingFraction: CGFloat = 0.4

    /// Square, so feature-printing sees a consistent aspect ratio regardless
    /// of the source face's bounding box shape.
    static let normalizedCropSize = CGSize(width: 256, height: 256)

    /// Returns nil if the padded box is degenerate (near-zero size) --
    /// callers should just skip that face.
    ///
    /// IMPORTANT: the padded box is forced square BEFORE any clamping to the
    /// source image's bounds, and out-of-bounds regions are filled with
    /// black rather than clipped. A face near the edge of frame (distant
    /// shots, off-angle faces -- exactly the low-capture-quality cases)
    /// naturally produces a padded box that extends past the image edge. The
    /// previous version clamped via `intersection`, which silently breaks
    /// the square aspect ratio for those faces, and the later resize to
    /// 256x256 then stretched the result anisotropically -- so the feature
    /// print was partly encoding crop distortion, not the face itself. That
    /// distortion correlated with capture quality (edge-of-frame faces score
    /// low on both), which is exactly the confound the cluster-quality
    /// report flagged.
    static func crop(face boundingBox: Vision.NormalizedRect, from image: CGImage) -> CGImage? {
        let imageSize = CGSize(width: image.width, height: image.height)
        let rect = boundingBox.toImageCoordinates(imageSize, origin: .upperLeft)

        let paddedWidth = rect.width * (1 + 2 * paddingFraction)
        let paddedHeight = rect.height * (1 + 2 * paddingFraction)
        let side = max(paddedWidth, paddedHeight)
        guard side > 1 else { return nil }

        let squareRect = CGRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )

        return render(image, sourceRect: squareRect, to: normalizedCropSize)
    }

    /// Draws `image` into a `size`-sized canvas such that `sourceRect` (which
    /// may extend beyond `image`'s own bounds) exactly fills the canvas.
    /// Because sourceRect and the canvas are both square, the scale factor is
    /// uniform in x and y -- no stretch, regardless of how much of sourceRect
    /// falls outside the source image. Out-of-bounds area renders as black,
    /// not distorted image content.
    private static func render(_ image: CGImage, sourceRect: CGRect, to size: CGSize) -> CGImage? {
        guard let colorSpace = image.colorSpace else { return nil }
        guard let context = CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))

        let scaleX = size.width / sourceRect.width
        let scaleY = size.height / sourceRect.height // == scaleX, sourceRect is square
        let drawRect = CGRect(
            x: -sourceRect.origin.x * scaleX,
            y: -sourceRect.origin.y * scaleY,
            width: CGFloat(image.width) * scaleX,
            height: CGFloat(image.height) * scaleY
        )
        context.draw(image, in: drawRect)
        return context.makeImage()
    }
}
