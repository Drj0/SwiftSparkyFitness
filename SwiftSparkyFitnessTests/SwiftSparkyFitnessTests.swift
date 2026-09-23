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
            goals: .init(calories: nil, protein: nil, carbs: nil, fat: nil, waterGoalMl: nil),
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
        var goalsToReturn = NutritionGoals(raw: [:])
        var goalsLoadError: Error?
        var goalsSaveError: Error?
        var savedGoals: [NutritionGoals] = []
        var createdCustomFoods: [CustomFoodInput] = []
        var createCustomFoodError: Error?
        var lookedUpExerciseNames: [String] = []
        var createdExerciseEntries: [ExerciseEntryInput] = []
        var updatedExerciseEntries: [(id: String, input: ExerciseEntryInput)] = []
        var exerciseWriteError: Error?
        var localFoodsToReturn: [Food] = []
        var externalFoodsToReturn: [Food] = []
        var localSearchError: Error?
        var externalSearchError: Error?
        var localSearchQueries: [String] = []
        var externalSearchQueries: [String] = []
        var suggestionsToReturn = FoodSuggestions.none
        var suggestionsError: Error?
        var suggestionsRequests = 0
        var syncedActiveEnergy: [Double] = []
        var syncActiveEnergyError: Error?
        var mealTypesToReturn: [MealType] = []
        var createdMealTypes: [(name: String, sortOrder: Int)] = []
        var updatedMealTypes: [(id: String, input: MealTypeInput)] = []
        var deletedMealTypeIds: [String] = []
        var mealTypeWriteError: Error?
        var containersToReturn: [WaterContainer] = []
        var createdContainers: [WaterContainerInput] = []
        var setPrimaryIds: [Int] = []
        var deletedContainerIds: [Int] = []
        var containerWriteError: Error?
        var adjustCalls: [(drinks: Int, containerId: Int?)] = []
        var preferenceWrites: [(setting: UserPreferences.Setting, value: String)] = []
        var preferenceWriteError: Error?

        func signIn(email: String, password: String) async throws -> SessionUser { fatalError("unused") }
        func signUp(email: String, password: String) async throws -> SessionUser { fatalError("unused") }
        func currentSession() async throws -> SessionUser? { nil }
        func signOut() async {}
        func requestPasswordReset(email: String) async throws {
            passwordResetRequests.append(email)
            if let passwordResetError { throw passwordResetError }
        }
        func dailySummary(date: Date) async throws -> DailySummary { summaryToReturn }
        func mealTypes() async throws -> [MealType] { mealTypesToReturn }
        func createMealType(name: String, sortOrder: Int) async throws -> MealType {
            createdMealTypes.append((name, sortOrder))
            if let mealTypeWriteError { throw mealTypeWriteError }
            let created = MealType(id: "new-\(name)", name: name, sortOrder: sortOrder, userId: "user-1")
            mealTypesToReturn.append(created)
            return created
        }
        func updateMealType(id: String, _ input: MealTypeInput) async throws -> MealType {
            updatedMealTypes.append((id, input))
            if let mealTypeWriteError { throw mealTypeWriteError }
            return MealType(id: id, name: input.name ?? "x", sortOrder: input.sortOrder ?? 0, userId: "user-1", isVisible: input.isVisible)
        }
        func deleteMealType(id: String) async throws {
            deletedMealTypeIds.append(id)
            if let mealTypeWriteError { throw mealTypeWriteError }
            mealTypesToReturn.removeAll { $0.id == id }
        }
        func searchFoods(query: String) async throws -> [Food] {
            localSearchQueries.append(query)
            if let localSearchError { throw localSearchError }
            return localFoodsToReturn
        }
        func searchExternalFoods(query: String) async throws -> [Food] {
            externalSearchQueries.append(query)
            if let externalSearchError { throw externalSearchError }
            return externalFoodsToReturn
        }
        func foodSuggestions() async throws -> FoodSuggestions {
            suggestionsRequests += 1
            if let suggestionsError { throw suggestionsError }
            return suggestionsToReturn
        }
        func createCustomFood(_ input: CustomFoodInput) async throws -> Food {
            createdCustomFoods.append(input)
            if let createCustomFoodError { throw createCustomFoodError }
            return Food(id: "created-food", name: input.name, brand: input.brand, defaultVariant: nil)
        }
        func materializeExternalFood(_ food: Food) async throws -> Food { fatalError("unused") }
        func createFoodEntry(_ input: FoodEntryInput) async throws {}
        func updateFoodEntry(id: String, _ input: FoodEntryInput) async throws {}
        func deleteFoodEntry(id: String) async throws {}
        func searchExercises(query: String) async throws -> [Exercise] { [] }
        func findOrCreateExercise(named name: String) async throws -> Exercise {
            lookedUpExerciseNames.append(name)
            return Exercise(id: "exercise-1", name: name, category: nil)
        }
        func createExerciseEntry(_ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
            createdExerciseEntries.append(input)
            if let exerciseWriteError { throw exerciseWriteError }
            return ExerciseSessionSummary(id: "session-1", name: nil, caloriesBurned: input.caloriesBurned, durationMinutes: input.durationMinutes, exerciseId: input.exerciseId)
        }
        func updateExerciseEntry(id: String, _ input: ExerciseEntryInput) async throws -> ExerciseSessionSummary {
            updatedExerciseEntries.append((id, input))
            if let exerciseWriteError { throw exerciseWriteError }
            return ExerciseSessionSummary(id: id, name: nil, caloriesBurned: input.caloriesBurned, durationMinutes: input.durationMinutes, exerciseId: input.exerciseId)
        }
        func deleteExerciseEntry(id: String) async throws {}

        func syncActiveEnergy(kilocalories: Double, date: Date) async throws {
            syncedActiveEnergy.append(kilocalories)
            if let syncActiveEnergyError { throw syncActiveEnergyError }
        }
        func userPreferences() async throws -> UserPreferences { preferencesToReturn }
        func updateUserPreference(_ setting: UserPreferences.Setting, to value: String) async throws -> UserPreferences {
            preferenceWrites.append((setting, value))
            if let preferenceWriteError { throw preferenceWriteError }
            return preferencesToReturn
        }
        func goals(date: Date) async throws -> NutritionGoals {
            if let goalsLoadError { throw goalsLoadError }
            return goalsToReturn
        }
        func saveGoals(_ goals: NutritionGoals, startingOn date: Date) async throws {
            savedGoals.append(goals)
            if let goalsSaveError { throw goalsSaveError }
        }
        func waterTotals(date: Date) async throws -> WaterTotals { totalsToReturn }
        func waterLog(date: Date) async throws -> [WaterLogEntry] { logToReturn }
        func waterContainers() async throws -> [WaterContainer] { containersToReturn }
        func createWaterContainer(_ input: WaterContainerInput) async throws -> WaterContainer {
            createdContainers.append(input)
            if let containerWriteError { throw containerWriteError }
            return WaterContainer(id: 99, name: input.name, volume: input.volume, unit: input.unit, isPrimary: false, servingsPerContainer: input.servingsPerContainer)
        }
        func setPrimaryWaterContainer(id: Int) async throws {
            setPrimaryIds.append(id)
            if let containerWriteError { throw containerWriteError }
        }
        func deleteWaterContainer(id: Int) async throws {
            deletedContainerIds.append(id)
            if let containerWriteError { throw containerWriteError }
        }
        func adjustWater(date: Date, drinks: Int, containerId: Int?) async throws -> WaterTotals {
            adjustCalls.append((drinks, containerId))
            return try await adjustWater(date: date, drinks: drinks)
        }
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
            goals: .init(calories: nil, protein: nil, carbs: nil, fat: nil, waterGoalMl: goalMl),
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

    // MARK: - Unit preferences

    /// The server accepts anything — `default_weight_unit: "bogus"` returns
    /// 200 and is stored — so the option lists are the only guard, and every
    /// label getter has to fall through rather than trust what comes back.
    func testUnitOptionsExcludeCompoundUnitsTheUICannotShow() {
        let weight = UserPreferences.Setting.weight.options.map(\.value)
        XCTAssertEqual(weight, ["kg", "lbs"])
        XCTAssertFalse(weight.contains("st_lbs"), "a single numeric field can't express stone and pounds")

        let measurement = UserPreferences.Setting.measurement.options.map(\.value)
        XCTAssertEqual(measurement, ["cm", "inches"])
        XCTAssertFalse(measurement.contains("ft_in"))
    }

    /// A compound unit set from the web client still has to read back sanely
    /// rather than falling through to the wrong label.
    func testAValueSetElsewhereIsStillLabelledHonestly() {
        let compound = UserPreferences(
            defaultWeightUnit: "st_lbs", defaultMeasurementUnit: "ft_in",
            waterDisplayUnit: "ml", measurementDecimalPlaces: 0
        )
        XCTAssertEqual(compound.weightUnitLabel, "st")
        XCTAssertEqual(compound.measurementUnitLabel, "ft")
        XCTAssertEqual(compound.value(for: .weight), "st_lbs")
        // ...and the picker knows it has nothing to highlight.
        XCTAssertFalse(UserPreferences.Setting.weight.options.contains { $0.value == "st_lbs" })
    }

    @MainActor
    func testSelectingAUnitWritesOnlyThatKey() async {
        let stub = StubAPIClient()
        let viewModel = UnitPreferencesViewModel(apiClient: stub)
        await viewModel.load()

        await viewModel.select("lbs", for: .weight)
        XCTAssertEqual(stub.preferenceWrites.count, 1)
        XCTAssertEqual(stub.preferenceWrites.first?.setting, .weight)
        XCTAssertEqual(stub.preferenceWrites.first?.value, "lbs")

        // Re-picking what's already stored is not a write.
        await viewModel.select(viewModel.preferences.value(for: .water), for: .water)
        XCTAssertEqual(stub.preferenceWrites.count, 1)
    }

    // MARK: - Water overshoot

    /// The bar filled and stopped at 100%, so 2 litres and 4 litres drew
    /// identically. `progress` stays clamped because it's a width; the
    /// excess is a second lap.
    @MainActor
    func testWaterOvershootIsReportedSeparatelyFromTheClampedFill() {
        let stub = StubAPIClient()
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)
        viewModel.adopt(summary: DailySummary(
            calorieBalance: .init(eaten: 0, burned: 0, remaining: 0, goal: 2000),
            waterIntake: 3000, waterIntakeBreakdown: nil,
            goals: .init(calories: nil, protein: nil, carbs: nil, fat: nil, waterGoalMl: 2000),
            foodEntries: [], exerciseSessions: []
        ))

        XCTAssertEqual(viewModel.progress, 1)
        XCTAssertEqual(viewModel.overshoot, 0.5)

        // Under goal: no second lap at all.
        viewModel.adopt(summary: DailySummary(
            calorieBalance: .init(eaten: 0, burned: 0, remaining: 0, goal: 2000),
            waterIntake: 1000, waterIntakeBreakdown: nil,
            goals: .init(calories: nil, protein: nil, carbs: nil, fat: nil, waterGoalMl: 2000),
            foodEntries: [], exerciseSessions: []
        ))
        XCTAssertEqual(viewModel.progress, 0.5)
        XCTAssertEqual(viewModel.overshoot, 0)
    }

    // MARK: - Water containers

    private func container(_ id: Int, _ name: String, _ volume: Double, unit: String = "ml", primary: Bool = false, servings: Int = 1) -> WaterContainer {
        WaterContainer(id: id, name: name, volume: volume, unit: unit, isPrimary: primary, servingsPerContainer: servings)
    }

    /// The server converts on write — a 24 oz container logged 709.764 ml —
    /// and this mirrors it only so the card can say what a tap is worth
    /// *before* making it.
    func testContainerVolumeConvertsToMillilitresPerServing() {
        XCTAssertEqual(container(1, "Bottle", 750).mlPerServing, 750)
        XCTAssertEqual(container(2, "Oz", 24, unit: "oz").mlPerServing, 24 * 29.5735, accuracy: 0.001)
        XCTAssertEqual(container(3, "Litre", 1.5, unit: "liter").mlPerServing, 1500)
        // Split into servings: a 1 L flask drunk as 4 cups is 250 ml a tap.
        XCTAssertEqual(container(4, "Flask", 1000, servings: 4).mlPerServing, 250)
        // An unrecognised unit is treated as millilitres rather than guessed.
        XCTAssertEqual(container(5, "Odd", 300, unit: "cups").mlPerServing, 300)
    }

    /// The whole reason containers are modelled: the server does NOT consult
    /// the primary container on its own. Verified live — with a 750 ml
    /// primary set, a bare `change_drinks: 1` still logged 250 ml. If the app
    /// stops sending the id, setting a container silently does nothing.
    @MainActor
    func testQuickAddSendsThePrimaryContainerId() async {
        let stub = StubAPIClient()
        stub.containersToReturn = [container(7, "Bottle", 750, primary: true)]
        stub.totalsToReturn = WaterTotals(waterMl: 750, manualMl: 750, ledgerMl: 750, foodMl: 0)
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)

        await viewModel.loadPrimaryContainer()
        XCTAssertEqual(viewModel.mlPerDrink, 750)
        await viewModel.adjust(drinks: 1)

        XCTAssertEqual(stub.adjustCalls.first?.containerId, 7)
    }

    /// The decrement deletes the most recent manual rows whatever container
    /// they came from, so naming one would imply a precision it hasn't got.
    @MainActor
    func testUndoDoesNotNameAContainer() async {
        let stub = StubAPIClient()
        stub.containersToReturn = [container(7, "Bottle", 750, primary: true)]
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)
        await viewModel.loadPrimaryContainer()

        await viewModel.adjust(drinks: -1)

        XCTAssertEqual(stub.adjustCalls.first?.drinks, -1)
        XCTAssertNil(stub.adjustCalls.first?.containerId)
    }

    @MainActor
    func testWithoutAContainerATapIsStillTheServersDefault() async {
        let stub = StubAPIClient()
        let viewModel = WaterViewModel(date: Date(), apiClient: stub)

        await viewModel.loadPrimaryContainer()

        XCTAssertNil(viewModel.primaryContainer)
        XCTAssertEqual(viewModel.mlPerDrink, Water.defaultMlPerDrink)
        XCTAssertEqual(viewModel.drinkLabel, "250 ml each")
    }

    /// Adding the first container makes it primary — otherwise it would
    /// appear to do nothing until the user also tapped "Use this".
    @MainActor
    func testTheFirstContainerAddedBecomesPrimary() async {
        let stub = StubAPIClient()
        let viewModel = WaterContainersViewModel(apiClient: stub)
        await viewModel.load()

        viewModel.newName = "Water bottle"
        viewModel.newVolume = "750"
        await viewModel.create()
        XCTAssertEqual(stub.setPrimaryIds, [99])

        // A later one doesn't steal primary from whatever is already set.
        stub.containersToReturn = [container(1, "Existing", 500, primary: true)]
        await viewModel.load()
        viewModel.newName = "Mug"
        viewModel.newVolume = "300"
        await viewModel.create()
        XCTAssertEqual(stub.setPrimaryIds, [99], "unchanged")
    }

    @MainActor
    func testContainerVolumeMustBeARealNumberInRange() async {
        let viewModel = WaterContainersViewModel(apiClient: StubAPIClient())
        viewModel.newName = "Bottle"

        viewModel.newVolume = ""
        XCTAssertFalse(viewModel.canCreate)
        viewModel.newVolume = "abc"
        XCTAssertFalse(viewModel.canCreate)
        viewModel.newVolume = "0"
        XCTAssertFalse(viewModel.canCreate)
        viewModel.newVolume = "99999"
        XCTAssertFalse(viewModel.canCreate, "server bounds volume at 9999.999")
        viewModel.newVolume = "750"
        XCTAssertTrue(viewModel.canCreate)
        // Comma decimals are typed on plenty of keyboards.
        viewModel.newVolume = "1,5"
        XCTAssertEqual(viewModel.parsedVolume, 1.5)
    }

    // MARK: - Smart-scale measurements

    /// BMR is the one field whose lower bound isn't just "more than zero":
    /// the column carries a 600–6000 constraint, and without modelling it the
    /// server answers a raw 400 for an otherwise plausible number.
    @MainActor
    func testBMRIsRejectedBelowTheServersLowerBound() async {
        let stub = StubAPIClient()
        let viewModel = LogBodyViewModel(
            kind: .measurements, date: Date(), minDate: Date(), maxDate: Date(), apiClient: stub
        )

        viewModel.text[BodyField.bmr.rawValue] = "550"
        var saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertEqual(viewModel.error(for: .bmr), "Must be at least 600")
        XCTAssertTrue(stub.upsertedBodyInputs.isEmpty)

        viewModel.text[BodyField.bmr.rawValue] = "1650"
        saved = await viewModel.save()
        XCTAssertTrue(saved)
        XCTAssertEqual(stub.upsertedBodyInputs.first?.values[.bmr] ?? nil, 1650)
    }

    func testSmartScaleFieldsCarryTheServersColumnNamesAndUnits() {
        XCTAssertEqual(BodyField.muscleMassKg.apiKey, "muscle_mass_kg")
        XCTAssertEqual(BodyField.boneMassKg.apiKey, "bone_mass_kg")
        XCTAssertEqual(BodyField.bodyWaterPercentage.apiKey, "body_water_percentage")
        XCTAssertEqual(BodyField.bmr.apiKey, "bmr")

        let prefs = UserPreferences.serverDefaults
        XCTAssertEqual(BodyField.muscleMassKg.unitLabel(prefs), prefs.weightUnitLabel)
        XCTAssertEqual(BodyField.bodyWaterPercentage.unitLabel(prefs), "%")
        XCTAssertEqual(BodyField.bmr.unitLabel(prefs), "kcal")
        // Percentages are bounded at 100 server-side.
        XCTAssertEqual(BodyField.bodyWaterPercentage.maximum, 100)
        XCTAssertEqual(BodyField.bmr.maximum, 6000)
    }

    // MARK: - Meal categories

    private func systemMeal(_ id: String, _ name: String, _ order: Int, visible: Bool = true) -> MealType {
        MealType(id: id, name: name, sortOrder: order, userId: nil, isVisible: visible)
    }

    private func customMeal(_ id: String, _ name: String, _ order: Int, visible: Bool = true) -> MealType {
        MealType(id: id, name: name, sortOrder: order, userId: "user-1", isVisible: visible)
    }

    /// The server protects its four (403 on rename, reorder and delete), so
    /// the UI must not offer those controls in the first place.
    func testSystemDefaultsAreDistinguishedFromUserCategories() {
        XCTAssertTrue(systemMeal("b", "breakfast", 10).isSystemDefault)
        XCTAssertFalse(customMeal("p", "Pre-Workout", 25).isSystemDefault)
        // The four ship lowercase; a user's own is stored as typed.
        XCTAssertEqual(systemMeal("b", "breakfast", 10).displayName, "Breakfast")
        XCTAssertEqual(customMeal("p", "Pre-Workout", 25).displayName, "Pre-Workout")
    }

    /// The endpoint returns hidden categories too, because the management
    /// screen has to list them — so every other consumer has to filter.
    func testHiddenCategoriesAreNotOfferedForLogging() {
        let meals = [
            customMeal("p", "Pre-Workout", 25, visible: false),
            systemMeal("d", "dinner", 40),
            systemMeal("b", "breakfast", 10),
        ]
        XCTAssertEqual(meals.visibleOnly.map(\.id), ["b", "d"])
        // A row from before the column existed has no value and is visible.
        XCTAssertTrue(MealType(id: "x", name: "old", sortOrder: 1).visible)
    }

    /// Hiding a meal stops it being offered; it must not bury food already
    /// logged there, which would look like data loss.
    @MainActor
    func testAHiddenMealStillShowsOnADayThatAlreadyUsedIt() async {
        let stub = StubAPIClient()
        stub.mealTypesToReturn = [
            systemMeal("b", "breakfast", 10),
            customMeal("p", "Pre-Workout", 25, visible: false),
            systemMeal("d", "dinner", 40, visible: false),
        ]
        stub.summaryToReturn = DailySummary(
            calorieBalance: .init(eaten: 200, burned: 0, remaining: 0, goal: 2000),
            waterIntake: 0, waterIntakeBreakdown: nil,
            goals: .init(calories: 2000, protein: nil, carbs: nil, fat: nil, waterGoalMl: nil),
            foodEntries: [
                FoodEntrySummary(id: "1", foodName: "Shake", mealType: "Pre-Workout", quantity: 1, unit: "serving", calories: 200, protein: nil, carbs: nil, fat: nil, foodId: nil, variantId: nil, mealTypeId: "p", brandName: nil, servingSize: nil, servingUnit: nil),
            ],
            exerciseSessions: []
        )
        let viewModel = TodayViewModel(apiClient: stub, health: StubHealthKit())

        await viewModel.load()

        // Pre-Workout is hidden but has food, so it stays. Dinner is hidden
        // and empty, so it goes.
        XCTAssertEqual(viewModel.entriesByMeal.map(\.mealType.id), ["b", "p"])
        // Neither hidden meal may be offered as somewhere to log new food.
        XCTAssertEqual(viewModel.loggableMealTypes.map(\.id), ["b"])
    }

    @MainActor
    func testCreatingACategoryPutsItAfterTheExistingOnes() async {
        let stub = StubAPIClient()
        stub.mealTypesToReturn = [systemMeal("b", "breakfast", 10), systemMeal("d", "dinner", 40)]
        let viewModel = MealCategoriesViewModel(apiClient: stub)
        await viewModel.load()

        viewModel.newName = "  Pre-Workout  "
        await viewModel.create()

        XCTAssertEqual(stub.createdMealTypes.map(\.name), ["Pre-Workout"])
        XCTAssertEqual(stub.createdMealTypes.first?.sortOrder, 50)
        XCTAssertEqual(viewModel.newName, "", "the field clears so the next one can be typed")
    }

    /// The server answers 409 while food is still logged against a category.
    /// That's a rule worth explaining rather than reporting as a failure.
    @MainActor
    func testDeletingACategoryStillInUseExplainsWhy() async {
        let stub = StubAPIClient()
        stub.mealTypesToReturn = [customMeal("p", "Pre-Workout", 25)]
        stub.mealTypeWriteError = APIError.server(
            message: "Cannot delete this meal type because it is still in use.", code: nil
        )
        let viewModel = MealCategoriesViewModel(apiClient: stub)
        await viewModel.load()

        await viewModel.delete(stub.mealTypesToReturn[0])

        let message = try? XCTUnwrap(viewModel.errorMessage)
        XCTAssertEqual(message?.contains("still has food logged against it"), true)
        XCTAssertEqual(message?.contains("Pre-Workout"), true)
    }

    /// A rename must never be attempted against one of the server's four —
    /// it's a guaranteed 403, and the UI hides the control.
    @MainActor
    func testRenamingASystemDefaultIsRefusedWithoutAskingTheServer() async {
        let stub = StubAPIClient()
        let breakfast = systemMeal("b", "breakfast", 10)
        stub.mealTypesToReturn = [breakfast]
        let viewModel = MealCategoriesViewModel(apiClient: stub)
        await viewModel.load()

        await viewModel.rename(breakfast, to: "Brekkie")

        XCTAssertTrue(stub.updatedMealTypes.isEmpty)
        XCTAssertNotNil(viewModel.errorMessage)
    }

    /// Visibility is the one edit a default does allow, so it must go through.
    @MainActor
    func testHidingASystemDefaultIsAllowedAndSendsOnlyVisibility() async {
        let stub = StubAPIClient()
        let breakfast = systemMeal("b", "breakfast", 10)
        stub.mealTypesToReturn = [breakfast]
        let viewModel = MealCategoriesViewModel(apiClient: stub)
        await viewModel.load()

        await viewModel.setVisible(false, for: breakfast)

        let update = try? XCTUnwrap(stub.updatedMealTypes.first)
        XCTAssertEqual(update?.id, "b")
        XCTAssertEqual(update?.input.isVisible, false)
        // Sending name or sortOrder for a default is a 403 even unchanged.
        XCTAssertNil(update?.input.name)
        XCTAssertNil(update?.input.sortOrder)
    }

    // MARK: - Cleared goals

    /// A goal the user never set is null; one they *cleared* is 0. Only the
    /// first is caught by `?? fallback`, and the goals sheet made the second
    /// reachable — dividing a ring's progress by it produced infinity.
    func testAClearedWaterGoalFallsBackInsteadOfBeingZero() {
        let cleared = DailySummary.Goals(calories: 2000, protein: 0, carbs: 0, fat: 0, waterGoalMl: 0)
        XCTAssertEqual(cleared.effectiveWaterGoalMl, DailySummary.Goals.fallbackWaterGoalMl)
        XCTAssertTrue((1000 / cleared.effectiveWaterGoalMl).isFinite)

        let never = DailySummary.Goals(calories: nil, protein: nil, carbs: nil, fat: nil, waterGoalMl: nil)
        XCTAssertEqual(never.effectiveWaterGoalMl, DailySummary.Goals.fallbackWaterGoalMl)

        let real = DailySummary.Goals(calories: 2000, protein: nil, carbs: nil, fat: nil, waterGoalMl: 3000)
        XCTAssertEqual(real.effectiveWaterGoalMl, 3000)
    }

    // MARK: - Apple Health

    private final class StubHealthKit: HealthKitReading {
        var isAvailable = true
        var state: HealthAuthorizationState = .requested
        var reading: EnergyReading = .noData
        var readError: Error?
        var authorizationRequests = 0
        var energyQueries = 0

        func authorizationState() async -> HealthAuthorizationState { state }
        func requestAuthorization() async throws { authorizationRequests += 1 }
        func activeEnergy(on date: Date) async throws -> EnergyReading {
            energyQueries += 1
            if let readError { throw readError }
            return reading
        }
    }

    private func healthSession(_ calories: Double) -> ExerciseSessionSummary {
        ExerciseSessionSummary(id: "health-1", name: "Active Calories", caloriesBurned: calories, durationMinutes: 0, exerciseId: "sentinel")
    }

    private func loggedSession() -> ExerciseSessionSummary {
        ExerciseSessionSummary(id: "run-1", name: "Running", caloriesBurned: 300, durationMinutes: 30, exerciseId: "ex-1")
    }

    /// The server stores a Health active-energy figure as an exercise entry
    /// against an exercise it calls "Active Calories", so it arrives looking
    /// like a zero-minute workout the user never logged. Left in the list it
    /// would offer to be edited and swiped away, then silently return on the
    /// next sync.
    func testHealthActiveEnergyIsNotTreatedAsALoggedWorkout() {
        let sessions = [loggedSession(), healthSession(420)]

        XCTAssertEqual(sessions.userLogged.map(\.id), ["run-1"])
        XCTAssertEqual(sessions.healthActiveEnergy, 420)
        XCTAssertTrue(sessions[1].isHealthActiveEnergy)
        XCTAssertFalse(sessions[0].isHealthActiveEnergy)
    }

    /// A day whose only "exercise" is the Health sentinel hasn't been logged
    /// in — Today must still offer its first-run layout rather than claiming
    /// a workout exists.
    @MainActor
    func testADayWithOnlyHealthEnergyStillCountsAsNothingLogged() async {
        let stub = StubAPIClient()
        stub.summaryToReturn = DailySummary(
            calorieBalance: .init(eaten: 0, burned: 420, remaining: 0, goal: 2000),
            waterIntake: 0, waterIntakeBreakdown: nil,
            goals: .init(calories: 2000, protein: nil, carbs: nil, fat: nil, waterGoalMl: nil),
            foodEntries: [], exerciseSessions: [healthSession(420)]
        )
        let viewModel = TodayViewModel(apiClient: stub, health: StubHealthKit())

        await viewModel.load()

        XCTAssertFalse(viewModel.hasLoggedAnything)
    }

    @MainActor
    func testHealthIsNotQueriedUnlessTheUserTurnedItOn() async {
        let health = StubHealthKit()
        health.reading = .kilocalories(500)
        let stub = StubAPIClient()
        HealthSync.isEnabled = false
        defer { HealthSync.isEnabled = false }

        await TodayViewModel(apiClient: stub, health: health).load()

        XCTAssertEqual(health.energyQueries, 0, "must not read Health for someone who never asked for it")
        XCTAssertTrue(stub.syncedActiveEnergy.isEmpty)
    }

    @MainActor
    func testEnabledHealthSyncsTheDaysActiveEnergyBeforeReadingTheSummary() async {
        let health = StubHealthKit()
        health.reading = .kilocalories(437.6)
        let stub = StubAPIClient()
        HealthSync.isEnabled = true
        defer { HealthSync.isEnabled = false }

        await TodayViewModel(apiClient: stub, health: health).load()

        XCTAssertEqual(stub.syncedActiveEnergy, [437.6])
    }

    /// A refused read, an unavailable store and a day with no movement are
    /// indistinguishable, and none of them should put an error on the screen.
    @MainActor
    func testHealthFailuresAreSilentAndDoNotBlockTheScreen() async {
        HealthSync.isEnabled = true
        defer { HealthSync.isEnabled = false }

        let noData = StubHealthKit()
        noData.reading = .noData
        let stub = StubAPIClient()
        let viewModel = TodayViewModel(apiClient: stub, health: noData)
        await viewModel.load()
        XCTAssertTrue(stub.syncedActiveEnergy.isEmpty, "nothing to report means nothing is sent")
        XCTAssertNil(viewModel.errorMessage)

        let throwing = StubHealthKit()
        throwing.readError = APIError.server(message: "health denied", code: nil)
        let stub2 = StubAPIClient()
        let viewModel2 = TodayViewModel(apiClient: stub2, health: throwing)
        await viewModel2.load()
        XCTAssertNil(viewModel2.errorMessage)

        // A failing *upload* is equally silent — the summary still loads.
        let working = StubHealthKit()
        working.reading = .kilocalories(200)
        let stub3 = StubAPIClient()
        stub3.syncActiveEnergyError = APIError.server(message: "nope", code: nil)
        let viewModel3 = TodayViewModel(apiClient: stub3, health: working)
        await viewModel3.load()
        XCTAssertNil(viewModel3.errorMessage)
        XCTAssertNotNil(viewModel3.summary)
    }

    // MARK: - Food search

    private func makeFood(_ id: String, _ name: String) -> Food {
        Food(id: id, name: name, brand: nil, defaultVariant: nil)
    }

    @MainActor
    func testBlankQueryStaysIdleAndAsksTheNetworkNothing() async {
        let stub = StubAPIClient()
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        viewModel.query = "   "
        await viewModel.search()

        XCTAssertEqual(viewModel.outcome.kindID, "idle")
        XCTAssertTrue(stub.localSearchQueries.isEmpty)
        XCTAssertTrue(stub.externalSearchQueries.isEmpty)
    }

    /// The user's own foods lead: they're verified entries, where the
    /// OpenFoodFacts matches are a best guess at a barcode database.
    @MainActor
    func testLocalResultsLeadTheMergedList() async {
        let stub = StubAPIClient()
        stub.localFoodsToReturn = [makeFood("local-1", "My Porridge")]
        stub.externalFoodsToReturn = [makeFood("off-1", "Porridge Oats")]
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        viewModel.query = "porridge"
        await viewModel.search()

        guard case .results(let foods) = viewModel.outcome else {
            return XCTFail("expected results, got \(viewModel.outcome)")
        }
        XCTAssertEqual(foods.map(\.id), ["local-1", "off-1"])
        XCTAssertEqual(stub.localSearchQueries, ["porridge"])
        XCTAssertEqual(stub.externalSearchQueries, ["porridge"])
    }

    /// "Nothing matched" and "we couldn't ask" are different answers and the
    /// design gives them different screens — collapsing both into an empty
    /// list would offer "add it yourself" to someone who is simply offline.
    @MainActor
    func testOnlyABothSidesFailureCountsAsANetworkError() async {
        let stub = StubAPIClient()
        stub.localSearchError = APIError.server(message: "down", code: nil)
        stub.externalSearchError = APIError.server(message: "down", code: nil)
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)
        viewModel.query = "porridge"
        await viewModel.search()
        XCTAssertEqual(viewModel.outcome.kindID, "networkError")

        // One source failing while the other simply has nothing is still
        // "no results" — not an error the user can act on.
        let partial = StubAPIClient()
        partial.externalSearchError = APIError.server(message: "down", code: nil)
        let partialViewModel = FoodSearchViewModel(mealTypes: [], apiClient: partial)
        partialViewModel.query = "porridge"
        await partialViewModel.search()
        XCTAssertEqual(partialViewModel.outcome.kindID, "noResults")
    }

    /// A failing source must not hide results the other one found.
    @MainActor
    func testResultsFromOneSourceSurviveTheOtherFailing() async {
        let stub = StubAPIClient()
        stub.externalSearchError = APIError.server(message: "off is down", code: nil)
        stub.localFoodsToReturn = [makeFood("local-1", "My Porridge")]
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        viewModel.query = "porridge"
        await viewModel.search()

        XCTAssertEqual(viewModel.outcome.kindID, "results")
    }

    /// Tapping "+" beside a meal names the destination explicitly; that must
    /// beat the time-of-day guess, which is how a 10pm tap on Breakfast used
    /// to open on Dinner.
    @MainActor
    func testAnExplicitMealBeatsTheTimeOfDayGuess() {
        let breakfast = MealType(id: "b", name: "breakfast", sortOrder: 10)
        let dinner = MealType(id: "d", name: "dinner", sortOrder: 40)
        let viewModel = FoodSearchViewModel(
            mealTypes: [breakfast, dinner], initialMealType: breakfast, apiClient: StubAPIClient()
        )
        XCTAssertEqual(viewModel.selectedMealType?.id, "b")
    }

    @MainActor
    func testMealChipsAreOrderedBySortOrderNotInputOrder() {
        let viewModel = FoodSearchViewModel(
            mealTypes: [
                MealType(id: "d", name: "dinner", sortOrder: 40),
                MealType(id: "b", name: "breakfast", sortOrder: 10),
            ],
            apiClient: StubAPIClient()
        )
        XCTAssertEqual(viewModel.mealTypes.map(\.id), ["b", "d"])
    }

    @MainActor
    func testRecentFoodsLoadForTheIdleStateAndAreFetchedOnce() async {
        let stub = StubAPIClient()
        stub.suggestionsToReturn = FoodSuggestions(
            recentFoods: [makeFood("r1", "Greek Yoghurt")],
            topFoods: [makeFood("t1", "Porridge Oats")]
        )
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        await viewModel.loadRecents()
        XCTAssertEqual(viewModel.recentFoods.map(\.id), ["r1"])

        // The sheet's .task can re-run; re-fetching a list that can't have
        // changed while the sheet is open would just flicker it.
        await viewModel.loadRecents()
        XCTAssertEqual(stub.suggestionsRequests, 1)
    }

    /// Recents are a shortcut on a screen that works without them, so a
    /// failure must not raise an error state over the search box — the idle
    /// prompt is the fallback.
    @MainActor
    func testFailingToLoadRecentsIsSilent() async {
        let stub = StubAPIClient()
        stub.suggestionsError = APIError.server(message: "down", code: nil)
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        await viewModel.loadRecents()

        XCTAssertTrue(viewModel.recentFoods.isEmpty)
        XCTAssertEqual(viewModel.outcome.kindID, "idle")
    }

    /// The suggestions call and the search call are different modes of the
    /// same path, and a search must not be mistaken for one.
    @MainActor
    func testSearchingDoesNotRefetchSuggestions() async {
        let stub = StubAPIClient()
        stub.localFoodsToReturn = [makeFood("local-1", "Porridge")]
        let viewModel = FoodSearchViewModel(mealTypes: [], apiClient: stub)

        viewModel.query = "porridge"
        await viewModel.search()

        XCTAssertEqual(stub.suggestionsRequests, 0)
    }

    // MARK: - Custom food

    @MainActor
    func testCustomFoodRefusesToSaveWithoutANameOrRealCalories() async {
        let stub = StubAPIClient()
        let viewModel = CustomFoodViewModel(apiClient: stub)

        viewModel.name = "   "
        viewModel.calories = "200"
        var saved = await viewModel.save()
        XCTAssertNil(saved)
        XCTAssertNotNil(viewModel.nameError)

        viewModel.name = "Porridge"
        viewModel.calories = "not a number"
        saved = await viewModel.save()
        XCTAssertNil(saved)
        XCTAssertNotNil(viewModel.caloriesError)

        viewModel.calories = "-5"
        saved = await viewModel.save()
        XCTAssertNil(saved)
        XCTAssertNotNil(viewModel.caloriesError)

        // None of those may have reached the network.
        XCTAssertTrue(stub.createdCustomFoods.isEmpty)
    }

    @MainActor
    func testCustomFoodSendsTheTypedValuesAndTreatsBlankMacrosAsZero() async {
        let stub = StubAPIClient()
        let viewModel = CustomFoodViewModel(apiClient: stub)
        viewModel.name = "Porridge Oats"
        viewModel.servingSize = "40"
        viewModel.servingUnit = "g"
        viewModel.calories = "156"
        viewModel.protein = "5.2"
        // A macro left unparseable is a zero, not a failed save — the sheet
        // only makes calories mandatory.
        viewModel.carbs = ""
        viewModel.fat = "3"

        let food = await viewModel.save()

        XCTAssertNotNil(food)
        let sent = try? XCTUnwrap(stub.createdCustomFoods.first)
        XCTAssertEqual(sent?.name, "Porridge Oats")
        XCTAssertEqual(sent?.servingSize, 40)
        XCTAssertEqual(sent?.servingUnit, "g")
        XCTAssertEqual(sent?.calories, 156)
        XCTAssertEqual(sent?.protein, 5.2)
        XCTAssertEqual(sent?.carbs, 0)
        XCTAssertEqual(sent?.fat, 3)
    }

    @MainActor
    func testCustomFoodSurfacesAServerFailureRatherThanReportingSuccess() async {
        let stub = StubAPIClient()
        stub.createCustomFoodError = APIError.server(message: "Food already exists.", code: nil)
        let viewModel = CustomFoodViewModel(apiClient: stub)
        viewModel.name = "Porridge"
        viewModel.calories = "156"

        let food = await viewModel.save()

        XCTAssertNil(food)
        XCTAssertEqual(viewModel.bannerMessage, "Food already exists.")
    }

    // MARK: - Log exercise

    @MainActor
    func testExerciseRequiresBothAnActivityAndADuration() async {
        let stub = StubAPIClient()
        let viewModel = LogExerciseViewModel(apiClient: stub)

        var saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(viewModel.activityError)
        XCTAssertNotNil(viewModel.durationError)

        viewModel.activityName = "Cycling"
        // Zero is not a duration — it would log a session burning nothing.
        viewModel.durationMinutesText = "0"
        saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(viewModel.durationError)

        XCTAssertTrue(stub.createdExerciseEntries.isEmpty)
    }

    @MainActor
    func testExerciseCreateLooksUpTheActivityThenLogsTheEstimatedBurn() async {
        let stub = StubAPIClient()
        let viewModel = LogExerciseViewModel(apiClient: stub)
        viewModel.activityName = "Cycling"
        viewModel.durationMinutesText = "45"
        viewModel.intensity = .vigorous

        XCTAssertEqual(viewModel.estimatedCalories, 45 * 12)
        let saved = await viewModel.save()
        XCTAssertTrue(saved)

        XCTAssertEqual(stub.lookedUpExerciseNames, ["Cycling"])
        let sent = try? XCTUnwrap(stub.createdExerciseEntries.first)
        XCTAssertEqual(sent?.exerciseId, "exercise-1")
        XCTAssertEqual(sent?.durationMinutes, 45)
        XCTAssertEqual(sent?.caloriesBurned, 540)
        XCTAssertTrue(stub.updatedExerciseEntries.isEmpty)
    }

    /// Diary's edit path already knows the exercise id, so it must PUT
    /// against it rather than doing a redundant find-or-create — which would
    /// also risk creating a second exercise if the name had been edited.
    @MainActor
    func testExerciseEditUpdatesInPlaceWithoutRecreatingTheActivity() async {
        let stub = StubAPIClient()
        let entryDate = Date(timeIntervalSince1970: 1_700_000_000)
        let viewModel = LogExerciseViewModel(
            editingEntryId: "entry-9", exerciseId: "exercise-7", name: "Running",
            durationMinutes: 30, caloriesBurned: 240, entryDate: entryDate,
            apiClient: stub
        )

        // 240/30 = 8 kcal/min, which is exactly the moderate preset.
        XCTAssertEqual(viewModel.intensity, .moderate)
        XCTAssertEqual(viewModel.durationMinutesText, "30")
        XCTAssertTrue(viewModel.isEditing)

        let saved = await viewModel.save()
        XCTAssertTrue(saved)

        XCTAssertTrue(stub.lookedUpExerciseNames.isEmpty, "editing must not create another exercise")
        XCTAssertTrue(stub.createdExerciseEntries.isEmpty)
        let update = try? XCTUnwrap(stub.updatedExerciseEntries.first)
        XCTAssertEqual(update?.id, "entry-9")
        XCTAssertEqual(update?.input.exerciseId, "exercise-7")
        XCTAssertEqual(update?.input.entryDate, entryDate, "an edit must not silently move the entry to today")
    }

    /// Intensity isn't stored — it's reverse-derived from the logged
    /// kcal/minute, so the preset that reopens is the nearest one, not
    /// necessarily the one originally chosen.
    @MainActor
    func testExerciseEditPicksTheNearestIntensityPreset() {
        let stub = StubAPIClient()
        let nearlyLight = LogExerciseViewModel(
            editingEntryId: "e", exerciseId: "x", name: "Walk",
            durationMinutes: 60, caloriesBurned: 260, entryDate: Date(), apiClient: stub
        )
        // 4.33 kcal/min sits nearest the light preset (4), not moderate (8).
        XCTAssertEqual(nearlyLight.intensity, .light)

        let zeroDuration = LogExerciseViewModel(
            editingEntryId: "e", exerciseId: "x", name: "Odd",
            durationMinutes: 0, caloriesBurned: 100, entryDate: Date(), apiClient: stub
        )
        // Guards the divide-by-zero rather than producing a NaN rate.
        XCTAssertEqual(zeroDuration.intensity, .moderate)
        XCTAssertEqual(zeroDuration.durationMinutesText, "")
    }

    // MARK: - Goals

    /// A representative row: the five fields the app edits, plus columns it
    /// has no UI for at all, plus the three macro percentages that must stay
    /// null.
    private func sampleGoalsRaw() -> [String: JSONValue] {
        [
            "goal_date": .string("2026-09-23"),
            "calories": .number(2000),
            "protein": .number(150),
            "carbs": .number(200),
            "fat": .number(70),
            "water_goal_ml": .number(2500),
            "sodium": .number(2300),
            "dietary_fiber": .number(30),
            "target_exercise_calories_burned": .number(400),
            "protein_percentage": .null,
            "carbs_percentage": .null,
            "fat_percentage": .null,
            "custom_meal_percentages": .object(["breakfast": .number(25)]),
            "custom_nutrients": .object([:]),
        ]
    }

    /// The write replaces the whole row and zeroes anything it isn't sent
    /// (verified live: sodium 2300 -> 0 from a POST that merely omitted it).
    /// Editing a calorie goal here must therefore carry the untouched columns
    /// back out, or it destroys goals set in the web client.
    @MainActor
    func testSavingAGoalPreservesColumnsTheAppDoesNotModel() async {
        let stub = StubAPIClient()
        stub.goalsToReturn = NutritionGoals(raw: sampleGoalsRaw())
        let viewModel = GoalsViewModel(date: Date(), apiClient: stub)

        await viewModel.load()
        viewModel.text[GoalsViewModel.Field.calories.rawValue] = "1800"
        let saved = await viewModel.save()

        XCTAssertTrue(saved)
        let payload = stub.savedGoals.last!.writePayload(startingOn: "2026-09-23")
        XCTAssertEqual(payload["p_calories"], .number(1800))
        // The point of the test: untouched columns survive.
        XCTAssertEqual(payload["p_sodium"], .number(2300))
        XCTAssertEqual(payload["p_dietary_fiber"], .number(30))
        XCTAssertEqual(payload["p_target_exercise_calories_burned"], .number(400))
        XCTAssertEqual(payload["custom_meal_percentages"], .object(["breakfast": .number(25)]))
    }

    /// Three zeroed percentages would count as "all three are numbers", and
    /// the server then computes macro grams from them and overrides the gram
    /// fields — so null has to stay null rather than being coerced.
    func testMacroPercentagesStayNullRatherThanBecomingZero() {
        let payload = NutritionGoals(raw: sampleGoalsRaw()).writePayload(startingOn: "2026-09-23")
        XCTAssertEqual(payload["p_protein_percentage"], .null)
        XCTAssertEqual(payload["p_carbs_percentage"], .null)
        XCTAssertEqual(payload["p_fat_percentage"], .null)
    }

    /// Write keys take a `p_` prefix; the two custom objects don't, and
    /// `goal_date` isn't a write key at all (the write names it
    /// `p_start_date`). An unprefixed field returns 200 and writes nothing.
    func testWritePayloadPrefixesEverythingExceptTheDocumentedExceptions() {
        let payload = NutritionGoals(raw: sampleGoalsRaw()).writePayload(startingOn: "2026-09-23")

        XCTAssertEqual(payload["p_start_date"], .string("2026-09-23"))
        XCTAssertNil(payload["goal_date"], "goal_date is read-only; the write uses p_start_date")
        XCTAssertNil(payload["p_goal_date"])
        XCTAssertNotNil(payload["custom_nutrients"], "must NOT be prefixed")
        XCTAssertNil(payload["p_custom_nutrients"])
    }

    /// If the load failed there's no row to mutate, so saving would write a
    /// five-field row over the user's real one. Save fails closed.
    @MainActor
    func testSaveIsRefusedWhenTheCurrentGoalsCouldNotBeRead() async {
        let stub = StubAPIClient()
        stub.goalsLoadError = APIError.server(message: "nope", code: nil)
        let viewModel = GoalsViewModel(date: Date(), apiClient: stub)

        await viewModel.load()
        XCTAssertTrue(viewModel.loadFailed)
        XCTAssertFalse(viewModel.canSave)

        viewModel.text[GoalsViewModel.Field.calories.rawValue] = "1800"
        let saved = await viewModel.save()

        XCTAssertFalse(saved)
        XCTAssertTrue(stub.savedGoals.isEmpty, "nothing may be written without a loaded row")
    }

    @MainActor
    func testCaloriesAreRequiredAndZeroedGoalsPrefillAsEmpty() async {
        let stub = StubAPIClient()
        stub.goalsToReturn = NutritionGoals(raw: [
            "calories": .number(0), "protein": .number(0),
            "carbs": .number(0), "fat": .number(0), "water_goal_ml": .number(0),
        ])
        let viewModel = GoalsViewModel(date: Date(), apiClient: stub)

        await viewModel.load()
        // A zeroed row is how the server says "no goal set" — showing "0"
        // would invite saving it back as a real goal of zero.
        XCTAssertEqual(viewModel.text[GoalsViewModel.Field.calories.rawValue], "")

        let saved = await viewModel.save()
        XCTAssertFalse(saved)
        XCTAssertNotNil(viewModel.error(for: .calories))
        XCTAssertTrue(stub.savedGoals.isEmpty)
    }

    /// The server fills `calorieBalance.goal` with a default of 2000 for an
    /// account that has never set one, so asking *that* whether a goal exists
    /// always answered yes and the goal-not-set card could never appear —
    /// leaving the user's rings measured against a target they never chose.
    /// The goal row is the only honest source.
    @MainActor
    func testNoGoalIsRecognisedEvenThoughTheServerDefaultsTheBalanceTo2000() async {
        let stub = StubAPIClient()
        stub.summaryToReturn = DailySummary(
            calorieBalance: .init(eaten: 0, burned: 240, remaining: 2240, goal: 2000),
            waterIntake: 0, waterIntakeBreakdown: nil,
            goals: .init(calories: 0, protein: 0, carbs: 0, fat: 0, waterGoalMl: 0),
            foodEntries: [], exerciseSessions: []
        )
        let viewModel = TodayViewModel(apiClient: stub)

        await viewModel.load()

        XCTAssertFalse(viewModel.hasGoalSet)
    }

    @MainActor
    func testAGoalThatIsActuallySetReadsAsSet() async {
        let stub = StubAPIClient()
        stub.summaryToReturn = DailySummary(
            calorieBalance: .init(eaten: 0, burned: 0, remaining: 1800, goal: 1800),
            waterIntake: 0, waterIntakeBreakdown: nil,
            goals: .init(calories: 1800, protein: nil, carbs: nil, fat: nil, waterGoalMl: nil),
            foodEntries: [], exerciseSessions: []
        )
        let viewModel = TodayViewModel(apiClient: stub)

        await viewModel.load()

        XCTAssertTrue(viewModel.hasGoalSet)
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
