# PRD — duvro
### AI photo-dump curator + aesthetic editor for Instagram
**Owner:** Adam (Nick Zhao) · **Version:** 1.4 · **Date:** August 1, 2026 · **Status:** Draft
**Identity:** duvro (pron. "dove-roh") · duvro.app · IG @duvro.app · duvro.app@gmail.com

---

## 1. One-liner

Upload your camera roll from a trip or a weekend, tell duvro your vibe, and it picks your best photos, renders each one in 3 aesthetic edits, and hands you a ready-to-post Instagram dump — caption included.

## 2. Why this exists

**User problem:** Gen Z posters (especially girls posting dumps and travelers posting trips) sit on 100+ photos and spend 30–60 minutes agonizing over which to post and how to edit them for a cohesive feed. Existing tools solve slices (Picker AI = selection, ism/Dazz = filters, InstaDump = selection + basic edits) but nobody owns the full "camera roll → posted dump" flow with taste.

**Competitive context:** InstaDump (live, solo dev, est. <$1K MRR) and Autoroll (waitlist) are the direct competitors. Neither has meaningful distribution.

**The real competitive risk is platform absorption, not indie apps.** Apple (Photos) or Instagram could ship "AI select best photos" as a native feature at any time. AI selection is therefore the hook, not the moat. **The moat is taste:** opinionated, named, trend-riding Vibe Packs that make people want *these specific edits* — the one thing a serve-everyone platform structurally won't build. Selection gets the install; taste keeps the user.

**Core quality bar:** the app must make users feel "these are exactly the photos I would've picked, only better." Humans select for emotion (best friend, the 2am moment), not technical quality — so curation must weight emotional signals alongside aesthetics. Recurring-person identity isn't available on-device, so this happens in two places: on-device, group-shot weighting (a photo with more than one person reads as more meaningful than a solo shot); at the model stage, the Stage 2 call infers visually who matters most across the set. A dump must also have compositional variety (people + place + food + detail), never 7 homogeneous "best" shots.

**Business model:** 100% free in v1.

## 3. Target user

**Persona A — "Aesthetic poster" (primary):** 16–24, female, posts dumps every 1–3 weeks, cares deeply about feed cohesion, already uses VSCO/Dazz/ism, discovers apps on TikTok. Trigger moment: "I have 200 photos from this weekend and no idea which ones are good."

**Persona B — "Trip dumper":** 18–30, any gender, posts 1–2x/month after trips/events, lower editing skill, wants the post done fast. Trigger moment: back from a trip, camera roll chaos, posting feels like a chore.

Both personas: iPhone users, personal (not Creator/Business) Instagram accounts.

## 4. Core user flow (screen order is canonical)

