//
//  TodayViewModel.swift
//  SwiftSparkyFitness
//
//  Owns the Today screen's data: the daily summary, meal types (fetched
//  once and reused by the logging sheets), and the macro/meal-grouping math
//  the design needs but the API doesn't return pre-computed.
//

import Foundation
import Combine

enum LogTarget {
    case food, exercise, weight, measurements
}

@MainActor
final class TodayViewModel: ObservableObject {
    @Published private(set) var summary: DailySummary?
    @Published private(set) var mealTypes: [MealType] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    @Published var isPresentingFoodSearch = false
    @Published var isPresentingLogExercise = false
    @Published var isPresentingLogChoice = false
    @Published var isPresentingWaterAmount = false
    @Published var isPresentingLogWeight = false
    @Published var isPresentingLogMeasurements = false
    @Published var isPresentingSetGoals = false
    /// Set by a meal section's "+" so Log Food opens on the meal the user
    /// actually tapped, instead of falling back to the time-of-day guess
    /// (tapping "+" beside Dinner at 9am used to open on Breakfast).
    @Published var pendingMealType: MealType?
    /// Which sheet to open once the log-choice sheet finishes dismissing —
    /// presenting it immediately (before the dismiss animation completes)
    /// would race two sheet presentations against each other.
    @Published var pendingLogTarget: LogTarget?

    // MARK: - Module 4

    /// Unit labels come from the server, never from a hardcoded constant —
    /// see UserPreferences. Starts on the same defaults the
    /// `user_preferences` table declares so the first frame isn't unlabelled.
    @Published private(set) var preferences: UserPreferences = .serverDefaults
    /// The day's single check-in row (weight + measurements).
    @Published private(set) var bodyMeasurements: BodyMeasurements = .none
    /// Water is its own small view model so Today's card and Diary's water
    /// section share one set of rules.
    let water: WaterViewModel

    private let apiClient: APIClientProtocol
    private let health: HealthKitReading
    private var cancellables = Set<AnyCancellable>()
    private var today = Date()

    init(
        apiClient: APIClientProtocol = APIClient.shared,
        health: HealthKitReading = HealthKitService.shared
    ) {
        self.apiClient = apiClient
        self.health = health
        self.water = WaterViewModel(date: today, apiClient: apiClient)
        // `water` is its own ObservableObject, so a quick-add publishes to
        // the water card but NOT to this screen — which decides between the
        // populated and "nothing logged yet" layouts, and feeds the summary
        // card's water ring. Without forwarding, logging the day's first
        // glass left Today on its first-run layout (taking the card the tap
        // came from off screen) until the next load.
        water.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // Settings can add a meal, rename a unit or change the water
        // container while this screen stays alive behind the tab bar, so it
        // has to be told. `mealTypes` is dropped rather than merged because
        // it's cached across loads — without clearing it, a new category
        // would never appear, not even on pull-to-refresh.
        NotificationCenter.default.publisher(for: .referenceDataChanged)
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.mealTypes = []
                    await self?.load()
                }
            }
            .store(in: &cancellables)
    }

    /// Reads the goal *row*, not `calorieBalance.goal` — the latter falls back
    /// to a server-side default of 2000 for an account that has never set
    /// one, so asking it made this always true and left the goal-not-set card
    /// permanently unreachable.
    var hasGoalSet: Bool {
        (summary?.goals.calories ?? 0) > 0
    }

    /// Water and body entries count here as of Module 4 — without them,
    /// logging a glass of water on an otherwise empty day would flip Today
    /// back to the "nothing logged yet" state and take the water card the
    /// tap came from off screen with it.
    var hasLoggedAnything: Bool {
        !(summary?.foodEntries.isEmpty ?? true)
            || !(summary?.exerciseSessions.userLogged.isEmpty ?? true)
            || water.totalMl > 0
            || bodyMeasurements.exists
    }

    var macroTotals: (protein: Double, carbs: Double, fat: Double) {
        (summary?.foodEntries ?? []).macroTotals
    }

    /// Meal sections to render. A hidden meal still appears on a day that
    /// already has food in it — hiding one stops it being *offered*, it
    /// doesn't retroactively bury what's already logged there.
    var entriesByMeal: [(mealType: MealType, entries: [FoodEntrySummary])] {
        mealTypes.grouped(summary?.foodEntries ?? [])
            .filter { $0.mealType.visible || !$0.entries.isEmpty }
    }

    /// Meals the logging sheets may offer. The endpoint returns hidden ones
    /// so the management screen can list them, so this filter is the caller's
    /// job.
    var loggableMealTypes: [MealType] { mealTypes.visibleOnly }

    /// Pushes today's active energy from Health to the server, if the user
    /// turned that on.
    ///
    /// Runs *before* the summary is fetched so the figure is already in the
    /// balance the screen then renders — otherwise every launch would show a
    /// burn total one load out of date. The write upserts, so repeating it on
    /// every load is harmless.
    ///
    /// Deliberately silent on failure: an unavailable Health store, a refused
    /// permission and a day with no movement are indistinguishable here, and
    /// none of them is something to interrupt the screen for.
    private func syncHealthActiveEnergy() async {
        guard HealthSync.isEnabled else { return }
        guard case .kilocalories(let kilocalories)? = try? await health.activeEnergy(on: today) else { return }
        try? await apiClient.syncActiveEnergy(kilocalories: kilocalories, date: today)
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        today = Date()
        water.setDate(today)
        await syncHealthActiveEnergy()
        do {
            async let summaryTask = apiClient.dailySummary(date: today)
            async let mealTypesTask = mealTypes.isEmpty ? apiClient.mealTypes() : mealTypes
            // The day's check-in and the unit preferences are separate
            // endpoints from the summary (it carries no body data at all —
            // confirmed live), so they're fetched alongside it rather than
            // serially.
            async let bodyTask = apiClient.bodyMeasurements(date: today)
            async let preferencesTask = apiClient.userPreferences()

            let loadedSummary = try await summaryTask
            summary = loadedSummary
            water.adopt(summary: loadedSummary)
            // Quick-add has to name the primary container explicitly, so the
            // screen needs to know which one that is before the first tap.
            await water.loadPrimaryContainer()
            mealTypes = try await mealTypesTask
            bodyMeasurements = try await bodyTask
            preferences = try await preferencesTask
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Re-reads only the check-in row — used after a body sheet saves, so
    /// the card updates without re-fetching the whole day.
    func reloadBodyMeasurements() async {
        do {
            bodyMeasurements = try await apiClient.bodyMeasurements(date: today)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
