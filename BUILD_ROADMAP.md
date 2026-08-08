# BUILD ROADMAP — duvro
### Implementation spec + phase checklist for Claude Code
Companion to `prd.md` (v1.4), `UI_NOTES.md` (design system, motion spec, mockup fix list), and `duvro-flow.mermaid` (screen map). This file tells Claude Code *how* to build; the PRD says *what*; UI_NOTES says *how it looks*. The PRD's §4 screen order is canonical: welcome → import → select vibe (+count input) → vibe preview sheet (its CTA starts curation) → curation progress → curation showcase → 3-way edit (+advanced) per photo → final review (+runner-ups) → caption → ready-when-you-are.

## Product thesis (read before writing any code)

1. **Taste is the moat; selection is the hook.** Apple/Instagram can ship "AI select best photos" natively — they can't ship opinionated Pinterest-girl aesthetics. Vibe Packs are the product; the selection AI is the demo that earns the install. Allocate polish time accordingly.
2. **Vision nominates, the model selects.** On-device Vision is reliable at mechanical filtering — screenshots, near-duplicates, face/body counts, capture quality, category — but it scores technical quality, not "does the user look good" or who matters emotionally. A blurry photo with the user's best friend beats a perfect sunset, so the final call goes to a model that can judge a curated set the way a person would, not a composite score. Vision narrows a roll to a shortlist per category (Phase 3); the model composes the final *varied* dump (people/place/food/detail, people-first) from that shortlist (Phase 3.5). Users forgive mediocre edits before they forgive bad photo choices.
3. **Momentum over judgment.** Curation results are revealed as an animated showcase (exact timing in UI_NOTES §4) that flows straight into editing — never a static results grid that invites the user to sit and judge the AI. Corrections happen late (skip during edits; remove/swap at confirmation), after the user is invested.
4. **Humility in copy.** "our favorites ✨" — never "the best photos." "what we left out" — never "rejected." A wrong pick should feel like a taste difference, not a malfunction.
5. **The bar:** users should feel "these are exactly the photos I would've picked, only better." Tested, not vibed — see the overlap test in Phase 3.

## 0. Ground rules for Claude Code

- **Stack:** Swift 5.10+, SwiftUI only (no UIKit view controllers except where required, e.g., PHPicker wrapper), **zero third-party dependencies**.
- **Min target: iOS 18.0.** This unlocks `VNCalculateImageAestheticsScoresRequest` (built-in aesthetic scoring + screenshot/utility detection), replacing an entire custom ML pipeline. Target audience (16–24) updates iOS fast.
- **Devices:** iPhone only, portrait only.
- **Privacy architecture:** on-device by default. `PHPickerViewController` requires NO photo library permission for reading (user-picked photos only). The only permission the app requests is **add-only** photo access (`NSPhotoLibraryAddUsageDescription`) for saving finished edits, requested at export time, not launch. One exception: the curation call (Phase 3.5) and captions (Phase 9) share a single serverless endpoint (Vercel) proxying the Claude API — a shortlist of downsampled, low-resolution thumbnails plus per-photo metrics leaves the device for that call. API key never ships in the app; hard daily spend cap; nothing stored server-side, including logs.
- **Performance rules:** downsample every imported photo to ≤1280px longest side immediately for all scoring/preview work; keep originals in a temp-file store; full-resolution rendering happens ONCE, at export. Never hold 200 full-res UIImages in memory.
- **Vertical slices:** every phase ends with a runnable app. Do not start phase N+1 until phase N's acceptance checks pass.
- **Workflow per task:** implement → build (`xcodebuild`) → run in simulator → screenshot (`xcrun simctl io booted screenshot out.png`) → verify against acceptance criteria → commit. Small commits, one per checklist item.
- **Simulator note:** seed the simulator photo library with 100+ varied test photos (`xcrun simctl addmedia booted <files>`), including blurry shots, bursts/near-duplicates, screenshots, food, portraits, landscapes.

## 1. Project structure

