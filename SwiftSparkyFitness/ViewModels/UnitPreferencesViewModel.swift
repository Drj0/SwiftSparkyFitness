//
//  UnitPreferencesViewModel.swift
//  SwiftSparkyFitness
//
//  The units every weight/measurement/water figure is shown in. Switching
//  kg/lb or cm/in converts what's stored (LocalAPIClient.convertStoredUnits);
//  the server keeps metric either way (UserPreferences.metricFactor).
//

import Foundation
import Combine

@MainActor
final class UnitPreferencesViewModel: ObservableObject {
    @Published private(set) var preferences: UserPreferences = .serverDefaults
    @Published private(set) var isLoading = false
    @Published private(set) var busySetting: UserPreferences.Setting?
    @Published var errorMessage: String?

    private let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = AppServices.client) {
        self.apiClient = apiClient
    }

    func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            preferences = try await apiClient.userPreferences()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func select(_ value: String, for setting: UserPreferences.Setting) async {
        guard value != preferences.value(for: setting) else { return }
        busySetting = setting
        errorMessage = nil
        defer { busySetting = nil }
        do {
            // No haptic here: the picker fires one as the choice is made. A
            // buzz that waits for the server arrives after the menu has
            // already closed on the new value.
            preferences = try await apiClient.updateUserPreference(setting, to: value)
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            // Re-read so the picker snaps back to what's actually stored
            // rather than sitting on a choice that didn't take.
            await load()
        }
    }
}
