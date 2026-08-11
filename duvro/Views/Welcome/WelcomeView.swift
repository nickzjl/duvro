//
//  WelcomeView.swift
//  duvro
//
//  prd.md §4 step 1 ("one-screen value prop... secondary demo entry using
//  bundled sample photos, also serves App Review, which cannot test on an
//  empty photo library"). In the canonical flow and in the Views structure
//  from early on, but had no phase checklist item anywhere -- fell through
//  (see BUILD_ROADMAP's doc fix, same session).
//
//  Root screen: no back control. UI_NOTES §6 -- every screen AFTER welcome
//  gets one; ImportView is the next screen now (previously the app's
//  literal root) and gained a back control of its own to match.
//
//  Visual target: design/01_welcome.png, corrected per two doc/mockup
//  conflicts (docs win):
//    - UI_NOTES fix 12: the mockup shows a SECOND privacy line ("we only
//      see what you pick") -- deleted entirely, not replaced. No longer
//      true now that the Stage 2 curation call sends downsampled
//      thumbnails off-device (prd.md §8). "your photos stay yours." plus
//      the lock icon is the ONLY on-screen privacy copy in the app.
//    - UI_NOTES fix 13: the mockup has no secondary action at all --
//      "see how it works" added, required so App Review can evaluate the
//      app without a populated photo library.
//
//  PLACEHOLDER IMAGERY: the ~3 bundled sample photos this screen's card
//  stack (and "see how it works") are meant to ship with don't exist yet
//  -- nobody has shot them (BUILD_ROADMAP's Deferred work register, same
//  blocker as the pack preview sheet's sample images). `samplePhotos` is
//  plain [UIImage] with no idea where they came from -- the caller
//  decides (DebugWelcomePhotos.swift in DEBUG, empty in Release).
//  Anywhere from 0 to 3+ images is handled gracefully, not assumed away.
//
//  Do NOT add the app-wide film grain overlay here -- separate deferred
//  item (UI_NOTES §1), not part of this screen's build.
//

import SwiftUI

struct WelcomeView: View {
    /// Up to 3 used, front-to-back per `cardStack`. Placeholder-sourced --
    /// see the file header.
    let samplePhotos: [UIImage]
    var onStartNewChapter: () -> Void
    var onSeeHowItWorks: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)
            header
            Spacer(minLength: 20)
            cardStack
            Spacer(minLength: 20)
            actions
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
        .background(Color(hex: "F7F4EE").ignoresSafeArea())
    }

    // MARK: - Wordmark + subtitle

    private var header: some View {
        VStack(spacing: 8) {
            Text("duvro")
                .font(.duvroDisplay)
                .foregroundStyle(Color(hex: "171614"))
            // "Inter italic" per spec -- distinct from .duvroSerifItalic
            // (Newsreader italic, used elsewhere for serif copy accents).
            // No dedicated Inter-italic token exists yet; .italic()
            // applied to the Inter body token, same treatment Task 4 used
            // for the vibe screen's "7 is the sweet spot" helper.
            Text("your memories, curated for the feed.")
                .font(.duvroBody)
                .italic()
                .foregroundStyle(Color(hex: "777169"))
        }
        .multilineTextAlignment(.center)
    }

    // MARK: - Photo card stack (UI_NOTES §4's print-bordered card treatment)

    /// Rotation values are 3 of the 4 UI_NOTES §4 specifies for the
    /// curation-progress shuffle (-10°/-5°/0°/+10°) -- that spec is for a
    /// 4-position ANIMATED stack; this one is static with 3 cards, so it
    /// reuses -10°/0°/+10° (front card upright, per that same section's
    /// "a loose stack, front card upright") rather than inventing new
    /// values for a different card count.
    private var cardStack: some View {
        ZStack {
            printCard(image(at: 1), rotation: -10, offset: CGSize(width: -30, height: -8), size: CGSize(width: 200, height: 250))
            printCard(image(at: 2), rotation: 10, offset: CGSize(width: 28, height: -4), size: CGSize(width: 200, height: 250))
            printCard(image(at: 0), rotation: 0, offset: .zero, size: CGSize(width: 232, height: 290))
        }
        .frame(height: 320)
        .frame(maxWidth: .infinity)
    }

    private func image(at index: Int) -> UIImage? {
        samplePhotos.indices.contains(index) ? samplePhotos[index] : nil
    }

    private func printCard(_ image: UIImage?, rotation: Double, offset: CGSize, size: CGSize) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // No placeholder image available (Release, or fewer than
                // 3 DebugFixture photos) -- a muted empty print frame,
                // not a blank gap or a crash.
                Color(hex: "EEE9DF")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(10)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.06), radius: 18, x: 0, y: 4)
        .rotationEffect(.degrees(rotation))
        .offset(offset)
    }

    // MARK: - Actions (UI_NOTES fixes 12 + 13)

    private var actions: some View {
        VStack(spacing: 16) {
            Button(action: onStartNewChapter) {
                Text("start a new chapter")
                    .font(.duvroButton)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                    .background(Color(hex: "171614"))
                    .clipShape(Capsule())
            }

            // UI_NOTES fix 13: not in the mockup at all -- required so App
            // Review can evaluate the app without a populated photo
            // library (prd.md §4 step 1).
            Button("see how it works", action: onSeeHowItWorks)
                .font(.duvroCaption)
                .foregroundStyle(Color(hex: "777169"))

            // UI_NOTES fix 12: the mockup's SECOND line ("we only see
            // what you pick") is deleted, not replaced -- no longer true
            // now that curation sends thumbnails off-device. This lock
            // line is the ONLY on-screen privacy copy in the app.
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                Text("your photos stay yours.")
                    .font(.duvroCaption)
            }
            .foregroundStyle(Color(hex: "A7A097"))
        }
    }
}

#Preview {
    WelcomeView(samplePhotos: [], onStartNewChapter: {}, onSeeHowItWorks: {})
}
