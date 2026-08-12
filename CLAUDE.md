# CLAUDE.md — duvro

## Read these first, every session
1. `prd.md` — what the app does. **Source of truth for behavior.**
2. `BUILD_ROADMAP.md` — how to build it. Phases, acceptance criteria, gotchas.
3. `UI_NOTES.md` — design system + the fix list correcting the mockups.
4. `duvro-flow.mermaid` — screen map / navigation.
5. `/design/` — Stitch screenshots. **Visual target only. Where a mockup and the PRD/UI_NOTES conflict, the docs win.**

## Current status
**Phase 8 acceptance is still NOT met (packs untuned — unchanged), but tonight's session (unsupervised, five prioritized fix tasks) cleared a real crash and three visible rendering bugs, and added a scoring improvement.** 70/70 tests passing (was 53 at session start). Simulator, Release-configuration, and device-target builds all green after every task.

**FIXED — CRASH: export.** Last session's diagnostic in `ExportService.saveAll` fetched newly-created assets back via `PHAsset.fetchAssets(withLocalIdentifiers:)` to log their persisted `creationDate`. That's a Photos-library READ, and `.addOnly` authorization grants none — it crashed on device. Removed the fetch; kept the read-free invocation counter. Audited the rest of the export path and everything else touched last session for other reads — none found. **Consequence for the Instagram-picker-order investigation (see below): the diagnostic that would have distinguished its two hypotheses is gone** — that question is back to needing the user's own on-device comparison against the stock Photos app, not richer console output.

**FIXED — pill text top-aligned instead of centered.** `.lineLimit(2, reservesSpace: true)` reserved the right height but Text pinned its glyphs to the top of it. Fixed with an invisible two-line reference Text behind the real label in a ZStack (ZStack's default centering does the rest). Verified on all three packs.

**FIXED — Polaroid frame, two compounding bugs.** (1) The photo was scaled to FIT the interior instead of FILL it, adding letterboxing that read as one big uniform border and washed out the thicker-bottom effect. (2) The op returned an image at the full native-aspect extent (relying on SwiftUI's on-screen fill-crop to trim it to 4:5), but that crop didn't coincide with the op's own 4:5 window — correct on export, wrong (huge equal margins) in the live preview. Fixed by filling instead of fitting, and by cropping the op's own output to its 4:5 window directly, so preview and export are pixel-identical again. `render()` also needed a fix (rasterize at the op chain's own final extent, not the pre-chain source extent) since this is now the first op whose output extent legitimately differs from its input's.

**FIXED — Y2K date stamp, two more compounding bugs.** (1) Same extent-vs-window bug as the Polaroid frame — positioned near the native extent's edge, which for a non-4:5 source falls outside what survives the crop. (2) The stamp's `UIGraphicsImageRenderer` never pinned `format.scale = 1`, so it defaulted to the device's Retina scale (2x/3x); since `CIImage(cgImage:)` has no concept of "points," the position math (written assuming canvas-size-in-points = rendered-pixel-width) was off by that multiple. Both fixed. Also wired real capture dates: `Photo.captureDate` (optional, added at import via `PhotoImportService.captureDate(from:)`, EXIF `DateTimeOriginal` → TIFF `DateTime` fallback), threaded through `EditEngine` so the stamp uses it, falling back to today only when genuinely absent. **14/15 (93%) of the bundled real photos carried a usable date** — verified directly. Caveat: that read bypasses PHPicker entirely (DebugFixture loads bundled files straight off disk), so it confirms the EXIF-reading code is correct but not, by itself, that PHPicker's `loadFileRepresentation` preserves `DateTimeOriginal` under add-only authorization — Apple documents PHPicker as stripping GPS/location EXIF without full library access while leaving other tags intact, which is why this should hold, but only a real on-device import fully confirms it. If it doesn't, `timestamp` needs to come out of the P0.3 payload contract.

**NEW — crop-clip penalty in scoring.** A 4:5 center crop on a landscape group shot can cut people out, and group shots are the category the product thesis says matter most. `CompositeScoring.clipPenalty` now tests every detected face/human box against the eventual 4:5 crop window and subtracts a proportional penalty from the composite (face-weighted heavily, body lightly, capped so it penalizes rather than rejects). The three existing composite weights are unchanged — the penalty subtracts, it doesn't compete for weight share. Surfaced as a `clip` value in the debug grid. The underlying fix (repositioning the crop itself instead of just penalizing it) is recorded but not built — BUILD_ROADMAP Deferred work register item 10.

**Still unresolved, DO NOT flip the creationDate sign again: the Instagram picker photo order.** Two prior sign inversions both failed to fix it, and the diagnostic that might have told us more just had to be removed (see above, it crashed). Two live, undistinguished hypotheses: (1) Instagram's picker may not sort by `creationDate` at all; (2) a prior "14 duplicate assets for a 7-photo post" incident was never conclusively closed, and if `PHPhotoLibrary.performChanges` still invokes its block more than once, paired assets would carry identical creationDates, breaking any sort regardless of direction. The in-memory invocation counter (kept, Photos-read-free) still watches for (2). Comparing against the stock Photos app's own ordering is the highest-value next step, and it has to happen by eye on-device now — there's no safe way to read the result back in-app.

**Known placeholders/gaps, all flagged in-code:** pack-preview sample imagery is DebugFixture photos (DEBUG-only; real bundled own/licensed sample images don't exist yet — Release builds show empty tiles); the Y2K date stamp's font is system monospace (no bundled Y2K-style font — do not bundle one without asking); the vibe screen's helper text is Inter italic (Caveat isn't bundled); "see how it works" on Welcome is DEBUG-only functional; ImportView's real "choose your vibe" flow still has nothing to curate from in Release builds until Vision scoring exists outside DEBUG (`ScoringService` is still `#if DEBUG`-only — separate, larger, pre-existing gap, BUILD_ROADMAP Deferred work register item 9, not touched this session). The app still doesn't force light mode anywhere except its DEBUG overlay (noted last session, still true, still unscoped).

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
