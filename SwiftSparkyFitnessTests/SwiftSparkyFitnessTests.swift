//
//  SwiftSparkyFitnessTests.swift
//  SwiftSparkyFitnessTests
//
//  Covers the parts of the Today/Diary state-sync path that don't need a
//  live server: the shared grouping/macro math both screens read off the
//  same DailySummary, the food-entry scale-inversion Diary's edit sheet
//  depends on (this is exactly where a real bug was found live — editing
//  an entry opened the sheet at the food's base serving size instead of
//  the logged quantity), and DiaryViewModel's date-navigation bounds.
//

import XCTest
import Combine
import SwiftUI
import UIKit
@testable import SwiftSparkyFitness

final class SwiftSparkyFitnessTests: XCTestCase {

    // MARK: - Shared grouping/macro math (Today + Diary read this identically)

    func testMacroTotalsSumsAcrossEntries() {
        let entries = [
            FoodEntrySummary(id: "1", foodName: "A", mealType: "breakfast", quantity: 100, unit: "g", calories: 200, protein: 10, carbs: 20, fat: 5, foodId: nil, variantId: nil, mealTypeId: nil, brandName: nil, servingSize: nil, servingUnit: nil),
            FoodEntrySummary(id: "2", foodName: "B", mealType: "lunch", quantity: 50, unit: "g", calories: 100, protein: nil, carbs: 30, fat: nil, foodId: nil, variantId: nil, mealTypeId: nil, brandName: nil, servingSize: nil, servingUnit: nil),
        ]
        let totals = entries.macroTotals
        XCTAssertEqual(totals.protein, 10) // second entry's nil protein doesn't crash or count as anything but 0
        XCTAssertEqual(totals.carbs, 50)
        XCTAssertEqual(totals.fat, 5)
    }

    func testGroupedSortsByMealSortOrderAndKeepsEmptyMeals() {
        let mealTypes = [
            MealType(id: "d", name: "dinner", sortOrder: 40),
            MealType(id: "b", name: "breakfast", sortOrder: 10),
        ]
        let entries = [
            FoodEntrySummary(id: "1", foodName: "Toast", mealType: "breakfast", quantity: 1, unit: "serving", calories: 150, protein: nil, carbs: nil, fat: nil, foodId: nil, variantId: nil, mealTypeId: nil, brandName: nil, servingSize: nil, servingUnit: nil),
        ]
        let grouped = mealTypes.grouped(entries)
        XCTAssertEqual(grouped.map(\.mealType.name), ["breakfast", "dinner"]) // sorted by sortOrder, not input order
        XCTAssertEqual(grouped[0].entries.count, 1)
        XCTAssertEqual(grouped[1].entries.count, 0) // dinner has no entries — still present, not dropped
    }

    // MARK: - FoodEntrySummary.editableFood (Diary's edit-sheet reconstruction)

    /// The exact scenario a live bug was caught in: a 50g/200kcal base
    /// variant logged at 100g (scale 2x) must reconstruct back to the
    /// 50g/200kcal base, not the entry's post-scale 100g/400kcal.
    func testEditableFoodInvertsTheLoggedScale() throws {
        let entry = FoodEntrySummary(
            id: "entry-1", foodName: "Snack Bar", mealType: "breakfast",
            quantity: 100, unit: "g", calories: 400, protein: 20, carbs: 40, fat: 10,
            foodId: "food-1", variantId: "variant-1", mealTypeId: "meal-1", brandName: nil,
            servingSize: 50, servingUnit: "g"
        )
        let food = try XCTUnwrap(entry.editableFood)
        XCTAssertEqual(food.id, "food-1")
        let variant = try XCTUnwrap(food.defaultVariant)
        XCTAssertEqual(variant.servingSize, 50)
        XCTAssertEqual(variant.calories, 200)
        XCTAssertEqual(variant.protein, 10)
        XCTAssertEqual(variant.carbs, 20)
        XCTAssertEqual(variant.fat, 5)
    }

