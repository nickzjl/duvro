//
//  VibeSelectionView.swift
//  duvro
//
//  Phase 8, Task 4 (BUILD_ROADMAP Phase 8, prd.md §4 steps 3-4 / P0.4,
//  UI_NOTES §1/§3/§6 + fix 3). "Select vibe": a photo-count text input
//  (P0.4) plus the three pack cards. Tapping a card opens
//  PackPreviewSheet (Task 3) -- there is no separate preview link
//  anywhere (UI_NOTES §3); that sheet's "use this vibe" is the only CTA
//  on this whole screen, which is why THIS view deliberately has no
//  primary button of its own (UI_NOTES §6).
//

import SwiftUI

struct VibeSelectionView: View {
    var sessionStore: SessionStore
    /// Supplies ~5 sample photos to preview a given pack in. Caller-
    /// provided so this view (compiled in every configuration) has no
    /// direct dependency on DebugFixture -- the real (Release-safe) call
    /// site and the DEBUG launch path answer this differently. See
    /// PackPreviewSheet.swift's file header for the fuller reasoning.
    var samplePhotos: (VibePack) -> [Photo]
    /// The pack card's own small thumbnail (SampleAssets.packThumbnail) --
    /// separate from `samplePhotos` since it's a dedicated, purpose-picked
    /// image per pack, not just "whichever preview photo comes first."
    var packThumbnail: (VibePack) -> UIImage?
    /// Called once "use this vibe" is tapped inside a pack's preview
    /// sheet, with the resolved photo count (already validated/defaulted
    /// -- see resolvedCount()). Curation progress/showcase (prd.md §4
    /// steps 5-6) aren't built this session -- the real call site hands
    /// off to the existing FallbackSelectionService path instead; see
    /// that call site's own "CURATION INSERTION POINT" comment.
    var onVibeSelected: (VibePack, Int) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var countText = "\(VibeSelectionView.defaultCount)"
    @FocusState private var countFieldFocused: Bool
    @State private var showCountWarning = false
    @State private var countWarningMessage = ""
    @State private var packs: [VibePack] = []
    @State private var packsFailedToLoad = false
    @State private var previewingPack: VibePack?

