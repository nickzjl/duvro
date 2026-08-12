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
//  SAMPLE IMAGERY: the card stack's 3 photos are real bundled product
//  content (SampleAssets/Welcome/, part of every build configuration
//  including Release -- see SampleAssets.swift), not a DEBUG-only
//  placeholder. Each of `samplePhotos`' 3 slots is independently optional
//  so a missing image (a bundle lookup failure) degrades to an empty
//  print frame for just that card rather than losing the whole stack.
//
//  Do NOT add the app-wide film grain overlay here -- separate deferred
//  item (UI_NOTES §1), not part of this screen's build.
//

import SwiftUI

struct WelcomeView: View {
    /// Named, not positional -- see SampleAssets.welcomePhotos() for which
    /// image was matched to which slot and why.
    let samplePhotos: SampleAssets.WelcomePhotos
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

    // MARK: - Photo card stack (design/01_welcome.png)

    /// Rebuilt to match design/01_welcome.png directly (the prior version
    /// used UI_NOTES §4's curation-progress shuffle angles/spacing, which
    /// reads as a much looser, smaller-spread stack than this mockup
    /// actually shows) -- geometry below is read off the mockup image
    /// itself, then adjusted by screenshot comparison, per this session's
    /// own instruction. Named constants so a future pass can nudge any one
    /// card without re-deriving the whole stack.
    private enum CardGeometry {
        static let back = (rotation: -8.0, offset: CGSize(width: -50, height: -85), size: CGSize(width: 160, height: 200))
        static let middle = (rotation: 7.0, offset: CGSize(width: 46, height: -18), size: CGSize(width: 176, height: 220))
        static let front = (rotation: -2.0, offset: CGSize(width: 0, height: 50), size: CGSize(width: 250, height: 312))
    }

    private var cardStack: some View {
        ZStack {
            printCard(samplePhotos.back, rotation: CardGeometry.back.rotation, offset: CardGeometry.back.offset, size: CardGeometry.back.size)
            printCard(samplePhotos.middle, rotation: CardGeometry.middle.rotation, offset: CardGeometry.middle.offset, size: CardGeometry.middle.size)
            printCard(samplePhotos.front, rotation: CardGeometry.front.rotation, offset: CardGeometry.front.offset, size: CardGeometry.front.size)
        }
        .frame(height: 380)
        .frame(maxWidth: .infinity)
    }

    /// Thin equal border on the sides/top, noticeably thicker on the
    /// bottom -- a real print border, confirmed against the mockup (not
    /// the prior version's uniform padding on all four sides). Same
    /// asymmetric-border idea as the Digicam Polaroid EditOp, expressed
    /// here as UI chrome rather than baked into pixels.
    private enum PrintBorder {
        static let side: CGFloat = 8
        static let bottom: CGFloat = 26
    }

    private func printCard(_ image: UIImage?, rotation: Double, offset: CGSize, size: CGSize) -> some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                // No sample image available (a bundle lookup failure) --
                // a muted empty print frame, not a blank gap or a crash.
                Color(hex: "EEE9DF")
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .padding(.horizontal, PrintBorder.side)
        .padding(.top, PrintBorder.side)
        .padding(.bottom, PrintBorder.bottom)
        .background(Color(hex: "FFFCF7"))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 14, x: 0, y: 6)
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
    WelcomeView(samplePhotos: SampleAssets.welcomePhotos(), onStartNewChapter: {}, onSeeHowItWorks: {})
}
