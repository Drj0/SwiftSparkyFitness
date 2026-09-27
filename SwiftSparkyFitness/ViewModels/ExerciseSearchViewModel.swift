//
//  ExerciseSearchViewModel.swift
//  SwiftSparkyFitness
//
//  Log Exercise search: query -> results, mirroring FoodSearchViewModel's
//  shape (idle/results/noResults/networkError, recents in the idle state).
//
//  Three sources: the built-in ExerciseCatalog (offline, and the only one
//  with a calorie rate), the user's own library (`searchExercises` — custom
//  exercises plus anything already materialized), and the external catalog
//  (Free Exercise DB + Wger). One exercise appears once, from the highest-
//  priority source — see ExerciseCatalog for the order. Catalog and external
//  hits aren't loggable until they're in the user's library; `exercise(for:)`
//  does that when one is picked, so searching itself stays read-only.
//

import Foundation
import Combine

enum ExerciseSearchResult: Identifiable {
    case catalog(CatalogExercise)
    case owned(Exercise)
    case external(ExternalExerciseResult)

    var id: String {
        switch self {
        case .catalog(let entry): return "catalog-\(entry.name)"
        case .owned(let exercise): return "owned-\(exercise.id)"
        case .external(let result): return "external-\(result.source)-\(result.id)"
        }
    }

    var name: String {
        switch self {
        case .catalog(let entry): return entry.name
        case .owned(let exercise): return exercise.name
        case .external(let result): return result.name
        }
    }

    var category: String? {
        switch self {
        case .catalog(let entry): return entry.category
        case .owned(let exercise): return exercise.category
        case .external(let result): return result.category
        }
    }

    /// The catalog's own glyph where it knows the exercise, otherwise a
    /// generic one by kind.
    var symbol: String {
        if let entry = ExerciseCatalog.entry(named: name) { return entry.symbol }
        return category == "cardio" ? "figure.mixed.cardio" : "figure.strengthtraining.traditional"
    }

    /// Only external results need a subtitle naming where they came from —
    /// three databases otherwise look identically authoritative, the same
    /// reasoning food search already uses for its "· USDA" suffix.
    var sourceLabel: String? {
        switch self {
        case .catalog, .owned: return nil
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
    /// Latest logged weight in kg, for MET → kcal. nil until one is logged.
    @Published private(set) var weightKg: Double?

    /// Tap-to-log suggestions for before anything is typed, minus whatever
    /// Recent already shows.
    var popularExercises: [CatalogExercise] {
        let recent = Set(recentExercises.map { ExerciseCatalog.normalized($0.name) })
        return ExerciseCatalog.popular.filter { !recent.contains(ExerciseCatalog.normalized($0.name)) }
    }

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

    /// Best-effort: without a weight the estimate falls back to
    /// `ExerciseCatalog.fallbackWeightKg`, which is still a usable default.
    func loadWeight() async {
        guard weightKg == nil else { return }
        let today = Date()
        guard let start = Calendar.current.date(byAdding: .day, value: -365, to: today),
              let rows = try? await apiClient.bodyMeasurements(from: start, to: today),
              let weight = rows.lazy.compactMap(\.measurements.weight).first,
              let preferences = try? await apiClient.userPreferences() else { return }
        // Stored in whatever unit the preference names (see UserPreferences).
        switch preferences.defaultWeightUnit ?? "kg" {
        case "kg": weightKg = weight
        case "lbs": weightKg = weight * 0.453_592_37
        default: break // st_lbs: no reliable single number; use the fallback.
        }
    }

    /// Turns a picked result into a loggable exercise from the user's own
    /// library, carrying the best calorie rate available: the catalog's
    /// MET estimate outranks a provider's figure (Health's measured calories
    /// outrank both, but only exist on imported workouts, not here).
    func exercise(for result: ExerciseSearchResult) async throws -> Exercise {
        let owned: Exercise
        switch result {
        case .owned(let exercise):
            owned = exercise
        case .external(let external):
            owned = try await apiClient.materializeExternalExercise(external)
        case .catalog(let entry):
            owned = try await apiClient.libraryExercise(for: entry)
        }
        return withBestRate(owned)
    }

    private func withBestRate(_ exercise: Exercise) -> Exercise {
        let rate: Double?
        if let entry = ExerciseCatalog.entry(named: exercise.name) {
            rate = entry.caloriesPerHour(weightKg: weightKg ?? ExerciseCatalog.fallbackWeightKg)
        } else {
            rate = exercise.caloriesPerHour.flatMap { $0 > 0 ? $0 : nil }
        }
        return Exercise(
            id: exercise.id, name: exercise.name, category: exercise.category, modality: exercise.modality,
            caloriesPerHour: rate, equipment: exercise.equipment, primaryMuscles: exercise.primaryMuscles,
            secondaryMuscles: exercise.secondaryMuscles, instructions: exercise.instructions,
            source: exercise.source, isCustom: exercise.isCustom
        )
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

        // Highest-priority source first; a name already shown is skipped
        // further down. An owned exercise the catalog also knows is shown as
        // the catalog row — picking it still reuses the owned one.
        let sentinel = ExerciseSessionSummary.healthActiveEnergyName
        let catalogHits = ExerciseCatalog.search(trimmed)
        var seen = Set(catalogHits.map { ExerciseCatalog.normalized($0.name) })
        let ownedHits = ownedResults.filter { $0.name != sentinel && seen.insert(ExerciseCatalog.normalized($0.name)).inserted }
        let externalHits = externalResults.filter { seen.insert(ExerciseCatalog.normalized($0.name)).inserted }
        let combined = catalogHits.map(ExerciseSearchResult.catalog)
            + ownedHits.map(ExerciseSearchResult.owned)
            + externalHits.map(ExerciseSearchResult.external)
        if !combined.isEmpty {
            outcome = .results(combined)
        } else if ownedFailed || externalFailed {
            // Same rule as food search: nothing found while a source failed
            // is not a trustworthy "no results".
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
