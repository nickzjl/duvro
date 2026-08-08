//
//  EditEngine.swift
//  duvro
//
//  Phase 4: parses an EditVariant's op list into a CIFilter chain and
//  renders it. One shared, Metal-backed CIContext for the whole app --
//  creating a CIContext per render is the standard CoreImage performance
//  mistake (each one compiles/caches its own shaders); see sharedContext
//  below.
//
//  Renders from the existing <=1280px downsamples (Photo.downsampledURL),
//  not full-res -- full-res rendering only happens at export (Phase 7, not
//  built this session).
//
//  FAIL-SAFE (BUILD_ROADMAP Phase 4): any failure anywhere in the pipeline
//  (source image unreadable, an op fails to produce output, the context
//  fails to render) falls back toward the original photo -- never crashes,
//  never a blank frame. A single failed op is skipped (treated as a no-op)
//  rather than aborting the whole chain, so one bad parameter doesn't blank
//  out an otherwise-fine variant.
//
//  Stateless and repeatable: render(photo:variant:) re-parses nothing
//  persistent (EditOp is already a parsed Swift value by the time it gets
//  here -- VibePackLoader did the JSON parsing once, at load time) and can
//  be called repeatedly. Phase 5 calling this 3x per photo and caching the
//  results is the expected usage.
//

import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

/// nonisolated: render(photo:variant:) is a pure, stateless, CPU-bound call
/// with no reason to be pinned to MainActor -- SWIFT_DEFAULT_ACTOR_ISOLATION
/// = MainActor would otherwise isolate the whole enum by default (same
/// pattern as CompositeScoring/ClusteringService/ShortlistService). Callers
/// off the main actor (e.g. a debug or edit screen rendering in the
/// background so timing/measurement isn't confounded by UI work) need this
/// to actually be callable from there.
nonisolated enum EditEngine {
    /// One Metal-backed CIContext, created once, reused for every render.
    /// CIContext is documented thread-safe for concurrent rendering
    /// (Apple's CoreImage docs), matching the enum's nonisolated-ness.
    private static let sharedContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        // No Metal device (e.g. an unusual host) -- fall back to a
        // software context rather than crashing at first use.
        return CIContext(options: nil)
    }()

    /// Renders `photo`'s downsampled preview through `variant`'s op chain.
    /// Never throws. On any failure, falls back toward the original,
    /// unedited image rather than returning nothing or a blank frame.
    static func render(photo: Photo, variant: EditVariant) -> UIImage {
        guard let sourceCIImage = CIImage(contentsOf: photo.downsampledURL) else {
            // Can't even decode the source from disk -- fall back to the
            // in-memory thumbnail rather than crash or return nothing.
            return photo.thumbnail
        }

        var image = sourceCIImage
        for op in variant.ops {
            image = apply(op, to: image) ?? image // a failed op is a no-op, not a chain abort
        }

        let extent = sourceCIImage.extent
        if let cgImage = sharedContext.createCGImage(image, from: extent) {
            return UIImage(cgImage: cgImage)
        }

        // Full chain failed to render -- try the unedited source before
        // giving up entirely.
        if let originalCGImage = sharedContext.createCGImage(sourceCIImage, from: extent) {
            return UIImage(cgImage: originalCGImage)
        }
        return photo.thumbnail
    }

    // MARK: - Op -> CIFilter

    private static func apply(_ op: EditOp, to image: CIImage) -> CIImage? {
        switch op {
        case .toneCurve(let points):
            return applyToneCurve(points: points, to: image)
        case .colorControls(let saturation, let brightness, let contrast):
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.saturation = Float(saturation)
            filter.brightness = Float(brightness)
            filter.contrast = Float(contrast)
            return filter.outputImage
        case .temperatureTint(let temperature, let tint):
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            // Fixed D65 source white point; the pack only ever specifies
            // the target.
            filter.neutral = CIVector(x: 6500, y: 0)
            filter.targetNeutral = CIVector(x: CGFloat(temperature), y: CGFloat(tint))
            return filter.outputImage
        case .vignette(let intensity, let radius):
            let filter = CIFilter.vignette()
            filter.inputImage = image
            filter.intensity = Float(intensity)
            filter.radius = Float(radius)
            return filter.outputImage
        case .bloom(let radius, let intensity):
            let filter = CIFilter.bloom()
            filter.inputImage = image
            filter.radius = Float(radius)
            filter.intensity = Float(intensity)
            return filter.outputImage
        case .grain(let intensity, let size):
            return applyGrain(intensity: intensity, size: size, to: image)
        case .fade(let amount):
            return applyFade(amount: amount, to: image)
        }
    }

    /// CIToneCurve requires exactly 5 points -- a malformed pack with the
    /// wrong count skips this op (fail-safe) instead of crashing on an
    /// out-of-bounds array access.
    private static func applyToneCurve(points: [CGPoint], to image: CIImage) -> CIImage? {
        guard points.count == 5 else { return nil }
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = points[0]
        filter.point1 = points[1]
        filter.point2 = points[2]
        filter.point3 = points[3]
        filter.point4 = points[4]
        return filter.outputImage
    }

    /// No single built-in CIFilter is "grain" -- this composites
    /// CIRandomGenerator noise over the image. Rough/plausible, matching
    /// this session's scope (Golden Hour's actual look is untuned; see the
    /// Deferred work register): desaturate the noise, push its contrast by
    /// `intensity` so it reads as luminance grain rather than color
    /// confetti, scale it by `size` before cropping back down (crop
    /// resamples, so a larger scale reads as coarser/bigger grain), then
    /// blend over the base image with soft-light so it darkens and
    /// lightens rather than flatly overlaying.
    private static func applyGrain(intensity: Double, size: Double, to image: CIImage) -> CIImage? {
        guard intensity > 0 else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return image }

        guard let noise = CIFilter.randomGenerator().outputImage else { return nil }
        let scaled = noise.transformed(by: CGAffineTransform(scaleX: max(size, 0.1), y: max(size, 0.1)))

        let mono = CIFilter.colorControls()
        mono.inputImage = scaled
        mono.saturation = 0
        mono.contrast = Float(1 + intensity * 3)
        guard let monoOutput = mono.outputImage else { return nil }

        let blend = CIFilter.softLightBlendMode()
        blend.inputImage = monoOutput.cropped(to: extent)
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent)
    }

    /// No single built-in CIFilter is "fade" either -- a classic lifted-
    /// black, pulled-highlight film-fade look is a tone curve, built here
    /// from one `amount` (0...1) instead of 5 explicit points so a pack
    /// author (currently: this file's own golden_hour.json) doesn't have
    /// to hand-derive a spline for a fairly mechanical shape.
    private static func applyFade(amount: Double, to image: CIImage) -> CIImage? {
        guard amount > 0 else { return image }
        let lift = CGFloat(amount) * 0.12
        let filter = CIFilter.toneCurve()
        filter.inputImage = image
        filter.point0 = CGPoint(x: 0, y: lift)
        filter.point1 = CGPoint(x: 0.25, y: 0.25 + lift * 0.5)
        filter.point2 = CGPoint(x: 0.5, y: 0.5)
        filter.point3 = CGPoint(x: 0.75, y: 0.75 - lift * 0.3)
        filter.point4 = CGPoint(x: 1, y: 1 - lift * 0.4)
        return filter.outputImage
    }
}
