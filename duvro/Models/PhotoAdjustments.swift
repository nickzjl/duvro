//
//  PhotoAdjustments.swift
//  duvro
//
//  Phase 8, advanced adjustments sheet (UI_NOTES §5, prd.md P0.8). A
//  user's per-photo tweaks on top of the Vibe Pack variant's own look --
//  distinct from EditVariant/EditOp (the pack's own, non-user-editable
//  style), applied as a SEPARATE pass after the variant's op chain runs,
//  in both EditEngine.render (preview) and renderFullResJPEGData (export),
//  so the two stay pixel-parity per Phase 6's preview-matches-export
//  acceptance. Crop is deliberately absent -- see the advanced sheet's own
//  session report for why it isn't threaded through this session.
//
nonisolated struct PhotoAdjustments: Equatable, Sendable {
    /// Blends the variant's fully-styled output back toward the original,
    /// unedited photo. 1.0 (default) is the variant at full strength, 0.0
    /// is the original, untouched. Lets a user back off a look they find
    /// too strong without losing the pack's aesthetic entirely.
    var intensity: Double = 1.0
    /// Additional brightness on top of the variant's own grade -- same
    /// units/range as CIColorControls' own brightness (roughly -1...1).
    var brightness: Double = 0.0
    /// Additional contrast multiplier on top of the variant's own grade --
    /// same units as CIColorControls' own contrast (1.0 = unchanged).
    var contrast: Double = 1.0

    var isDefault: Bool { self == PhotoAdjustments() }
}
