# CLAUDE.md — duvro

## Read these first, every session
1. `prd.md` — what the app does. **Source of truth for behavior.**
2. `BUILD_ROADMAP.md` — how to build it. Phases, acceptance criteria, gotchas.
3. `UI_NOTES.md` — design system + the fix list correcting the mockups.
4. `duvro-flow.mermaid` — screen map / navigation.
5. `/design/` — Stitch screenshots. **Visual target only. Where a mockup and the PRD/UI_NOTES conflict, the docs win.**

## Current status
**Phase 8 acceptance is still NOT met (packs untuned — unchanged), but the welcome screen, all three pack previews, and the vibe-select thumbnails now show real bundled content instead of placeholders, and this session found + fixed a real, pre-existing layout bug that only real photos exposed.** 70/70 tests passing, unchanged. Simulator, Release-configuration, and device-target builds all green; Release bundle contents verified directly (all 21 SampleAssets files present, DebugAssets absent).

**NEW — real SampleAssets bundled and wired (`duvro/SampleAssets/`, `SampleAssets.swift`).** 21 real photos: 3 for the welcome card stack, 5 per pack for its preview grid, 3 pack-card thumbnails. Lives at `duvro/SampleAssets/` specifically so the existing file-system-synchronized group that already syncs `duvro/` picks it up with zero project-file edits — same mechanism DebugAssets uses, minus that file's Release exclusion and its gitignore entry (this is real shipped product content, not a privacy-sensitive debug fixture). Replaces the deleted `DebugWelcomePhotos.swift`/`DebugPackPreviewPhotos.swift`; all 6 real/DEBUG call sites now use it unconditionally, closing the `#if DEBUG return [] #else` gap that used to leave Release's pack previews and welcome stack empty.

**Two flagged matching gaps, both need the user's own correction pass:** (1) pack thumbnail filenames are content hashes, not pack-named as instructed — matched by eye against the vibe-select mockup instead (verified: no embedded title/description/keyword metadata to fall back on either). Digicam's is a weak match. (2) Welcome's back/middle card slots have no real content match against design/01's own back/middle cards — only the front card does; the other two are leftovers split by tone alone. See `SampleAssets.swift`'s own comments for the full per-slot reasoning.

**FIXED — real, pre-existing pack-preview grid bug**, independent of the SampleAssets work above: `PackPreviewSheet`'s bottom-row tiles sized themselves via `.frame(maxWidth: .infinity, maxHeight: .infinity)` applied OUTSIDE the tile function, with `.clipShape`/`.clipped()` applied INSIDE it first — a resizable `aspectRatio(.fill)` Image's reported ideal size before that outer frame lands can be close to its own native pixel dimensions, so clipping against that size and then wrapping the result in a smaller outer frame doesn't re-clip, it just moves where the oversized content is measured from. Never visible with the old uniformly-shaped DebugFixture placeholders; immediately visible with real photos of varied native aspect ratios (tiles overlapping into the row above). Fixed by taking an explicit `size` parameter and applying `.frame` before clipping, so the clip always happens at the final size. Confirmed the row/column math itself was always correct by swapping in plain `Color` views through the identical geometry, which rendered perfectly.

**FIXED — welcome card stack rebuilt to match design/01_welcome.png.** The previous version reused UI_NOTES §4's curation-progress shuffle geometry (a different, more loosely-spread animated stack) and a uniform four-side border. Rebuilt from the mockup directly: back/middle cards shrunk and pulled in so the front card actually hides most of them; front card enlarged; border changed to a real print border (thin sides/top, thick bottom — same asymmetric idea as the Digicam Polaroid EditOp, here as UI chrome). Iterated three passes against a direct side-by-side comparison with the mockup image.