    private static let minCount = 4
    private static let maxCount = 20
    private static let defaultCount = 7
    /// Canonical order, per prd.md §6 -- not alphabetical, not load order.
    private static let packOrder = ["golden_hour", "digicam", "travel_film"]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                header
                countField
                packSection
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 40)
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .onAppear { loadPacksIfNeeded() }
        .sheet(item: $previewingPack) { pack in
            PackPreviewSheet(
                pack: pack,
                samplePhotos: samplePhotos(pack),
                onUseThisVibe: {
                    onVibeSelected(pack, resolvedCount())
                }
            )
            .presentationCornerRadius(28) // UI_NOTES §1: "sheets 28pt radius"
        }
        .alert("let's adjust that", isPresented: $showCountWarning) {
            Button("ok") {}
        } message: {
            Text(countWarningMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "171614"))
                        .frame(width: 44, height: 44)
                }
                .padding(.leading, -12) // visually align the chevron glyph with the page's 20pt margin, matching EditFlowView's topBar
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("pick a vibe")
                    .font(.duvroHeadline)
                    .foregroundStyle(Color(hex: "171614"))
                Text("curate the mood for your post.")
                    .font(.duvroBody)
                    .foregroundStyle(Color(hex: "777169"))
            }
        }
    }

    // MARK: - Photo count (prd.md P0.4, UI_NOTES §6's corner-radius fix)

    private var countField: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("photo count")
                .font(.duvroCaption)
                .foregroundStyle(Color(hex: "777169"))
                .textCase(.uppercase)
                .tracking(0.5)

            HStack(alignment: .center, spacing: 16) {
                TextField("", text: $countText)
                    .keyboardType(.numberPad)
                    .focused($countFieldFocused)
                    .font(.duvroHeadline)
                    .foregroundStyle(Color(hex: "171614"))
                    .multilineTextAlignment(.center)
                    .frame(width: 72, height: 56)
                    .background(Color(hex: "FFFCF7"))
                    .overlay(
                        // UI_NOTES §6: the mockup's count field is sharp-
                        // cornered while every other element uses continuous
                        // rounded corners -- normalized here to match.
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color(hex: "DDD6CA"), lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .toolbar {
                        ToolbarItemGroup(placement: .keyboard) {
                            Spacer()
                            Button("done") { countFieldFocused = false }
                        }
                    }

                // Caveat -- UI_NOTES §1's own named example of the ONE
                // handwritten-note-per-screen allowance ("7 is the sweet
                // spot") -- isn't bundled. Inter italic stands in; do NOT
                // bundle a new font to close this without asking. Flagged
                // in the session report.
                Text("7 is the sweet spot.")
                    .font(.duvroSubheadline)
                    .italic()
                    .foregroundStyle(Color(hex: "A04021"))
            }
        }
        .onChange(of: countFieldFocused) { wasFocused, isFocused in
            if wasFocused, !isFocused {
                validateAndResolveCount()
            }
        }
    }

    // MARK: - Pack cards (UI_NOTES fix 3: complete, correct, never-truncated variant names)

    private var packSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            // "AVAILABLE PRESETS" in the mockup -- UI_NOTES §6: "presets is
            // not this product's vocabulary."
            Text("vibe packs")
                .font(.duvroCaption)
                .foregroundStyle(Color(hex: "777169"))
                .textCase(.uppercase)
                .tracking(0.5)

            if packs.isEmpty, packsFailedToLoad {
                Text("packs failed to load -- try again in a moment.")
                    .font(.duvroCaption)
                    .foregroundStyle(Color(hex: "777169"))
            }

            VStack(spacing: 12) {
                ForEach(packs) { pack in
                    packCard(pack)
                }
            }
        }
    }

    private func packCard(_ pack: VibePack) -> some View {
        Button {
            validateAndResolveCount() // resolve/flag the count at the moment it's about to matter, in case the field never lost focus
            previewingPack = pack
        } label: {
            HStack(alignment: .top, spacing: 14) {
                cardThumbnail(pack)
                VStack(alignment: .leading, spacing: 4) {
                    Text(pack.displayName)
                        .font(.duvroPackTitle)
                        .foregroundStyle(Color(hex: "171614"))
                    // Complete and correct, never truncated (UI_NOTES fix
                    // 3) -- no lineLimit, so a long row wraps rather than
                    // clipping ("SOFT G…", "FADED POSTCARD ·" in the
                    // mockup are exactly the bug being fixed).
                    Text(pack.variants.map { $0.name.lowercased() }.joined(separator: " · "))
                        .font(.duvroVariantLabel)
                        .foregroundStyle(Color(hex: "A04021"))
                        .fixedSize(horizontal: false, vertical: true)
                    Text(Self.blurbs[pack.id] ?? "")
                        .font(.duvroCaption)
                        .foregroundStyle(Color(hex: "777169"))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(Color(hex: "FFFCF7"))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color(hex: "DDD6CA"), lineWidth: 1)
            )
            // Whisper shadow (UI_NOTES §1: y4/blur18/6%) -- cards read as
            // obviously tappable even with no primary CTA on this screen
            // (UI_NOTES §6).
            .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 4)
        }
        .buttonStyle(.plain)
    }

    /// The card's own small thumbnail -- a dedicated SampleAssets image
    /// (SampleAssets.packThumbnail), plain and UNEDITED, not a
    /// pack-rendered image. Ambiguous, made-alone simplification carried
    /// over from the original build: rendering a pack-graded thumbnail
    /// for every card on this screen would mean 3 extra EditEngine.render
    /// calls before the screen can even show cards, for a thumbnail small
    /// enough that the graded look barely reads at that size anyway -- the
    /// full graded look is one tap away in PackPreviewSheet, which is what
    /// that screen is for.
    private func cardThumbnail(_ pack: VibePack) -> some View {
        Group {
            if let thumbnail = packThumbnail(pack) {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(hex: "EEE9DF")
            }
        }
        .frame(width: 64, height: 80) // 4:5, UI_NOTES §1
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
    }

    /// Not in prd.md/UI_NOTES or the VibePack JSON schema -- original UI
    /// copy for this screen (same ambiguous-decision treatment, and same
    /// reasoning, as PackPreviewSheet's per-pack quotes). Flagged in the
    /// session report.
    private static let blurbs: [String: String] = [
        "golden_hour": "drenches your photos in late-afternoon warmth.",
        "digicam": "flash-heavy, raw, and unmistakably early-2000s.",
        "travel_film": "rich color and a little grain, like it was worth remembering."
    ]

    // MARK: - Photo count validation (prd.md P0.4)

    /// Fires when the count field loses focus AND defensively again right
    /// before a pack card opens its preview (in case the user tapped a
    /// card without the field ever losing focus, e.g. straight from the
    /// keyboard's "done" never being tapped). Idempotent either way.
    private func validateAndResolveCount() {
        guard let value = Int(countText), value > 0 else {
            // Empty or genuinely invalid input -- silent default per
            // prd.md P0.4, no message (there's nothing coherent to explain).
            countText = "\(Self.defaultCount)"
            return
        }
        if value < Self.minCount {
            countWarningMessage = "4 is the fewest we can work with -- variety across people, place, food, and detail needs at least that many photos. set to \(Self.defaultCount) for now."
            showCountWarning = true
            countText = "\(Self.defaultCount)"
        } else if value > Self.maxCount {
            countWarningMessage = "20 is instagram's limit for a single post, so that's as many as we can use. set to \(Self.defaultCount) for now."
            showCountWarning = true
            countText = "\(Self.defaultCount)"
        }
    }

    /// Final, defensive resolution at the moment the count is actually
    /// used -- clamps even if validateAndResolveCount somehow didn't fire
    /// first, so a malformed value here still fails toward the same
    /// default rather than an out-of-range or garbage count ever reaching
    /// FallbackSelectionService.
    private func resolvedCount() -> Int {
        let value = Int(countText) ?? Self.defaultCount
        return min(max(value, Self.minCount), Self.maxCount)
    }

    // MARK: - Pack loading

    private func loadPacksIfNeeded() {
        guard packs.isEmpty else { return }
        var loaded: [VibePack] = []
        var anyFailed = false
        for name in Self.packOrder {
            switch VibePackLoader.load(named: name) {
            case .success(let pack):
                loaded.append(pack)
            case .failure(let error):
                anyFailed = true
                #if DEBUG
                print("[vibe-select] '\(name)' failed to load: \(error.diagnosticDescription)")
                #endif
            }
        }
        packs = loaded
        packsFailedToLoad = anyFailed
    }
}
