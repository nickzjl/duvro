//
//  PackPreviewSheet.swift
//  duvro
//
//  Phase 8, Task 3 (BUILD_ROADMAP Phase 8, prd.md §4 step 4, UI_NOTES §3 +
//  fix 7). Tapping a pack card opens this sheet; "use this vibe" is the
//  ONLY CTA -- there is no separate "preview" link anywhere (UI_NOTES §3:
//  "this deliberately forces the user to see each pack's look before
//  committing"). This view knows nothing about where its sample photos or
//  its "use this vibe" action's downstream behavior come from -- both are
//  handed in by the caller (Task 4's vibe selection screen in the real
//  flow; DebugLaunchRootView's `-duvroDebugScreen packPreview` path for
//  screenshotting this file on its own, since simctl can't tap a card to
//  reach a sheet that's normally one tap away).
//
//  BLOCKER, routed around rather than solved (flagged per this session's
//  instructions): the ~18 real bundled sample photos this screen is
//  ultimately meant to ship with don't exist yet -- nobody has shot them
//  (BUILD_ROADMAP's Deferred work register). `samplePhotos` is just
//  `[Photo]`, with no knowledge of where they came from, SPECIFICALLY so
//  swapping DebugFixture placeholders for real bundled images later is a
//  change to the CALLER (DebugPackPreviewPhotos.swift, or its Release
//  replacement), not to this file.
//
//  CACHING (Phase 8 acceptance: "previews load instantly"): renders are
//  cached in PackPreviewRenderCache, which lives outside this view's own
//  @State so it survives the sheet being dismissed and reopened, or a
//  different pack's sheet opening in between -- unlike EditFlowView's
//  renderCache, which only needs to survive within one edit session's
//  view lifetime.
//

import SwiftUI