**Carried forward from the prior session, unchanged this session:** the crash fix (Photos-library read removed from `ExportService.saveAll`), pill-text centering, the Polaroid-frame and Y2K-date-stamp preview/export-parity fixes, real EXIF capture dates (93% capture rate on bundled real photos, PHPicker's own behavior still needs on-device confirmation), and the crop-clip scoring penalty. See git history for full detail on each.

**NEW — crop-clip penalty in scoring.** A 4:5 center crop on a landscape group shot can cut people out, and group shots are the category the product thesis says matter most. `CompositeScoring.clipPenalty` now tests every detected face/human box against the eventual 4:5 crop window and subtracts a proportional penalty from the composite (face-weighted heavily, body lightly, capped so it penalizes rather than rejects). The three existing composite weights are unchanged — the penalty subtracts, it doesn't compete for weight share. Surfaced as a `clip` value in the debug grid. The underlying fix (repositioning the crop itself instead of just penalizing it) is recorded but not built — BUILD_ROADMAP Deferred work register item 10.

**Still unresolved, DO NOT flip the creationDate sign again: the Instagram picker photo order.** Two prior sign inversions both failed to fix it, and the diagnostic that might have told us more just had to be removed (see above, it crashed). Two live, undistinguished hypotheses: (1) Instagram's picker may not sort by `creationDate` at all; (2) a prior "14 duplicate assets for a 7-photo post" incident was never conclusively closed, and if `PHPhotoLibrary.performChanges` still invokes its block more than once, paired assets would carry identical creationDates, breaking any sort regardless of direction. The in-memory invocation counter (kept, Photos-read-free) still watches for (2). Comparing against the stock Photos app's own ordering is the highest-value next step, and it has to happen by eye on-device now — there's no safe way to read the result back in-app.

**Known placeholders/gaps, all flagged in-code:** the Y2K date stamp's font is system monospace (no bundled Y2K-style font — do not bundle one without asking); the vibe screen's helper text is Inter italic (Caveat isn't bundled); "see how it works" on Welcome is DEBUG-only functional (uses DebugFixture's demo-mode data, unrelated to the SampleAssets work this session); ImportView's real "choose your vibe" flow still has nothing to curate from in Release builds until Vision scoring exists outside DEBUG (`ScoringService` is still `#if DEBUG`-only — separate, larger, pre-existing gap, BUILD_ROADMAP Deferred work register item 9, not touched this session). The app still doesn't force light mode anywhere except its DEBUG overlay (still true, still unscoped).

See BUILD_ROADMAP's Deferred work register for everything still open (pack tuning — item 1, all three packs; clustering threshold; CategoryMapper reliability; the skip-pool redesign; named album; the Instagram Mixed-ratio-toggle entry; ScoringService's DEBUG-only wiring; and the new smart-crop entry, item 10). Update this line at the end of every session.

## What duvro is
An iOS app that turns a camera roll into a ready-to-post Instagram photo dump. The user imports 20–200 photos, picks a Vibe Pack, and duvro curates a set, renders each photo in 3 aesthetic variants for the user to choose between, then hands off to Instagram with the photos saved in order and the caption on the clipboard.

## Product thesis (governs judgment calls)
1. **Taste is the moat; selection is the hook.** Apple/Instagram could ship "AI pick my best photos" tomorrow — they'll never ship opinionated Pinterest-girl aesthetics. Vibe Packs get the most polish time.
2. **Vision nominates, the model selects.** On-device Vision is reliable at mechanical filtering — screenshots, near-duplicates, face/body counts, capture quality, category — but it scores technical quality, not "does the user look good" or who matters emotionally. A blurry photo with the user's best friend beats a perfect sunset, so the final call goes to a model that can judge a curated set the way a person would. Vision narrows a roll to a shortlist per category; it does not decide the final post.
3. **Momentum over judgment.** Never give the user a screen whose only purpose is to evaluate the AI. Corrections happen late, after they're invested.
4. **Humility in copy.** "our favorites" — never "the best photos." "almost made it" — never "rejected."
5. **The bar:** users should feel "these are exactly the photos I would've picked, only better."

## Ground rules
- **Stack:** Swift 5.10+, SwiftUI only, **zero third-party dependencies**. iOS 18.0 minimum. iPhone only, portrait only.
- **Privacy architecture:** on-device by default. PHPicker (no library permission needed to read); the only *photo library* permission requested is **add-only**, at export time. One exception: the curation call and captions both go through a single serverless endpoint (Vercel) proxying the Claude API — a shortlist of downsampled, low-resolution thumbnails plus per-photo metrics leaves the device for that one call. API key never ships in the app; hard daily spend cap; nothing stored server-side, including logs.
- **Performance:** downsample every import to ≤1280px immediately for scoring/preview; full-res render happens ONCE, at export. Never hold 200 full-res images in memory.
- **No accounts.** No login, no profile avatars, no settings gear, no tab bars. Header = back control + wordmark + at most one contextual action.
- **Voice:** warm, lowercase-leaning, humble. Never surface "AI," "algorithm," "optimized," or technical scores in the UI.
- **Photos display at 4:5 everywhere.**

## Workflow
- One phase per session. Do not start phase N+1 until phase N's acceptance criteria pass.
- Per task: implement → `xcodebuild` → run in simulator → screenshot (`xcrun simctl io booted screenshot out.png`) → verify against acceptance criteria and the matching mockup → commit.
- Small commits, one per checklist item.
- Ask before adding any dependency, any new screen, or any feature not in the PRD.
- When a mockup detail and a doc conflict, follow the doc and say so rather than silently picking one.

## Hard gate
The **overlap test** governs everything downstream: real users hand-pick 7 photos from their own ~100, and duvro's picks must overlap ≥4/7 or be rated equal/better. The on-device shortlist (Phase 3) alone doesn't produce a post, so this tests the full pipeline — Phase 3's shortlist plus Phase 3.5's curation call — and is only executable once Phase 3.5 exists (see BUILD_ROADMAP Phase 3.5). If it fails, stop and re-tune — shortlist thresholds, the curation prompt, or both — before building anything downstream. Nothing else in the app matters if selection is bad.
