//
//  UnitPreferencesViewModel.swift
//  SwiftSparkyFitness
//
//  The units every weight/measurement/water figure is labelled with.
//
//  Nothing converts. The stored number is in whatever unit the preference
//  names — the reference web client writes the typed value as-is and
//  `check_in_measurements` has no unit column — so switching kg to lb
//  relabels the field and does NOT rewrite the 73.5 already stored. That's
//  the web client's behaviour too, and diverging would make the same row mean
//  different things in the two clients.
//
//  The screen says so out loud, because a silent relabel is the kind of thing
//  that looks like a bug the first time you see it.
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

    init(apiClient: APIClientProtocol = APIClient.shared) {
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
            preferences = try await apiClient.updateUserPreference(setting, to: value)
            Haptics.selection()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            // Re-read so the picker snaps back to what's actually stored
            // rather than sitting on a choice that didn't take.
            await load()
        }
    }
}
