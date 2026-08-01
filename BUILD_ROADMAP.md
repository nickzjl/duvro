# BUILD ROADMAP — duvro
### Implementation spec + phase checklist for Claude Code
Companion to `prd.md` (v1.4), `UI_NOTES.md` (design system, motion spec, mockup fix list), and `duvro-flow.mermaid` (screen map). This file tells Claude Code *how* to build; the PRD says *what*; UI_NOTES says *how it looks*. The PRD's §4 screen order is canonical: welcome → import → select vibe (+count input) → vibe preview sheet (its CTA starts curation) → curation progress → curation showcase → 3-way edit (+advanced) per photo → final review (+runner-ups) → caption → ready-when-you-are.

## Product thesis (read before writing any code)

1. **Taste is the moat; selection is the hook.** Apple/Instagram can ship "AI select best photos" natively — they can't ship opinionated Pinterest-girl aesthetics. Vibe Packs are the product; the selection AI is the demo that earns the install. Allocate polish time accordingly.
2. **Humans pick for emotion, vision models pick for quality.** A blurry photo with the user's best friend beats a perfect sunset. Scoring must weight recurring people and groups; selection must produce a *varied* dump (people/place/food/detail), not a homogeneous quality ranking. Users forgive mediocre edits before they forgive bad photo choices.
3. **Momentum over judgment.** Curation results are revealed as a ~3s animated showcase that flows straight into editing — never a static results grid that invites the user to sit and judge the AI. Corrections happen late (skip during edits; remove/swap at confirmation), after the user is invested.
4. **Humility in copy.** "our favorites ✨" — never "the best photos." "what we left out" — never "rejected." A wrong pick should feel like a taste difference, not a malfunction.
5. **The bar:** users should feel "these are exactly the photos I would've picked, only better." Tested, not vibed — see the overlap test in Phase 3.

## 0. Ground rules for Claude Code

- **Stack:** Swift 5.10+, SwiftUI only (no UIKit view controllers except where required, e.g., PHPicker wrapper), **zero third-party dependencies**.
- **Min target: iOS 18.0.** This unlocks `VNCalculateImageAestheticsScoresRequest` (built-in aesthetic scoring + screenshot/utility detection), replacing an entire custom ML pipeline. Target audience (16–24) updates iOS fast.
- **Devices:** iPhone only, portrait only.
- **Privacy architecture:** everything on-device except the P1 caption endpoint. `PHPickerViewController` requires NO photo library permission for reading (user-picked photos only). The only permission the app requests is **add-only** photo access (`NSPhotoLibraryAddUsageDescription`) for saving finished edits, requested at export time, not launch.
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
- [ ] Create Xcode project (bundle id `com.duvro.app` or matching final identifier)
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
  - [ ] `VNCalculateImageAestheticsScoresRequest` → `overallScore` and `isUtility` (screenshots/receipts → hard reject)
  - [ ] `VNGenerateImageFeaturePrintRequest` → feature print per photo (similarity)
  - [ ] `VNDetectFaceRectanglesRequest` + `VNDetectFaceCaptureQualityRequest` → face count + best face quality
  - [ ] **Recurring-person detection (the best-friend fix):** crop faces → feature-print the crops → cluster across the session; photos containing a person from a large cluster get an "important person" boost. No identity, no names, on-device, discarded after session
  - [ ] **Group-shot boost:** 2+ faces → bonus
  - [ ] `VNClassifyImageRequest` → map labels to dump categories: `people` / `place` / `food` / `detail`
  - [ ] Blur check only if aesthetics score proves insufficient (Laplacian variance via vImage)
- [ ] Composite score (starting point, debug grid decides): `0.4*aesthetic + 0.25*importantPerson + 0.2*faceQuality + 0.1*groupBonus + 0.05*sharpness`; utility → reject
- [ ] DEBUG-only grid overlay showing every photo's scores + category (this is the tuning tool — build it well)
- **Accept:** 100 photos scored in ≤15s on a real iPhone; screenshots flagged; scores eyeball-correct on the debug grid.

### Phase 3 — Curation + count input + showcase
- [ ] **Photo count text input** on the vibe screen: numeric keypad, helper text "7 is the sweet spot"; values > 20 blocked with "20 is the max — that's Instagram's carousel limit"; import requires ≥20 photos selected; empty/invalid defaults to 7
- [ ] Duplicate clustering: pairwise feature-print distance; greedy selection by composite score with distance threshold (start 0.55, tune with real bursts)
- [ ] **Composition-aware selection:** enforce category variety (7-dump target ≈ 3–4 people / 2 place / 1 food / 1 detail; degrade gracefully; people-first). A dump of 7 sunsets is a selection failure even if they score highest
- [ ] Rejection pass: utility images, score floor, near-black/near-white exposure
- [ ] **Curation showcase (replaces any results grid):** ~3s animated reveal flashing through the chosen photos (fast crossfade or hard-cut montage per design direction), auto-advancing into the edit flow. No buttons, no decisions, no scores
- [ ] Compute and store the adaptive runner-up set now (2–5 emotional near-misses; many near-misses → 5, clean separation → 2) for use on the final review screen
- **Accept:** (a) burst of 10 near-identical selfies + 50 mixed → exactly one from the burst; (b) a roll with obvious people-shots never yields an all-landscape dump; (c) showcase runs smoothly and lands on photo 1's edit screen with variants already rendered; (d) **overlap test** (via debug build): 3 real users hand-pick 7 from their own ~100 photos → AI overlap ≥4/7 OR user rates the AI set good/better. If this fails, stop and re-tune before further phases.

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
- [ ] **"what we left out"** row: the stored adaptive 2–5 runner-ups, "almost made it" label, **persistent + on each thumbnail** (no hover states — touch only), tap to **add** (if under count) or **replace**; newly added photos route through the 3-way edit before joining
- [ ] All copy per voice rules ("our favorites ✨")
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
- [ ] **Travel Film** pack: Kodak-style / Faded Postcard / Deep Teal
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

- **Fonts:** display = EB Garamond (or Cormorant Garamond — decide before Phase 1; both OFL, bundleable); UI/body = Inter. Max 2 fonts
- **Colors:** background Warm Ivory `#F7F4EE`; elevated Pure Cream `#FFFCF7`; secondary surface Soft Paper `#EEE9DF`; primary text Ink Black `#171614`; secondary Warm Gray `#777169`; muted Stone `#A7A097`; accent Burnished Gold `#A78252` (pressed `#866540`); divider Hairline Beige `#DDD6CA`; success Muted Sage `#71816C`
- **Shape/space:** 8pt grid; 20pt page padding; buttons 54pt tall, 18pt radius; cards 12–18pt radius, continuous corners; sheets 28pt radius; shadows y4/blur18/6% max — prefer borders and tonal separation
- **Texture:** 2–4% film-grain overlay; photos dominate every screen (60–80% of visual area)
- **Copy voice:** humble bestie, lowercase-leaning, never authoritative. "our favorites ✨" not "Best Photos"; "almost made it" not "Rejected"; "ready when you are" not "Export Complete". No exclamation-point salesmanship. Never "AI optimized" / "algorithmically ranked" / "perfect photos"
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