    func testEditableFoodIsNilWithoutTheIdsARealEditNeeds() {
        let entry = FoodEntrySummary(
            id: "entry-1", foodName: "Mystery", mealType: "breakfast",
            quantity: 100, unit: "g", calories: 400, protein: nil, carbs: nil, fat: nil,
            foodId: nil, variantId: "variant-1", mealTypeId: nil, brandName: nil,
            servingSize: 50, servingUnit: "g"
        )
        XCTAssertNil(entry.editableFood) // missing foodId — nothing to PUT against
    }

    // MARK: - DiaryViewModel date bounds

    /// Records what it was asked to do, so a test can assert on the *request*
    /// (which fields a check-in write actually carries, how many drinks a tap
    /// sends) and not just on the resulting published state.
    private final class StubAPIClient: APIClientProtocol {
        var summaryToReturn = DailySummary(
            calorieBalance: .init(eaten: 0, burned: 0, remaining: 0, goal: 0),
            waterIntake: 0, waterIntakeBreakdown: nil,
            goals: .init(protein: nil, carbs: nil, fat: nil, waterGoalMl: nil),
            foodEntries: [], exerciseSessions: []
        )
        var totalsToReturn = WaterTotals.zero
        var logToReturn: [WaterLogEntry] = []
        var bodyToReturn = BodyMeasurements.none
        var preferencesToReturn = UserPreferences.serverDefaults

        var drinkAdjustments: [Int] = []
        var exactAmounts: [Double] = []
        var deletedWaterEntryIds: [String] = []
        var deletedBodyIds: [String] = []
        var upsertedBodyInputs: [BodyMeasurementsInput] = []
        var passwordResetRequests: [String] = []
        var passwordResetError: Error?

        func signIn(email: String, password: String) async throws -> SessionUser { fatalError("unused") }
        func signUp(email: String, password: String) async throws -> SessionUser { fatalError("unused") }
        func currentSession() async throws -> SessionUser? { nil }
        func signOut() async {}
        func requestPasswordReset(email: String) async throws {
            passwordResetRequests.append(email)
            if let passwordResetError { throw passwordResetError }
        }
        func dailySummary(date: Date) async throws -> DailySummary { summaryToReturn }
        func mealTypes() async throws -> [MealType] { [] }
        func searchFoods(query: String) async throws -> [Food] { [] }
        func searchExternalFoods(query: String) async throws -> [Food] { [] }
        func createCustomFood(_ input: CustomFoodInput) async throws -> Food { fatalError("unused") }
        func materializeExternalFood(_ food: Food) async throws -> Food { fatalError("unused") }
        func createFoodEntry(_ input: FoodEntryInput) async throws {}
        func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {}
        func deleteFoodEntry(id: String) async throws {}
        func searchExercises(query: String) async throws -> [Exercise] { [] }
        func findOrCreateExercise(named name: String) async throws -> Exercise { fatalError("unused") }
        func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary { fatalError("unused") }
        func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary { fatalError("unused") }
        func deleteExerciseEntry(id: String) async throws {}

        func userPreferences() async throws -> UserPreferences { preferencesToReturn }
        func waterTotals(date: Date) async throws -> WaterTotals { totalsToReturn }
        func waterLog(date: Date) async throws -> [WaterLogEntry] { logToReturn }
        func adjustWater(date: Date, drinks: Int) async throws -> WaterTotals {
            drinkAdjustments.append(drinks)
            return totalsToReturn
        }
        func logWaterAmount(date: Date, milliliters: Double) async throws -> WaterTotals {
            exactAmounts.append(milliliters)
            return totalsToReturn
        }
        func deleteWaterLogEntry(id: String) async throws { deletedWaterEntryIds.append(id) }
        func bodyMeasurements(date: Date) async throws -> BodyMeasurements { bodyToReturn }
        func upsertBodyMeasurements(_ input: BodyMeasurementsInput) async throws -> BodyMeasurements {
            upsertedBodyInputs.append(input)
            return bodyToReturn
        }
        func deleteBodyMeasurements(id: String) async throws { deletedBodyIds.append(id) }
    }

