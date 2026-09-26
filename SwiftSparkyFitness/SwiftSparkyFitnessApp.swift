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

    /// Nav-bar titles in the app's serif. Has to happen before the first bar
    /// is built, and the appearance proxy is process-wide, so it lives here
    /// rather than in the one screen that currently has a stack.
    init() {
        AppNavigationBar.apply()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme((AppDisplayMode(rawValue: displayModeRaw) ?? .system).colorScheme)
        }
    }
}
