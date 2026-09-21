//
//  AppFont.swift
//  SwiftSparkyFitness
//
//  Type scale from the design system. The design specifies Newsreader
//  (serif, headlines) and Work Sans (sans, everything else); neither ships
//  on iOS and no font files were provided, so this uses SwiftUI's built-in
//  serif design (renders as New York) and the system sans in their place —
//  same scale/weights, native fonts instead of bundling assets.
//  ponytail: swap in real Newsreader/Work Sans .ttf files (Font.custom) if
//  brand fidelity to the exact typeface ever matters more than shipping.
//
//  DYNAMIC TYPE
//  ------------
//  `Font.system(size:)` is a FIXED point size and ignores the user's text
//  setting entirely — the whole app used to render byte-identically at
//  accessibility-XXXL.
//
//  Two ways to fix that were tried:
//
//  1. Remap every size onto a semantic text style (`.subheadline` etc).
//     Rejected: it changes the design's sizes at the *default* setting
//     (body(14) would render at 15pt), i.e. a visual redesign nobody asked
//     for.
//  2. Scale the exact design size through `UIFontMetrics` inside these
//     functions. Rejected after testing: it produces the right numbers, but
//     a plain function isn't part of SwiftUI's dependency graph, so nothing
//     re-evaluates when the setting changes. Measured in the simulator — the
//     title grew only after a full relaunch, and a background/foreground
//     round trip did nothing.
//
//  So the scaling lives in a `@ScaledMetric` view modifier instead, which
//  *is* reactive, and preserves the exact design size at the default setting.
//  Use `.appBody(15)` / `.appDisplay(26)` in place of `.font(AppFont.body(15))`.
//
//  The raw `AppFont.body/display` functions are kept for the rare case that
//  needs a `Font` value rather than a modifier; they do NOT scale, so prefer
//  the modifiers.
//

import SwiftUI

enum AppFont {
    /// Non-scaling. Prefer `.appDisplay(_:weight:)`.
    static func display(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .serif)
    }

    /// Non-scaling. Prefer `.appBody(_:weight:)`.
    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
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
    private let weight: Font.Weight
    private let design: Font.Design

    init(size: CGFloat, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: AppFont.textStyle(for: size))
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Work Sans-style sans, for body copy, labels, and buttons.
    func appBody(_ size: CGFloat, weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: .default))
    }

    /// Newsreader-style serif, for headlines and screen titles.
    func appDisplay(_ size: CGFloat, weight: Font.Weight = .semibold) -> some View {
        modifier(ScaledFont(size: size, weight: weight, design: .serif))
    }
}
