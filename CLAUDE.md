# CLAUDE.md — duvro

## Read these first, every session
1. `prd.md` — what the app does. **Source of truth for behavior.**
2. `BUILD_ROADMAP.md` — how to build it. Phases, acceptance criteria, gotchas.
3. `UI_NOTES.md` — design system + the fix list correcting the mockups.
4. `duvro-flow.mermaid` — screen map / navigation.
5. `/design/` — Stitch screenshots. **Visual target only. Where a mockup and the PRD/UI_NOTES conflict, the docs win.**

## Current status
**Phase 8 is built and verified on device — Phase 8 acceptance is NOT yet met, for the same shape of reason Phase 4 wasn't.** This session (unsupervised overnight run) added: three new edit ops (lightLeak, polaroidFrame, dateStamp — test suite grew 36→49, all passing); the Digicam and Travel Film pack JSONs (Light Leak/Polaroid/Y2K Digicam, Kodak Style/Faded Postcard/Deep Teal — exact prd.md §6 names); the pack preview sheet (~5 sample images, cached renders, black-pill "use this vibe" CTA, "— duvro" attribution); and the vibe selection screen (photo-count text input wired into `FallbackSelectionService.select(from:count:)`, three pack cards, complete never-truncated variant names). All four verified via on-device `simctl` screenshot, both Simulator and device-target (`generic/platform=iOS`) builds green, Release configuration also confirmed green. Acceptance is unmet because all three packs — Golden Hour included — are still untuned (Deferred work register #1); nobody has run the 10-diverse-photos eyeball test on any of them. This blocks Phase 8 acceptance and TestFlight, not anything downstream: the screens/ops themselves don't change once tuning happens, only values in the three pack JSONs do.

**Known placeholders shipped this session, all flagged in-code:** pack-preview sample imagery is DebugFixture photos (DEBUG-only; real bundled own/licensed sample images don't exist yet — Release builds show empty tiles); dateStamp renders today's date (no EXIF capture-timestamp source yet — isolated behind `EditEngine.currentDateStampText()` for a one-line future swap); dateStamp's font is system monospace and the vibe screen's "7 is the sweet spot" helper is Inter italic (Caveat, UI_NOTES §1's named example, isn't bundled — do not bundle a new font without asking); ImportView's real (non-DEBUG) "choose your vibe" flow hands off to `FallbackSelectionService` correctly but has nothing to curate from until Vision scoring exists outside DEBUG (`ScoringService` is still `#if DEBUG`-only — a separate, larger, pre-existing gap, not touched this session).

**Do not touch: the Instagram picker photo order.** The creationDate-inversion fix (oldest=photo 1) did NOT resolve the real on-device symptom (IG's picker still shows photos reversed) — user is diagnosing with device feedback separately. `ExportService.creationDate` and its stagger logic are working-but-unverified; leave them alone until that diagnosis lands.

See BUILD_ROADMAP's Deferred work register for everything still open (pack tuning — item 1 now covers all three packs, clustering threshold, CategoryMapper reliability, EXIF timestamp capture, the skip-pool redesign, named album, and the new Instagram Mixed-ratio-toggle entry). Update this line at the end of every session.

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
