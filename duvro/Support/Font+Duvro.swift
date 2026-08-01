//
//  Font+Duvro.swift
//  duvro
//
//  Central type scale (UI_NOTES §1). Screens should pull tokens from here
//  rather than reaching for `.system` or `.custom` directly, so a type
//  change only ever touches this file.
//
//  Display type (headlines, pack names) = Newsreader, a serif.
//  Everything else (UI, body, buttons) = Inter.
//
//  NOTE: falls back to the system font automatically if a custom font name
//  isn't registered in the bundle yet (SwiftUI does this silently, no
//  crash) — see the font-bundling task before these render as intended.
//

import SwiftUI

extension Font {
    // MARK: - Display (Newsreader) — headlines, pack names, hero moments

    /// Large hero headline: welcome screen, curation showcase title ("our favorites").
    static var duvroDisplay: Font {
        .custom("NewsreaderRoman-SemiBold", size: 34, relativeTo: .largeTitle)
    }

    /// Standard screen headline, e.g. "pick your favorites," "your photos."
    static var duvroHeadline: Font {
        .custom("NewsreaderRoman-Medium", size: 26, relativeTo: .title2)
    }

    /// Vibe Pack names and other emphasized serif labels.
    static var duvroSerifLabel: Font {
        .custom("NewsreaderRoman-Medium", size: 18, relativeTo: .headline)
    }

    /// Occasional italic accent within serif copy.
    static var duvroSerifItalic: Font {
        .custom("NewsreaderItalic-Italic", size: 18, relativeTo: .headline)
    }

    // MARK: - UI / body (Inter)

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
}
