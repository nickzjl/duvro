//
//  FontComparisonView.swift
//  duvro
//
//  TEMPORARY, DEBUG-only. Side-by-side comparison of the two Newsreader
//  optical-size cuts under consideration for display headlines (item 14,
//  Aug 1 2026 session): opsz=16 (currently wired into Font+Duvro.swift)
//  vs. opsz=36 (candidate, since Newsreader is only ever used for display
//  headlines/pack names in this app, never body text).
//
//  Not wired into Font+Duvro.swift -- references the raw PostScript names
//  directly so both cuts can render side by side regardless of which one
//  the shared type scale currently points at. Delete this file and revert
//  duvroApp.swift once a cut is picked.
//

import SwiftUI

struct FontComparisonView: View {
    private let headline = "our favorites"
    private let size: CGFloat = 34

    var body: some View {
        ZStack {
            Color(hex: "F7F4EE").ignoresSafeArea()

            VStack(spacing: 48) {
                cut(
                    label: "opsz=16 -- current (Font+Duvro.swift)",
                    postScriptName: "NewsreaderRoman-SemiBold"
                )
                cut(
                    label: "opsz=36 -- candidate",
                    postScriptName: "Newsreader36pt-SemiBold"
                )
            }
            .padding(.horizontal, 20)
        }
    }

    private func cut(label: String, postScriptName: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(label)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color(hex: "777169"))
            Text(headline)
                .font(.custom(postScriptName, size: size))
                .foregroundStyle(Color(hex: "171614"))
            Text(postScriptName)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color(hex: "A7A097"))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

#Preview {
    FontComparisonView()
}
