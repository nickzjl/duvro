# CLAUDE.md — duvro

## Read these first, every session
1. `prd.md` — what the app does. **Source of truth for behavior.**
2. `BUILD_ROADMAP.md` — how to build it. Phases, acceptance criteria, gotchas.
3. `UI_NOTES.md` — design system + the fix list correcting the mockups.
4. `duvro-flow.mermaid` — screen map / navigation.
5. `/design/` — Stitch screenshots. **Visual target only. Where a mockup and the PRD/UI_NOTES conflict, the docs win.**

## Current status
**Phase 2 complete — Phase 3 next (redefined this session).** Verified on physical device: 100 photos scored in 2.24s (limit 15s); 200-photo peak memory 167MB import / 155MB scoring (limit 400MB); debug-grid composites match the renormalized formula against pre-change baselines. The screenshot-categorization bug noted in earlier status lines was fixed after that device pass (label-based hard reject, independent of `isUtility` — see `CompositeScoring.swift`) and is no longer open. This session was **docs-only**: pivoted curation to a two-stage funnel (on-device Vision shortlist → one Claude API call for final selection) across prd.md / BUILD_ROADMAP.md / CLAUDE.md / UI_NOTES.md; no Swift file was touched. BUILD_ROADMAP's Phase 3 is now shortlist-only (~30 candidates, not a post), with a new Phase 3.5 for the curation call — read both before resuming Phase 3. Update this line at the end of every session.

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
Phase 3 contains the **overlap test**: real users hand-pick 7 photos from their own ~100, and duvro's picks must overlap ≥4/7 or be rated equal/better. If it fails, stop and re-tune scoring before building anything downstream. Nothing else in the app matters if selection is bad.
