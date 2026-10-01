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
    var symbol: String { ExerciseCatalog.symbol(name: name, category: category) }

    var modality: ExerciseModality? {
        switch self {
        case .catalog(let entry): return entry.modality
        case .owned(let exercise): return exercise.modality
        case .external(let result): return result.modality
        }
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

    /// Which kind of exercise the idle lists show.
    @Published var category: ExerciseCategoryFilter = .all

    /// The last session of everything logged lately, by
    /// `ExerciseLastSession.key` — what recents describe, what one-tap
    /// "log again" repeats, and what the editor starts from. Read from the
    /// on-device diary once per sheet.
    @Published private(set) var history: [String: ExerciseLastSession] = [:]
    /// Units the history is labelled in.
    @Published private(set) var preferences: UserPreferences = .serverDefaults
    /// Recents logged again from this sheet a moment ago, showing a check.
    @Published private(set) var justLogged: Set<String> = []
    @Published private(set) var quickLoggingId: String?
    @Published var quickLogError: String?

    /// Recents in the selected category.
    var visibleRecents: [Exercise] {
        recentExercises.filter { category.matches($0.category ?? ExerciseCatalog.entry(named: $0.name)?.category) }
    }

    /// Catalog suggestions for the selected category, minus whatever Recent
    /// already shows.
    var browseExercises: [CatalogExercise] {
        let recent = Set(recentExercises.map { ExerciseCatalog.normalized($0.name) })
        return ExerciseCatalog.browse(category).filter { !recent.contains(ExerciseCatalog.normalized($0.name)) }
    }

    /// The old name for All's suggestions, kept for callers that predate
    /// the category filter.
    var popularExercises: [CatalogExercise] {
        let recent = Set(recentExercises.map { ExerciseCatalog.normalized($0.name) })
        return ExerciseCatalog.popular.filter { !recent.contains(ExerciseCatalog.normalized($0.name)) }
    }

    let apiClient: APIClientProtocol
    private let entryDate: Date

    init(entryDate: Date = Date(), apiClient: APIClientProtocol = AppServices.client) {
        self.entryDate = entryDate
        self.apiClient = apiClient
    }

    func lastSession(for name: String) -> ExerciseLastSession? {
        history[ExerciseLastSession.key(name)]
    }

    /// A long enough window that a weekly or monthly exercise still has a
    /// last time; one fetch, once per sheet.
    func loadHistory() async {
        guard history.isEmpty else { return }
        let start = Calendar.current.date(byAdding: .day, value: -180, to: Date()) ?? Date()
        async let sessions = apiClient.exerciseHistory(since: start)
        async let prefs = try? apiClient.userPreferences()
        let (loaded, loadedPreferences) = await (sessions, prefs)
        history = loaded
        if let loadedPreferences { preferences = loadedPreferences }
    }

    /// "3 × 8 · 60 kg · 2 days ago", for a row that has been logged before.
    func lastSessionSummary(for name: String, modality: ExerciseModality?) -> String? {
        guard let last = lastSession(for: name) else { return nil }
        let detail = ExerciseFormatting.detail(
            last, fallbackModality: modality,
            weightUnit: preferences.weightUnitLabel, distanceUnit: preferences.distanceUnitLabel
        )
        let when = ExerciseFormatting.relativeDay(last.date)
        let often = last.timesThisWeek >= 2 ? " · \(last.timesThisWeek)× this week" : ""
        return [detail.isEmpty ? nil : detail, when].compactMap { $0 }.joined(separator: " · ") + often
    }

    /// One tap to repeat a recent exercise exactly as it was last logged —
    /// the same "+" Recent foods have. The sheet stays open, so a whole
    /// routine of repeats is a tap each.
    func quickLog(_ exercise: Exercise) async {
        guard let last = lastSession(for: exercise.name), quickLoggingId == nil else { return }
        quickLoggingId = exercise.id
        quickLogError = nil
        defer { quickLoggingId = nil }
        do {
            _ = try await apiClient.createExerciseEntry(ExerciseEntryInput(repeating: last, exercise: exercise, on: entryDate))
            justLogged.insert(exercise.id)
            var updated = last
            updated.timesThisWeek += 1
            history[ExerciseLastSession.key(exercise.name)] = updated
            Haptics.success()
        } catch {
            quickLogError = "Couldn't log \(exercise.name). Check your connection and try again."
            Haptics.error()
        }
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

    /// Catalog MET beats a provider's figure; with neither (a custom
    /// exercise), a typical rate for its kind still gives Save a labelled
    /// estimate rather than a required blank.
    func withBestRate(_ exercise: Exercise) -> Exercise {
        let weight = weightKg ?? ExerciseCatalog.fallbackWeightKg
        let rate: Double
        if let entry = ExerciseCatalog.entry(named: exercise.name) {
            rate = entry.caloriesPerHour(weightKg: weight)
        } else if let known = exercise.caloriesPerHour, known > 0 {
            rate = known
        } else {
            rate = ExerciseCatalog.fallbackMET(category: exercise.category, modality: exercise.modality) * weight
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
