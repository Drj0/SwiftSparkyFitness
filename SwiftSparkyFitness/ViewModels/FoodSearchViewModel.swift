//
//  FoodSearchViewModel.swift
//  SwiftSparkyFitness
//
//  Backs the Log Food search sheet: query -> results, with the "no results"
//  and "network error" states the design specifies as distinct outcomes
//  (not just "results.isEmpty" collapsing both into one look).
//
//  Four sources, queried together: the user's own foods, INDB (bundled
//  Indian dishes, answers in milliseconds), USDA (generic foods, server
//  mode) and Open Food Facts (packaged products sold in India). The list is
//  re-ranked by FoodSearchRanker as each source answers, so INDB and local
//  matches show at once and slower network results slot in — the list stays
//  dimmed until the last source is in.
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
    /// No result holds every word of the query; the list is the closest
    /// ones, and says so.
    @Published private(set) var resultsAreClosestMatches = false
    @Published var selectedMealType: MealType?

    /// Recently logged foods, shown in the idle state. A failure here is
    /// deliberately silent: this is a shortcut on an otherwise usable screen,
    /// and an error banner over the search box would be louder than the
    /// feature is important. The idle prompt is the fallback.
    @Published private(set) var recentFoods: [Food] = []
    @Published private(set) var isLoadingRecents = false

    /// What the diary says about each food lately (by `FoodLogStat.key`):
    /// the "5× this week" cue and the amount one-tap re-log uses. Read from
    /// the on-device diary once per sheet; bumped locally on each quick log.
    @Published private(set) var logStats: [String: FoodLogStat] = [:]
    /// Recents logged from this sheet a moment ago, showing a check.
    @Published private(set) var justLogged: Set<String> = []
    @Published var quickLogError: String?
    private var quickLogsInFlight: Set<String> = []

    let mealTypes: [MealType]
    private let apiClient: APIClientProtocol
    private let indianFoods: IndianFoodDB
    private let entryDate: Date

    /// Network answers for this sheet, by source and query: backspacing to
    /// a query already asked shows it instantly, and doesn't spend Open Food
    /// Facts' ~10 searches a minute twice. Failures aren't cached.
    private var networkCache: [String: [Food]] = [:]

    /// Foods and brands this user logs most, from the same suggestions the
    /// idle screen shows; ranking leans on them so search learns from the
    /// diary. Empty until `loadRecents` answers.
    private var history = FoodSearchRanker.History.none

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
    init(
        mealTypes: [MealType], initialMealType: MealType? = nil,
        entryDate: Date = Date(),
        apiClient: APIClientProtocol = AppServices.client, indianFoods: IndianFoodDB = .shared
    ) {
        self.entryDate = entryDate
        self.mealTypes = mealTypes.sorted { $0.sortOrder < $1.sortOrder }
        self.selectedMealType = initialMealType ?? Self.defaultMealType(from: mealTypes)
        self.apiClient = apiClient
        self.indianFoods = indianFoods
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
        // The sheet just opened: decode INDB now, off the main actor, so the
        // first keystroke doesn't pay for it.
        Task { await indianFoods.prepare() }
        guard recentFoods.isEmpty else { return }
        isLoadingRecents = true
        defer { isLoadingRecents = false }
        // A 30-day window: enough for the last amount of anything in
        // Recents, and a bounded read however long the diary grows.
        let since = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
        // On-device and a few ms, so no need to race it with the request.
        logStats = await apiClient.foodLogStats(since: since)
        let suggestions = try? await apiClient.foodSuggestions()
        recentFoods = suggestions?.recentFoods ?? []
        history = FoodSearchRanker.History(topFoods: suggestions?.topFoods ?? [], recentFoods: recentFoods)
    }

    func logStat(for food: Food) -> FoodLogStat? { logStats[FoodLogStat.key(for: food)] }

    /// The amount a recent food is shown and quick-logged at: the last one
    /// used, else one default serving.
    func quickLogQuantity(for food: Food) -> Double {
        logStat(for: food)?.lastQuantity ?? food.defaultVariant?.servingSize ?? 1
    }

    /// One tap on a recent food's "+": logs it to the selected meal at its
    /// last amount and stays on the sheet, so a second helping (or the next
    /// food) is one more tap. A tap while that food's log is still in flight
    /// is ignored rather than doubled.
    func quickLog(_ food: Food) async {
        guard let mealType = selectedMealType, quickLogsInFlight.insert(food.id).inserted else { return }
        defer { quickLogsInFlight.remove(food.id) }
        let quantity = quickLogQuantity(for: food)
        do {
            let loggable = food.isExternal ? try await apiClient.materializeExternalFood(food) : food
            try await apiClient.createFoodEntry(
                FoodEntryInput(food: loggable, mealTypeId: mealType.id, quantity: quantity, entryDate: entryDate))
            let key = FoodLogStat.key(for: food)
            var stat = logStats[key] ?? FoodLogStat(timesThisWeek: 0, lastQuantity: quantity)
            let weekStart = Calendar.current.startOfDay(for: Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date())
            if entryDate >= weekStart { stat.timesThisWeek += 1 }
            stat.lastQuantity = quantity
            logStats[key] = stat
            Haptics.success()
            justLogged.insert(food.id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                self?.justLogged.remove(food.id)
            }
        } catch {
            Haptics.error()
            quickLogError = "Couldn't log \(food.name). Check your connection and try again."
        }
    }

    func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            outcome = .idle
            return
        }
        isSearching = true
        defer { isSearching = false }
        // What the sources are asked: "2 roti" searches for roti. `trimmed`
        // stays the identity of this search for the stale-query checks.
        let text = FoodSearchText.searchText(trimmed)

        var lists: [FoodSource: [Food]] = [:]
        var anyFailed = false
        // Whether *this* search put anything on screen. Sources can answer
        // with items the ranker drops (no word of the query in them), so
        // "some source returned something" isn't the same thing — and the
        // previous query's list must not be left standing.
        var showedResults = false
        await withTaskGroup(of: (FoodSource, [Food], Bool).self) { group in
            group.addTask { @MainActor in
                let result = await self.fetch(text, self.apiClient.searchFoods)
                return (.local, result.foods, result.failed)
            }
            group.addTask { @MainActor in
                (.indb, await self.indianFoods.search(text).map(\.asFood), false)
            }
            // USDA is what makes generic foods findable ("Apple, raw"). It
            // returns nothing when the server has no USDA provider configured,
            // which is a deployment choice rather than a failure.
            group.addTask { @MainActor in
                await self.cachedFetch(.usda, text, self.apiClient.searchUsdaFoods)
            }
            // Too short to be worth one of OFF's few searches a minute;
            // INDB and the user's own foods cover one- and two-letter queries.
            if text.count >= OpenFoodFactsSearch.minimumQueryLength {
                group.addTask { @MainActor in
                    await self.cachedFetch(.openFoodFacts, text, self.apiClient.searchExternalFoods)
                }
            }

            for await (source, foods, failed) in group {
                lists[source] = foods
                anyFailed = anyFailed || failed
                // A newer keystroke may have started (and awaited) another
                // search while this one was in flight; don't let a slower,
                // superseded response clobber whatever that search showed.
                guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    group.cancelAll()
                    return
                }
                let ranking = await FoodSearchRanker.rankedOffMain(Array(lists.values), query: text, history: history)
                let ranked = ranking.foods
                // Re-check: the ranking hop is a suspension point too.
                guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else {
                    group.cancelAll()
                    return
                }
                if !ranked.isEmpty {
                    resultsAreClosestMatches = ranking.closestOnly
                    outcome = .results(ranked)
                    showedResults = true
                }
            }
        }

        guard !Task.isCancelled, trimmed == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        if showedResults { return }
        if anyFailed {
            // Nothing found *and* a source didn't answer: "no results" would
            // be a guess, and a wrong one — OpenFoodFacts drops the odd
            // request, so a query that matched a minute ago read as having no
            // matches. The error state offers Retry, which is the real fix.
            outcome = .networkError(query: trimmed)
        } else {
            outcome = .noResults(query: trimmed)
        }
    }

    /// `fetch`, answered from this sheet's cache when the same source was
    /// already asked the same query.
    private func cachedFetch(_ source: FoodSource, _ query: String, _ call: (String) async throws -> [Food]) async -> (FoodSource, [Food], Bool) {
        let key = "\(source.rawValue)|\(query.lowercased())"
        if let cached = networkCache[key] { return (source, cached, false) }
        let result = await fetch(query, call)
        if !result.failed, !Task.isCancelled { networkCache[key] = result.foods }
        return (source, result.foods, result.failed)
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
