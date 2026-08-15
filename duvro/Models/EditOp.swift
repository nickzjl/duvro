//
//  EditOp.swift
//  duvro
//
//  Phase 4: one step in a Vibe Pack variant's filter chain. Ops needed for
//  Golden Hour (BUILD_ROADMAP Phase 4): toneCurve, colorControls,
//  temperatureTint, vignette, bloom, grain, fade -- exactly these seven,
//  applied in the array order EditVariant.ops lists them. EditEngine is
//  where an op turns into an actual CIFilter.
//
//  Phase 8 added three more: lightLeak, polaroidFrame, dateStamp -- Digicam
//  pack ops (Travel Film needs none of these three; it's built entirely
//  from the original seven). Exactly the "new case here plus a new branch
//  in EditEngine.apply(_:to:)" this file predicted -- no restructuring of
//  the JSON schema. `halation` is still NOT included; nothing in Digicam or
//  Travel Film needs it.
//
//  Golden Hour tuning added `vibrance` -- needed because the hand-graded
//  reference specifies Vibrance and Saturation as separate, independently-
//  valued adjustments (they behave differently on skin tones; colorControls'
//  saturation alone can't reproduce vibrance's selective boost). No existing
//  op covers it -- CIVibrance has no colorControls equivalent. Same "new
//  case here plus a new branch in EditEngine.apply(_:to:)" pattern as Phase
//  8's three additions; reuses the `amount` coding key already declared for
//  `fade` rather than adding a redundant one.
//

import CoreGraphics

/// nonisolated: pure data, decoded from JSON and read from EditEngine's
/// nonisolated render path. SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor would
/// otherwise isolate this type (and its custom Codable conformance below)
/// by default -- same fix pattern as CompositeScoring/ClusteringService/
/// ShortlistService/VibePack.
nonisolated enum EditOp: Sendable, Equatable {
    /// Five-point spline tone curve (perceptual/gamma-2 space, matching
    /// CIToneCurve). Exactly 5 points, each 0...1 on both axes for a
    /// typical curve (values outside that range are valid CI input but
    /// push into extrapolation territory).
    case toneCurve(points: [CGPoint])
    /// Matches CIColorControls 1:1.
    case colorControls(saturation: Double, brightness: Double, contrast: Double)
    /// Matches CIVibrance's `amount` 1:1. Distinct from colorControls'
    /// saturation on purpose -- vibrance boosts muted colors more than
    /// already-saturated ones and is gentler on skin tones, which
    /// colorControls' uniform saturation multiplier cannot reproduce
    /// (Golden Hour's tuned values, first pack to need this op, rely on
    /// that distinction -- see BUILD_ROADMAP).
    case vibrance(amount: Double)
    /// Matches CITemperatureAndTint's targetNeutral; EditEngine supplies a
    /// fixed D65 (6500K, tint 0) neutral as the source white point.
    case temperatureTint(temperature: Double, tint: Double)
    /// Matches CIVignette 1:1.
    case vignette(intensity: Double, radius: Double)
    /// Matches CIBloom 1:1.
    case bloom(radius: Double, intensity: Double)
    /// Synthetic film-grain overlay. Not a single built-in CIFilter --
    /// EditEngine composites CIRandomGenerator noise over the image.
    /// `intensity` is overlay strength (0...1-ish); `size` scales the noise
    /// before cropping (>1 = coarser/bigger grain, <1 = finer).
    case grain(intensity: Double, size: Double)
    /// Lifted-black "faded film" look. Not a single built-in CIFilter --
    /// EditEngine builds a tone curve from `amount` (0...1).
    case fade(amount: Double)
    /// Warm red-orange glare wash, radiating from one corner -- a
    /// vintage film-burn/light-leak look, composited via a screen blend so
    /// it can only ever brighten, never darken. `intensity` is the leak's
    /// peak opacity at its origin (0...1-ish); `corner` is where it
    /// radiates from -- one of "topLeading", "topTrailing",
    /// "bottomLeading", "bottomTrailing" (SwiftUI-style, RTL-safe naming).
    /// An unrecognized corner string is a no-op (EditEngine.apply), not a
    /// crash -- see that fail-safe contract in EditEngine's header.
    case lightLeak(intensity: Double, corner: String)
    /// Composites the photo, shrunk down, onto a white Polaroid-style
    /// frame -- NOT a crop or aspect-ratio change to the op chain's own
    /// extent (EditEngine.applyPolaroidFrame preserves `image.extent`
    /// exactly, same invariant every other op in this file maintains, so
    /// the existing render()/renderFullResJPEGData() crop logic keeps
    /// working unmodified); the frame's border geometry is computed
    /// relative to the eventual 4:5 export/preview crop window
    /// (EditEngine.centerCropRect), so it reads correctly post-crop
    /// regardless of the source photo's native aspect ratio.
    /// `borderWidth` is the top/left/right border as a fraction of the
    /// 4:5 window's width (e.g. 0.06 = 6%); `bottomBorderMultiplier` is
    /// how many times thicker the bottom border is than the other three --
    /// a real Polaroid's signature asymmetry. Values outside
    /// EditEngine.applyPolaroidFrame's sanity bounds are a no-op.
    case polaroidFrame(borderWidth: Double, bottomBorderMultiplier: Double)
    /// Yellow Y2K-digicam-style date/time stamp in a bottom corner.
    /// `corner` is "bottomLeading" or "bottomTrailing" (unrecognized ->
    /// no-op); `scale` is the stamp's text height as a fraction of the
    /// image's height. The date text itself is NOT a pack parameter --
    /// there's no EXIF capture-timestamp source in the pipeline yet
    /// (PhotoImportService never reads DateTimeOriginal, Photo has no
    /// timestamp field), so EditEngine.currentDateStampText() stands in
    /// with today's date at render time. That gap is isolated behind that
    /// one function specifically so wiring in a real capture date later is
    /// a one-line swap there, not a change to this case's shape or to
    /// applyDateStamp's call site. Flagged in the Phase 8 session report.
    case dateStamp(corner: String, scale: Double)
}

