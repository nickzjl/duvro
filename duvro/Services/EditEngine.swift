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

    /// Releases CIContext's OWN internal caches -- compiled kernel
    /// programs and, more importantly here, intermediate/cached render
    /// results. NOT touched by autoreleasepool: autoreleasepool only
    /// scopes Objective-C AUTORELEASED objects allocated in the current
    /// pool; it has no effect on state a persistent object (this shared,
    /// app-wide CIContext) deliberately holds onto internally across
    /// calls. That persistence is normally a FEATURE -- it's why a shared
    /// context exists at all (the file header's "creating a CIContext per
    /// render is the standard CoreImage performance mistake") -- for the
    /// interactive preview path (`render`, used by EditFlowView's 3-variant
    /// comparison, measured 8-17ms/render) it's exactly what makes repeat
    /// renders fast. For full-res export it's the opposite problem: the
    /// SAME shared context that's already accumulated cache from every
    /// preview render this whole session (import grid, edit screen,
    /// final review, the handoff photo strip) goes on to render 7 more
    /// 12MP images through itself with nothing ever releasing what it's
    /// holding -- on device this measured 733MB peak against a 400MB
    /// ceiling, 1.8x over. Export isn't latency-sensitive the way
    /// interactive preview is (a progress bar is already showing;
    /// clearing caches costs render time on the NEXT photo but not
    /// correctness), so the trade toward memory safety is a clear one
    /// here specifically. Call after each full-res render
    /// (ExportService.renderAll) -- never from the preview path, where
    /// it would undo the whole reason a shared context exists.
    static func clearRenderCaches() {
        sharedContext.clearCaches()
    }

    // MARK: - Full-res export (Phase 7)

    /// duvro's ONE, canonical 4:5 crop -- a centered fill-crop of `extent`
    /// to `aspectRatio` (width/height), matching what
    /// `Image(...).resizable().aspectRatio(4/5, contentMode: .fill).clipped()`
    /// shows on screen everywhere else in the app (EditFlowView's photo
    /// stage, FinalReviewView's carousel/thumbnails). SwiftUI's fill+clip
    /// doesn't touch pixel data -- it renders the op chain at the photo's
    /// NATIVE aspect ratio, then visually hides whatever falls outside a
    /// centered 4:5 window. renderFullResJPEGData below reproduces that
    /// exact behavior at the pixel level (crop AFTER the op chain, not
    /// before -- see its comment) specifically so export matches preview
    /// pixel-for-pixel, not just approximately (Phase 6 acceptance:
    /// "preview matches final export 1:1"). If anything else in this app
    /// ever needs a literal pixel crop instead of a view-level visual one,
    /// it should call this same function rather than re-deriving the math.
    static func centerCropRect(for extent: CGRect, aspectRatio: CGFloat) -> CGRect {
        guard extent.width > 0, extent.height > 0, aspectRatio > 0 else { return extent }
        let sourceAspect = extent.width / extent.height
        var cropWidth = extent.width
        var cropHeight = extent.height
        if sourceAspect > aspectRatio {
            // Source is relatively WIDER than 4:5 -- crop the sides, keep full height.
            cropWidth = extent.height * aspectRatio
        } else {
            // Source is relatively TALLER than 4:5 -- crop top/bottom, keep full width.
            cropHeight = extent.width / aspectRatio
        }
        let x = extent.origin.x + (extent.width - cropWidth) / 2
        let y = extent.origin.y + (extent.height - cropHeight) / 2
        return CGRect(x: x, y: y, width: cropWidth, height: cropHeight)
    }

    /// Full-res JPEG render for export -- ExportService's per-photo unit of
    /// work. Loads from `photo.originalURL` (the full-resolution PHPicker
    /// copy), NOT `downsampledURL` (the <=1280px preview source `render`
    /// above uses). Encodes straight from CIImage to JPEG Data via the
    /// shared CIContext, skipping an intermediate CGImage/UIImage
    /// materialization -- one less full-res buffer alive at a time, which
    /// matters here specifically (a 12MP original is ~48MB decoded; this
    /// function's caller is expected to run this inside an
    /// autoreleasepool, one photo at a time -- see ExportService).
    ///
    /// Crops AFTER the op chain runs, not before: vignette/bloom/grain
    /// ops compute relative to whatever extent they're handed, and the
    /// in-app PREVIEW (`render` above) always hands them the photo's full,
    /// UNCROPPED native extent -- the crop only happens visually, after
    /// the fact, at the SwiftUI view layer. Cropping the source first
    /// would make a full-res vignette/grain look different from the
    /// preview's (wrong center, wrong apparent radius). Running the op
    /// chain on the full extent and cropping the RESULT reproduces the
    /// preview's actual pixels, per centerCropRect's doc comment.
    ///
    /// Never throws -- returns nil on any failure (unreadable original,
    /// full chain fails to render even after EditEngine's own per-op
    /// fail-safe, or JPEG encoding fails) so ExportService can surface a
    /// clear per-photo failure instead of silently exporting a placeholder
    /// or crashing mid-export.
    static func renderFullResJPEGData(photo: Photo, variant: EditVariant, compressionQuality: CGFloat = 0.9) -> Data? {
        guard let sourceCIImage = CIImage(contentsOf: photo.originalURL) else { return nil }

        var image = sourceCIImage
        for op in variant.ops {
            image = apply(op, to: image) ?? image // same per-op fail-safe as the preview path
        }

        let cropRect = centerCropRect(for: sourceCIImage.extent, aspectRatio: 4.0 / 5.0)
        let cropped = image.cropped(to: cropRect)

        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let data = try? sharedContext.jpegRepresentation(
            of: cropped,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compressionQuality]
        ) {
            return data
        }

        // Full chain (or the crop itself) failed to encode -- try the
        // unedited, cropped source before giving up, matching `render`'s
        // own fallback-toward-original spirit.
        let croppedSource = sourceCIImage.cropped(to: cropRect)
        return try? sharedContext.jpegRepresentation(
            of: croppedSource,
            colorSpace: colorSpace,
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: compressionQuality]
        )
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