1. **Welcome** — one-screen value prop, primary CTA "start a new chapter"; secondary demo entry using bundled sample photos (also serves App Review, which cannot test on an empty photo library).
2. **Import** — user selects 20–200 photos (native photo picker).
3. **Select vibe** — photo count is a **text input field** (numeric keypad) with helper text "7 is the sweet spot"; values below 4 or above 20 trigger a gentle message (4 is the floor — composition variety, people/place/food/detail, can't resolve below that; 20 is the max — that's Instagram's carousel limit); empty/invalid defaults to 7. This is separate from the 20-photo import minimum in step 2. Tapping a pack card opens its preview.
4. **Vibe preview (required step, not optional)** — the pack card opens a sheet with ~5 bundled sample images in that pack's look; its **"use this vibe" button is the CTA that selects the pack AND starts curation.** There is no separate preview link — this forces the user to actually see each aesthetic before committing.
5. **Curation progress** — two stages behind one screen. On-device: Vision rejects junk (blurry, duplicate, screenshot), classifies every photo into people/place/food/detail, clusters near-duplicates, and shortlists the strongest candidates per category (~30 photos total). Then: a single call sends those shortlisted thumbnails plus per-photo metrics to rank, select, and compose the final post. The network call adds real wait time on top of on-device scoring — the progress screen already accommodates an indeterminate duration rather than promising a fixed time (no percentage, runs as long as curation takes; UI_NOTES §4).
6. **Curation showcase (no decisions)** — headline "our favorites". Instead of a static results grid, the chosen photos fade in one at a time, accumulating into a collage (exact timing in UI_NOTES §4), then flow the user **directly** into editing. Rationale: a results screen is a judgment checkpoint where a disappointed user churns; a reveal creates momentum and gets them invested before they evaluate. There is deliberately no accept/reject step here.
7. **3-way edit, per photo** — each photo is shown in the 3 edit variants **of the selected Vibe Pack** (never the pack list again). Tapping a variant pill or swiping horizontally on the photo changes which variant is displayed — pill highlight and photo stay in sync; neither action advances. Variant 1 is pre-selected on arrival, so a user who likes it can advance in one tap. The primary button, **"keep this one,"** commits the currently displayed variant and advances to the next photo; the back control returns to the previous photo with its pick intact and re-editable. An **"advanced"** control opens a sheet with intensity / brightness / contrast / crop for that photo. A quiet "skip this photo" removes a pick the user hates (next-best backfills, keeping composition valid).
8. **Final review ("the final touches")** — after the last edit the user lands here directly; no "ready to post?" branch, no restart invitation. A swipeable Instagram-style carousel of the exact post with drag-to-reorder, per-photo remove, and per-photo adjust. Beneath it: the **"what we left out"** row — adaptive 2–5 runner-ups (sized by emotional near-misses), each with a persistent + to add or swap in.
9. **Caption** — ONE suggestion based on the actual photos + vibe (lowercase-casual), pre-filled and editable, plus regenerate. Single suggestion by design: the user has already made many choices during editing, so this minimizes decision load at the finish.
10. **"Ready when you are" (handoff)** — full-res edited photos are saved in order to the user's **camera roll** (add-only permission requested here), staggered one second apart so they land as the N most recent photos, contiguous, **oldest = photo 1, newest = the last photo** (CHANGED on device — verified that Instagram's picker shows the highest-`creationDate` asset first, the opposite of the "most-recent-first" assumption this originally shipped with) — no named album; a `PHAssetCollectionChangeRequest` to create one crashes under add-only authorization (see BUILD_ROADMAP's Deferred work register, "named album dropped in v1"). Caption copied to clipboard, and the screen shows **visual posting instructions**: ① open Instagram → new post → ② select your N most recent photos, tap them in order → ③ paste your caption. Button: "open Instagram."

## 5. Feature requirements

### P0 — must ship (this IS the app)
| # | Feature | Notes |
|---|---------|-------|
| P0.1 | Photo import via PHPicker | No photo-library permission required — PHPicker reads user-picked photos only. Add-only permission is requested once, at export |
| P0.2 | On-device photo filtering, categorizing & shortlisting | Vision framework: rejects junk (blur, screenshots) below a quality floor; clusters near-duplicates via feature-print similarity; classifies each photo into people/place/food/detail; scores face count and face capture quality. This is nomination, not final selection — Vision narrows 20–200 photos down to a shortlist of the strongest candidates per category (~30 total) for the curation call (P0.3) to choose and compose from |
| P0.3 | Curation call (Stage 2 selection) | One API call, made after Stage 1 shortlisting. Payload per shortlisted photo: a downsampled thumbnail plus exactly five metrics — `category`, `faceCount`, `faceQuality`, `clusterID`, `timestamp` (EXIF DateTimeOriginal). No composite score, `isUtility`, or text coverage is sent — the model judges independently rather than re-ranking Vision's ordering. The model is instructed to center the post on whoever appears most often (inferred visually from the photos, not computed on-device) and to compose across categories. Runs on the shared Vercel/Claude endpoint (§8) |
| P0.4 | Photo count text input | Numeric field, "7 is the sweet spot" helper; count blocked below 4 (composition variety can't resolve below that) or above 20 (Instagram's carousel limit); empty/invalid defaults to 7. Separate from the 20-photo import minimum |
| P0.5 | Composition-aware selection | People/place/food/detail variety; no user decision surface at this stage |
| P0.6 | Curation showcase animation | "our favorites" — staggered fade-in collage of the picks, auto-advances into editing. Exact timing in UI_NOTES §4 |
| P0.7 | 3 Vibe Packs × 3 variants each | Core Image filter pipelines (see §6); variants are pack-specific styles |
| P0.8 | Per-photo 3-way pick + advanced sheet | Signature interaction — tap a pill or swipe the photo to compare the 3 variants (pills stay in sync, neither action advances — UI_NOTES fix 1); variant 1 pre-selected on arrival; primary button commits the displayed variant and advances, back returns to the previous photo with its pick intact; advanced sheet = intensity/brightness/contrast/crop, never occluding or blurring the photo (UI_NOTES §5); "skip this photo" with auto-backfill |
| P0.9 | Final review screen | IG-style swipeable carousel preview, per-photo adjust, drag-to-reorder, remove; adaptive 2–5 "what we left out" row with persistent + to add/swap. No confirm/restart branch — flows forward to caption |
| P0.10 | Handoff with posting instructions | Camera roll save, no album (see §7) + clipboard caption + visual 3-step guide + open Instagram |
| P0.11 | Vibe Pack preview sheet | Tapping a pack card opens it; ~5 bundled sample images in that pack's look (own/licensed photos only, for copyright/App Review reasons); its "use this vibe" button selects the pack AND starts curation |

### P1 — ship if time allows
- Caption generation (single Claude API call with photo thumbnails; ONE editable suggestion + regenerate, not three — shares the curation call's Vercel endpoint, not a separate server (§8); degrade gracefully to templates if offline)
- Share-to-TikTok export (same photos, 9:16 padded)
- Onboarding: 15-second demo with bundled sample photos (also doubles as App Review demo)

### P2 — explicitly out of v1
- "Apply my taste" shortcut (AI learns the user's variant preference from their first ~3 picks and finishes the rest) — deferred: risks the user disliking the final post; test only if TestFlight shows pick fatigue on large dumps
- Generative AI edits (image-model relight/retouch)
- Instagram Stories SDK integration
- Video support
- Android / web
- Accounts, cloud sync, backend (beyond the shared curation + caption endpoint, §8)
- Scheduling, auto-posting
- Monetization

## 6. Vibe Packs (not a feature — the product)

Vibe Packs are the moat (see §2): they're what users come back for and what platforms won't copy. Users don't want "AI" — they want "make this look like the girls on Pinterest." Packs get hero treatment in the UI, branded names treated as marketing assets, and the largest share of build/tuning time.

Each pack = 3 named, handcrafted Core Image pipelines. **The 3 edit variants shown per photo are always the 3 styles of the selected pack** — distinct interpretations of one aesthetic, never a re-offer of the pack menu. Quality bar: testers ask "what filter is this?" unprompted.

**v1 packs:**
1. **Golden Hour** — Sun-kissed · Warm Film · Soft Glow → Persona A default
2. **Digicam** — **Light Leak** (warm red-orange glare wash, vintage film-burn feel) · **Polaroid** (photo composited into a white Polaroid frame on a 4:5 canvas) · **Y2K Digicam** (cool early-digital grade + yellow date/time stamp, bottom corner) → trend-riding
3. **Travel Film** — Kodak Style · Faded Postcard · Deep Teal → Persona B default

New packs ship whenever a good idea comes — no fixed cadence. Pack architecture: JSON-defined filter params so a new pack is a content drop, not an engineering project.

## 7. Instagram integration spec (hard constraints)

- **No auto-posting.** Personal accounts cannot post via Instagram's API (Business/Creator + FB Page only). No private-API workarounds — account-ban risk kills the product.
- **The handoff:** (a) export final edits, in order, to the user's camera roll — staggered `creationDate` one second apart, **oldest first** (CHANGED on device: verified Instagram's picker shows the newest-`creationDate` asset first, not oldest, so the post's first photo has to be the oldest of the batch to appear first there), so the exported post is the N most recent photos; NOT a named album (`PHAssetCollectionChangeRequest` requires more than the add-only permission this app requests — see BUILD_ROADMAP's Deferred work register), (b) copy caption to clipboard ("caption copied — just paste ✨" toast), (c) show the 3-step posting guide (§4 step 10), (d) deep link `instagram://library` (fallback: open Instagram app; fallback: App Store link). ~15 seconds of user effort — acceptable, but all copy says "prepped, not posted."
- **Known limitations:** carousels cannot be pre-loaded into IG's composer; captions cannot be pre-filled. Do not promise either.
- **Mixed aspect ratios:** IG forces every carousel slide into the first photo's ratio — Polaroid variant therefore renders on a standard 4:5 canvas rather than changing the image shape.

## 8. Tech stack & architecture

- **SwiftUI + Swift**, built with Claude Code. First iOS app → keep dependency count at ~zero.
- **No accounts, no login, no user-data backend:** no login screen, no user accounts, no persistence server-side. All photo scoring, clustering, and edit rendering run on the user's iPhone.
- **Vision framework** (on-device): aesthetics scoring, feature prints for similarity, face detection/quality — this is Stage 1 of curation (filtering, categorizing, deduping, shortlisting; see §5 P0.2).
- **Core Image** for all edit rendering (GPU, real-time); CoreGraphics for frame/timestamp composites.
- **One serverless endpoint (Vercel), proxying the Claude API, shared by two features:** the curation call (Stage 2 — ranks, selects, and composes the final post from the on-device shortlist; §5 P0.3) and caption generation (P1). The API key is never embedded in the app. Hard daily spend cap. Nothing is stored server-side, including logs — request bodies (thumbnails, metrics) are not retained.

## 9. Product risks

| Risk | Mitigation |
|---|---|
| Apple or Instagram ships native "AI select best photos" | Moat is taste, not selection: opinionated Vibe Packs, pack brand names, trend speed. Selection is the hook, packs are the retention |
| AI misses an emotionally important photo (the "best friend" problem) | Group boosts; composition variety; "skip this photo" during edits; "what we left out" row at final review; humble "our favorites" framing |
| Selection quality below the "better taste than me" bar | Concrete test: testers hand-pick 7 from their own 100 photos → AI picks must heavily overlap or be rated equal/better. Gate at Phase 3 + 3.5 and TestFlight |
| Showcase-then-edit flow hides a bad selection until late | The final review screen is the safety net: full preview, remove, and runner-up swaps before anything is final |
| Edits look mid → no differentiation | Timebox dedicated days purely on filter tuning against reference photos; test with target-persona users on TestFlight |
| IG handoff friction feels like a broken promise | Posting instructions on the handoff screen; copy everywhere says "prepped, not posted" |
| Per-session API cost runs against a "100% free" product | Hard daily spend cap on the Vercel endpoint; payload is deliberately small (~30 downsampled thumbnails + 5 metrics each, not the full roll); measure real per-session cost pre-launch and revisit if it doesn't hold at scale |
| Added latency (the curation network round-trip) delays the showcase — the app's signature, most screen-recordable moment | Curation progress screen already accommodates an indeterminate wait (no percentage; UI_NOTES §4); keep the Stage 2 payload minimal to bound call time; measure end-to-end curation time on TestFlight and re-tune if it dulls the showcase's impact |
| Offline or endpoint failure blocks curation entirely | Needs a fallback so a user without a connection still gets a post — see BUILD_ROADMAP's offline-fallback note (flagged there as a decision made under time pressure, may be revisited) |

**Noted for the record, not yet scheduled:** the curation call transmits photo thumbnails off-device, which the on-device privacy claims elsewhere in this doc no longer cover unconditionally. Before TestFlight this needs: App Store privacy labels updated to declare photo data as transmitted (not just processed on-device); confirmation that the Vercel endpoint does not log request bodies (thumbnails or metrics); and a legal review of transmitting images containing identifiable faces to a third-party model API. None of this blocks the current build — recording it here so it isn't lost by the time TestFlight is close.

## 10. Open questions

*Resolved:* sample photo set is required (P1, doubles as App Review demo). Showcase style is a staggered fade-in collage, not hard cuts (UI_NOTES §4). Bundle identifier is `app.duvro.duvro` (set at Phase 0 project creation). Serif face is **Newsreader**, used for display headlines and pack names; **Inter** is used for UI and body text (see UI_NOTES §1).
