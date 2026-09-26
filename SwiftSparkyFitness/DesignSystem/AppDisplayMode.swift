//
//  AppDisplayMode.swift
//  SwiftSparkyFitness
//
//  Light/dark/system, stored as one AppStorage string and applied once at
//  the app root via `.preferredColorScheme`.
//

import SwiftUI

enum AppDisplayMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let defaultsKey = "appDisplayMode"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// Nil defers to the system setting, which is what `.preferredColorScheme` wants for "System".
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
