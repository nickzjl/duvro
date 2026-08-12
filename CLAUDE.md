# CLAUDE.md — duvro

## Read these first, every session
1. `prd.md` — what the app does. **Source of truth for behavior.**
2. `BUILD_ROADMAP.md` — how to build it. Phases, acceptance criteria, gotchas.
3. `UI_NOTES.md` — design system + the fix list correcting the mockups.
4. `duvro-flow.mermaid` — screen map / navigation.
5. `/design/` — Stitch screenshots. **Visual target only. Where a mockup and the PRD/UI_NOTES conflict, the docs win.**

## Current status
**Phase 8 acceptance is still NOT met (packs untuned — unchanged), but the app gained a real root screen, a caption screen, and a real-device-blocking bug fix this session (unsupervised overnight run).** Welcome is now the app's actual root (prd.md §4 step 1, previously missing from every phase checklist — fell through; RootFlowView swaps Welcome/ImportView, no NavigationStack). Caption (Phase 9's UI half) is built and inserted between Final Review and Handoff at all 6 real/DEBUG call sites — `CaptionService`'s `TemplateCaptionService` is real offline-fallback code (BUILD_ROADMAP Phase 9's own acceptance line), not a stub; the network implementation drops in behind `CaptionServiceProtocol` later. 53/53 tests passing (was 36 at session start). Simulator, Release-configuration, and device-target builds all green throughout.

**FIXED: white screen after "use this vibe" on the real device path.** Root cause: `handleVibeSelected` dismissed one `fullScreenCover` while presenting a sibling one in the same synchronous callback that itself fired from inside a nested `.sheet`'s own `dismiss()` — three presentation-layer transitions racing in one tick; UIKit silently drops the new presentation instead of crashing. Fixed by collapsing the real flow's four separate `fullScreenCover`s into one persistent cover with content-swapping state (matching the DEBUG "vibe select" button's already-proven pattern). Verified via a scripted state transition (not an interactive tap — see the session's own report for why), not yet re-confirmed on a physical device. **Known residual risk, not fixed:** ImportView's DEBUG "edit"/"review" chain uses the same multi-cover dismiss+present pattern (without the nested-sheet trigger that broke the real flow, so likely fine) — restructuring it to the same safe pattern is a clean recommended follow-up.

**Still unresolved, DO NOT flip the creationDate sign again: the Instagram picker photo order.** Two prior sign inversions both failed to fix it. This session traced the whole export pipeline (loop order, array order, handle-call order) and found no reordering bug — the stagger reaches each photo in its correct sequence. Two live, undistinguished hypotheses: (1) Instagram's picker may not sort by `creationDate` at all (best fit for "two inversions, no change either time" — unverifiable from code, no visibility into third-party app behavior); (2) a prior session's "14 duplicate assets for a 7-photo post" incident was never conclusively closed — if `PHPhotoLibrary.performChanges` is still invoking its block more than once, paired assets would carry identical creationDates, breaking any sort regardless of direction. New DEBUG-only instrumentation added to `ExportService.saveAll` (fetches back the exact assets just created, logs actual persisted count + creationDates) — next real export's console output should distinguish these; compare against the stock Photos app's own ordering as the highest-value next step.

**Known placeholders/gaps, all flagged in-code:** pack-preview sample imagery is DebugFixture photos (DEBUG-only; real bundled own/licensed sample images don't exist yet — Release builds show empty tiles); dateStamp renders today's date and uses the system monospace font (no EXIF timestamp source, no bundled Y2K-style font); the vibe screen's helper text is Inter italic (Caveat isn't bundled); "see how it works" on Welcome is DEBUG-only functional (loads the fixture, jumps to vibe select) — unwired in Release, no bundled demo assets exist yet; ImportView's real "choose your vibe" flow still has nothing to curate from in Release builds until Vision scoring exists outside DEBUG (`ScoringService` is still `#if DEBUG`-only — separate, larger, pre-existing gap). **New this session:** the app doesn't force light mode anywhere except its DEBUG overlay — discovered when the Simulator's system appearance silently switched to Dark mid-session and a product screen rendered with the wrong background; not fixed (app-wide dark-mode support is unscoped, undecided).

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