    @MainActor
    func testDateBoundsClampToAccountCreationAndToday() {
        let calendar = Calendar.current
        let createdAt = calendar.date(byAdding: .day, value: -3, to: Date())!
        let user = SessionUser(email: "demo@sparkyfitness.com", name: "Demo", createdAt: createdAt)
        let viewModel = DiaryViewModel(user: user, apiClient: StubAPIClient())

        // Starts on today, at the max bound — can't go forward.
        XCTAssertFalse(viewModel.canGoToNextDay)
        XCTAssertTrue(viewModel.canGoToPreviousDay)

        viewModel.goToPreviousDay()
        viewModel.goToPreviousDay()
        viewModel.goToPreviousDay()
        // Now 3 days back == account creation date, the min bound.
        XCTAssertFalse(viewModel.canGoToPreviousDay)
        XCTAssertTrue(viewModel.canGoToNextDay)

        // One more attempt must not walk past the bound.
        viewModel.goToPreviousDay()
        XCTAssertFalse(viewModel.canGoToPreviousDay)
    }

    @MainActor
    func testJumpToDateClampsOutOfRangeInput() {
        let calendar = Calendar.current
        let createdAt = calendar.date(byAdding: .day, value: -3, to: Date())!
        let user = SessionUser(email: "demo@sparkyfitness.com", name: "Demo", createdAt: createdAt)
        let viewModel = DiaryViewModel(user: user, apiClient: StubAPIClient())

        let farFuture = calendar.date(byAdding: .year, value: 1, to: Date())!
        viewModel.jumpToDate(farFuture)
        XCTAssertFalse(viewModel.canGoToNextDay) // clamped to today, not the requested future date

        let farPast = calendar.date(byAdding: .year, value: -1, to: Date())!
        viewModel.jumpToDate(farPast)
        XCTAssertFalse(viewModel.canGoToPreviousDay) // clamped to account creation date
    }

    // MARK: - Module 4: water

    private func summary(waterMl: Double, manualMl: Double, foodMl: Double = 0, goalMl: Double? = nil) -> DailySummary {
        DailySummary(
            calorieBalance: .init(eaten: 0, burned: 0, remaining: 0, goal: 2000),
            waterIntake: waterMl,
            waterIntakeBreakdown: WaterTotals(waterMl: waterMl, manualMl: manualMl, ledgerMl: manualMl, foodMl: foodMl),
            goals: .init(protein: nil, carbs: nil, fat: nil, waterGoalMl: goalMl),
            foodEntries: [], exerciseSessions: []
        )
    }

    @MainActor
    func testWaterQuickAddSendsOneDrinkAndUndoSendsMinusOne() async {
        let stub = StubAPIClient()
        stub.totalsToReturn = WaterTotals(waterMl: 250, manualMl: 250, ledgerMl: 250, foodMl: 0)
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)

        await viewModel.adjust(drinks: 1)
        await viewModel.adjust(drinks: -1)

