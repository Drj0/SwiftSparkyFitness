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
    @Published var isPresentingLogWeight = false
    @Published var isPresentingLogMeasurements = false
    @Published var isPresentingSetGoals = false
    /// The food whose editor is open — tapped, or Edit from its menu.
    @Published var editingFoodEntry: FoodEntrySummary?
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
    /// The most recent weight from an earlier day, when today's is nil —
    /// so BodyCard can show a real number instead of a bare "Log today's →"
    /// on a day the user simply hasn't weighed in yet. `nil` whenever
    /// today's own weight exists, so it's unambiguous which figure a
    /// non-nil `bodyMeasurements.weight` vs. this represents.
    @Published private(set) var lastLoggedWeight: (value: Double, date: Date)?
    /// Whether this account has ever logged a food — nil until known. Only
    /// someone who hasn't gets the "first bite" nudge; an empty day for
    /// anyone else is just an empty day.
    @Published private(set) var hasLoggedFoodBefore: Bool?

    var showsFirstFoodNudge: Bool {
        isViewingToday && hasLoggedFoodBefore == false && (summary?.foodEntries.isEmpty ?? false)
    }
    /// Water is its own small view model so Today's card and Diary's water
    /// section share one set of rules.
    let water: WaterViewModel

    private let apiClient: APIClientProtocol
    private let health: HealthKitReading
    private var cancellables = Set<AnyCancellable>()
    /// The day on screen. Named `today` from before the week strip existed;
    /// it's only a past day when `selectedDay` says so.
    private(set) var today = Date()
    /// A past day picked from the week strip, or nil to follow the real
    /// today (so a screen left open over midnight still rolls forward).
    @Published private(set) var selectedDay: Date?

    var isViewingToday: Bool { selectedDay == nil }

    /// The day `summary` was loaded for. Differs from `today` while a
    /// newly picked day is still loading, so the screen can dim the old one.
    @Published private(set) var loadedDay: Date?
    var isSwitchingDay: Bool {
        guard let loadedDay else { return false }
        return !Calendar.current.isDate(loadedDay, inSameDayAs: today)
    }

    /// The day new entries are logged to. `today` is a load-time snapshot,
    /// so after a background trip past midnight it can still be yesterday;
    /// the live case reads the clock instead.
    var entryDate: Date { selectedDay ?? Date() }

    func select(day: Date) async {
        let calendar = Calendar.current
        selectedDay = calendar.isDateInToday(day) ? nil : calendar.startOfDay(for: day)
        await load()
    }

    init(
        apiClient: APIClientProtocol = AppServices.client,
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

    /// Today's exercise card — sums the same `userLogged` sessions
    /// `hasLoggedAnything` already filters the Health "Active Calories"
    /// sentinel out of, so the card can't show a workout the user never
    /// logged.
    private var loggedExerciseSessions: [ExerciseSessionSummary] {
        (summary?.exerciseSessions.userLogged ?? []).filter { !$0.isHealthDuplicate }
    }

    var hasLoggedExercise: Bool { !loggedExerciseSessions.isEmpty }

    var exerciseDurationMinutes: Double {
        loggedExerciseSessions.reduce(0) { $0 + ($1.durationMinutes ?? 0) }
    }

    var exerciseCaloriesBurned: Double {
        loggedExerciseSessions.reduce(0) { $0 + ($1.caloriesBurned ?? 0) }
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
        // Only the live day: browsing a past day shouldn't write to it.
        guard HealthSync.isEnabled, isViewingToday else { return }
        guard case .kilocalories(let kilocalories)? = try? await health.activeEnergy(on: today) else { return }
        try? await apiClient.syncActiveEnergy(kilocalories: kilocalories, date: today)
    }

    /// The day's steps from Health, for the Steps card. Read only; nothing
    /// here is written anywhere. Nil when Health is off or has none.
    @Published private(set) var healthSteps: Int?

    var showsHealthActivity: Bool { HealthSync.isEnabled && health.isAvailable }

    /// Health's active energy as *stored* for the day, not a live read: it is
    /// the figure the balance actually uses, so the card can't disagree with
    /// the ring (a live read on a past day could, since only today is synced).
    var healthActiveKilocalories: Double? { summary?.exerciseSessions.healthActiveEnergy }

    /// Logged exercise on top of Health's active energy in the day's burn:
    /// what Health doesn't already contain (see `dayBurn`).
    var extraLoggedKilocalories: Double { summary?.exerciseSessions.handLoggedKilocalories ?? 0 }

    private static let stepsAuthorizationKey = "healthStepsAuthorizationRequested"

    private func loadHealthSteps() async {
        guard showsHealthActivity else {
            healthSteps = nil
            return
        }
        // Anyone who connected Health before steps were read needs one more
        // answer; HealthKit shows the sheet only for types not yet asked.
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: Self.stepsAuthorizationKey) {
            _ = try? await health.requestAuthorization()
            defaults.set(true, forKey: Self.stepsAuthorizationKey)
        }
        let day = today
        let steps = try? await health.steps(on: day)
        guard day == today else { return }
        healthSteps = steps ?? nil
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let day = selectedDay ?? Date()
        today = day
        water.setDate(day)
        await syncHealthActiveEnergy()
        await HealthWorkoutImporter.importWorkouts(on: day, apiClient: apiClient, health: health)
        do {
            async let summaryTask = apiClient.dailySummary(date: today)
            async let mealTypesTask = mealTypes.isEmpty ? apiClient.mealTypes() : mealTypes
            // The day's check-in and the unit preferences are separate
            // endpoints from the summary (it carries no body data at all —
            // confirmed live), so they're fetched alongside it rather than
            // serially.
            async let bodyTask = apiClient.bodyMeasurements(date: today)
            // Steps come from Health, not the server, so they load alongside.
            async let stepsTask: Void = loadHealthSteps()
            async let preferencesTask = apiClient.userPreferences()

            let loadedSummary = try await summaryTask
            let loadedMealTypes = try await mealTypesTask
            let loadedBody = try await bodyTask
            let loadedPreferences = try await preferencesTask
            await stepsTask
            // Tapping through the week strip overlaps loads; a slower one for
            // a day the user already left must not paint over the newer day.
            guard day == today else { return }
            summary = loadedSummary
            loadedDay = day
            water.adopt(summary: loadedSummary)
            // Quick-add has to name the primary container explicitly, so the
            // screen needs to know which one that is before the first tap.
            await water.loadPrimaryContainer()
            mealTypes = loadedMealTypes
            bodyMeasurements = loadedBody
            preferences = loadedPreferences
            await loadLastLoggedWeightIfNeeded()
            await learnWhetherFoodWasLoggedBefore(dayHasFood: !loadedSummary.foodEntries.isEmpty)
        } catch {
            guard day == today else { return }
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Set when removing a food fails. Separate from `errorMessage`, which
    /// only shows when the whole day failed to load.
    @Published var deleteError: String?

    func deleteFoodEntry(_ entry: FoodEntrySummary) async {
        do {
            try await apiClient.deleteFoodEntry(id: entry.id)
            Haptics.success()
            await load()
        } catch {
            deleteError = error.localizedDescription
            Haptics.error()
        }
    }

    /// Re-reads only the check-in row — used after a body sheet saves, so
    /// the card updates without re-fetching the whole day.
    func reloadBodyMeasurements() async {
        do {
            bodyMeasurements = try await apiClient.bodyMeasurements(date: today)
            await loadLastLoggedWeightIfNeeded()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    /// The server's recent foods are empty until a first food is logged, on
    /// any device — so no flag of this app's own is needed. Asked once, and
    /// only while it could still be false; a failure counts as "has logged",
    /// since a missing nudge costs nothing and a wrong one reads as a reset.
    private func learnWhetherFoodWasLoggedBefore(dayHasFood: Bool) async {
        if dayHasFood { hasLoggedFoodBefore = true }
        guard hasLoggedFoodBefore == nil else { return }
        guard let suggestions = try? await apiClient.foodSuggestions() else {
            hasLoggedFoodBefore = true
            return
        }
        hasLoggedFoodBefore = !suggestions.recentFoods.isEmpty
    }

    /// Only fetched when today has nothing logged — a day that already has
    /// its own weight never needs a fallback. A year is generous for "most
    /// recent weigh-in"; the range endpoint has no server-side cap, so the
    /// client is what bounds this, same rule Progress already applies to
    /// its own range reads.
    private func loadLastLoggedWeightIfNeeded() async {
        guard bodyMeasurements.weight == nil else {
            lastLoggedWeight = nil
            return
        }
        guard let start = Calendar.current.date(byAdding: .day, value: -365, to: today) else { return }
        // Best-effort: this is a nice-to-have fallback display, not
        // something worth surfacing its own error banner for.
        guard let rows = try? await apiClient.bodyMeasurements(from: start, to: today) else { return }
        // Newest first, per the server's own order (confirmed live) — the
        // first row carrying a weight is the most recent one.
        for row in rows {
            guard let weight = row.measurements.weight,
                  let date = Self.dayFormatter.date(from: row.entryDate) else { continue }
            lastLoggedWeight = (weight, date)
            return
        }
        lastLoggedWeight = nil
    }
}
