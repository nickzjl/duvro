//
//  EditEngine.swift
//  duvro
//
//  Phase 4: parses an EditVariant's op list into a CIFilter chain and
//  renders it. One shared, Metal-backed CIContext for the PREVIEW path
//  (`render`, below) -- creating a CIContext per render is the standard
//  CoreImage performance mistake (each one compiles/caches its own
//  shaders); see sharedContext below. The EXPORT path (`renderFullResJPEGData`)
//  deliberately does NOT use it -- see that function's doc comment for why
//  a fresh, disposed-per-render context is the correct trade there instead.
//
//  Renders from the existing <=1280px downsamples (Photo.downsampledURL),
//  not full-res -- full-res rendering only happens at export (Phase 7).
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
    /// One Metal-backed CIContext, created once, reused for every PREVIEW
    /// render. CIContext is documented thread-safe for concurrent
    /// rendering (Apple's CoreImage docs), matching the enum's
    /// nonisolated-ness.
    private static let sharedContext: CIContext = makeContext()

    /// Try Metal, fall back to software -- shared by sharedContext's
    /// lazy init above (one, for the app's lifetime) and
    /// renderFullResJPEGData below (one per full-res render, disposed
    /// after). Factored out so both paths get the identical fallback
    /// behavior from one place rather than two copies that could drift.
    private static func makeContext() -> CIContext {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        // No Metal device (e.g. an unusual host) -- fall back to a
        // software context rather than crashing at first use.
        return CIContext(options: nil)
    }

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

        // Rasterize at the CHAIN'S OWN final extent, not the source's --
        // most ops preserve the source extent, but polaroidFrame
        // deliberately doesn't (its output extent is the 4:5 `window`, not
        // the source's native-aspect bounds; see its doc comment). Reading
        // an op's smaller extent through the SOURCE's larger rect would
        // sample undefined space outside the image's actual content.
        // sourceCIImage.extent remains the fallback for the rare op that
        // returns something empty/infinite (defensive, not expected).
        let renderExtent = (image.extent.isEmpty || image.extent.isInfinite) ? sourceCIImage.extent : image.extent
        if let cgImage = sharedContext.createCGImage(image, from: renderExtent) {
            return UIImage(cgImage: cgImage)
        }

        // Full chain failed to render -- try the unedited source before
        // giving up entirely.
        if let originalCGImage = sharedContext.createCGImage(sourceCIImage, from: sourceCIImage.extent) {
            return UIImage(cgImage: originalCGImage)
        }
        return photo.thumbnail
    }

    /// Export renders at up to this many pixels on the long edge, not the
    /// source's native sensor resolution. This is a DEVIATION from what
    /// BUILD_ROADMAP/prd.md originally said ("full-resolution rendering,"
    /// "at full quality") -- see BUILD_ROADMAP's Deferred work register
    /// and Known gotchas for the full record of why, and the doc updates
    /// that went with this change. Short version: on-device measurement
    /// showed 531MB peak against the 400MB ceiling with 24MP sources
    /// rendered at native resolution -- current iPhones shoot up to 48MP,
    /// so uncapped rendering doesn't just barely violate the ceiling, it
    /// scales with whatever resolution phones ship next. 2048px is
    /// roughly 1.9x Instagram's own carousel serving resolution
    /// (~1080x1350) -- everything past that is invisible to anyone
    /// viewing the post on the platform this app exists to serve, and
    /// 2048px is still a genuinely sharp image for anything else the
    /// saved camera-roll copy gets used for.
    static let maxExportPixelSize: CGFloat = 2048

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

    /// Full-res (capped, see maxExportPixelSize) JPEG render for export --
    /// ExportService's per-photo unit of work. Loads from
    /// `photo.originalURL` (the full-resolution PHPicker copy), NOT
    /// `downsampledURL` (the <=1280px preview source `render` above uses)
    /// -- but not the RAW original either: first downsamples to
    /// `maxPixelSize` via PhotoImportService.downsample (the exact same
    /// Image I/O thumbnail path import already uses for the ≤1280px
    /// preview -- proven, EXIF-aware, no new image-processing logic) into
    /// a temp file, then reads THAT. Encodes straight from CIImage to
    /// JPEG Data via a FRESH CIContext (EditEngine.makeContext()) --
    /// deliberately NOT sharedContext, and disposed (falls out of scope,
    /// ARC releases it) when this function returns.
    ///
    /// Why: after the resolution cap above, memory measured on device
    /// was still climbing across the 7-photo loop and never coming back
    /// down -- +97 to +123MB per 24MP photo, permanently. Traced to
    /// sharedContext itself: CIContext.clearCaches(), called after every
    /// render, measured EXACTLY +0.0MB every single time on the
    /// expensive photos -- proof the retained memory isn't in what that
    /// method targets (its documented "caches," e.g. compiled shader
    /// programs). Most likely explanation: Metal-backed intermediate
    /// textures tied to the context's own lifetime, not its cache --
    /// Golden Hour's grain op specifically (applyGrain, a
    /// softLightBlendMode composite of two full-size inputs) is harder
    /// for CoreImage to fuse into fewer passes than the rest of the
    /// chain, which is consistent with retention scaling with op-chain
    /// complexity rather than just image size. A context that goes out
    /// of scope releases everything tied to it unconditionally --
    /// doesn't depend on identifying exactly what CoreImage was holding
    /// or why, the way clearCaches() apparently needed to and couldn't.
    /// Slower than the shared context (each one recompiles its shaders
    /// from scratch -- the "standard CoreImage performance mistake" this
    /// file's header warns about) -- an acceptable trade specifically
    /// because export isn't latency-sensitive the way interactive
    /// preview is (a progress bar is already showing), and because the
    /// cost is now FLAT per photo, not accumulating across the loop the
    /// way the retained memory was. sharedContext stays exactly as-is
    /// for `render` above -- EditFlowView's 3-variant comparison,
    /// verified 8-17ms/render, where reuse is what makes that speed
    /// possible and there's no 7-photo loop for anything to accumulate
    /// across.
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
    /// the downsample step failing, full chain fails to render even after
    /// EditEngine's own per-op fail-safe, or JPEG encoding fails) so
    /// ExportService can surface a clear per-photo failure instead of
    /// silently exporting a placeholder or crashing mid-export.
    static func renderFullResJPEGData(photo: Photo, variant: EditVariant, compressionQuality: CGFloat = 0.9, maxPixelSize: CGFloat = maxExportPixelSize) -> Data? {
        // Fresh, disposed-per-render context -- see the doc comment
        // above for why this replaced sharedContext here specifically.
        let context = makeContext()

        // Downsample BEFORE ever touching CoreImage -- a 24MP+ original
        // decoded and run through a multi-step CIFilter chain at native
        // resolution measured 531MB peak against a 400MB ceiling on
        // device (97-123MB retained per 24MP photo, never released --
        // see maxExportPixelSize's doc comment and BUILD_ROADMAP's Known
        // gotchas). Capping here, via Image I/O's thumbnail generator
        // (which can use JPEG's own DCT scaling to avoid ever fully
        // decoding the original at native resolution), means CoreImage
        // never sees more pixels than maxPixelSize allows in the first
        // place -- cheaper than decoding full-res and scaling down after.
        // Written to a temp file (Image I/O's thumbnail API is
        // file/CGImage-based, not a CIImage producer) and removed once
        // this function returns.
        let cappedURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("duvro-export-capped-\(UUID().uuidString)")
            .appendingPathExtension("jpg")
        defer { try? FileManager.default.removeItem(at: cappedURL) }
        do {
            try PhotoImportService.downsample(imageAt: photo.originalURL, maxPixelSize: maxPixelSize, to: cappedURL)
        } catch {
            return nil
        }

        // .applyOrientationProperty: true -- WITHOUT this, CIImage(contentsOf:)
        // reads the raw, as-stored pixel buffer and silently ignores the
        // image's EXIF orientation tag. iPhone photos taken in portrait
        // are frequently stored with a landscape pixel buffer plus an
        // orientation flag saying how to display it upright; SwiftUI
        // (and Image I/O's OWN thumbnail generator -- including the
        // downsample call directly above, via
        // kCGImageSourceCreateThumbnailWithTransform, which is why
        // cappedURL is already correctly oriented on disk) honor that
        // flag automatically, but plain CIImage(contentsOf:) does not.
        // Kept here even though cappedURL's orientation is already baked
        // in (downsample's transform option normalizes the tag to
        // "normal" once applied) -- harmless if redundant, and this
        // function's own test (fullResRenderAppliesEXIFOrientationBeforeCropping)
        // verifies the actual behavior either way rather than assuming it.
        let orientationOptions: [CIImageOption: Any] = [.applyOrientationProperty: true]
        guard let sourceCIImage = CIImage(contentsOf: cappedURL, options: orientationOptions) else { return nil }

        var image = sourceCIImage
        for op in variant.ops {
            image = apply(op, to: image) ?? image // same per-op fail-safe as the preview path
        }

        let cropRect = centerCropRect(for: sourceCIImage.extent, aspectRatio: 4.0 / 5.0)
        let cropped = image.cropped(to: cropRect)

        let colorSpace = cropped.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        if let data = try? context.jpegRepresentation(
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
        return try? context.jpegRepresentation(
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
        case .lightLeak(let intensity, let corner):
            return applyLightLeak(intensity: intensity, corner: corner, to: image)
        case .polaroidFrame(let borderWidth, let bottomBorderMultiplier):
            return applyPolaroidFrame(borderWidth: borderWidth, bottomBorderMultiplier: bottomBorderMultiplier, to: image)
        case .dateStamp(let corner, let scale):
            return applyDateStamp(corner: corner, scale: scale, to: image)
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

    // MARK: - Phase 8: Digicam ops

    /// Maps a "topLeading"/"topTrailing"/"bottomLeading"/"bottomTrailing"
    /// corner string to a CI-space point (origin bottom-left, Y up) within
    /// `extent` -- shared by lightLeak and dateStamp so both ops describe
    /// corners the same way in JSON. An unrecognized string returns nil,
    /// which each caller treats as "op is a no-op" (fail-safe: a malformed
    /// pack renders the unedited image, never crashes).
    private static func cornerPoint(_ corner: String, in extent: CGRect) -> CGPoint? {
        switch corner {
        case "topLeading": return CGPoint(x: extent.minX, y: extent.maxY)
        case "topTrailing": return CGPoint(x: extent.maxX, y: extent.maxY)
        case "bottomLeading": return CGPoint(x: extent.minX, y: extent.minY)
        case "bottomTrailing": return CGPoint(x: extent.maxX, y: extent.minY)
        default: return nil
        }
    }

    /// Warm red-orange glare radiating from one corner -- a radial
    /// gradient, screen-blended so it can only brighten (never darken,
    /// unlike vignette). `intensity` is the gradient's peak alpha at its
    /// origin; radius is a fixed proportion of the image's longest edge
    /// (Digicam's own JSON is the only tuning knob this session -- see
    /// BUILD_ROADMAP's Deferred work register, "Digicam/Travel Film pack
    /// tuning," matching Golden Hour's own untuned status).
    private static func applyLightLeak(intensity: Double, corner: String, to image: CIImage) -> CIImage? {
        guard intensity > 0 else { return image }
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        guard let origin = cornerPoint(corner, in: extent) else { return image } // unknown corner -- no-op, not a crash

        let gradient = CIFilter.radialGradient()
        gradient.center = origin
        gradient.radius0 = 0
        gradient.radius1 = Float(max(extent.width, extent.height)) * 0.85
        let peakAlpha = CGFloat(min(max(intensity, 0), 1))
        gradient.color0 = CIColor(red: 1.0, green: 0.45, blue: 0.15, alpha: peakAlpha)
        gradient.color1 = CIColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 0)
        guard let gradientImage = gradient.outputImage?.cropped(to: extent) else { return nil }

        let blend = CIFilter.screenBlendMode()
        blend.inputImage = gradientImage
        blend.backgroundImage = image
        return blend.outputImage?.cropped(to: extent)
    }

    /// Composites the photo, shrunk to fit, onto a white Polaroid-style
    /// frame with an asymmetric (thicker) bottom border. Border/interior
    /// geometry is computed against `centerCropRect(for: extent, aspectRatio:
    /// 4/5)` -- the SAME window renderFullResJPEGData crops to after the op
    /// chain runs -- so the frame reads correctly (centered, right
    /// proportions) regardless of the source photo's native aspect ratio.
    ///
    /// UNLIKE every other op in this file, the returned image's extent is
    /// `window` (the 4:5 rect), NOT the same extent as `image`. This was a
    /// deliberate change from an earlier version that preserved the full
    /// native extent and painted white outside `window` too, counting on
    /// render()'s/renderFullResJPEGData()'s downstream 4:5 crop to trim it
    /// away. That worked for the EXPORT path (renderFullResJPEGData does
    /// perform that crop) but not the PREVIEW path: render() never crops at
    /// the pixel level -- it counts on SwiftUI's
    /// `Image(...).aspectRatio(4/5, contentMode: .fill).clipShape(...)` to
    /// visually hide whatever falls outside a centered 4:5 window, and on
    /// device that did NOT coincide with `window`'s own math, leaving the
    /// outside-window white margin visible as a large, wrong, equal border
    /// on every side (the bug this fix addresses). Every other op in this
    /// file is a uniform pixel filter, so a crop mismatch there just shifts
    /// which pixels show, invisibly -- polaroidFrame is the first op to
    /// paint a hard white/photo boundary, which is what made the mismatch
    /// visible at all. Cropping to `window` HERE removes the ambiguity at
    /// the source: the returned image already IS the intended 4:5 photo,
    /// so renderFullResJPEGData's downstream crop is a same-rect no-op, and
    /// SwiftUI's fill-crop of an already-4:5 image can't mis-crop it either
    /// (scale 1, nothing left to trim).
    private static func applyPolaroidFrame(borderWidth: Double, bottomBorderMultiplier: Double, to image: CIImage) -> CIImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        // Sanity bounds -- a border wide enough to eat the whole frame, or
        // a non-positive/absurd bottom multiplier, would produce a
        // degenerate or ill-defined interior. Treat as malformed: no-op,
        // not a crash or a blank frame.
        guard borderWidth > 0, borderWidth < 0.3, bottomBorderMultiplier >= 1, bottomBorderMultiplier < 6 else { return image }

        let window = centerCropRect(for: extent, aspectRatio: 4.0 / 5.0)
        let side = window.width * CGFloat(borderWidth)
        let top = side
        let bottom = side * CGFloat(bottomBorderMultiplier)
        let interior = CGRect(
            x: window.minX + side,
            y: window.minY + bottom, // CI space: Y up, so the thicker border sits near the window's minY (bottom of frame)
            width: window.width - side * 2,
            height: window.height - top - bottom
        )
        guard interior.width > 0, interior.height > 0 else { return image }

        // Fill the interior, don't fit inside it. `min` (aspect-FIT) was
        // the actual bug: for a source photo whose native aspect ratio
        // doesn't match the interior's, fit leaves extra letterboxing
        // INSIDE the interior on top of the intentional border -- e.g. a
        // landscape source centered in a portrait interior picks up equal
        // top+bottom padding roughly TWICE the size of the coded top/
        // bottom borders, which reads as one big uniform white margin on
        // every side (the reported bug) and washes out
        // bottomBorderMultiplier's thicker-bottom effect entirely. `max`
        // (aspect-FILL) scales the photo to cover the interior edge to
        // edge -- excess on one axis gets cropped below, never padded --
        // which is what makes a real Polaroid's photo fill most of the
        // frame with only the coded border showing.
        let scale = max(interior.width / extent.width, interior.height / extent.height)
        let scaledWidth = extent.width * scale
        let scaledHeight = extent.height * scale
        let dx = interior.minX + (interior.width - scaledWidth) / 2 - extent.minX * scale
        let dy = interior.minY + (interior.height - scaledHeight) / 2 - extent.minY * scale
        let scaledPhoto = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))
            .cropped(to: interior) // fill overflows one axis -- crop back to the interior so it never spills onto the border

        let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1)).cropped(to: window)
        return scaledPhoto.composited(over: white).cropped(to: window)
    }

    /// System monospace stands in for a bundled Y2K-digicam-style font --
    /// none is bundled yet (Task 1 gap, flagged in the Phase 8 session
    /// report; do NOT bundle a new font to close this without asking).
    /// Isolated so swapping in a real font later is a one-line change
    /// here, not a change to applyDateStamp's call site.
    private static func dateStampFont(pointSize: CGFloat) -> UIFont {
        UIFont.monospacedSystemFont(ofSize: pointSize, weight: .semibold)
    }

    /// No EXIF capture timestamp exists in the pipeline yet -- Task 1 gap,
    /// flagged in the Phase 8 session report. PhotoImportService never
    /// reads kCGImagePropertyExifDateTimeOriginal (or a PHAsset
    /// creationDate) and Photo has no timestamp field, so there is no real
    /// capture date to stamp. Today's date stands in as a placeholder,
    /// isolated behind this one function specifically so wiring in a real
    /// capture timestamp later is a one-line swap here, not a change to
    /// applyDateStamp or to EditOp's shape.
    private static func currentDateStampText(referenceDate: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM'/'dd'/'yy"
        return formatter.string(from: referenceDate)
    }

    /// Yellow Y2K-digicam-style date stamp in a bottom corner. No single
    /// CIFilter draws text -- rasterizes via UIGraphicsImageRenderer (a
    /// small transparent-background bitmap, converted to CIImage), then
    /// composites it over the base image at the requested corner.
    private static func applyDateStamp(corner: String, scale: Double, to image: CIImage) -> CIImage? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite, extent.width > 0, extent.height > 0 else { return image }
        guard scale > 0, scale < 0.2 else { return image } // sanity bound -- not a crash-avoidance need, just an absurd-value guard

        let text = currentDateStampText()
        let fontSize = extent.height * CGFloat(scale)
        guard fontSize > 0 else { return image }
        let font = dateStampFont(pointSize: fontSize)
        // Y2K digicam yellow -- warm and slightly desaturated, closer to a
        // real LCD/stamp overlay than a flat #FFFF00.
        let stampColor = UIColor(red: 1.0, green: 0.86, blue: 0.15, alpha: 1.0)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: stampColor]
        let textSize = (text as NSString).size(withAttributes: attributes)
        guard textSize.width > 0, textSize.height > 0 else { return image }

        let padding = fontSize * 0.3
        let canvasSize = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        let renderer = UIGraphicsImageRenderer(size: canvasSize)
        let stampUIImage = renderer.image { _ in
            // Faint black backing offset by 1pt so the yellow glyph still
            // reads against bright backgrounds (a bare yellow stamp
            // disappears on a light sky) -- matches real digicam overlays.
            let shadowAttributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.black.withAlphaComponent(0.35)]
            (text as NSString).draw(at: CGPoint(x: padding + 1, y: padding + 1), withAttributes: shadowAttributes)
            (text as NSString).draw(at: CGPoint(x: padding, y: padding), withAttributes: attributes)
        }
        guard let stampCGImage = stampUIImage.cgImage else { return image }
        let stampCIImage = CIImage(cgImage: stampCGImage)

        let margin = fontSize * 0.8
        let x: CGFloat
        switch corner {
        case "bottomLeading":
            x = extent.minX + margin
        case "bottomTrailing":
            x = extent.maxX - margin - canvasSize.width
        default:
            return image // unknown corner -- no-op, not a crash
        }
        let y = extent.minY + margin

        let positioned = stampCIImage.transformed(by: CGAffineTransform(translationX: x, y: y))
        return positioned.composited(over: image).cropped(to: extent)
    }
}