struct PackPreviewSheet: View {
    let pack: VibePack
    /// ~5 photos to render in this pack's look. Caller-supplied on
    /// purpose -- see the file header's BLOCKER note.
    let samplePhotos: [Photo]
    /// Called after this sheet dismisses itself. Both "select this pack"
    /// AND "start curation" are the caller's responsibility (curation
    /// progress/showcase aren't built this session -- Task 4 hands off to
    /// the existing shortlist/fallback path instead); this view only
    /// knows that its one job finished.
    var onUseThisVibe: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var renderedImages: [UIImage] = []

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    sampleGrid
                    quoteBlock
                }
                .padding(.horizontal, 20)
                .padding(.top, 20)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ctaStack
        }
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
        .task(id: pack.id) {
            await renderIfNeeded()
        }
    }

    // MARK: - Header (pack title + variant names, UI_NOTES §1 + fix 3)

    private var header: some View {
        VStack(spacing: 6) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color(hex: "171614"))
                        .frame(width: 44, height: 44)
                }
                Spacer()
                Color.clear.frame(width: 44, height: 44) // balances the chevron so the title stays centered
            }
            .overlay(
                Text(pack.displayName)
                    .font(.duvroPackTitle)
                    .foregroundStyle(Color(hex: "171614"))
            )

            // Variant names, exact and complete -- UI_NOTES fix 3 is
            // explicit that mockups clip this row ("SOFT G…"); default
            // Text wrapping (no lineLimit set) means a long row wraps to a
            // second line instead of truncating.
            Text(pack.variants.map { $0.name.lowercased() }.joined(separator: " · "))
                .font(.duvroVariantLabel)
                .foregroundStyle(Color(hex: "A04021"))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: - Sample grid: 1 large + 4 small, per design/04-06 mockups

    private var sampleGrid: some View {
        GeometryReader { geo in
            let spacing: CGFloat = 8
            let bigColumnWidth = geo.size.width * 0.58
            let smallColumnWidth = geo.size.width - bigColumnWidth - spacing
            let topRowHeight = geo.size.height * 0.66
            let bottomRowHeight = geo.size.height - topRowHeight - spacing
            let stackedTileHeight = (topRowHeight - spacing) / 2

            VStack(spacing: spacing) {
                HStack(alignment: .top, spacing: spacing) {
                    tile(0)
                        .frame(width: bigColumnWidth, height: topRowHeight)
                    VStack(spacing: spacing) {
                        tile(1).frame(height: stackedTileHeight)
                        tile(2).frame(height: stackedTileHeight)
                    }
                    .frame(width: smallColumnWidth, height: topRowHeight)
                }
                .frame(height: topRowHeight)
                HStack(spacing: spacing) {
                    tile(3).frame(maxWidth: .infinity, maxHeight: .infinity)
                    tile(4).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: bottomRowHeight)
            }
            // GeometryReader does NOT clip its content to geo.size by
            // default -- pinning the VStack to geo's own exact size (not
            // just relying on its children's frames summing to the same
            // number) is what actually prevents it. Caught on-device: an
            // earlier version without this line rendered the grid
            // correctly but let it silently overflow a few points past
            // its intended 300pt, painting over quoteBlock below it.
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .frame(height: 300)
        .clipped() // belt-and-suspenders against the same overflow, regardless of cause
    }

    private func tile(_ index: Int) -> some View {
        Group {
            if renderedImages.indices.contains(index) {
                Image(uiImage: renderedImages[index])
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else if samplePhotos.indices.contains(index) {
                // Rendering hasn't finished yet -- the unedited thumbnail,
                // not a blank tile, same fail-safe-toward-something-visible
                // spirit as EditEngine/EditFlowView.
                Image(uiImage: samplePhotos[index].thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(hex: "EEE9DF")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .clipped()
    }

    // MARK: - Quote + attribution (UI_NOTES fix 7: "— duvro", not "— journaling with intent")

    private var quoteBlock: some View {
        VStack(alignment: .trailing, spacing: 6) {
            Text("\u{201C}\(Self.quotes[pack.id] ?? Self.quotes["golden_hour"]!)\u{201D}")
                .font(.duvroSerifItalic)
                .foregroundStyle(Color(hex: "171614"))
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("— duvro")
                .font(.duvroCaption)
                .foregroundStyle(Color(hex: "777169"))
        }
        .padding(.bottom, 12)
    }

    /// Not in prd.md/UI_NOTES or the VibePack JSON schema -- these are
    /// original UI copy written for this screen (inspired by the design/
    /// mockups' tone, not transcribed from them), since a quote per pack
    /// appears consistently across all three preview mockups but isn't
    /// specified as loaded data anywhere. Flagged as an ambiguous, made-
    /// alone decision in the session report. Keyed by VibePack.id so a
    /// future pack without an entry here falls back to Golden Hour's line
    /// rather than showing nothing.
    private static let quotes: [String: String] = [
        "golden_hour": "the light here feels like a quiet promise kept.",
        "digicam": "late nights, borrowed flashes, and unfiltered moments.",
        "travel_film": "not all who wander are lost — some are just here for the view."
    ]

    // MARK: - Sticky CTA (UI_NOTES §1: black pill wins here too, not the mockup's terracotta rectangle)

    private var ctaStack: some View {
        VStack(spacing: 12) {
            Button {
                dismiss()
                onUseThisVibe()
            } label: {
                Text("use this vibe")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }

            Button("cancel") {
                dismiss()
            }
            .font(.duvroCaption)
            .foregroundStyle(Color(hex: "777169"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(Color(hex: "F7F4EE"))
    }

    // MARK: - Rendering

    /// Every sample photo rendered in the pack's FIRST variant -- a single
    /// representative look, matching the mockups (all 5 images read as one
    /// consistent grade, not a mix of the pack's 3 variants). Ambiguous
    /// decision, made alone: neither prd.md nor UI_NOTES specifies which
    /// variant a multi-variant pack should preview with.
    private func renderIfNeeded() async {
        guard let variant = pack.variants.first, !samplePhotos.isEmpty else { return }
        if let cached = await PackPreviewRenderCache.renders(for: pack, samplePhotos: samplePhotos) {
            renderedImages = cached
            return
        }
        let photos = samplePhotos
        let rendered = await Task.detached(priority: .userInitiated) {
            photos.map { EditEngine.render(photo: $0, variant: variant) }
        }.value
        renderedImages = rendered
        await PackPreviewRenderCache.store(rendered, for: pack, samplePhotos: samplePhotos)
    }
}

/// Outlives any single PackPreviewSheet instance (app-process-lifetime, in-
/// memory only -- no disk persistence, nothing here claims to survive a
/// relaunch) so reopening a pack's sheet, or opening a second pack's sheet
/// and coming back to the first, is instant rather than re-rendering.
/// @MainActor: UIImage isn't officially Sendable, and every render/read
/// here already happens from MainActor-adjacent contexts (SwiftUI view
/// tasks) -- matching, not fighting, that constraint.
@MainActor
enum PackPreviewRenderCache {
    private static var storage: [String: [UIImage]] = [:]

    static func renders(for pack: VibePack, samplePhotos: [Photo]) -> [UIImage]? {
        storage[key(pack: pack, samplePhotos: samplePhotos)]
    }

    static func store(_ images: [UIImage], for pack: VibePack, samplePhotos: [Photo]) {
        storage[key(pack: pack, samplePhotos: samplePhotos)] = images
    }

    /// Keyed on pack id + the exact sample photo IDs shown, in order -- if
    /// the caller ever changes which photos represent a pack (e.g. real
    /// bundled images replacing DebugFixture placeholders), the cache
    /// naturally misses instead of serving stale renders of the wrong set.
    private static func key(pack: VibePack, samplePhotos: [Photo]) -> String {
        pack.id + "|" + samplePhotos.map { $0.id.uuidString }.joined(separator: ",")
    }
}