/// nonisolated on the extension too -- the Codable conformance is declared
/// here, separately from the enum's primary declaration above, and
/// isolation doesn't inherit across that split automatically.
nonisolated extension EditOp: Codable {
    private enum OpType: String, Codable {
        case toneCurve, colorControls, temperatureTint, vignette, bloom, grain, fade
        case lightLeak, polaroidFrame, dateStamp
        case vibrance
    }

    /// Field names are reused across cases on purpose (e.g. `intensity`
    /// appears in vignette, bloom, grain, AND lightLeak) -- each is decoded
    /// only within its own case's branch below, so there's no collision;
    /// JSON stays readable without prefixed key names like
    /// `vignetteIntensity`. `corner` is shared between lightLeak and
    /// dateStamp for the same reason.
    private enum CodingKeys: String, CodingKey {
        case type, points, saturation, brightness, contrast, temperature, tint, intensity, radius, size, amount
        case corner, borderWidth, bottomBorderMultiplier, scale
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(OpType.self, forKey: .type)
        switch type {
        case .toneCurve:
            self = .toneCurve(points: try container.decode([CGPoint].self, forKey: .points))
        case .colorControls:
            self = .colorControls(
                saturation: try container.decode(Double.self, forKey: .saturation),
                brightness: try container.decode(Double.self, forKey: .brightness),
                contrast: try container.decode(Double.self, forKey: .contrast)
            )
        case .temperatureTint:
            self = .temperatureTint(
                temperature: try container.decode(Double.self, forKey: .temperature),
                tint: try container.decode(Double.self, forKey: .tint)
            )
        case .vignette:
            self = .vignette(
                intensity: try container.decode(Double.self, forKey: .intensity),
                radius: try container.decode(Double.self, forKey: .radius)
            )
        case .bloom:
            self = .bloom(
                radius: try container.decode(Double.self, forKey: .radius),
                intensity: try container.decode(Double.self, forKey: .intensity)
            )
        case .grain:
            self = .grain(
                intensity: try container.decode(Double.self, forKey: .intensity),
                size: try container.decode(Double.self, forKey: .size)
            )
        case .fade:
            self = .fade(amount: try container.decode(Double.self, forKey: .amount))
        case .vibrance:
            self = .vibrance(amount: try container.decode(Double.self, forKey: .amount))
        case .lightLeak:
            self = .lightLeak(
                intensity: try container.decode(Double.self, forKey: .intensity),
                corner: try container.decode(String.self, forKey: .corner)
            )
        case .polaroidFrame:
            self = .polaroidFrame(
                borderWidth: try container.decode(Double.self, forKey: .borderWidth),
                bottomBorderMultiplier: try container.decode(Double.self, forKey: .bottomBorderMultiplier)
            )
        case .dateStamp:
            self = .dateStamp(
                corner: try container.decode(String.self, forKey: .corner),
                scale: try container.decode(Double.self, forKey: .scale)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .toneCurve(let points):
            try container.encode(OpType.toneCurve, forKey: .type)
            try container.encode(points, forKey: .points)
        case .colorControls(let saturation, let brightness, let contrast):
            try container.encode(OpType.colorControls, forKey: .type)
            try container.encode(saturation, forKey: .saturation)
            try container.encode(brightness, forKey: .brightness)
            try container.encode(contrast, forKey: .contrast)
        case .temperatureTint(let temperature, let tint):
            try container.encode(OpType.temperatureTint, forKey: .type)
            try container.encode(temperature, forKey: .temperature)
            try container.encode(tint, forKey: .tint)
        case .vignette(let intensity, let radius):
            try container.encode(OpType.vignette, forKey: .type)
            try container.encode(intensity, forKey: .intensity)
            try container.encode(radius, forKey: .radius)
        case .bloom(let radius, let intensity):
            try container.encode(OpType.bloom, forKey: .type)
            try container.encode(radius, forKey: .radius)
            try container.encode(intensity, forKey: .intensity)
        case .grain(let intensity, let size):
            try container.encode(OpType.grain, forKey: .type)
            try container.encode(intensity, forKey: .intensity)
            try container.encode(size, forKey: .size)
        case .fade(let amount):
            try container.encode(OpType.fade, forKey: .type)
            try container.encode(amount, forKey: .amount)
        case .vibrance(let amount):
            try container.encode(OpType.vibrance, forKey: .type)
            try container.encode(amount, forKey: .amount)
        case .lightLeak(let intensity, let corner):
            try container.encode(OpType.lightLeak, forKey: .type)
            try container.encode(intensity, forKey: .intensity)
            try container.encode(corner, forKey: .corner)
        case .polaroidFrame(let borderWidth, let bottomBorderMultiplier):
            try container.encode(OpType.polaroidFrame, forKey: .type)
            try container.encode(borderWidth, forKey: .borderWidth)
            try container.encode(bottomBorderMultiplier, forKey: .bottomBorderMultiplier)
        case .dateStamp(let corner, let scale):
            try container.encode(OpType.dateStamp, forKey: .type)
            try container.encode(corner, forKey: .corner)
            try container.encode(scale, forKey: .scale)
        }
    }
}
