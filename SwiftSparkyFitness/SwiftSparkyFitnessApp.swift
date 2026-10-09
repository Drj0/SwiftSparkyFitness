//
//  SwiftSparkyFitnessApp.swift
//  SwiftSparkyFitness
//
//  Created by Dheeraj on 17/09/26.
//

import SwiftUI

@main
struct SwiftSparkyFitnessApp: App {
    @AppStorage(AppDisplayMode.defaultsKey) private var displayModeRaw = AppDisplayMode.system.rawValue
    @AppStorage(AppDisplayMode.experimentalDarkKey) private var experimentalDark = false

    /// Nav-bar titles in the app's serif. Has to happen before the first bar
    /// is built, and the appearance proxy is process-wide, so it lives here
    /// rather than in the one screen that currently has a stack.
    init() {
        AppNavigationBar.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Cold-launch application only — not `.preferredColorScheme`,
                // and not `.onChange` here either. Verified live: an
                // `.onChange(of: displayModeRaw)` at this App/Scene level
                // does not reliably refire on every change (Dark -> System
                // updated the stored value but never called this), where the
                // same modifier on `SettingsView` — the one place the value
                // actually changes — does. `SettingsView.onChange` owns the
                // live case; this owns the value already on disk at launch.
                .onAppear { AppDisplayMode.apply(.effective(raw: displayModeRaw, experimentalDark: experimentalDark)) }
        }
    }
}
