//
//  AppFont.swift
//  SwiftSparkyFitness
//
//  Type scale from the design system, in the design's own typefaces:
//  Newsreader (serif, headlines) and Work Sans (sans, everything else).
//
//  BUNDLED FACES
//  -------------
//  Upstream ships both families as *variable* fonts only — there are no
//  static instances in google/fonts. Bundling a variable font and asking for
//  a weight is unreliable on iOS, so the four faces in Resources/Fonts are
//  static instances cut with `fonttools varLib.instancer --update-name-table`
//  (the flag matters: without it every instance keeps the source font's name
//  records, so all three Work Sans weights claim the PostScript name
//  "WorkSans-Regular" and iOS registers only one of them).
//
//  Newsreader also has an optical-size axis; it's pinned at 16, the family's
//  own default and one of only three opsz values its STAT table names.
//
//  Reference a face by POSTSCRIPT name, not filename — instancing rewrites
//  these to carry a "Roman" infix, so the file WorkSans-SemiBold.ttf is
//  addressed as "WorkSansRoman-SemiBold".
//
//  Only the weights the app actually uses are bundled (sans regular/semibold/
//  bold, serif semibold). `Font.custom` falls back to the system font if a
//  name doesn't resolve, so a missing face degrades quietly rather than
//  crashing.
//
//  DYNAMIC TYPE
//  ------------
//  `Font.system(size:)` and `Font.custom(_:fixedSize:)` are both FIXED point
//  sizes and ignore the user's text setting — the whole app used to render
//  byte-identically at accessibility-XXXL.
//
//  Two ways to fix that were tried:
//
//  1. Remap every size onto a semantic text style (`.subheadline` etc).
//     Rejected: it changes the design's sizes at the *default* setting
//     (body(14) would render at 15pt), i.e. a visual redesign nobody asked
//     for.
//  2. Scale the exact design size through `UIFontMetrics` inside a plain
//     function. Rejected after testing: it produces the right numbers, but a
//     plain function isn't part of SwiftUI's dependency graph, so nothing
//     re-evaluates when the setting changes. Measured in the simulator — the
//     title grew only after a full relaunch, and a background/foreground
//     round trip did nothing.
//
//  So the scaling lives in a `@ScaledMetric` view modifier instead, which
//  *is* reactive, and preserves the exact design size at the default setting.
//  The modifier then asks for that already-scaled size with
//  `Font.custom(_:fixedSize:)` — the plain `Font.custom(_:size:)` would scale
//  it a *second* time against `.body`.
//
//  Use `.appBody(15)` / `.appDisplay(26)`. There is deliberately no
//  `Font`-returning variant: one existed, was unused, and returned a system
//  font, so the two ways of asking for "the app's body font" disagreed.
//

import SwiftUI

enum AppFont {
    /// PostScript names of the bundled faces. See the note above on why these
    /// don't match the filenames.
    enum Face {
        static let sansRegular = "WorkSansRoman-Regular"
        static let sansSemiBold = "WorkSansRoman-SemiBold"
        static let sansBold = "WorkSansRoman-Bold"
        static let serifSemiBold = "NewsreaderRoman-SemiBold"
    }

    /// Nearest bundled sans face for a requested weight. Asking CoreText for a
    /// weight that isn't bundled makes it synthesise one by smearing the
    /// outlines, which looks noticeably worse than rounding to a real cut.
    static func sansFace(for weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight, .thin, .light, .regular: return Face.sansRegular
        case .medium, .semibold: return Face.sansSemiBold
        default: return Face.sansBold
        }
    }

    /// The stock text style whose scaling curve best matches each design size.
    /// Small text grows proportionally more than large text under Dynamic
    /// Type, so anchoring each size to its nearest style keeps captions and
    /// hero numbers growing at their correct relative rates.
    static func textStyle(for size: CGFloat) -> Font.TextStyle {
        switch size {
        case ..<11.5: return .caption2
        case ..<12.5: return .caption
        case ..<13.5: return .footnote
        case ..<15.5: return .subheadline
        case ..<16.5: return .callout
        case ..<19:   return .headline
        case ..<21:   return .title3
        case ..<24:   return .title2
        case ..<29:   return .title
        default:      return .largeTitle
        }
    }
}

/// Scales a design point size with Dynamic Type while keeping it exactly
/// on-design at the default setting.
private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let face: String

    init(size: CGFloat, face: String, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.face = face
    }

    func body(content: Content) -> some View {
        content.font(.custom(face, fixedSize: size))
    }
}

extension View {
    /// Work Sans, for body copy, labels, and buttons.
    func appBody(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(
            ScaledFont(
                size: size,
                face: AppFont.sansFace(for: weight),
                relativeTo: AppFont.textStyle(for: size)
            )
        )
    }

    /// Newsreader, for headlines and screen titles. Takes no weight: the
    /// design only ever sets it semibold, and only that cut is bundled — a
    /// weight argument here would be silently ignored.
    func appDisplay(_ size: CGFloat) -> some View {
        modifier(
            ScaledFont(
                size: size,
                face: AppFont.Face.serifSemiBold,
                relativeTo: AppFont.textStyle(for: size)
            )
        )
    }
}
