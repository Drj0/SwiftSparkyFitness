//
//  ExerciseSearchViewModel.swift
//  SwiftSparkyFitness
//
//  Log Exercise search: query -> results, mirroring FoodSearchViewModel's
//  shape (idle/results/noResults/networkError, recents in the idle state).
//
//  Two sources, not the food screen's three: the user's own library
//  (`searchExercises` — custom exercises plus anything already materialized
//  from a provider) and the external catalog (Free Exercise DB + Wger,
//  already merged/alternated by `APIClient.searchExternalExercises`). An
//  external hit isn't loggable until materialized — see
//  ExerciseEntryEditorViewModel.select(_:), which is where that happens, not
//  here: search should stay read-only.
//

import Foundation
import Combine

enum ExerciseSearchResult: Identifiable {
    case owned(Exercise)
    case external(ExternalExerciseResult)

    var id: String {
        switch self {
        case .owned(let exercise): return "owned-\(exercise.id)"
        case .external(let result): return "external-\(result.source)-\(result.id)"
        }
    }

    var name: String {
        switch self {
        case .owned(let exercise): return exercise.name
        case .external(let result): return result.name
        }
    }

    var category: String? {
        switch self {
        case .owned(let exercise): return exercise.category
        case .external(let result): return result.category
        }
    }

    /// Only external results need a subtitle naming where they came from —
    /// three databases otherwise look identically authoritative, the same
    /// reasoning food search already uses for its "· USDA" suffix.
    var sourceLabel: String? {
        switch self {
        case .owned: return nil
        case .external(let result):
            return result.source == "wger" ? "Wger" : "Free Exercise DB"
        }
    }
}

enum ExerciseSearchOutcome {
    case idle
    case results([ExerciseSearchResult])
    case noResults(query: String)
    case networkError(query: String)

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
final class ExerciseSearchViewModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var outcome: ExerciseSearchOutcome = .idle
    @Published private(set) var isSearching = false
    @Published private(set) var recentExercises: [Exercise] = []
    @Published private(set) var isLoadingRecents = false

    let apiClient: APIClientProtocol

    init(apiClient: APIClientProtocol = AppServices.client) {
        self.apiClient = apiClient
    }

    var hasResults: Bool {
        if case .results = outcome { return true }
        return false
    }

    func loadRecents() async {
        guard recentExercises.isEmpty else { return }
        isLoadingRecents = true
        defer { isLoadingRecents = false }
        recentExercises = (try? await apiClient.recentExercises())?.filter { $0.name != ExerciseSessionSummary.healthActiveEnergyName } ?? []
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = .idle
            return
        }
        isSearching = true
        defer { isSearching = false }

        async let owned = fetch(trimmed, apiClient.searchExercises)
        async let external = fetchExternal(trimmed)

        let (ownedResults, ownedFailed) = await owned
        let (externalResults, externalFailed) = await external

        guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }

        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let combined = ownedResults.filter { $0.name != sentinel }.map(ExerciseSearchResult.owned)
            + externalResults.map(ExerciseSearchResult.external)
        if !combined.isEmpty {
            outcome = .results(combined)
        } else if ownedFailed && externalFailed {
            outcome = .networkError(query: trimmed)
        } else {
            outcome = .noResults(query: trimmed)
        }
    }

    private func fetch(_ query: String, _ call: (String) async throws -> [Exercise]) async -> (exercises: [Exercise], failed: Bool) {
        do {
            return (try await call(query), false)
        } catch {
            return ([], !Task.isCancelled)
        }
    }

    private func fetchExternal(_ query: String) async -> (results: [ExternalExerciseResult], failed: Bool) {
        do {
            return (try await apiClient.searchExternalExercises(query: query), false)
        } catch {
            return ([], !Task.isCancelled)
        }
    }
}
