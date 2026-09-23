//
//  DiaryViewModel.swift
//  SwiftSparkyFitness
//
//  Diary is Today's "read + edit" counterpart: same GET /api/daily-summary
//  as Today (confirmed live it already carries everything a day view needs
//  — food_id/variant_id/meal_type_id per food entry, exercise_id per
//  session — so there's no separate by-date endpoint to model), just for
//  whatever date is currently selected instead of always today. Editing or
//  deleting here always goes through the same food-entries/exercise-entries
//  calls Module 2's logging sheets use, so Today reads the same underlying
//  state back next time it loads — there's no separate "Diary state" to
//  drift out of sync.
//

import Foundation
import Combine
import SwiftUI

@MainActor
final class DiaryViewModel: ObservableObject {
    @Published private(set) var summary: DailySummary?
    @Published private(set) var mealTypes: [MealType] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var selectedDate: Date

    /// Which way the last date change travelled, so the view can slide the
    /// new day in from the side it came from. Without it a day change swapped
    /// the header instantly and left the *previous* day's rows on screen for
    /// the whole fetch, with nothing saying they were stale.
    enum PageDirection { case forward, backward }
    @Published private(set) var lastPageDirection: PageDirection = .forward

    /// Per-section collapse state, keyed by a stable id ("breakfast",
    /// "exercise", ...) — starts empty (nothing collapsed) rather than
    /// tracking an "expanded" set, so a newly-appearing section (e.g. the
    /// first time Water has anything in it) defaults to visible.
    @Published var collapsedSections: Set<String> = []

    @Published var editingFoodEntry: FoodEntrySummary?
    @Published var editingExerciseEntry: ExerciseSessionSummary?

    // MARK: - Module 4

    /// The selected day's itemised water ledger and its single check-in row.
    /// Neither is part of GET /api/daily-summary (it carries a water *total*
    /// and no body data at all), so both are separate reads keyed to the
    /// same selected date.
    let water: WaterViewModel
    @Published private(set) var bodyMeasurements: BodyMeasurements = .none
    @Published private(set) var preferences: UserPreferences = .serverDefaults
    @Published var isPresentingBodySheet: LogBodyViewModel.Kind?

    /// Confirmed with the user: Diary can't navigate before the account
    /// existed (nothing to show) or past today (nothing logged yet).
    let minDate: Date
    let maxDate: Date

    private let apiClient: APIClientProtocol
    private var cancellables = Set<AnyCancellable>()

    init(user: SessionUser, apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
        let calendar = Calendar.current
        maxDate = calendar.startOfDay(for: Date())
        minDate = min(calendar.startOfDay(for: user.createdAt ?? Date()), maxDate)
        selectedDate = maxDate
        water = WaterViewModel(date: maxDate, apiClient: apiClient)
        // Same reason as TodayViewModel: `water` publishes on its own, but
        // this screen renders the section header's total, the summary card's
        // water ring and the has-anything-logged branch off it.
        water.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var canGoToPreviousDay: Bool {
        Calendar.current.startOfDay(for: selectedDate) > minDate
    }

    var canGoToNextDay: Bool {
        Calendar.current.startOfDay(for: selectedDate) < maxDate
    }

    func goToPreviousDay() {
        guard canGoToPreviousDay, let previous = Calendar.current.date(byAdding: .day, value: -1, to: selectedDate) else { return }
        lastPageDirection = .backward
        selectedDate = previous
        Task { await load() }
    }

    func goToNextDay() {
        guard canGoToNextDay, let next = Calendar.current.date(byAdding: .day, value: 1, to: selectedDate) else { return }
        lastPageDirection = .forward
        selectedDate = next
        Task { await load() }
    }

    /// From the date-picker sheet — clamps into range instead of rejecting,
    /// since a system DatePicker's own bounds already keep the user from
    /// picking outside [minDate, maxDate] in the first place.
    func jumpToDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        let clamped = min(max(day, minDate), maxDate)
        lastPageDirection = clamped < selectedDate ? .backward : .forward
        selectedDate = clamped
        Task { await load() }
    }

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

    func isCollapsed(_ sectionId: String) -> Bool {
        collapsedSections.contains(sectionId)
    }

    /// Collapsing used to mutate the set bare, so a whole meal's rows blinked
    /// out between frames. The mutation is the animation's trigger, so it has
    /// to be wrapped here rather than at the call site's `isCollapsed` read.
    /// `animated` comes from the view because Reduce Motion lives in the
    /// SwiftUI environment, which a view model can't see.
    func toggleSection(_ sectionId: String, animated: Bool = true) {
        // A hand-rolled disclosure control: the system would fire this for a
        // real DisclosureGroup, so it has to be fired by hand here.
        Haptics.selection()
        var next = collapsedSections
        if next.contains(sectionId) {
            next.remove(sectionId)
        } else {
            next.insert(sectionId)
        }
        if animated {
            withAnimation(.snappy(duration: 0.28)) { collapsedSections = next }
        } else {
            collapsedSections = next
        }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        water.setDate(selectedDate)
        do {
            async let summaryTask = apiClient.dailySummary(date: selectedDate)
            async let mealTypesTask = mealTypes.isEmpty ? apiClient.mealTypes() : mealTypes
            async let bodyTask = apiClient.bodyMeasurements(date: selectedDate)
            async let preferencesTask = apiClient.userPreferences()

            let loadedSummary = try await summaryTask
            summary = loadedSummary
            water.adopt(summary: loadedSummary)
            mealTypes = try await mealTypesTask
            bodyMeasurements = try await bodyTask
            preferences = try await preferencesTask
            // The ledger is what makes Diary's water rows individually
            // deletable, so it's loaded after the total is on screen rather
            // than blocking it.
            await water.loadEntries()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    /// Re-reads just the check-in row — used after a body sheet saves or a
    /// swipe deletes it, so the Body section reflects the change without
    /// re-fetching the whole day.
    func reloadBodyMeasurements() async {
        do {
            bodyMeasurements = try await apiClient.bodyMeasurements(date: selectedDate)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Deletes the day's whole check-in row — weight and every measurement
    /// on it. That's what a swipe on the Body section means, and it's the
    /// only kind of delete the endpoint offers (clearing one field is a
    /// save with that field emptied, which the sheet handles).
    func deleteBodyMeasurements() async {
        guard let id = bodyMeasurements.id else { return }
        do {
            try await apiClient.deleteBodyMeasurements(id: id)
            bodyMeasurements = .none
            // Weight feeds the server's BMR (and so Today's calorie
            // balance), so the day's summary is re-read rather than just
            // dropping the row locally.
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func deleteFoodEntry(_ entry: FoodEntrySummary) async {
        do {
            try await apiClient.deleteFoodEntry(id: entry.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func deleteExerciseEntry(_ entry: ExerciseSessionSummary) async {
        do {
            try await apiClient.deleteExerciseEntry(id: entry.id)
            await load()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
