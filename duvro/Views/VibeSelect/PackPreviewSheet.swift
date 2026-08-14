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
//  SAMPLE PHOTOS: `samplePhotos` is just `[Photo]`, with no knowledge of
//  where they came from -- the caller (SampleAssets.packPreviewPhotos(for:),
//  real bundled product content as of this session) decides. This view
//  stays decoupled from that on purpose, same reasoning as before real
//  images existed: swapping the source later is a change to the caller,
//  not to this file.
//
//  RAW ORIGINALS, NOT RENDERED (deliberate, temporary -- see UI_NOTES §3):
//  the sample grid shows the unedited source photo. Previously rendered
//  each sample through the pack's first variant (with a
//  PackPreviewRenderCache to keep reopening instant); removed rather
//  than left dangling-but-unused, since the packs are untuned and a
//  rendered preview right now would show the untuned look, not what the
//  pack is meant to look like. Restore the variant-rendering + cache pair
//  (git history has the previous version) once pack tuning is done.
//
//  FULL RESOLUTION, NOT Photo.thumbnail (bug found after the raw-
//  originals change above shipped -- previews read visibly soft/blurry
//  compared to the actual SampleAssets files). DIAGNOSIS: Photo.thumbnail
//  is capped at 200px on its longest edge (PhotoImportService.
//  thumbnailImage(maxPixelSize: 200), the same cap used for the
//  in-memory import grid) -- fine for a 60pt grid cell, but the large
//  tile here renders at roughly 0.58 * sheet width, which on a real
//  device at 2x/3x scale needs 600-1200+px to stay crisp. No
//  interpolation modifier is degrading anything, and the drawn frame
//  size is correct -- the SOURCE bitmap being fed in was just too small,
//  upscaled ~3-6x by .resizable(). Fixed by loading photo.originalURL
//  directly (fullResImages below), the exact file bytes in SampleAssets/,
//  at its own native resolution -- not re-downsampled at all. Async
//  (Task.detached, off the main thread) since these are real file reads,
//  even though local/bundled and fast; thumbnail is kept as the fallback
//  for the one frame before that completes, same fail-toward-something-
//  visible pattern used elsewhere in this codebase.
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
    /// Loaded from photo.originalURL, at native resolution -- see file
    /// header FULL RESOLUTION note. Keyed by Photo.id, populated once
    /// per pack (`.task(id: pack.id)`), so switching packs (a different
    /// sheet instance each time, but belt-and-suspenders) reloads.
    @State private var fullResImages: [UUID: UIImage] = [:]

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
            await loadFullResImagesIfNeeded()
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
            // 0.66 (the original value) made the large tile noticeably
            // TALLER/narrower than design/04-06's own large tile, which
            // needed the fill-crop to cut away more of the source photo's
            // top and bottom to cover that shape -- confirmed by pixel-
            // measuring the mockup directly (its large tile is ~202x278pt,
            // aspect ~0.73) rather than eyeballing. 0.60 reproduces that
            // measured aspect almost exactly (0.58/0.60 column:row ratio
            // -> ~0.73) without touching bigColumnWidth's 0.58, which
            // wasn't reported as wrong.
            let topRowHeight = geo.size.height * 0.60
            let bottomRowHeight = geo.size.height - topRowHeight - spacing
            let stackedTileHeight = (topRowHeight - spacing) / 2
            let bottomTileWidth = (geo.size.width - spacing) / 2

            VStack(spacing: spacing) {
                HStack(alignment: .top, spacing: spacing) {
                    tile(0, size: CGSize(width: bigColumnWidth, height: topRowHeight))
                    VStack(spacing: spacing) {
                        tile(1, size: CGSize(width: smallColumnWidth, height: stackedTileHeight))
                        tile(2, size: CGSize(width: smallColumnWidth, height: stackedTileHeight))
                    }
                    .frame(width: smallColumnWidth, height: topRowHeight)
                }
                .frame(height: topRowHeight)
                HStack(spacing: spacing) {
                    tile(3, size: CGSize(width: bottomTileWidth, height: bottomRowHeight))
                    tile(4, size: CGSize(width: bottomTileWidth, height: bottomRowHeight))
                }
                .frame(height: bottomRowHeight)
            }
            // GeometryReader does NOT clip its content to geo.size by
            // default -- pinning the VStack to geo's own exact size (not
            // just relying on its children's frames summing to the same
            // number) is what actually prevents it. Caught on-device: an
            // earlier version without this line rendered the grid
            // correctly but let it silently overflow a few points past
            // its intended height, painting over quoteBlock below it.
            .frame(width: geo.size.width, height: geo.size.height)
        }
        // 300pt (the original value) left the grid stopping about halfway
        // down the sheet, with a large dead area above the CTA -- nowhere
        // close to design/04-06, where the grid occupies most of the
        // sheet's vertical space. 480pt is what's actually left once the
        // header, quote block, and CTA row's own real heights are
        // subtracted from a standard iPhone's usable height -- verified by
        // screenshot comparison against the mockups, not derived from a
        // device-size constant (this sheet has no GeometryReader of its
        // own above this point to compute it from directly).
        .frame(height: 480)
        .clipped() // belt-and-suspenders against the same overflow, regardless of cause
    }

    /// `size` is applied INSIDE this function, before `.clipShape`/`.clipped`
    /// -- not left to the caller to apply afterward. That ordering is load-
    /// bearing, not stylistic: the previous version constrained size only
    /// from the OUTSIDE (`tile(index).frame(width:height:)` at the call
    /// site), with `.clipShape`/`.clipped()` applied INSIDE this function
    /// first. A resizable, aspectRatio(.fill) Image's reported ideal size
    /// before an explicit frame is applied can be very large (its own
    /// native pixel dimensions, effectively unbounded relative to a small
    /// grid tile) -- clipping against THAT size, then wrapping the already-
    /// clipped result in a smaller outer frame, does not re-clip; it just
    /// changes where the (already oversized) painted content is measured
    /// from, which is what let real SampleAssets photos (varied native
    /// aspect ratios, unlike the previous uniformly-shaped DebugFixture
    /// placeholders) visibly spill outside their intended tile and overlap
    /// neighbors. Applying the frame FIRST, then clipping, guarantees the
    /// clip always happens at the final, correct size.
    private func tile(_ index: Int, size: CGSize) -> some View {
        Group {
            if samplePhotos.indices.contains(index) {
                // Raw original, unedited, at full resolution -- see file
                // header. Falls back to the 200px thumbnail only for the
                // one frame before loadFullResImagesIfNeeded() completes.
                let photo = samplePhotos[index]
                Image(uiImage: fullResImages[photo.id] ?? photo.thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color(hex: "EEE9DF")
            }
        }
        .frame(width: size.width, height: size.height)
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

    // MARK: - Full-resolution loading (see file header FULL RESOLUTION note)

    private func loadFullResImagesIfNeeded() async {
        let photos = samplePhotos
        let loaded = await Task.detached(priority: .userInitiated) {
            Dictionary(uniqueKeysWithValues: photos.compactMap { photo -> (UUID, UIImage)? in
                guard let image = UIImage(contentsOfFile: photo.originalURL.path) else { return nil }
                return (photo.id, image)
            })
        }.value
        fullResImages = loaded
    }
}
