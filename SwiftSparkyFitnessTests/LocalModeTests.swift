//
//  LocalModeTests.swift
//  SwiftSparkyFitnessTests
//
//  Module 10's local-only data layer, exercised through the same
//  `APIClientProtocol` every screen calls.
//
//  These began as a throwaway verification pass over `LocalAPIClient` and are
//  kept because they caught two real bugs (a meal rename leaving logged rows
//  grouped under the old name, and the Apple Health sentinel being offered as
//  a loggable activity), both pinned below. The cases the main suite's
//  "Local-only mode" section already covers are not repeated here.
//
//  Every test runs against an isolated in-memory store, so nothing touches the
//  real one on disk.
//

import XCTest
@testable import SwiftSparkyFitness

@MainActor
final class LocalModeTests: XCTestCase {

    private func makeLocal() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    /// Fixed calendar days rather than offsets from today: the range reads
    /// below predicate on the `yyyy-MM-dd` key, and a literal key is what
    /// makes an off-by-one-day failure readable.
    private func day(_ key: String) -> Date { LocalDay.date(key)! }

    private func food(_ id: String, calories: Double = 200) -> Food {
        Food(
            id: id,
            name: "Food \(id)",
            brand: nil,
            defaultVariant: FoodVariant(
                id: "\(id)-variant",
                servingSize: 100,
                servingUnit: "g",
                calories: calories,
                protein: 10,
                carbs: 20,
                fat: 5
            )
        )
    }

    private func seedFood(_ client: LocalAPIClient, id: String, calories: Double = 200) async throws -> Food {
        try await client.materializeExternalFood(food(id, calories: calories))
    }

    // MARK: - Range reads (Progress)