```
duvro/
├── App/                    DuvroApp.swift, RootView (flow coordinator)
├── Models/                 Photo.swift (id, tempURL, thumbnail, scores, category), VibePack.swift, EditVariant.swift, Session.swift
├── Services/
│   ├── PhotoImportService  PHPicker wrapper → [Photo]
│   ├── ScoringService      Vision requests, concurrent (TaskGroup)
│   ├── CurationService     rejection + emotional boosts + composition selection
│   ├── EditEngine          JSON pack → CIFilter chain → rendered variants (+ frame/timestamp composites)
│   ├── ExportService       album creation, ordered save, clipboard, deep link
│   └── CaptionService      (P1) calls Vercel endpoint
├── Views/                  one folder per flow step (Welcome, Import, VibeSelect, PackPreview, CurationProgress, Showcase, PickEdits, Confirm, Caption, Handoff)
├── Packs/                  golden_hour.json, digicam.json, travel_film.json + preview sample images
└── DuvroTests/             unit tests for scoring thresholds, pack parsing, selection logic
```

State: one `@Observable` `SessionStore` owning the flow (photos → scores → selection → picks/tweaks → export). No persistence in v1 — a session is ephemeral.

---

## 2. Phase checklist

### Phase 0 — Project setup
- [ ] Create Xcode project (bundle id `app.duvro.duvro`)
- [ ] Git init, `.gitignore` for Xcode, first commit
- [ ] Add `CLAUDE.md`: paste "Ground rules" + product thesis + current phase status (keep updated every session)
- [ ] Min deployment iOS 18, portrait lock, iPhone only
- [ ] Confirm signing works; app runs on Adam's physical iPhone
- **Accept:** blank app launches on device.

### Phase 1 — Photo import
- [ ] `PhotoImportService`: PHPicker wrapper, `.images` filter, selection limit 200, no library permission prompt
- [ ] On import: copy originals to temp dir, generate ≤1280px downsamples + 200px thumbnails (ImageIO thumbnailing, not UIImage resizing)
- [ ] Import screen per design system; grid of thumbnails with count
- [ ] Memory check: import 200 photos, memory stays < 400MB
- **Accept:** 200-photo import completes, grid scrolls at 60fps, no permission dialog appears.

### Phase 2 — Scoring engine
- [ ] `ScoringService`, concurrent (TaskGroup, max ~4 in flight):
  - [ ] `VNCalculateImageAestheticsScoresRequest` → `overallScore` and `isUtility`. Reject decision (see `CompositeScoring.swift`) is (a) `VNClassifyImageRequest` label `screenshot` ≥ 0.5 confidence, OR (b) `isUtility` AND normalized aesthetic below a floor — `isUtility` alone proved unreliable on real photos (fires on plated food and gym-bench shots as readily as receipts), so it only rejects paired with a low aesthetic score
  - [ ] `VNGenerateImageFeaturePrintRequest` → feature print per photo (similarity)
  - [ ] `VNDetectFaceRectanglesRequest` + `VNDetectFaceCaptureQualityRequest` → face count + best face quality
  - [ ] **Group-shot boost (the best-friend fix, identity-free):** 2+ faces → bonus. A general Vision feature print encodes lighting/framing/composition, not identity — recurring-person detection via face-crop clustering was tried and removed (design-level dead end, not a bug; see git history). Group-shot weighting carries the emotional-signal intent without needing to recognize *who* is in the photo
  - [ ] `VNClassifyImageRequest` → map labels to dump categories: `people` / `place` / `food` / `detail`
  - [ ] Blur check only if aesthetics score proves insufficient (Laplacian variance via vImage)
- [ ] Composite score (starting point, debug grid decides): `0.5714*aesthetic + 0.2857*faceQuality + 0.1429*groupBonus` (i.e. 4/7, 2/7, 1/7 -- the original 0.4/0.2/0.1 proportions renormalized after dropping importantPerson and sharpness, see CompositeScoring.swift); utility → reject
- [ ] DEBUG-only grid overlay showing every photo's scores + category (this is the tuning tool — build it well)
- **Accept:** 100 photos scored in ≤15s on a real iPhone; screenshots flagged; scores eyeball-correct on the debug grid.

