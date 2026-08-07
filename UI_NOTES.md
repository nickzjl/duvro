# UI_NOTES — duvro
### Design cohesion rules + the fix list for Claude Code
Read alongside `prd.md` (behavior) and `BUILD_ROADMAP.md` (implementation). This file governs **how it looks and what to correct** from the Stitch mockups.

## 0. How to use the mockups

Stitch screenshots in `/design/` are the **visual target, not the source of truth.** Where a mockup and the PRD disagree, the PRD wins. The mockups were assembled from three different Stitch aesthetic directions and are not internally consistent — unifying them is your job (see §1).

Workflow per screen: build the SwiftUI screen → run in simulator → screenshot → compare against the mockup → close the gap. Match layout, hierarchy, and type scale. Do NOT copy the mockups' inconsistencies.

## 1. Design system — single source of truth (highest priority)

The mockups mix two visual languages. **Unify everything to this system:**

- **Background:** warm ivory `#F7F4EE` · **Elevated cards:** `#FFFCF7` · **Secondary surface:** `#EEE9DF`
- **Text:** ink black `#171614` · secondary `#777169` · muted `#A7A097`
- **Accent:** terracotta `#A04021` (pressed `#7F3319`) — used ONLY for: selected states, the handwritten-style helper notes, and pack variant names. Never for primary buttons.
- **Primary buttons:** black `#171614` fill, white text, full-radius pill, 54pt tall. (The mockups show both black pills and terracotta rectangles — **black pill wins everywhere**, including "use this vibe," which is currently terracotta.)
- **Dividers/borders:** `#DDD6CA`, 1px
- **Success:** Muted Sage `#71816C`
- **Type:** display headlines, screen titles, and Vibe Pack **titles** (Golden Hour / Digicam / Travel Film) = **Newsreader** (serif); Vibe Pack **variant names** (sun-kissed · warm film · soft glow — these read in the terracotta accent per the Accent line above, but the font is still Inter), UI, and body = **Inter**. Handwritten accent (Caveat) allowed for at most one helper note per screen, e.g. "7 is the sweet spot."
- **Type-size floor:** Newsreader is used at **20pt and above only**. The bundled cut is optical size 36, tuned for display use — its hairlines render thin and lose legibility below 20pt. Anything smaller is Inter, regardless of whether a mockup shows a serif there (see the handoff screen correction in §6).
- **Case:** lowercase headlines and buttons throughout. The handoff screen currently uses sentence-case body copy ("Your curation is polished...") — convert all body copy to the same lowercase-leaning voice as the rest of the app.
- **Texture:** 2–4% film grain overlay, app-wide.
- **Shape:** cards 12–18pt radius, continuous corners; whisper shadows only (y4/blur18/6%).
- **Spacing:** 8pt grid; 20pt page padding; sheets 28pt radius.
- **Photos:** every photo displayed at **4:5** everywhere in the app — edit screen, preview, handoff strip. Instagram locks carousels to the first slide's ratio, so a consistent 4:5 makes the in-app preview honest. (Mockups mix square and portrait — normalize.)

## 2. Fix list (mockup → correct behavior)

### Must fix
1. **Three-way edit: keep the clean pill layout, but make the variants comparable.** The mockup's single-photo + three-pill layout is the approved visual design — do NOT replace it with a three-up grid. The one gap to close: the user currently has to tap blind. Add (a) **horizontal swipe on the photo** to move between the three variants, with the pill highlighting in sync, and (b) **pre-render all three** so switching is instant with a crossfade, never a load. Optional if it stays clean: tiny rendered thumbnails inside the pills. Goal is comparison at a glance without adding visual clutter.
   **Advance mechanic:** tapping a pill or swiping the photo only changes which variant is displayed (pill and photo stay in sync) — neither action advances to the next photo. Variant 1 of the selected pack is pre-selected on arrival, so a user who likes it advances in a single tap. The primary button at the bottom commits the currently displayed variant and advances to the next photo; the back control returns to the previous photo with its pick intact and re-editable.
