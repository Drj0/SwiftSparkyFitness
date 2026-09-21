//
//  AppColor.swift
//  SwiftSparkyFitness
//
//  Color tokens from the design system (light/dark pairs where the design
//  specified both; single value where it didn't, e.g. macro/status colors).
//

import SwiftUI

extension Color {
    init(hex: String) {
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }

    static func adaptive(light: Color, dark: Color) -> Color {
        Color(UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(dark) : UIColor(light)
        })
    }
}

enum AppColor {
    static let background = Color.adaptive(light: Color(hex: "FAF6F3"), dark: Color(hex: "171217"))
    static let surface = Color.adaptive(light: Color(hex: "FFFFFF"), dark: Color(hex: "241D25"))
    static let accent = Color.adaptive(light: Color(hex: "E23573"), dark: Color(hex: "FF5C94"))
    static let accentSoft = Color.adaptive(light: Color(hex: "FDE7EE"), dark: Color(hex: "3A2430"))
    static let ink = Color.adaptive(light: Color(hex: "201A1D"), dark: Color(hex: "F6EFF2"))
    static let secondaryText = Color.adaptive(light: Color(hex: "6E6469"), dark: Color(hex: "B7ABA6"))
    /// Tertiary text: "Not logged yet", "RESULTS", field placeholders.
    /// Was `B7ABA6`, which is **2.24:1** on white — half the 4.5:1 WCAG AA
    /// minimum, and it was carrying real state information rather than
    /// decoration. Darkened to clear AA while staying clearly recessive
    /// against `secondaryText`.
    static let placeholder = Color.adaptive(light: Color(hex: "78706D"), dark: Color(hex: "9A8C92"))
    static let hairline = Color.adaptive(light: Color(hex: "ECE1DE"), dark: Color(hex: "3A2F38"))
    /// Unselected tab labels. Previously shared `placeholder`'s 2.24:1, which
    /// made three of the four tabs read as *disabled* rather than *unselected*.
    /// Now its own token so navigation chrome can be darker than in-content
    /// placeholder text.
    static let inactiveTab = Color.adaptive(light: Color(hex: "7D7278"), dark: Color(hex: "9A8C92"))
    /// Flat input/chip background (search bars, meal chips, form fields).
    /// Was hardcoded to the light-mode value everywhere it was used, which
    /// combined with AppColor.ink's dark-mode near-white to make text
    /// unreadable — light text on a background that never got any darker.
    static let inputBackground = Color.adaptive(light: Color(hex: "F4EEEC"), dark: Color(hex: "2E252B"))

    // Status/macro colors. Water shifts to a deeper blue in dark mode — the
    // light-mode "sky" blue reads as washed-out/pastel on a dark background
    // instead of standing out the way it's meant to.
    //
    // `energy` and `carbs` were single values with no light/dark pair, tuned
    // against the dark surface — on white they measured 2.95:1 and **2.03:1**
    // against a 4.5:1 requirement, and they carry the macro numbers, which are
    // the payload of that card. They're now adaptive and AA-clear for TEXT.
    // The bright originals live on as `*Graphic`, for the ring arcs where the
    // mark is 14pt thick and vibrancy matters more than text contrast.
    static let energy = Color.adaptive(light: Color(hex: "12735E"), dark: Color(hex: "2FD3AC"))
    static let carbs = Color.adaptive(light: Color(hex: "8F5B06"), dark: Color(hex: "F5A623"))
    static let energyGraphic = Color.adaptive(light: Color(hex: "1FA98A"), dark: Color(hex: "2FD3AC"))
    static let carbsGraphic = Color.adaptive(light: Color(hex: "F5A623"), dark: Color(hex: "F5A623"))
    static let water = Color.adaptive(light: Color(hex: "2F9BEA"), dark: Color(hex: "5AC8FA"))
    static let waterSoft = Color.adaptive(light: Color(hex: "E7F3FD"), dark: Color(hex: "172A3A"))
    static let destructive = Color(hex: "E14B4B")

    // Error banner/field state.
    static let errorBackground = Color.adaptive(light: Color(hex: "FDECEC"), dark: Color(hex: "3A1F22"))
    static let errorBorder = Color.adaptive(light: Color(hex: "F6C6C6"), dark: Color(hex: "5C2C30"))
    static let errorText = Color.adaptive(light: Color(hex: "8F2A2A"), dark: Color(hex: "FF9B9B"))

    /// Ring chart's unfilled track, and the dashed "goal not set" ring border.
    static let ringTrack = Color.adaptive(light: Color(hex: "EFE7E4"), dark: Color(hex: "3A2F38"))
    /// "Sparky" quote card text, and its dashed-border sibling on the
    /// goal-not-set card — both sit on accentSoft, so need their own
    /// light/dark pair rather than AppColor.accent's.
    static let sparkyQuote = Color.adaptive(light: Color(hex: "8F1C48"), dark: Color(hex: "FF9EC0"))
    static let dashedBorder = Color.adaptive(light: Color(hex: "DCD2CE"), dark: Color(hex: "3A2F38"))
}