    /// Progress reads raw entries for a span and sums them itself. The span is
    /// expressed as a string comparison on `dayKey`, which is the one part of
    /// this layer that isn't obviously correct by reading it — `#Predicate`
    /// has to support `>=`/`<=` on a String for any of Progress to work.
    func testFoodEntryRangeReturnsOnlyTheDaysInsideIt() async throws {
        let local = makeLocal()
        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "breakfast", quantity: 100, entryDate: day("2026-09-10")))
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day("2026-09-15")))
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day("2026-10-01")))

        let rows = try await local.foodEntries(from: day("2026-09-01"), to: day("2026-09-30"))

        XCTAssertEqual(rows.map(\.entryDate).sorted(), ["2026-09-10", "2026-09-15"], "the October row is outside the range")
        // Stored already scaled: 100 g of a 100 g / 200 kcal food is 200, 50 g is 100.
        XCTAssertEqual(rows.compactMap(\.calories).reduce(0, +), 300, accuracy: 0.001)
    }

    func testBodyMeasurementRangeReturnsOnlyTheDaysInsideIt() async throws {
        let local = makeLocal()
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: day("2026-09-05"), values: [.weight: 80]))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: day("2026-09-20"), values: [.weight: 79]))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: day("2026-08-01"), values: [.weight: 82]))

        let rows = try await local.bodyMeasurements(from: day("2026-09-01"), to: day("2026-09-30"))

        XCTAssertEqual(rows.count, 2, "the August check-in is outside the range")
    }

    // MARK: - Goals

    /// A goal that changes mid-range has to step on the day it was set, not
    /// apply retroactively — the Progress goal line draws exactly this.
    func testGoalsRangeStepsOnTheDayTheNewGoalWasSet() async throws {
        let local = makeLocal()
        try await local.saveGoals(NutritionGoals(raw: ["calories": .number(2000)]), startingOn: day("2026-09-01"))
        try await local.saveGoals(NutritionGoals(raw: ["calories": .number(2400)]), startingOn: day("2026-09-15"))

        let byDay = try await local.goals(from: day("2026-09-01"), to: day("2026-09-20"))

        XCTAssertEqual(byDay["2026-09-14"]?.calories, 2000)
        XCTAssertEqual(byDay["2026-09-15"]?.calories, 2400, "the new goal applies from its own day")
        XCTAssertEqual(byDay["2026-09-20"]?.calories, 2400)
    }

    /// Goals are carried as an opaque key/value bag so columns this app
    /// doesn't model survive a round trip. Server mode gets that for free from
    /// the wire format; local mode has to store the bag rather than the four
    /// fields it happens to edit, or every save would silently drop the
    /// sodium, fibre and per-meal split the web client can set.
    func testGoalsRoundTripPreservesColumnsTheAppDoesNotModel() async throws {
        let local = makeLocal()
        var goals = NutritionGoals(raw: [
            "calories": .number(2000),
            "sodium": .number(2300),
            "protein_percentage": .null,
            "custom_nutrients": .object(["x": .number(1)])
        ])
        goals.calories = 2250
        try await local.saveGoals(goals, startingOn: day("2026-09-10"))

        let back = try await local.goals(date: day("2026-09-10"))
        let payload = back.writePayload(startingOn: "2026-09-10")

        XCTAssertEqual(back.calories, 2250)
        XCTAssertEqual(payload["p_sodium"], .number(2300), "unmodelled column dropped: \(payload.keys.sorted())")
        XCTAssertEqual(payload["p_protein_percentage"], .null, "a null percentage became something else")
        XCTAssertEqual(payload["custom_nutrients"], .object(["x": .number(1)]))
    }

    /// Saving twice on one date replaces that date's row. Appending instead
    /// would leave the carry-forward read picking between two rows with the
    /// same start date.
    func testSavingGoalsTwiceOnADateReplacesRatherThanDuplicates() async throws {
        let local = makeLocal()
        try await local.saveGoals(NutritionGoals(raw: ["calories": .number(2000)]), startingOn: day("2026-09-10"))
        try await local.saveGoals(NutritionGoals(raw: ["calories": .number(2500)]), startingOn: day("2026-09-10"))

        let stored = try await local.goals(date: day("2026-09-10"))

        XCTAssertEqual(stored.calories, 2500)
        XCTAssertEqual(local.store.all(LocalGoalRow.self).count, 1)
    }

    // MARK: - Tap-to-edit

    /// Diary and Today open an entry for editing by rebuilding a `Food` from
    /// the logged row, which needs both ids and the *unscaled* variant. A row
    /// missing either just doesn't respond to a tap — no error, nothing.
    func testALoggedFoodRowCanBeReopenedAndResaved() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        let food = try await seedFood(local, id: "f1", calories: 200)
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "breakfast", quantity: 250, entryDate: date))

        let candidates = try await local.dailySummary(date: date).foodEntries
        let entry = try XCTUnwrap(candidates.first)
        XCTAssertEqual(entry.calories, 500, accuracy: 0.001)
        XCTAssertEqual(entry.mealType, "Breakfast", "Diary groups on this name")

        let editable = try XCTUnwrap(entry.editableFood, "the row is not tap-to-edit")
        XCTAssertEqual(editable.defaultVariant?.calories ?? 0, 200, accuracy: 0.001, "the sheet would reopen at the wrong base")
        XCTAssertEqual(editable.defaultVariant?.servingSize, 100)

        try await local.updateFoodEntry(
            id: entry.id,
            FoodEntryInput(food: editable, mealTypeId: try XCTUnwrap(entry.mealTypeId), quantity: 100, entryDate: date)
        )

        let after = try await local.dailySummary(date: date).foodEntries
        XCTAssertEqual(after.count, 1, "an edit replaced the row rather than adding one")
        XCTAssertEqual(after.first?.calories ?? 0, 200, accuracy: 0.001)
    }

    func testALoggedExerciseRowCanBeReopenedAndResaved() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        let exercise = try await local.findOrCreateExercise(named: "Run")
        _ = try await local.createExerciseEntry(
            ExerciseEntryInput(exerciseId: exercise.id, modality: .duration, entryDate: date, durationMinutes: 30, caloriesBurned: 300)
        )

        let candidates = try await local.dailySummary(date: date).exerciseSessions
        let session = try XCTUnwrap(candidates.first)
        XCTAssertEqual(session.name, "Run", "the sheet would open with an empty activity name")

        _ = try await local.updateExerciseEntry(
            id: session.id,
            ExerciseEntryInput(
                exerciseId: try XCTUnwrap(session.exerciseId, "the row is not tap-to-edit"),
                modality: .duration, entryDate: date, durationMinutes: 45, caloriesBurned: 450
            )
        )

        let reread = try await local.dailySummary(date: date).exerciseSessions
        let after = try XCTUnwrap(reread.first)
        XCTAssertEqual(after.durationMinutes, 45)
        XCTAssertEqual(after.caloriesBurned, 450)
        XCTAssertEqual(after.name, "Run")
    }

    // MARK: - Water

    /// The "−" control is an undo for hand-logged drinks. Water that came from
    /// somewhere else has to survive it, which is the distinction the ledger's
    /// `source` column exists to make.
    func testUndoingDrinksLeavesWaterThatWasNotHandLogged() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        _ = try await local.adjustWater(date: date, drinks: 4)
        local.store.insert(LocalWaterEntry(dayKey: LocalDay.key(date), waterMl: 500, source: "provider"))

        let totals = try await local.adjustWater(date: date, drinks: -99)

        XCTAssertEqual(totals.manualMl, 0)
        XCTAssertEqual(totals.waterMl, 500, "the undo removed water it didn't log")
    }

    /// The card fires optimistically, so taps and undos arrive interleaved and
    /// out of step with what's stored. The net has to be right at the end.
    func testAFastSequenceOfTapsSettlesOnTheRightTotal() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        var last = WaterTotals.zero
        for delta in [1, 1, 1, -1, 1, 1, -1, 1] {
            last = try await local.adjustWater(date: date, drinks: delta)
        }

        let ledger = try await local.waterLog(date: date)

        XCTAssertEqual(last.waterMl, 1000, "net +4 drinks at 250 ml")
        XCTAssertEqual(ledger.count, 4, "the ledger should hold one row per surviving drink")
    }

    /// A tap is worth the primary container's volume only when the caller says
    /// so — the same contract the server has, where nothing consults the
    /// primary on its own.
    func testAQuickAddIsWorthTheContainerItNames() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        let container = try await local.createWaterContainer(WaterContainerInput(name: "Bottle", volume: 750))
        XCTAssertTrue(container.isPrimary, "the first container added becomes primary")

        let named = try await local.adjustWater(date: date, drinks: 1, containerId: container.id)
        let bare = try await local.adjustWater(date: date, drinks: 1)

        XCTAssertEqual(named.waterMl, 750)
        XCTAssertEqual(bare.waterMl - named.waterMl, 250, "a tap naming no container is the generic 250 ml")
    }

    func testAnExactAmountIsLoggedAsOneDeletableLedgerRow() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        _ = try await local.logWaterAmount(date: date, milliliters: 300)

        let entries = try await local.waterLog(date: date)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.waterMl, 300)

        try await local.deleteWaterLogEntry(id: try XCTUnwrap(entries.first).id)

        let after = try await local.waterTotals(date: date)
        XCTAssertEqual(after.waterMl, 0)
    }

    func testWaterDoesNotLeakIntoTheNextDay() async throws {
        let local = makeLocal()
        _ = try await local.adjustWater(date: day("2026-09-10"), drinks: 2)

        let nextDay = try await local.waterTotals(date: day("2026-09-11"))
        let theDay = try await local.dailySummary(date: day("2026-09-10"))

        XCTAssertEqual(nextDay.waterMl, 0)
        XCTAssertEqual(theDay.waterIntake, 500)
    }

    // MARK: - Meal categories

    /// **Regression.** Entries store the meal's name alongside its id, because
    /// that's the shape the day screens group on. Renaming the category used
    /// to update the category alone, so every row already logged against it
    /// stayed grouped under the old name until it happened to be re-saved.
    func testRenamingAMealAlsoRenamesTheRowsAlreadyLoggedAgainstIt() async throws {
        let local = makeLocal()
        let meal = try await local.createMealType(name: "Supper", sortOrder: 50)
        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 100, entryDate: day("2026-09-10")))

        _ = try await local.updateMealType(id: meal.id, MealTypeInput(name: "Tea"))

        let candidates = try await local.dailySummary(date: day("2026-09-10")).foodEntries
        let entry = try XCTUnwrap(candidates.first)
        XCTAssertEqual(entry.mealType, "Tea", "Diary groups by the stored name, which went stale after the rename")
    }

    /// The refusal to delete a meal still holding food has to lift once the
    /// food is gone, or the category is permanently undeletable.
    func testAMealCanBeDeletedOnceItsEntriesAre() async throws {
        let local = makeLocal()
        let meal = try await local.createMealType(name: "Supper", sortOrder: 50)
        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 100, entryDate: day("2026-09-10")))

        let candidates = try await local.dailySummary(date: day("2026-09-10")).foodEntries
        let entry = try XCTUnwrap(candidates.first)
        try await local.deleteFoodEntry(id: entry.id)
        try await local.deleteMealType(id: meal.id)

        let remaining = try await local.mealTypes()
        XCTAssertEqual(remaining.count, 4, "only the four seeded defaults should be left")
    }

    /// Hiding a meal stops it being offered for new entries; it must not
    /// orphan what was already logged under it.
    func testHidingAMealKeepsGroupingTheEntriesItAlreadyHas() async throws {
        let local = makeLocal()
        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "snacks", quantity: 100, entryDate: day("2026-09-10")))

        _ = try await local.updateMealType(id: "snacks", MealTypeInput(isVisible: false))

        let candidates = try await local.dailySummary(date: day("2026-09-10")).foodEntries
        let entry = try XCTUnwrap(candidates.first)
        XCTAssertEqual(entry.mealType, "Snacks")
    }

    /// Deleting a default is refused the same way renaming one is — the
    /// management screen is built around the server's asymmetry and local mode
    /// has to agree with it.
    func testDeletingASystemDefaultMealIsRefused() async throws {
        let local = makeLocal()
        do {
            try await local.deleteMealType(id: "breakfast")
            XCTFail("deleting a system default should be refused")
        } catch {}

        let remaining = try await local.mealTypes()
        XCTAssertEqual(remaining.count, 4)
    }

    // MARK: - Body measurements

    /// A day with nothing logged answers "none" rather than throwing — the
    /// weight card asks for every day it shows, most of which are empty.
    func testADayWithNoCheckInAnswersNothingLoggedRatherThanFailing() async throws {
        let local = makeLocal()
        let measurements = try await local.bodyMeasurements(date: day("2026-09-10"))
        XCTAssertEqual(measurements, .none)
    }

    func testDeletingTheDaysCheckInClearsIt() async throws {
        let local = makeLocal()
        let date = day("2026-09-10")
        let saved = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: date, values: [.weight: 80]))

        try await local.deleteBodyMeasurements(id: try XCTUnwrap(saved.id))

        let after = try await local.bodyMeasurements(date: date)
        XCTAssertEqual(after, .none)
    }

    // MARK: - Food search

    /// With no server there is no provider proxy, so the catalogue search is
    /// the user's own foods: matched on name *and* brand, and ranked for the
    /// idle state by what's actually been logged.
    func testTheLocalCatalogueIsSearchableByNameAndBrand() async throws {
        let local = makeLocal()
        let apple = try await local.createCustomFood(
            CustomFoodInput(name: "Apple", brand: nil, servingSize: 100, servingUnit: "g",
                            calories: 52, protein: 0, carbs: 14, fat: 0)
        )
        let bread = try await local.createCustomFood(
            CustomFoodInput(name: "Bread", brand: "Warby", servingSize: 100, servingUnit: "g",
                            calories: 250, protein: 9, carbs: 45, fat: 3)
        )
        try await local.createFoodEntry(FoodEntryInput(food: apple, mealTypeId: "breakfast", quantity: 100, entryDate: Date()))
        try await local.createFoodEntry(FoodEntryInput(food: bread, mealTypeId: "lunch", quantity: 100, entryDate: Date()))
        try await local.createFoodEntry(FoodEntryInput(food: bread, mealTypeId: "dinner", quantity: 100, entryDate: Date()))

        let suggestions = try await local.foodSuggestions()
        XCTAssertEqual(suggestions.topFoods.first?.name, "Bread", "top foods are ranked by how often a food is logged")

        let byName = try await local.searchFoods(query: "app")
        let byBrand = try await local.searchFoods(query: "warby")
        let noMatch = try await local.searchFoods(query: "zzz")
        XCTAssertEqual(byName.map(\.name), ["Apple"])
        XCTAssertEqual(byBrand.map(\.name), ["Bread"], "the brand should be searchable, not just the name")
        XCTAssertTrue(noMatch.isEmpty)

        // USDA needs a key that only a server holds; empty is the documented
        // contract for "no provider configured", not an error.
        let usda = try await local.searchUsdaFoods(query: "apple")
        XCTAssertTrue(usda.isEmpty)
    }

    /// Logging the same provider result twice must reuse the food it created
    /// the first time, or the catalogue fills with duplicates of whatever the
    /// user eats most.
    func testMaterialisingTheSameExternalFoodTwiceReusesIt() async throws {
        let local = makeLocal()
        var external = food("off-123")
        external.source = .openFoodFacts

        _ = try await local.materializeExternalFood(external)
        _ = try await local.materializeExternalFood(external)

        XCTAssertEqual(local.store.all(LocalFood.self).count, 1)
    }

    /// The Log Food sheet's "5× this week" and one-tap re-log amount, read
    /// from the diary on this device (server mode reads the same store).
    func testFoodLogStatsCountTheWeekAndRememberTheLastAmount() async throws {
        let local = makeLocal()
        let roti = try await seedFood(local, id: "roti")
        let calendar = Calendar.current
        let today = Date()
        let daysAgo = { (n: Int) in calendar.date(byAdding: .day, value: -n, to: today)! }
        try await local.createFoodEntry(FoodEntryInput(food: roti, mealTypeId: "lunch", quantity: 3, entryDate: daysAgo(20)))
        try await local.createFoodEntry(FoodEntryInput(food: roti, mealTypeId: "lunch", quantity: 2, entryDate: daysAgo(3)))
        try await local.createFoodEntry(FoodEntryInput(food: roti, mealTypeId: "dinner", quantity: 4, entryDate: daysAgo(1)))

        let stats = await local.foodLogStats(since: daysAgo(30))
        let stat = stats[FoodLogStat.key(for: roti)]
        XCTAssertEqual(stat?.timesThisWeek, 2, "the entry 20 days ago is outside the week")
        XCTAssertEqual(stat?.lastQuantity, 4, "the latest entry's amount")

        let recent = await local.foodLogStats(since: daysAgo(2))
        XCTAssertEqual(recent[FoodLogStat.key(for: roti)]?.timesThisWeek, 1, "only reads from `since`")
    }

    /// **Regression.** `syncActiveEnergy` has to create an activity row to
    /// hang the day's Health figure off, and that row used to show up in
    /// activity search — so "Active Calories" could be logged as a workout,
    /// which `dailySummary` would then read back as Health's own figure.
    func testTheHealthSentinelIsNotOfferedAsAnActivity() async throws {
        let local = makeLocal()
        try await local.syncActiveEnergy(kilocalories: 500, date: Date())

        let hits = try await local.searchExercises(query: "cal")

        XCTAssertTrue(hits.isEmpty, "the Health sentinel is offered as a loggable activity: \(hits.map(\.name))")
    }

    // MARK: - Day boundaries

    /// The day key is built in the device's own timezone, so a late-night
    /// entry belongs to the day the user thinks they're in. A UTC-based key
    /// would file anything after early evening onto tomorrow east of Greenwich.
    func testALateNightEntryLandsOnTheDayItWasLogged() async throws {
        let local = makeLocal()
        var components = DateComponents()
        components.year = 2026; components.month = 9; components.day = 10
        components.hour = 23; components.minute = 45
        let lateNight = try XCTUnwrap(Calendar.current.date(from: components))

        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "dinner", quantity: 100, entryDate: lateNight))

        let theDay = try await local.dailySummary(date: day("2026-09-10"))
        let nextDay = try await local.dailySummary(date: day("2026-09-11"))
        XCTAssertEqual(theDay.foodEntries.count, 1)
        XCTAssertEqual(nextDay.foodEntries.count, 0)
    }

    // MARK: - Preferences

    /// Preferences are seeded with the same defaults a fresh server account
    /// gets, and there is exactly one row to update rather than a new one per
    /// save.
    func testPreferencesStartAtTheServersDefaultsAndRoundTrip() async throws {
        let local = makeLocal()
        let initial = try await local.userPreferences()
        XCTAssertEqual(initial.defaultWeightUnit, "kg")

        let updated = try await local.updateUserPreference(.weight, to: "lbs")
        XCTAssertEqual(updated.defaultWeightUnit, "lbs")

        let reread = try await local.userPreferences()
        XCTAssertEqual(reread.defaultWeightUnit, "lbs")
        XCTAssertEqual(local.store.all(LocalPreferences.self).count, 1)
    }

    // MARK: - Choosing the mode

    /// **Regression.** `AuthViewModel` is a `@StateObject` on `ContentView`,
    /// so it is built on the first render — which on a fresh install happens
    /// *before* any mode has been chosen. It used to capture the client in
    /// `init`, which pinned it to `APIClient` for the life of the process: on
    /// a real device, choosing "Use on this device" then fired `get-session`
    /// at the placeholder address, hung on a spinner for the full timeout and
    /// landed on the can't-reach-the-server screen, which offered no way back
    /// to local mode. Resolving per use is what fixes it, and this pins the
    /// order — the view model is built with no mode set, as the app does it.
    func testChoosingLocalModeAfterLaunchStillAvoidsTheNetwork() async throws {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: AppMode.defaultsKey)
        addTeardownBlock {
            if let original {
                defaults.set(original, forKey: AppMode.defaultsKey)
            } else {
                defaults.removeObject(forKey: AppMode.defaultsKey)
            }
        }
        defaults.removeObject(forKey: AppMode.defaultsKey)

        // Built before a mode exists, exactly as ContentView builds it.
        let auth = AuthViewModel()
        AppMode.current = .local

        await auth.restoreSession()

        XCTAssertNotNil(auth.session, "local mode has no login to offer, so a session must always exist")
        XCTAssertEqual(auth.restoreState, .done, "an .unreachable state here means it asked the network")
    }

    // MARK: - Deleting everything

    /// Settings' "Delete all local data" is the only irreversible control in
    /// the app, and there's no server copy behind it. It has to leave a store
    /// that works — i.e. reseeded, not merely empty, or the app comes back
    /// with no meal categories to log against.
    func testDeletingEverythingLeavesAWorkingEmptyStore() async throws {
        let local = makeLocal()
        let food = try await seedFood(local, id: "f1")
        try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "breakfast", quantity: 100, entryDate: Date()))
        _ = try await local.adjustWater(date: Date(), drinks: 2)

        try local.store.deleteEverything()

        let meals = try await local.mealTypes()
        let today = try await local.dailySummary(date: Date())
        let preferences = try await local.userPreferences()
        XCTAssertEqual(meals.count, 4, "meal categories were not reseeded after the wipe")
        XCTAssertEqual(today.foodEntries.count, 0)
        XCTAssertEqual(today.waterIntake, 0)
        XCTAssertEqual(preferences.defaultWeightUnit, "kg")
    }

    // MARK: - Delete all local data

    /// "Delete all local data" destroys an on-disk store's files rather than
    /// deleting its rows (row deletes would reach iCloud), then reopens it:
    /// empty, and still taking writes — not a destroyed store that loses
    /// every entry after it.
    func testErasingThisDevicesCopyLeavesAnEmptyWorkingStore() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("erase-\(UUID().uuidString).store")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let store = try LocalStore(url: url)
        let local = LocalAPIClient(store: store)
        let run = try await local.findOrCreateExercise(named: "Run")
        _ = try await local.createExerciseEntry(
            ExerciseEntryInput(exerciseId: run.id, modality: .duration, entryDate: Date(), durationMinutes: 30, caloriesBurned: 300)
        )
        XCTAssertFalse(store.all(LocalExerciseEntry.self).isEmpty)

        try store.eraseThisDeviceCopy()

        XCTAssertTrue(store.all(LocalExerciseEntry.self).isEmpty)
        XCTAssertTrue(store.all(LocalExercise.self).isEmpty)
        let again = try await local.findOrCreateExercise(named: "Swim")
        _ = try await local.createExerciseEntry(
            ExerciseEntryInput(exerciseId: again.id, modality: .duration, entryDate: Date(), durationMinutes: 20, caloriesBurned: 150)
        )
        XCTAssertEqual(store.all(LocalExerciseEntry.self).count, 1)
    }

    /// Leaving a mode forgets whoever was signed in to it. Holding on let
    /// the on-device user open server mode's tabs after Delete all local
    /// data, writing to no account, when the chosen server didn't answer.
    func testAModeChangeForgetsTheSignedInUser() async throws {
        let auth = AuthViewModel(apiClient: LocalAPIClient(store: LocalStore(inMemory: true)))
        await auth.restoreSession()
        XCTAssertNotNil(auth.session)

        auth.resetForModeChange(restoring: false)
        XCTAssertNil(auth.session)
        XCTAssertEqual(auth.restoreState, .done)

        auth.resetForModeChange(restoring: true)
        XCTAssertEqual(auth.restoreState, .restoring, "the frame before the new mode's restore isn't the login form")
    }
}