2. **Add progress to the edit screen:** "3 of 7" at the top. Users in a per-photo loop need to see the end.
3. **Vibe selection variant names must be complete and correct:** Golden Hour = Sun-kissed · Warm Film · Soft Glow (mockup wrongly shows "Warm Glow" and omits one); Travel Film = Kodak Style · Faded Postcard · Deep Teal. If the row overflows on narrow screens, shrink type or wrap to two lines — never truncate.
4. **Import minimum:** copy reads "select 20–200 photos." Disable the import button below 20 with a gentle note; curation quality collapses on tiny sets.
5. **Safe-area / clipping bug:** the handoff photo strip renders behind the fixed bottom button. All scroll views need bottom content inset equal to the button container height + safe area. Audit every screen with a sticky CTA.
6. **Remove AI language from user-facing copy.** "Your AI-curated caption" → "your caption's on the clipboard." Never surface "AI," "algorithm," or "optimized" in the UI.
7. **Pack preview attribution:** replace the repeated "— journaling with intent" with "— duvro".
8. **Curation showcase (screen currently titled "the cloud of memory"):** retitle to **"our favorites"**. Behavior: 3–5 second reveal where the user's OWN selected photos fade in one at a time, building into a collage, then auto-advances into the edit flow. No buttons, no decisions. All imagery must be real user photos — the mockup's placeholder images are broken (browser chrome visible) and are not a reference for content.
9. **Runner-up "+" affordance must be always visible on iOS** — the mockup reveals it on hover, which doesn't exist on touch. Show a persistent small + on each runner-up thumbnail.
10. **Runner-up count is adaptive 2–5**, not fixed at 3 (mockup is a static demo). See PRD §4.
11. **Selected variant pill color:** mockups 09/10/11 (three-way edit) give the selected pill a black fill with white text — the same treatment as the primary CTA, so two black elements compete on one screen and the pill reads as the button. §1 already reserves black for primary buttons and terracotta `#A04021` for selected states. The selected variant pill uses the terracotta accent, not black fill. If a solid terracotta fill reads heavy at pill size, a terracotta 1px border + terracotta text on the cream card surface is the acceptable alternative — decide visually at Phase 5, but black is ruled out either way.
12. **Welcome screen privacy copy is no longer fully accurate.** The mockup (`design/01_welcome.png`) shows two lines under the primary button: "your photos stay yours." and "we only see what you pick." Keep the first line, with its lock icon — import is still local and nothing leaves the device at that step. **Delete the second line entirely.** It's no longer true now that curation exists: a downsampled, low-resolution shortlist of thumbnails is sent off-device for the Stage 2 curation call (prd.md §8; CLAUDE.md's privacy architecture line). "your photos stay yours 🔒" is the ONLY on-screen privacy copy in the app — the full explanation lives in the App Store privacy label and the privacy section (prd.md §9), not anywhere in the curation flow. Do not re-add in-flow disclosure copy.

### Should fix
13. Welcome screen needs a secondary action: "see how it works" / demo with bundled sample photos. Required so App Review can evaluate the app without a populated camera roll.
14. Handoff: keep the current 3-step layout (it reads clearly), but step 3 must include **"tap them in order"** — order is the one thing that silently breaks the post if the user gets it wrong. Add the "caption copied — just paste ✨" toast on arrival. "View album" secondary action and the publishing disclosure are optional polish, not blockers.
15. Per-photo edit headlines ("this one feels special," "there's beauty in this") are a nice touch from the mockups — keep them, but tie them to why the photo was selected where possible (group shot vs. landscape vs. detail get different copy), and randomize within category so they don't repeat inside one session.

## 3. Confirmed flow decisions (these override earlier PRD drafts)

- **Vibe selection has no separate "preview" link.** Tapping a pack card opens its preview sheet; the sheet's "use this vibe" button is the CTA that both selects the pack and starts curation. This deliberately forces the user to see each pack's look before committing.
- **Caption screen offers ONE suggestion** (pre-filled, editable) plus regenerate — not three cards. Rationale: the user has already made many choices during editing; this reduces decision load at the end.
- **No "ready to post? / take another look" branch.** After the last edit, the user lands directly on the final review screen ("the final touches") where they can reorder, remove, and swap in runner-ups, then continue to caption. Funneling forward avoids handing the user a moment to second-guess and restart.

## 4. Motion spec

Exact values below — no reference files needed. Implement natively in SwiftUI.

**Time-based reveals get specified numbers (below). Interactions do not** — use native SwiftUI patterns (`.onMove`, `.draggable`, native sheets) rather than mimicking web behavior. In particular: **there is no hover on iOS.** Any affordance the mockups reveal on hover must be permanently visible.

