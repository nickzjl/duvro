//
//  CaptionView.swift
//  duvro
//
//  Phase 9's UI half (BUILD_ROADMAP Phase 9, prd.md §4 step 9, UI_NOTES §3
//  + §6's caption bullet). Lands between Final Review and Handoff --
//  FinalReviewView's "add a caption" used to jump straight to Handoff
//  (Phase 6/7/8 scope, marked "SCOPE, per instruction" at every call
//  site); this session inserts the real screen at every "PHASE 9
//  INSERTION POINT" comment left for it, across duvroApp.swift and
//  ImportView.swift.
//
//  ONE suggestion, pre-filled and editable, plus regenerate -- NOT three
//  cards (UI_NOTES §3: "the user has already made many choices during
//  editing; this reduces decision load at the end").
//
//  Corrections vs design/13_caption.png (UI_NOTES §6, docs win over mockup):
//  - "copy and finish" is a text link in the mockup -- promoted to the
//    standard black pill (UI_NOTES §1).
//  - Removed the mockup's large dead zone + two ghost placeholder cards
//    at the bottom entirely; nothing stands in for them.
//  - Mockup's header is left-aligned; UI_NOTES §6 flags this as
//    differing from the other MOCKUPS' centered convention -- centered
//    here to match. Ambiguous/flagged consequence: this makes Caption's
//    own header inconsistent with ImportView/EditFlowView/
//    VibeSelectionView, which this session built left-aligned (matching
//    a different, established convention across THOSE screens). Not
//    reconciled here -- a cross-screen alignment pass is a separate,
//    unrequested task; see the session report.
//  - "your AI-curated caption" framing is out entirely (UI_NOTES fix 6:
//    never surface "AI" anywhere in the UI) -- no such label exists on
//    this screen.
//
//  CaptionService is a real, injected dependency (default
//  TemplateCaptionService()), not hardcoded inline -- the network
//  implementation drops in behind CaptionServiceProtocol later without
//  touching this file.
//

import SwiftUI

struct CaptionView: View {
    var sessionStore: SessionStore
    let pack: VibePack
    var captionService: CaptionServiceProtocol = TemplateCaptionService()
    /// Returns to Final Review. Deliberately NOT @Environment(\.dismiss):
    /// this screen is content-swapped inside an already-presented
    /// fullScreenCover, same pattern as every other real/debug flow
    /// screen this session (see ImportView's realFlowDestination()) --
    /// dismiss() there would exit the WHOLE cover, not step back one
    /// screen.
    var onBack: () -> Void
    /// "copy and finish" -- passes the user's final (possibly hand-
    /// edited) caption text forward. Handoff copies THIS to the
    /// clipboard now, replacing its old hardcoded placeholder string.
    var onContinue: (String) -> Void

    @State private var captionText = ""
    @State private var usedCaptions: Set<String> = []
    @State private var isLoading = true
    /// Phase 10: honest "no network" state -- see NetworkMonitor's own
    /// header for why this never blocks anything here (TemplateCaptionService
    /// already works offline; this only surfaces the real signal rather
    /// than staying silent about it).
    @State private var networkMonitor = NetworkMonitor()

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                VStack(spacing: 24) {
                    headline
                    if !networkMonitor.isConnected {
                        offlineNote
                    }
                    captionField
                    regenerateButton
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        // UI_NOTES fix 5: sticky bottom CTA needs a bottom content inset
        // equal to its own height + safe area -- safeAreaInset (not a
        // fixed padding guess) gives that structurally, same pattern as
        // every other sticky-CTA screen this session.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            continueButton
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .task {
            guard captionText.isEmpty else { return } // don't regenerate on every re-appear, only the first time
            await regenerate()
        }
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(hex: "171614"))
                    .frame(width: 44, height: 44)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
    }

    // MARK: - Headline (centered -- UI_NOTES §6, see file header)

    private var headline: some View {
        VStack(spacing: 6) {
            Text("add a caption")
                .font(.duvroHeadline)
                .foregroundStyle(Color(hex: "171614"))
            Text("edit it, or shuffle for another.")
                .font(.duvroBody)
                .italic()
                .foregroundStyle(Color(hex: "777169"))
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Offline note (Phase 10: honest, not blocking -- see NetworkMonitor)

    private var offlineNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 11, weight: .semibold))
            Text("no connection — here's a caption to get you started.")
                .font(.duvroCaption)
        }
        .foregroundStyle(Color(hex: "777169"))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(hex: "EEE9DF")) // Secondary surface, §1 -- understated, not an error color
        .clipShape(Capsule())
    }

    // MARK: - The one editable suggestion (UI_NOTES §3: one, not three)

    private var captionField: some View {
        TextEditor(text: $captionText)
            .font(.duvroBody)
            .foregroundStyle(Color(hex: "171614"))
            .scrollContentBackground(.hidden) // let the custom card background show through
            .padding(14)
            .frame(minHeight: 120)
            .background(Color(hex: "FFFCF7"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "DDD6CA"), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 4)
    }

    private var regenerateButton: some View {
        Button {
            Task { await regenerate() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 13, weight: .semibold))
                Text(isLoading ? "shuffling…" : "regenerate")
                    .font(.duvroLabel)
            }
            .foregroundStyle(Color(hex: "A04021"))
        }
        .disabled(isLoading)
    }

    // MARK: - Primary CTA (UI_NOTES §6: promoted from a text link to the standard black pill)

    private var continueButton: some View {
        Button {
            onContinue(captionText)
        } label: {
            Text("copy and finish")
                .font(.duvroButton)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 54)
                .background(Color(hex: "171614"))
                .clipShape(Capsule())
        }
        .disabled(captionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    // MARK: - Generation

    private func regenerate() async {
        isLoading = true
        if !captionText.isEmpty {
            usedCaptions.insert(captionText)
        }
        let next = await captionService.caption(packID: pack.id, excluding: usedCaptions)
        captionText = next
        isLoading = false
    }
}
