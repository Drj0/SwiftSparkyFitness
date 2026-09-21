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
    @Published var isPresentingGoalNotice = false
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
    private var cancellables = Set<AnyCancellable>()
    private var today = Date()

    init(apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
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
    }

    var hasGoalSet: Bool {
        (summary?.calorieBalance.goal ?? 0) > 0
    }

    /// Water and body entries count here as of Module 4 — without them,
    /// logging a glass of water on an otherwise empty day would flip Today
    /// back to the "nothing logged yet" state and take the water card the
    /// tap came from off screen with it.
    var hasLoggedAnything: Bool {
        !(summary?.foodEntries.isEmpty ?? true)
            || !(summary?.exerciseSessions.isEmpty ?? true)
            || water.totalMl > 0
            || bodyMeasurements.exists
    }

    var macroTotals: (protein: Double, carbs: Double, fat: Double) {
        (summary?.foodEntries ?? []).macroTotals
    }

    var entriesByMeal: [(mealType: MealType, entries: [FoodEntrySummary])] {
        mealTypes.grouped(summary?.foodEntries ?? [])
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        today = Date()
        water.setDate(today)
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