**Curation progress.** A stack of the user's own photos as print-bordered cards, shuffling forward one at a time. Exact values from the approved mockup:
- **Card shuffle:** 1s, `cubic-bezier(0.4, 0, 0.2, 1)`. Cards sit at **-10° / -5° / 0° / +10°** rotation — a loose stack, front card upright.
- **Status text + progress line:** 0.5s ease-in-out crossfade / width change.
- **Status copy cycles:** "removing duplicates…" → "sorting the moments…" *(PROPOSED, NOT FINAL — flag for review: replaces "finding familiar faces…", a leftover from the deleted recurring-person clustering; this describes Stage 1's actual people/place/food/detail categorization instead)* → "analyzing visual composition…" → "curating the narrative…" Headline above: "finding the moments that belong together."
- Thin progress line, no percentage (a stalled number is worse than no number). Runs as long as curation takes — this now spans on-device shortlisting AND the curation network call, which is why there's no percentage: the network leg's duration isn't predictable enough to promise one.
- **Offline / endpoint-failure fallback (flagged — decision made under time pressure, may be revisited):** if the curation call fails or there's no network, curation falls back to an on-device-only ranking of the Stage 1 shortlist rather than blocking — the user still gets a post, and this is NOT surfaced as an error state; the progress screen continues normally into the showcase. Whether a silent fallback is the right call (vs. a visible degraded-mode notice) hasn't been tested — revisit if BUILD_ROADMAP's Phase 3.5 overlap test shows the fallback's quality is noticeably worse.
- **Continuity:** the progress screen and the showcase are one continuous moment. Same card treatment, same photos; the stack resolves into the collage rather than cutting to a new screen.

**Curation showcase — the signature moment.** Headline: **"our favorites."** The chosen photos fade in one at a time, accumulating into a collage of print-bordered cards. Exact timing (extracted from the approved mockup):
- **Per-card animation:** 1.2s, ease-out. From `opacity 0, offset y +10pt` → `opacity 1, offset y 0`.
- **Stagger — scales with photo count, not fixed.** The approved mockup showed 13 cards at a 0.2s stagger totaling ≈3.7s, but card count equals the user's chosen photo count (4–20 per PRD §4), so a fixed 0.2s stagger would make the sequence run anywhere from 1.9s to 5.1s. **The "~13 cards → 3.7s" figure was a mockup artifact, not a spec — do not reintroduce a fixed stagger.** Instead:
  ```
  n = number of selected photos
  first card delay = 0.1s
  stagger = clamp((3.4 - 1.3) / (n - 1), 0.10, 0.28)   // seconds between cards
  total   = 0.1 + (n - 1) * stagger + 1.2               // seconds, end-to-end
  ```
  Guard `n = 1` separately (the stagger formula divides by `n - 1`): there's no gap to compute, so the sequence is just the first card's delay plus its animation.
  Worked examples: n=7 → stagger 0.28s (clamped), total ≈2.98s. n=13 → stagger 0.175s, total ≈3.4s. n=20 → stagger 0.11s, total ≈3.39s. n=1 → single card, ≈1.3s.
- **Rotation: 0°.** Cards are aligned, not scattered — the mockup's polish comes from overlap and layering, not tilt.
- Cards overlap with varied z-order and size; layout is a fixed collage, not a grid.
- All images are the user's real photos from this session — that's the entire hook.
- No buttons, no progress indicator, no interaction. Auto-advances to the first edit screen when the sequence completes.
- This is the most screen-recordable beat in the app: it must feel like a reveal, not a loading state.

**Everywhere else:** crossfades between edit variants (~0.25s), spring on selection with light haptic, 6pt card lift while dragging, native sheet physics. No confetti, no bouncing, no parallax.

## 5. Advanced adjustments sheet — rebuild (mockup is broken)

The mockup blurs and dims the photo behind the sheet, so the user cannot see the edit they are making. This is the single worst usability bug in the mockups. Rebuild as:

- **No backdrop blur, no dimming.** The photo must render at full clarity and full color the entire time the sheet is open. This is non-negotiable — it's the whole purpose of the screen.
- **Photo scales up into the remaining space** when the sheet opens (matched-geometry transition), staying centered in the visible area rather than being cropped by the sheet.
- **Compact detent (~35% height)**, drag-to-dismiss, so the user can swipe down for an unobstructed look and swipe back up without losing state.
- **Live rendering.** Values apply continuously as the slider moves. Replace "apply changes" with a simple "done" that only dismisses — nothing is "applied" because everything already is.
- **Controls: intensity, brightness, contrast, crop.** Remove grain and vignette — those are pack-level properties tuned in the Vibe Pack JSON, not user-facing dials. Exposing them lets users break the aesthetic that is the product's entire moat.
- **Hold-to-compare:** press and hold anywhere on the photo to see the unedited original, release to return. Works with the sheet open.

## 6. Remaining mockup inconsistencies (fix while building)

- **Vibe selection:** variant names still clip off the right edge ("SOFT G…", "FADED POSTCARD ·"). Wrap to two lines or reduce type size. Screen also has no visible primary CTA — correct, since the pack preview sheet's "use this vibe" is the CTA (UI_NOTES §3), but make sure tapping a card is obviously tappable.
- **Photo count field** is a sharp-cornered rectangle while every other element uses continuous rounded corners. Normalize.
- **Back button** is missing on the first edit screen but present on later ones. Every screen after welcome gets a back control.
- **Aspect ratios still mixed:** edit screens show square, final review shows portrait. Normalize to 4:5 everywhere (§1).
- **Final review CTA** reads "save the collection" — wrong model. Should read as continuing to the post, e.g. "add a caption."
- **Edit screen primary button** reads "save and continue" in the mockups — same objection as above: nothing is saved at that point (no persistence in v1; export happens only at handoff). Canonical label: **"keep this one."**
- **Caption screen** has a large dead zone and two ghost placeholder cards at the bottom; remove them. "copy and finish" is styled as a text link — promote to the standard black pill button. Header alignment (left) differs from other screens (centered).
- **Handoff:** body copy is sentence case while the app is lowercase; "Your curated caption" → "your caption." Photo strip still clips behind the button (safe-area inset, §2 fix 5).
- **Handoff step titles** ("saved to duvro album" / "caption copied" / "finish in instagram") are serif at ~13pt in the mockup — below the 20pt Newsreader floor (§1). These become **Inter Medium**.
- **Import:** copy says "select up to 200" — add the 20 minimum.
- **Showcase:** several placeholder images contain visible browser chrome. Content will be real user photos; ignore mockup imagery entirely.