### Phase 3 — On-device shortlist (reject, categorize, dedupe, shortlist)
Output of this phase is a **shortlist of ~30 candidates, not a final post.** Vision nominates here; it does not select — narrowing happens per category, final judgment happens in Phase 3.5.
- [ ] **Photo count text input** on the vibe screen: numeric keypad, helper text "7 is the sweet spot"; values < 4 blocked with a gentle note (composition variety — people/place/food/detail — can't resolve below 4); values > 20 blocked with "20 is the max — that's Instagram's carousel limit"; import requires ≥20 photos selected (separate from this floor); empty/invalid defaults to 7. This count is consumed downstream by the Phase 3.5 curation call — it does not change Stage 1's shortlist size (~30)
- [ ] Rejection pass: utility images, score floor, near-black/near-white exposure
- [ ] Near-duplicate clustering: pairwise feature-print distance (`ClusteringService`, a separate pass after all per-photo scoring completes, single-link via union-find). At most 3 photos per cluster may enter the shortlist — the cluster's top 3 by composite score, reached by a skip-and-continue fill rather than picking a single strongest representative: a burst usually has more than one usable shot, and Phase 3.5 is better placed to choose between them than a composite score is (distance threshold start 0.55, tune with real bursts)
- [ ] **Per-category shortlist:** within each of people/place/food/detail, keep Vision's top-scoring surviving candidates (target ~30 total across categories, weighted toward people). This is nomination, not final selection — permissive, not judgmental. When in doubt, keep the photo in the shortlist; the Phase 3.5 curation call decides
- **Accept:** (a) burst of 10 near-identical selfies + 50 mixed → the shortlist keeps only the cluster's strongest representative, not all 10; (b) shortlist output is ~30 candidates spanning every category that has viable photos, never empty for one that does; (c) rejection pass flags utility/exposure failures without over-firing on ordinary photos. **Phase 3 does not get signed off on its own** — its output is a shortlist, not a post, so the real acceptance gate (the overlap test, Product Thesis §5) only becomes testable once Phase 3.5 exists. Do not build past Phase 3.5 without that gate passing.

#### Known issues from the first device run (deferred)
First on-device run: 200 imported, 66 rejected, 134 surviving, 22 shortlisted (target ~30). Clustering + shortlist took 0.010s. Three problems and one product decision below, none fixed this session — deferred on purpose, don't retune/refactor around them without reading this first.

1. **Clustering threshold too loose.** At 0.55, single-link agglomerative clustering produced 26 clusters from 134 surviving photos, the largest containing 91 — 68% of the roll in one cluster. Single-link chains transitively (A merges with C whenever both are within threshold of B), so a loose threshold collapses everything. This starved the shortlist: the 3-per-cluster cap meant that 91-photo cluster contributed only 3 candidates, which is why the shortlist came in at 22 instead of ~30. Distribution: 21 clusters of size 1, one of size 2, two of size 3, two of size 5+. Next attempt: 0.35, then 0.25, until the largest cluster looks like a plausible burst (~5–15 photos).
2. **Category mapping is unreliable, and `place` is effectively dead.** Distribution across all 134 surviving photos: people 88, place 1, food 10, detail 35. The single `place` photo was a black screen. The roll contains real scenery, so outdoor/landscape labels are not routing to `place` — the same failure mode as `screenshot` falling through to `people` before the label-reject fix. Misrouting is broad: a toilet categorized as `food`, food photos landing in `people` and `detail`, a gym machine and stacked rocks in `detail`.
3. **Vision's aesthetics model is mis-calibrated for the target audience.** It scores technical photo quality. The photos this audience posts are often deliberately imperfect — reflections in windows, motion blur, grainy flash shots at night — and the model scores those down. The model's output cannot be retrained; how much the pipeline relies on it is still open. Question for Phase 3.5: how much ranking should move to the Stage 2 model, and whether composite score should rank the shortlist at all. To be decided from real testing.
4. **Product decision: no hardcoded composition quotas in selection.** Enforcing people/place/food/detail variety assumes every dump wants variety. It doesn't: a trip dump can be all scenery, a night out can be all people, and some users post only selfies. Forcing a token food photo into a roll that has one good food photo makes the post worse. Categories are still computed and still sent to Stage 2 as context, but the model decides composition from what the roll actually contains. This supersedes the composition-variety language in prd.md §2, P0.5, and this file's Phase 3.5 — flagged for a doc pass, not fixed here.

### Phase 3.5 — Curation call (Stage 2 selection)
Inserted after Phase 3, before Phase 4 (edit engine). This phase is what turns Phase 3's shortlist into an actual post — Phase 3's overlap-test gate is only truly evaluable once this phase exists.
- [ ] Vercel serverless function (curation endpoint — shared infrastructure with Phase 9's caption endpoint, see Project Structure): accepts the Stage 1 shortlist (~30 downsampled thumbnails + per-photo metrics — `category`, `faceCount`, `faceQuality`, `clusterID`, `timestamp`), the desired photo count (4–20, from the vibe screen's count input), and the vibe name → Claude API → ranked/selected photo IDs in final post order. No composite score, `isUtility`, or text coverage sent (see prd.md §5 P0.3 for the exact payload contract — the model must judge independently, not re-rank Vision's ordering). Hard daily budget cap; no image/request-body logging; static app token + IP rate limit
- [ ] `CurationService` calls the endpoint after Stage 1 shortlisting completes; on success, the returned selection replaces the shortlist as the session's chosen set
- [ ] **Composition-aware result:** the prompt instructs the model to compose across categories (people/place/food/detail, people-first) and to center the post on whoever appears most often (inferred visually from the thumbnails, not computed on-device). A dump of 7 sunsets from a people-heavy roll is a failure even if Vision scored them highest
- [ ] Compute and store the runner-up set for the final review screen: the shortlisted-but-not-chosen photos, adaptively sized 2–5 (many close misses → 5, clean separation → 2)
- [ ] **Curation showcase (replaces any results grid):** staggered fade-in collage of print-bordered cards — the user's chosen photos (Stage 2's output, not the raw shortlist) fade in one at a time (per-card 1.2s ease-out, opacity 0→1 with y offset +10pt→0, rotation 0°), overlapping with varied z-order and size, then auto-advances into the edit flow. No buttons, no decisions, no scores. UI_NOTES §4 is the authority for exact timing — see also the duration formula there (stagger scales with photo count, not a fixed 0.2s)
- [ ] **Offline / endpoint-failure fallback:** if the curation call fails or there's no network, fall back to an on-device-only ranking of the Stage 1 shortlist (composite score + composition-aware selection against the requested count) so the user still gets a post, never a dead end. Flagged in UI_NOTES as a decision made under time pressure — may be revisited
- **Accept:** (a) a roll with obvious people-shots never yields an all-landscape dump; (b) showcase runs smoothly on the Stage 2 result and lands on photo 1's edit screen with variants already rendered; (c) an offline run still produces a post via the fallback path; (d) **overlap test** (via debug build — this is the Product Thesis §5 gate, first executable here since this is the first phase where the full pipeline exists): 3 real users hand-pick 7 from their own ~100 photos → full pipeline (Stage 1 shortlist + Stage 2 selection) overlap ≥4/7 OR user rates the AI set good/better. If this fails, stop and re-tune — Stage 1's shortlist thresholds, the Stage 2 prompt, or both — before building anything downstream (Phase 4+).

### Phase 4 — Edit engine + first Vibe Pack
- [ ] `VibePack` JSON schema: 3 variants per pack; ops incl. `toneCurve`, `colorControls`, `temperatureTint`, `vignette`, `bloom`, `grain`, `halation`, `fade`, `lightLeak` (radial warm gradient, screen/lighten blend, edge-weighted), `polaroidFrame` (composite onto white frame on 4:5 canvas via CoreGraphics), `dateStamp` (yellow digital timestamp, bottom corner)
- [ ] `EditEngine`: parse JSON → CIFilter chain → render; one Metal `CIContext` app-wide; previews from 1280px downsamples
- [ ] Build **Golden Hour** (Sun-kissed / Warm Film / Soft Glow) — tune against reference boards on the debug grid
- [ ] Unit tests: pack parsing; malformed pack → safe fallback (original photo)
- **Accept:** any photo renders 3 variants <1s each on device; Golden Hour looks good on 10 diverse test photos, not just one.

### Phase 5 — 3-way edit screen (the signature interaction)
- [ ] Per photo: ONE large photo + three variant pills below (approved layout — do NOT use a three-up grid). **Horizontal swipe on the photo moves between the 3 variants of the selected pack, pills highlight in sync.** Pre-render all three so switching is an instant crossfade. Progress "3 of 7" at top. Never re-show the pack menu
- [ ] **"advanced"** control → compact bottom sheet (~35% detent): intensity (blends original↔edited), brightness, contrast, crop. **No backdrop blur, no dimming — the photo must stay fully visible and scale up into the remaining space.** Live rendering (no "apply" step); hold-to-compare with original. Full spec: UI_NOTES §5. Settings remembered per photo
- [ ] **"skip this photo"** (quiet placement): removes the pick; next-best backfills respecting composition; if nothing viable remains, dump size shrinks by one
- [ ] Pre-render next photo's variants in the background (zero perceived wait); haptic on selection; hold-to-see-original
- **Accept:** picking through a 7-photo dump feels fast; no spinner ever visible; advanced tweaks and skip round-trip without losing state.

### Phase 6 — Final review screen ("the final touches")
- [ ] Lands here directly after the last edit — NO "ready to post? / take another look" branch (see UI_NOTES §3)
- [ ] **Instagram-style swipeable carousel preview** of the exact post (correct order, edited images, uniform 4:5)
- [ ] Per-photo adjust (same advanced sheet), remove photo, drag-to-reorder via thumbnail strip
- [ ] **"what we left out"** row: the stored adaptive 2–5 runner-ups, **persistent + on each thumbnail** (no hover states — touch only), tap to **add** (if under count) or **replace**; newly added photos route through the 3-way edit before joining
- [ ] All copy per voice rules ("our favorites")
- **Accept:** preview matches final export 1:1; add/replace/remove/reorder all round-trip correctly; runner-up count varies with near-miss data.

### Phase 7 — Export + "ready when you are"
- [ ] Request add-only photo permission (first time here)
- [ ] Render FULL-RES from originals with each photo's variant + tweaks (background task, progress)
- [ ] Create/find album **"duvro — ready to post"**; save in carousel order with staggered `creationDate` (1s apart, newest = photo 1) so IG's picker shows them in order
- [ ] Copy caption (placeholder until Phase 9) to `UIPasteboard`; toast "caption copied — just paste ✨"
- [ ] **Posting instructions UI:** visual 3-step guide — ① open Instagram → new post ② select the duvro album, tap photos in order (numbered) ③ paste your caption
- [ ] Open Instagram: `instagram://library` → fallback `instagram://app` → fallback App Store link. Test all paths
- **Accept (US tester / brother via TestFlight):** photos appear in IG's picker in correct order at full quality; caption pastes; a first-time user completes posting from the instruction screen without help.

### Phase 8 — Remaining packs + pack preview
- [ ] **Digicam** pack: **Light Leak** (warm red-orange glare, per reference) / **Polaroid** (white frame on 4:5 canvas) / **Y2K Digicam** (cool early-digital grade + yellow timestamp)
- [ ] **Travel Film** pack: Kodak Style / Faded Postcard / Deep Teal
- [ ] Pack preview sheet: tapping a pack card opens it → ~5 bundled sample images rendered with the pack (own/licensed images; render at build or first launch and cache); sheet CTA "use this vibe" both selects the pack and starts curation
- [ ] Vibe select screen final: pack cards with cover imagery, full variant names (see UI_NOTES fix #3), no separate preview link
- **Accept:** all 3 packs pass the 10-diverse-photos eyeball test; previews load instantly; taste bar — at least one TestFlight tester asks "what filter is this?" unprompted. Packs are the product: if a pack is merely fine, keep tuning.

### Phase 9 — Captions (P1)
- [ ] Vercel serverless function: ≤7 small thumbnails (256px, JPEG q0.5) + vibe name → Claude API (haiku-class) → caption JSON. Hard daily budget cap; no image logging; static app token + IP rate limit
- [ ] `CaptionService`: ONE pre-filled editable suggestion + regenerate (not three — see UI_NOTES §3), offline fallback to canned templates per vibe
- **Accept:** captions <4s, lowercase-casual voice, never block export when offline.

### Phase 10 — Ship
- [ ] Onboarding: 3-screen intro OR 15s auto-demo with bundled sample photos
- [ ] App icon (outsourced — the #1 conversion asset; don't ship an AI-generated icon)
- [ ] Empty/error states: import canceled, zero photos pass curation, Instagram not installed, no network (captions), photo-permission denied at export
- [ ] App Store assets: screenshots showing the 3-way pick + showcase; subtitle with ASO keywords ("photo dump", "aesthetic editor")
- [ ] Privacy nutrition label (photos processed on device, not collected; caption endpoint transmits thumbnails, not stored)
- [ ] TestFlight → 5 persona testers + brother (IG handoff verification) → fix round → submit (reviewer notes: sample photos bundled for demo; Instagram account not required)

---

## 3. Design system

**`UI_NOTES.md` is the authority for all visual and motion decisions — read it before building any screen.** This section is a summary only; where the two differ, UI_NOTES wins.

**Direction:** warm editorial. Mockup screenshots live in `/design/` as visual targets (screenshot-vs-screenshot loop), but they were assembled from several Stitch directions and contain known errors — UI_NOTES §2 and §6 list every correction.

- **Fonts:** display = Newsreader (serif, OFL, bundled); UI/body = Inter. Max 2 fonts
- **Colors:** background Warm Ivory `#F7F4EE`; elevated Pure Cream `#FFFCF7`; secondary surface Soft Paper `#EEE9DF`; primary text Ink Black `#171614`; secondary Warm Gray `#777169`; muted Stone `#A7A097`; accent Terracotta `#A04021` (pressed `#7F3319`); divider Hairline Beige `#DDD6CA`; success Muted Sage `#71816C`
- **Shape/space:** 8pt grid; 20pt page padding; buttons 54pt tall, full-radius pill (27pt at 54pt); cards 12–18pt radius, continuous corners; sheets 28pt radius; shadows y4/blur18/6% max — prefer borders and tonal separation
- **Texture:** 2–4% film-grain overlay; photos dominate every screen (60–80% of visual area)
- **Copy voice:** humble bestie, lowercase-leaning, never authoritative. "our favorites" not "Best Photos"; "almost made it" not "Rejected"; "ready when you are" not "Export Complete". No exclamation-point salesmanship. Never "AI optimized" / "algorithmically ranked" / "perfect photos"
- **Prune from Stitch output when translating:** profile avatars, menu icons, "STEP X OF 6" overlines, any account-implying chrome — duvro has no accounts
- **Pack-first hierarchy:** vibe-select is the emotional home; pack cards get the richest treatment
- Claude Code: match tokens exactly; when in doubt, more whitespace and fewer elements

## 4. Known gotchas

1. `instagram://library` behavior changes between IG versions — deep links are best-effort; the fallback chain and the instruction screen are mandatory.
2. PHPicker delivers HEIC/JPEG/PNG — normalize via ImageIO; preserve orientation via `CGImagePropertyOrientation`.
3. CIImage coordinates are flipped vs UIKit — crop math bugs live here.
4. Feature-print distance thresholds differ by photo type (selfie bursts cluster tighter than landscapes) — tune on the debug grid.
5. Full-res rendering of up to 20 photos can spike memory — render sequentially, autorelease per photo.
6. IG carousels force every slide into the first photo's aspect ratio — hence Polaroid renders on a 4:5 canvas instead of changing image shape.
7. App Review: the app must be fully usable ending at "saved to your photos" even if Instagram isn't installed.
8. Numeric text field: use `.keyboardType(.numberPad)` + input filtering; don't let the keyboard cover the field (scroll/inset handling).
