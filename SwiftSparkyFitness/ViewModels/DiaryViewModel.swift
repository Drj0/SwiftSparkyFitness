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
import UIKit

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
    /// Module 12: the Exercise segment's "+" — search-and-materialize lives
    /// in its own sheet rather than this view model, same separation Today's
    /// FoodSearchView already has from TodayViewModel.
    @Published var isPresentingExerciseSearch = false

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
    /// Moves earlier when older history arrives (`historyStarts`).
    @Published private(set) var minDate: Date
    /// Today. Moves with the clock (see `rollOverToToday`): the view model
    /// lives as long as its tab, which can be days.
    @Published private(set) var maxDate: Date

    private let apiClient: APIClientProtocol
    private var cancellables = Set<AnyCancellable>()
    /// Which `load()` owns the outcome. Paging quickly overlaps them, and a
    /// slower one for a day already paged past used to land last — one
    /// day's rows under another day's header, there to edit or delete.
    private var loadGeneration = 0

    /// When a horizontal day swipe last moved. A button under the finger
    /// still fires on the release that ends a swipe — one across a meal
    /// header collapsed it as well as changing the day — so the buttons a
    /// swipe can cross ask `isMidDaySwipe` first. A time rather than a
    /// flag, so a drag the system cancels can't leave buttons dead. Not
    /// published: nothing draws from it.
    var lastDaySwipeAt = Date.distantPast
    var isMidDaySwipe: Bool { Date().timeIntervalSince(lastDaySwipeAt) < 0.3 }

    /// The diary's start moved earlier: on this device's own diary that
    /// happens when iCloud or a restored file brings back older days.
    func historyStarts(_ createdAt: Date?) {
        let start = min(Calendar.current.startOfDay(for: createdAt ?? Date()), maxDate)
        if start < minDate { minDate = start }
    }

    init(user: SessionUser, apiClient: APIClientProtocol = AppServices.client) {
        self.apiClient = apiClient
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        maxDate = today
        minDate = min(calendar.startOfDay(for: user.createdAt ?? Date()), today)
        selectedDate = today
        water = WaterViewModel(date: today, apiClient: apiClient)
        // Same reason as TodayViewModel: `water` publishes on its own, but
        // this screen renders the section header's total, the summary card's
        // water ring and the has-anything-logged branch off it.
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

        // Midnight while open, or waking up on a later day: iOS delivers the
        // time-change notice on resume, and becoming active covers the rest.
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor in self?.rollOverToToday() }
            }
            .store(in: &cancellables)
    }

    /// A screen left on today follows today. Without this, opening the app
    /// the next morning showed "Yesterday" with Next disabled, and every
    /// "+", quick log and "Log again" landed on yesterday.
    func rollOverToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        guard today > maxDate else { return }
        let wasOnToday = Calendar.current.isDate(selectedDate, inSameDayAs: maxDate)
        maxDate = today
        guard wasOnToday else { return }
        lastPageDirection = .forward
        selectedDate = today
        Task { await load() }
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
        guard !isMidDaySwipe else { return }
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
        loadGeneration += 1
        let generation = loadGeneration
        let date = selectedDate
        isLoading = true
        errorMessage = nil
        defer { if generation == loadGeneration { isLoading = false } }
        water.setDate(date)
        await HealthWorkoutImporter.importWorkouts(on: date, apiClient: apiClient)
        do {
            async let summaryTask = apiClient.dailySummary(date: date)
            async let mealTypesTask = mealTypes.isEmpty ? apiClient.mealTypes() : mealTypes
            async let bodyTask = apiClient.bodyMeasurements(date: date)
            async let preferencesTask = apiClient.userPreferences()

            let loadedSummary = try await summaryTask
            guard generation == loadGeneration else { return }
            summary = loadedSummary
            water.adopt(summary: loadedSummary)
            // Quick-add has to name the primary container explicitly, so the
            // screen needs to know which one that is before the first tap.
            await water.loadPrimaryContainer()
            let loadedMealTypes = try await mealTypesTask
            let loadedBody = try await bodyTask
            let loadedPreferences = try await preferencesTask
            guard generation == loadGeneration else { return }
            mealTypes = loadedMealTypes
            bodyMeasurements = loadedBody
            preferences = loadedPreferences
            // The ledger is what makes Diary's water rows individually
            // deletable, so it's loaded after the total is on screen rather
            // than blocking it.
            await water.loadEntries()
        } catch {
            guard generation == loadGeneration else { return }
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

    /// The day list's "Log again": the same session copied to `date` —
    /// usually today, from a past day's row. One tap for "I did this again".
    @discardableResult
    func logAgain(_ entry: ExerciseSessionSummary, on date: Date) async -> Bool {
        guard entry.exerciseId != nil else { return false }
        do {
            _ = try await apiClient.createExerciseEntry(ExerciseEntryInput(repeating: entry, on: date))
            Haptics.success()
            await load()
            return true
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
            return false
        }
    }

    /// Against the clock, not `maxDate`, so it's right even in the moment
    /// before a rollover lands.
    var isViewingToday: Bool {
        Calendar.current.isDateInToday(selectedDate)
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