        // The unit sent is drinks, not millilitres — the server decides what
        // a drink is worth (250 ml with no container).
        XCTAssertEqual(stub.drinkAdjustments, [1, -1])
        XCTAssertEqual(viewModel.mlPerDrink, 250)
        // The total shown is the server's answer to the write, not a local
        // increment.
        XCTAssertEqual(viewModel.totalMl, 250)
    }

    @MainActor
    func testUndoIsDisabledWhenNoManualWaterExists() {
        let viewModel = WaterViewModel(date: Date(), apiClient: StubAPIClient())

        // 500 ml on the day, but none of it hand-logged (e.g. all synced
        // from a provider) — the server's decrement only removes manual
        // rows, so the control must not pretend otherwise.
        viewModel.adopt(summary: summary(waterMl: 500, manualMl: 0, foodMl: 500))
        XCTAssertFalse(viewModel.canUndo)

        viewModel.adopt(summary: summary(waterMl: 750, manualMl: 750))
        XCTAssertTrue(viewModel.canUndo)
    }

    @MainActor
    func testWholeDrinksIgnoresPartialGlasses() {
        let viewModel = WaterViewModel(date: Date(), apiClient: StubAPIClient())

        // 300 ml logged as a custom amount is not "1 glass" of 250 —
        // rounding up would overstate what the card claims.
        viewModel.adopt(summary: summary(waterMl: 300, manualMl: 300))
        XCTAssertEqual(viewModel.wholeDrinks, 1)

        viewModel.adopt(summary: summary(waterMl: 240, manualMl: 240))
        XCTAssertEqual(viewModel.wholeDrinks, 0)

        viewModel.adopt(summary: summary(waterMl: 750, manualMl: 750))
        XCTAssertEqual(viewModel.wholeDrinks, 3)
    }

    @MainActor
    func testWaterGoalFallsBackWhenTheAccountHasNoWaterGoal() {
        let viewModel = WaterViewModel(date: Date(), apiClient: StubAPIClient())

        // water_goal_ml is null on a fresh account (confirmed live).
        viewModel.adopt(summary: summary(waterMl: 500, manualMl: 500, goalMl: nil))
        XCTAssertEqual(viewModel.goalMl, WaterViewModel.fallbackGoalMl)
        XCTAssertEqual(viewModel.progress, 0.25)

        viewModel.adopt(summary: summary(waterMl: 500, manualMl: 500, goalMl: 1000))
        XCTAssertEqual(viewModel.goalMl, 1000)
        XCTAssertEqual(viewModel.progress, 0.5)
    }

    @MainActor
    func testProgressNeverExceedsOne() {
        let viewModel = WaterViewModel(date: Date(), apiClient: StubAPIClient())
        viewModel.adopt(summary: summary(waterMl: 5000, manualMl: 5000, goalMl: 2000))
        XCTAssertEqual(viewModel.progress, 1) // a full ring, not a 250% one
    }

    @MainActor
    func testDeletingAWaterEntryRereadsTheLedgerAndTotal() async {
        let stub = StubAPIClient()
        stub.logToReturn = [
            WaterLogEntry(id: "entry-1", waterMl: 250),
            WaterLogEntry(id: "entry-2", waterMl: 300, containerName: "Custom amount"),
        ]
        stub.totalsToReturn = WaterTotals(waterMl: 550, manualMl: 550, ledgerMl: 550, foodMl: 0)
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)
        await viewModel.loadEntries()

        stub.logToReturn = [WaterLogEntry(id: "entry-2", waterMl: 300, containerName: "Custom amount")]
        stub.totalsToReturn = WaterTotals(waterMl: 300, manualMl: 300, ledgerMl: 300, foodMl: 0)
        await viewModel.delete(WaterLogEntry(id: "entry-1", waterMl: 250))

        XCTAssertEqual(stub.deletedWaterEntryIds, ["entry-1"])
        // Re-read rather than locally subtracted, so the aggregate the server
        // recomputes is what ends up on screen.
        XCTAssertEqual(viewModel.entries.map(\.id), ["entry-2"])
        XCTAssertEqual(viewModel.totalMl, 300)
    }

    func testProviderSyncedWaterIsNotDeletable() {
        XCTAssertTrue(WaterLogEntry(id: "a", waterMl: 250, source: "manual").isManual)
        XCTAssertTrue(WaterLogEntry(id: "b", waterMl: 250, source: nil).isManual) // absent == manual
        XCTAssertFalse(WaterLogEntry(id: "c", waterMl: 250, source: "garmin").isManual)
    }

    // MARK: - Module 4: weight & measurements

    /// The encoding rule the whole "two sheets, one row" design rests on:
    /// only the fields a sheet shows are sent, so saving a weight can't blank
    /// out a waist measurement logged the same day.
    private func encodedBody(_ input: BodyMeasurementsInput) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase // same as APIClient's
        let data = try encoder.encode(input)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testCheckInWriteOnlyCarriesTheFieldsItWasGiven() throws {
        let json = try encodedBody(BodyMeasurementsInput(date: Date(), values: [.weight: 73.1]))

        XCTAssertEqual(json["weight"] as? Double, 73.1)
        XCTAssertNotNil(json["entry_date"])
        // Absent, not null: null would clear a measurement the other sheet
        // may have just written.
        XCTAssertFalse(json.keys.contains("waist"))
        XCTAssertFalse(json.keys.contains("hips"))
    }

    func testClearingAFieldSendsAnExplicitNull() throws {
        let json = try encodedBody(BodyMeasurementsInput(date: Date(), values: [.waist: nil, .hips: 95]))

        XCTAssertTrue(json["waist"] is NSNull) // an explicit null is what clears the column
        XCTAssertEqual(json["hips"] as? Double, 95)
    }

    func testBodyFatPercentageUsesItsSnakeCaseColumnName() throws {
        let json = try encodedBody(BodyMeasurementsInput(date: Date(), values: [.bodyFatPercentage: 18.2]))

        // Dictionary keys bypass any key-encoding strategy, so this is
        // spelled out in BodyField.apiKey rather than inferred.
        XCTAssertEqual(json["body_fat_percentage"] as? Double, 18.2)
        XCTAssertFalse(json.keys.contains("bodyFatPercentage"))
    }

    /// GET for a day with nothing logged answers `{}` — not 404, not null.
    func testEmptyCheckInResponseDecodesAsNothingLogged() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let decoded = try decoder.decode(BodyMeasurements.self, from: Data("{}".utf8))

        XCTAssertFalse(decoded.exists)
        XCTAssertTrue(decoded.populatedFields.isEmpty)
        XCTAssertNil(decoded.weight)
    }

    func testCheckInResponseDecodesAndListsOnlyPopulatedFields() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let json = """
        {"id":"row-1","entry_date":"2026-09-21","weight":73.1,"neck":null,"waist":81,
         "hips":null,"steps":null,"height":null,"body_fat_percentage":18.2}
        """
        let decoded = try decoder.decode(BodyMeasurements.self, from: Data(json.utf8))

        XCTAssertTrue(decoded.exists)
        XCTAssertEqual(decoded.weight, 73.1)
        // Display order, and nulls left out entirely.
        XCTAssertEqual(decoded.populatedFields.map(\.field), [.weight, .waist, .bodyFatPercentage])
    }

    @MainActor
    func testWeightSheetRefusesToSaveWithoutAWeight() async {
        let stub = StubAPIClient()
        let viewModel = LogBodyViewModel(
            kind: .weight, date: Date(),
            minDate: Date(), maxDate: Date(), apiClient: stub
        )

        let saved = await viewModel.save()

        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.error(for: .weight), "How much do you weigh?")
        XCTAssertTrue(stub.upsertedBodyInputs.isEmpty) // nothing was written
    }

    @MainActor
    func testWeightSheetRejectsNonNumericAndOutOfRangeInput() async {
        let stub = StubAPIClient()
        let viewModel = LogBodyViewModel(
            kind: .weight, date: Date(),
            minDate: Date(), maxDate: Date(), apiClient: stub
        )

        viewModel.text[BodyField.weight.rawValue] = "seventy"
        var saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.error(for: .weight), "Numbers only")

        viewModel.text[BodyField.weight.rawValue] = "0"
        saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.error(for: .weight), "Must be more than 0")

        viewModel.text[BodyField.weight.rawValue] = "7300" // slipped decimal point
        saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.error(for: .weight), "That looks too high")

        XCTAssertTrue(stub.upsertedBodyInputs.isEmpty)
    }

    @MainActor
    func testMeasurementsSheetWritesOnlyFilledFieldsAndPrefillsFromTheStoredRow() async throws {
        let stub = StubAPIClient()
        let existing = BodyMeasurements(
            id: "row-1", weight: 73.1, neck: nil, waist: 81, hips: nil, height: nil, bodyFatPercentage: nil
        )
        let viewModel = LogBodyViewModel(
            kind: .measurements, date: Date(), existing: existing,
            minDate: Date(), maxDate: Date(), apiClient: stub
        )

        // Prefilled from what's stored, and a whole number isn't shown as "81.0".
        XCTAssertEqual(viewModel.text[BodyField.waist.rawValue], "81")
        // The weight isn't on this sheet at all, so it can't be touched here.
        XCTAssertFalse(viewModel.fields.contains(.weight))

        viewModel.text[BodyField.hips.rawValue] = "95"
        let saved = await viewModel.save()
        XCTAssertTrue(saved)

        let input = try XCTUnwrap(stub.upsertedBodyInputs.first)
        // Waist is re-sent unchanged (it's on screen and filled), hips is new,
        // and nothing else — crucially not weight.
        XCTAssertEqual(Set(input.values.keys), [.waist, .hips])
        XCTAssertEqual(input.values[.hips], 95)
    }

    @MainActor
    func testEmptyingAStoredMeasurementClearsItRatherThanBeingIgnored() async throws {
        let stub = StubAPIClient()
        let existing = BodyMeasurements(
            id: "row-1", weight: nil, neck: nil, waist: 81, hips: nil, height: nil, bodyFatPercentage: nil
        )
        let viewModel = LogBodyViewModel(
            kind: .measurements, date: Date(), existing: existing,
            minDate: Date(), maxDate: Date(), apiClient: stub
        )

        viewModel.text[BodyField.waist.rawValue] = ""
        let saved = await viewModel.save()
        XCTAssertTrue(saved)

        let input = try XCTUnwrap(stub.upsertedBodyInputs.first)
        XCTAssertEqual(Set(input.values.keys), [.waist])
        // .some(nil) — a cleared field, told apart from one never filled in.
        XCTAssertNotNil(input.values[.waist])
        XCTAssertNil(input.values[.waist] ?? nil)
    }

    @MainActor
    func testAnUntouchedMeasurementsSheetWritesNothing() async {
        let stub = StubAPIClient()
        let viewModel = LogBodyViewModel(
            kind: .measurements, date: Date(),
            minDate: Date(), maxDate: Date(), apiClient: stub
        )

        XCTAssertFalse(viewModel.hasPendingWrite)
        let saved = await viewModel.save()
        XCTAssertTrue(saved) // closes cleanly, but…
        XCTAssertTrue(stub.upsertedBodyInputs.isEmpty) // …sends no request
    }

    // MARK: - Module 4: cross-screen state

    @MainActor
    func testWaterAndBodyEntriesKeepTodayInItsPopulatedState() async {
        let stub = StubAPIClient()
        // A day with no food and no exercise — only water.
        stub.summaryToReturn = summary(waterMl: 250, manualMl: 250)
        let viewModel = TodayViewModel(apiClient: stub)
        await viewModel.load()

        // Without water counting here, logging a glass would flip Today back
        // to "nothing logged yet" and take the card the tap came from off
        // screen.
        XCTAssertTrue(viewModel.hasLoggedAnything)
    }

    /// Regression: `water` is its own ObservableObject, so a quick-add
    /// published to the water card but not to the screen around it — and
    /// Today decides between its populated and first-run layouts (and draws
    /// the summary card's water ring) from that same value. Logging the
    /// day's first glass left Today on the first-run layout, taking the card
    /// the tap came from off screen, until the next load.
    @MainActor
    func testWaterChangesRepublishThroughTheOwningScreen() async {
        let stub = StubAPIClient()
        stub.totalsToReturn = WaterTotals(waterMl: 250, manualMl: 250, ledgerMl: 250, foodMl: 0)
        let viewModel = TodayViewModel(apiClient: stub)

        var notifications = 0
        let cancellable = viewModel.objectWillChange.sink { _ in notifications += 1 }
        defer { cancellable.cancel() }

        await viewModel.water.adjust(drinks: 1)

        XCTAssertGreaterThan(notifications, 0, "a water change must republish through the screen that renders it")
        XCTAssertTrue(viewModel.hasLoggedAnything)
    }

    @MainActor
    func testDeletingTheDaysOnlyBodyRowClearsItAndRereadsTheDay() async {
        let stub = StubAPIClient()
        stub.bodyToReturn = BodyMeasurements(
            id: "row-1", weight: 73.1, neck: nil, waist: nil, hips: nil, height: nil, bodyFatPercentage: nil
        )
        let user = SessionUser(email: "demo@sparkyfitness.com", name: "Demo", createdAt: Date())
        let viewModel = DiaryViewModel(user: user, apiClient: stub)
        await viewModel.load()
        XCTAssertTrue(viewModel.bodyMeasurements.exists)

        // The server no longer has the row; the delete must be reflected here
        // immediately, not on the next launch.
        stub.bodyToReturn = .none
        await viewModel.deleteBodyMeasurements()

        XCTAssertEqual(stub.deletedBodyIds, ["row-1"])
        XCTAssertFalse(viewModel.bodyMeasurements.exists)
        XCTAssertTrue(viewModel.bodyMeasurements.populatedFields.isEmpty)
    }

    // MARK: - Module 4: unit labels come from the server

    func testUnitLabelsFollowTheServerPreference() {
        let metric = UserPreferences(
            defaultWeightUnit: "kg", defaultMeasurementUnit: "cm",
            waterDisplayUnit: "ml", measurementDecimalPlaces: 0
        )
        XCTAssertEqual(BodyField.weight.unitLabel(metric), "kg")
        XCTAssertEqual(BodyField.waist.unitLabel(metric), "cm")
        XCTAssertEqual(BodyField.bodyFatPercentage.unitLabel(metric), "%")

        let imperial = UserPreferences(
            defaultWeightUnit: "lbs", defaultMeasurementUnit: "inches",
            waterDisplayUnit: "oz", measurementDecimalPlaces: 1
        )
        XCTAssertEqual(BodyField.weight.unitLabel(imperial), "lb")
        XCTAssertEqual(BodyField.waist.unitLabel(imperial), "in")

        // measurement_decimal_places is a minimum: a whole number is padded
        // out to it…
        XCTAssertEqual(imperial.formatted(81), "81.0")
        XCTAssertEqual(metric.formatted(81), "81")
    }

    /// Regression: `measurement_decimal_places` defaults to 0 on the server,
    /// and obeying that literally displayed a weight logged as 73.1 as "73"
    /// (found by rendering the card). A presentation preference must never
    /// misreport the stored number.
    func testFormattingNeverDropsPrecisionTheUserActuallyEntered() {
        let zeroDecimals = UserPreferences(
            defaultWeightUnit: "kg", defaultMeasurementUnit: "cm",
            waterDisplayUnit: "ml", measurementDecimalPlaces: 0
        )
        XCTAssertEqual(zeroDecimals.formatted(73.1), "73.1")
        XCTAssertEqual(zeroDecimals.formatted(18.2), "18.2")
        XCTAssertEqual(zeroDecimals.formatted(72.85), "72.85")
        // …but a whole number still shows as one, not "73.00".
        XCTAssertEqual(zeroDecimals.formatted(73), "73")
        XCTAssertEqual(zeroDecimals.formatted(95), "95")
    }

    func testPreferencesDecodeFromTheLiveResponseShape() throws {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        // Trimmed copy of a real GET /api/user-preferences body — the
        // endpoint returns ~50 fields, and Decodable must ignore the rest.
        let json = """
        {"date_format":"MM/DD/YYYY","default_weight_unit":"kg","default_measurement_unit":"cm",
         "water_display_unit":"ml","measurement_decimal_places":0,"energy_unit":"kcal"}
        """
        let decoded = try decoder.decode(UserPreferences.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.weightUnitLabel, "kg")
        XCTAssertEqual(decoded.measurementUnitLabel, "cm")
        XCTAssertEqual(decoded.waterUnitLabel, "ml")
    }

    // MARK: - Password reset

    @MainActor
    func testResetSheetOpensOnTheAddressAlreadyTypedIntoLogin() {
        let viewModel = AuthViewModel(apiClient: StubAPIClient())
        viewModel.email = "someone@example.com"

        viewModel.preparePasswordReset()

        // Otherwise the one thing they've already typed has to be typed again.
        XCTAssertEqual(viewModel.resetEmail, "someone@example.com")
        XCTAssertEqual(viewModel.resetState, .editing)
    }

    @MainActor
    func testResetSendsTheTrimmedAddressAndReportsOnlyThatItWasAccepted() async {
        let stub = StubAPIClient()
        let viewModel = AuthViewModel(apiClient: stub)
        viewModel.resetEmail = "  someone@example.com  "

        await viewModel.requestPasswordReset()

        XCTAssertEqual(stub.passwordResetRequests, ["someone@example.com"])
        // There is no "sent" vs "no such account" outcome to assert, because
        // the server answers both identically on purpose.
        XCTAssertEqual(viewModel.resetState, .requested)
        XCTAssertNil(viewModel.resetError)
    }

    @MainActor
    func testResetFailureReturnsToEditingSoItCanBeRetried() async {
        let stub = StubAPIClient()
        stub.passwordResetError = APIError.server(message: "Server is down.", code: nil)
        let viewModel = AuthViewModel(apiClient: stub)
        viewModel.resetEmail = "someone@example.com"

        await viewModel.requestPasswordReset()

        // A transport failure must not look like a delivered reset link.
        XCTAssertEqual(viewModel.resetState, .editing)
        XCTAssertNotNil(viewModel.resetError)
    }

    @MainActor
    func testResetRefusesAnAddressThatIsObviouslyNotOne() {
        let viewModel = AuthViewModel(apiClient: StubAPIClient())

        viewModel.resetEmail = ""
        XCTAssertFalse(viewModel.canRequestReset)
        // The server accepts anything and answers 200, so without this the
        // user would be told a link was on its way to "asdf".
        viewModel.resetEmail = "asdf"
        XCTAssertFalse(viewModel.canRequestReset)
        viewModel.resetEmail = "someone@example.com"
        XCTAssertTrue(viewModel.canRequestReset)
    }

    // MARK: - Bundled typefaces

    /// `Font.custom` silently falls back to the system font when a name
    /// doesn't resolve, so a dropped file or a renamed face degrades into
    /// something that still looks plausible and ships unnoticed. These are
    /// PostScript names, which deliberately differ from the filenames (the
    /// instancer rewrites them to carry a "Roman" infix), so they're exactly
    /// the kind of string that rots without anything complaining.
    func testEveryBundledFaceResolves() {
        for face in [
            AppFont.Face.sansRegular,
            AppFont.Face.sansSemiBold,
            AppFont.Face.sansBold,
            AppFont.Face.serifSemiBold,
        ] {
            XCTAssertNotNil(
                UIFont(name: face, size: 15),
                "\(face) did not resolve — check UIAppFonts in Info.plist and the font's PostScript name"
            )
        }
    }

    /// Only three sans cuts are bundled, so every weight has to land on a real
    /// one; asking for a weight that isn't there makes CoreText synthesise it.
    func testSansWeightsMapToNearestBundledCut() {
        XCTAssertEqual(AppFont.sansFace(for: .light), AppFont.Face.sansRegular)
        XCTAssertEqual(AppFont.sansFace(for: .regular), AppFont.Face.sansRegular)
        XCTAssertEqual(AppFont.sansFace(for: .medium), AppFont.Face.sansSemiBold)
        XCTAssertEqual(AppFont.sansFace(for: .semibold), AppFont.Face.sansSemiBold)
        XCTAssertEqual(AppFont.sansFace(for: .bold), AppFont.Face.sansBold)
        XCTAssertEqual(AppFont.sansFace(for: .black), AppFont.Face.sansBold)
    }
}
