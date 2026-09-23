//
//  FoodSearchViewModel.swift
//  SwiftSparkyFitness
//
//  Backs the Log Food search sheet: query -> results, with the "no results"
//  and "network error" states the design specifies as distinct outcomes
//  (not just "results.isEmpty" collapsing both into one look).
//
//  Merges two sources: the local `foods` table (empty on a fresh install —
//  it only ever holds what a user has logged before) and OpenFoodFacts
//  (free, keyless, confirmed live) for real matches on first search. Local
//  results lead since they're the user's own verified entries.
//
//  The idle state (before anything is typed) shows the design's "RECENT"
//  section. That needs its own request: `GET /api/foods` has two mutually
//  exclusive modes, and the one that returns recents is the one with no
//  search term — so a search can never carry them along. See FoodSuggestions.
//

import Foundation
import Combine

enum FoodSearchOutcome {
    case idle
    case results([Food])
    case noResults(query: String)
    case networkError(query: String)

    /// Identity of the *kind* of thing on screen, for driving the results
    /// area's transition. Deliberately ignores the payload: a refinement
    /// that swaps one list of results for another should not replay the
    /// entrance animation, only a genuine change of state should.
    var kindID: String {
        switch self {
        case .idle: return "idle"
        case .results: return "results"
        case .noResults: return "noResults"
        case .networkError: return "networkError"
        }
    }
}

@MainActor
final class FoodSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var outcome: FoodSearchOutcome = .idle
    @Published private(set) var isSearching = false
    @Published var selectedMealType: MealType?

    /// Recently logged foods, shown in the idle state. A failure here is
    /// deliberately silent: this is a shortcut on an otherwise usable screen,
    /// and an error banner over the search box would be louder than the
    /// feature is important. The idle prompt is the fallback.
    @Published private(set) var recentFoods: [Food] = []
    @Published private(set) var isLoadingRecents = false

    let mealTypes: [MealType]
    private let apiClient: APIClientProtocol

    /// A search running over a list that's already on screen is a
    /// refinement: the view dims that list rather than replacing it with a
    /// spinner, which would flash on every debounced keystroke.
    var hasResults: Bool {
        if case .results = outcome { return true }
        return false
    }

    /// `initialMealType` is the meal the user explicitly asked for (a meal
    /// section's "+"). An explicit choice always beats the time-of-day guess,
    /// which stays as the fallback for entry points that don't name a meal
    /// (the FAB, "Log your first food").
    init(mealTypes: [MealType], initialMealType: MealType? = nil, apiClient: APIClientProtocol = APIClient.shared) {
        self.mealTypes = mealTypes.sorted { $0.sortOrder < $1.sortOrder }
        self.selectedMealType = initialMealType ?? Self.defaultMealType(from: mealTypes)
        self.apiClient = apiClient
    }

    /// Picks a sensible starting meal chip from the time of day, matching
    /// the design's rationale of choosing the destination before results load.
    private static func defaultMealType(from mealTypes: [MealType]) -> MealType? {
        let hour = Calendar.current.component(.hour, from: Date())
        let name: String
        switch hour {
        case ..<11: name = "breakfast"
        case 11..<15: name = "lunch"
        case 15..<18: name = "snacks"
        default: name = "dinner"
        }
        return mealTypes.first { $0.name == name } ?? mealTypes.first
    }

    func loadRecents() async {
        guard recentFoods.isEmpty else { return }
        isLoadingRecents = true
        defer { isLoadingRecents = false }
        recentFoods = (try? await apiClient.foodSuggestions())?.recentFoods ?? []
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = .idle
            return
        }
        isSearching = true
        defer { isSearching = false }

        async let local = fetch(trimmed, apiClient.searchFoods)
        async let external = fetch(trimmed, apiClient.searchExternalFoods)
        let (localFoods, localFailed) = await local
        let (externalFoods, externalFailed) = await external

        // A newer keystroke may have started (and awaited) another search
        // while this one was in flight; don't let a slower, superseded
        // response clobber whatever that later search already showed.
        guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        let combined = localFoods + externalFoods
        if !combined.isEmpty {
            outcome = .results(combined)
        } else if localFailed && externalFailed {
            outcome = .networkError(query: trimmed)
        } else {
            outcome = .noResults(query: trimmed)
        }
    }

    /// Runs one source and reports whether it genuinely failed. Cancellation
    /// (a newer keystroke debounced this search away) is not a failure —
    /// treating it as one would flash "can't reach the food database" mid-typing.
    private func fetch(_ query: String, _ call: (String) async throws -> [Food]) async -> (foods: [Food], failed: Bool) {
        do {
            return (try await call(query), false)
        } catch {
            return ([], !Task.isCancelled)
        }
    }
}
