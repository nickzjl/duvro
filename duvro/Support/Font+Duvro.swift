//
//  Font+Duvro.swift
//  duvro
//
//  Central type scale (UI_NOTES §1). Screens should pull tokens from here
//  rather than reaching for `.system` or `.custom` directly, so a type
//  change only ever touches this file.
//
//  Newsreader (the bundled cut is optical size 36, tuned for display, not
//  body text) is used at 20pt and above ONLY: hero display headlines,
//  screen headlines, and Vibe Pack titles (e.g. "Golden Hour"). Below 20pt
//  its hairlines lose legibility, so everything smaller is Inter --
//  including Vibe Pack variant names (e.g. "sun-kissed"), which are Inter
//  even though they read in the terracotta accent, not the ink-black body
//  color. See UI_NOTES §1.
//
//  NOTE: falls back to the system font automatically if a custom font name
//  isn't registered in the bundle (SwiftUI does this silently, no crash).
//

import SwiftUI

extension Font {
    // MARK: - Display (Newsreader, opsz=36) — 20pt and above only

    /// Large hero headline: welcome screen, curation showcase title ("our favorites").
    static var duvroDisplay: Font {
        .custom("Newsreader36pt-SemiBold", size: 34, relativeTo: .largeTitle)
    }

    /// Standard screen headline, e.g. "pick your favorites," "your photos."
    static var duvroHeadline: Font {
        .custom("Newsreader36pt-Medium", size: 26, relativeTo: .title2)
    }

    /// Vibe Pack TITLE only (Golden Hour / Digicam / Travel Film) -- not variant names.
    static var duvroPackTitle: Font {
        .custom("Newsreader36pt-Medium", size: 22, relativeTo: .headline)
    }

    /// Occasional italic accent within serif copy. Kept at the 20pt floor.
    static var duvroSerifItalic: Font {
        .custom("Newsreader36ptItalic-Italic", size: 20, relativeTo: .headline)
    }

    // MARK: - UI / body (Inter) — everything below 20pt, no exceptions

    static var duvroBody: Font {
        .custom("Inter-Regular", size: 16, relativeTo: .body)
    }

    static var duvroSubheadline: Font {
        .custom("Inter-Regular", size: 14, relativeTo: .subheadline)
    }

    static var duvroButton: Font {
        .custom("Inter-SemiBold", size: 17, relativeTo: .body)
    }

    static var duvroCaption: Font {
        .custom("Inter-Regular", size: 12, relativeTo: .caption)
    }

    static var duvroLabel: Font {
        .custom("Inter-Medium", size: 15, relativeTo: .subheadline)
    }

    /// Handoff screen step titles ("saved to duvro album" etc.) only.
    /// UI_NOTES §6: the mockup sets these in a ~13pt serif, which sits
    /// below the 20pt Newsreader floor (§1) -- same weight (Medium), same
    /// approximate size, corrected to Inter.
    static var duvroStepTitle: Font {
        .custom("Inter-Medium", size: 13, relativeTo: .subheadline)
    }

    /// Vibe Pack VARIANT name (e.g. "sun-kissed"), rendered in the terracotta
    /// accent color at the call site -- never Newsreader, per the 20pt floor.
    static var duvroVariantLabel: Font {
        .custom("Inter-Medium", size: 15, relativeTo: .subheadline)
    }
}
