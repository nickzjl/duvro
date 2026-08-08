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
//  Deliberately NOT included yet: lightLeak, polaroidFrame, dateStamp,
//  halation -- those are Digicam/Travel Film ops (Phase 8), out of scope
//  this session. Adding them later is a new `case` here plus a new branch
//  in EditEngine.apply(_:to:) -- no restructuring of this file or the JSON
//  schema required, which is the point of the discriminated-union shape
//  below.
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
}

/// nonisolated on the extension too -- the Codable conformance is declared
/// here, separately from the enum's primary declaration above, and
/// isolation doesn't inherit across that split automatically.
nonisolated extension EditOp: Codable {
    private enum OpType: String, Codable {
        case toneCurve, colorControls, temperatureTint, vignette, bloom, grain, fade
    }

    /// Field names are reused across cases on purpose (e.g. `intensity`
    /// appears in vignette, bloom, and grain) -- each is decoded only
    /// within its own case's branch below, so there's no collision; JSON
    /// stays readable without prefixed key names like `vignetteIntensity`.
    private enum CodingKeys: String, CodingKey {
        case type, points, saturation, brightness, contrast, temperature, tint, intensity, radius, size, amount
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
        }
    }
}
