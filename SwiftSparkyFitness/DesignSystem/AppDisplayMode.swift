//
//  AppDisplayMode.swift
//  SwiftSparkyFitness
//
//  Light/dark/system, stored as one AppStorage string and applied at every
//  connected window via `overrideUserInterfaceStyle` — not
//  `.preferredColorScheme`, which turned out not to be reliable here. See
//  `apply(_:)`.
//
//  Light only, unless dark mode is switched on under Settings → Experimental:
//  dark needs a proper pass before it's on by default, so a phone in dark
//  mode no longer drags the app into it. The System/Light/Dark choice only
//  counts while that switch is on.
//

import SwiftUI

enum AppDisplayMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appDisplayMode"
    static let experimentalDarkKey = "experimentalDarkMode"

    /// What the app actually shows: Light, unless experimental dark mode is on.
    static func effective(raw: String, experimentalDark: Bool) -> AppDisplayMode {
        experimentalDark ? AppDisplayMode(rawValue: raw) ?? .system : .light
    }

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Sets every connected window's interface style directly.
    ///
    /// The first version used `.preferredColorScheme(mode.colorScheme)` on
    /// the root view, `nil` for System. Verified live: switching from an
    /// explicit Light/Dark choice back to System left the app stuck on the
    /// explicit choice until the next relaunch — SwiftUI's `nil` doesn't
    /// reliably clear a previously-applied override, a known SwiftUI
    /// limitation, not a one-off. `UIWindow.overrideUserInterfaceStyle`
    /// resets correctly when set to `.unspecified`, including back to
    /// whatever the system is currently set to.
    static func apply(_ mode: AppDisplayMode) {
        let style: UIUserInterfaceStyle
        switch mode {
        case .system: style = .unspecified
        case .light: style = .light
        case .dark: style = .dark
        }
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .forEach { $0.overrideUserInterfaceStyle = style }
    }
}
