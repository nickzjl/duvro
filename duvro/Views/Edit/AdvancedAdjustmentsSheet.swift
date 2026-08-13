//
//  AdvancedAdjustmentsSheet.swift
//  duvro
//
//  Phase 8, the advanced adjustments sheet (UI_NOTES §5, prd.md P0.8).
//  design/15's mockup is explicitly broken (dims/blurs the photo, and
//  shows the wrong three sliders -- intensity/grain/vignette, not the
//  real four controls) -- used ONLY for this view's general shape (title
//  row, stacked slider rows with label-left/value-right, primary control
//  at bottom). Crop has no mockup reference and isn't built this session
//  (see BUILD_ROADMAP's session report for why); the mockup's X-to-close
//  is also NOT reproduced -- with live rendering and no separate "apply"
//  step, every change is already committed the instant a slider moves, so
//  an X and "done" would be two controls that do the exact same thing.
//  "done" alone, plus drag-to-dismiss (native to the sheet), covers it.
//
//  DELIBERATELY a "dumb" controls view, not the thing that renders the
//  photo: `adjustments` is a live two-way Binding into the PRESENTER's
//  own @State (EditFlowView), which already owns photoStage/renderCache
//  and does its own throttled live re-render on every change -- see
//  EditFlowView's scheduleAdjustmentRender(). This is also what makes
//  UI_NOTES §5's "no dimming, no blur, full clarity the entire time"
//  requirement automatically true: the photo was never inside this
//  sheet's view hierarchy to begin with, so there is nothing here that
//  could occlude it. Presentation modifiers
//  (.presentationDetents/.presentationBackgroundInteraction) are applied
//  at the call site (EditFlowView), not here, matching how
//  PackPreviewSheet.swift's own sheet chrome is owned by its presenter.
//
//  Grain and vignette are deliberately absent -- both are pack-level
//  properties tuned in the Vibe Pack JSON (prd.md §6: exposing them would
//  let a user break the aesthetic that's the product's entire moat), not
//  user-facing dials.
//

import SwiftUI

struct AdvancedAdjustmentsSheet: View {
    @Binding var adjustments: PhotoAdjustments
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("adjust this photo")
                .font(.duvroPackTitle) // 22pt Newsreader, not duvroHeadline's 26pt -- the compact ~35% detent doesn't have room for the larger token, and 22pt still clears the 20pt Newsreader floor (UI_NOTES §1)
                .foregroundStyle(Color(hex: "171614"))

            VStack(spacing: 10) {
                sliderRow(
                    title: "intensity",
                    valueLabel: "\(Int((adjustments.intensity * 100).rounded()))%",
                    value: $adjustments.intensity,
                    range: 0...1
                )
                sliderRow(
                    title: "brightness",
                    valueLabel: signedPercent(adjustments.brightness, center: 0, span: 0.3),
                    value: $adjustments.brightness,
                    range: -0.3...0.3
                )
                sliderRow(
                    title: "contrast",
                    valueLabel: signedPercent(adjustments.contrast, center: 1.0, span: 0.5),
                    value: $adjustments.contrast,
                    range: 0.5...1.5
                )
            }

            Button {
                dismiss()
            } label: {
                Text("done")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44) // was 54 (CLAUDE.md's PRIMARY button height) -- this isn't the screen's primary CTA, it's a compact sheet's only control, and 54 was part of what didn't fit in the ~35% detent
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .background(Color(hex: "FFFCF7").ignoresSafeArea())
    }

    private func sliderRow(title: String, valueLabel: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(.duvroLabel)
                    .foregroundStyle(Color(hex: "171614"))
                Spacer()
                Text(valueLabel)
                    .font(.duvroCaption)
                    .foregroundStyle(Color(hex: "777169"))
            }
            Slider(value: value, in: range)
                .tint(Color(hex: "A04021"))
        }
    }

    /// Brightness/contrast display relative to their own resting point
    /// (0 for brightness, 1.0 for contrast) as a signed percentage of
    /// their slider's own range, e.g. contrast 1.2 with span 0.5 reads
    /// "+40%" -- a friendlier number than the raw CIColorControls unit,
    /// consistent across both sliders since both ranges are symmetric
    /// around their center.
    private func signedPercent(_ value: Double, center: Double, span: Double) -> String {
        let pct = Int((((value - center) / span) * 100).rounded())
        return pct >= 0 ? "+\(pct)%" : "\(pct)%"
    }
}
