//
//  ServerPullTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 4 of docs/SYNC_SWITCHING_PLAN.md: the server's diary merged into a
//  device store. The pull must never overwrite what the device hasn't sent
//  yet, never resurrect what it deleted, and — with the push — round-trip
//  a diary without adding, losing or changing a thing.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class ServerPullTests: XCTestCase {

    private let account = SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com")
    private let day = LocalDay.date("2026-09-10")!

    private func makeDevice() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    private func pull(_ device: LocalAPIClient, from server: FakeSyncServer) async throws -> ServerPull.Report {
        try await ServerPull(store: device.store, server: server, account: account).run(from: day, to: day)
    }

    private func push(_ device: LocalAPIClient, to server: FakeSyncServer) async throws -> ServerPush.Report {
        try await ServerPush(store: device.store, server: server, account: account).run()
    }

    private func oats(_ client: LocalAPIClient) async throws -> Food {
        try await client.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: "Acme",
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
    }

    /// A diary written "on the server" — directly into the fake's store.
    private func seedServer(_ server: FakeSyncServer) async throws {
        let backing = server.backing
        let food = try await oats(backing)
        let meal = try await backing.createMealType(name: "Second breakfast", sortOrder: 15)
        try await backing.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 150, entryDate: day))
        try await backing.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day))
        let squat = try await backing.createCustomExercise(CustomExerciseInput(name: "Squat", category: "strength", modality: .weightReps))
        _ = try await backing.createExerciseEntry(ExerciseEntryInput(
            exerciseId: squat.id, modality: .weightReps, entryDate: day, durationMinutes: 20, caloriesBurned: 150,
            sets: [ExerciseSetInput(setNumber: 1, reps: 5, weight: 100)]
        ))
        _ = try await backing.logWaterAmount(date: day, milliliters: 500)
        _ = try await backing.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 72.5]))
        var goals = try await backing.goals(date: day)
        goals.calories = 2100
        try await backing.saveGoals(goals, startingOn: day)
        _ = try await backing.updateUserPreference(.weight, to: "lbs")
    }

    private func assertSameDay(_ a: LocalAPIClient, _ b: LocalAPIClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        let left = try await a.dailySummary(date: day)
        let right = try await b.dailySummary(date: day)
        XCTAssertEqual(left.foodEntries.count, right.foodEntries.count, "food entries", file: file, line: line)
        XCTAssertEqual(left.calorieBalance.eaten, right.calorieBalance.eaten, accuracy: 0.01, "eaten", file: file, line: line)
        XCTAssertEqual(Set(left.foodEntries.map { $0.mealType.lowercased() }), Set(right.foodEntries.map { $0.mealType.lowercased() }), "meals", file: file, line: line)
        XCTAssertEqual(left.exerciseSessions.userLogged.count, right.exerciseSessions.userLogged.count, "exercise", file: file, line: line)
        XCTAssertEqual(left.exerciseSessions.userLogged.first?.setsList.first?.weight, right.exerciseSessions.userLogged.first?.setsList.first?.weight, "sets", file: file, line: line)
        XCTAssertEqual(left.waterIntake, right.waterIntake, accuracy: 0.5, "water", file: file, line: line)
    }

    // MARK: - Bringing a diary in

    func testAPullBringsTheServersDiaryIn() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()

        let report = try await pull(device, from: server)

        XCTAssertGreaterThan(report.added, 0)
        try await assertSameDay(device, server.backing)
        let weight = try await device.bodyMeasurements(date: day).weight
        XCTAssertEqual(weight, 72.5)
        let calories = try await device.goals(date: day).calories
        XCTAssertEqual(calories, 2100)
        let unit = try await device.userPreferences().defaultWeightUnit
        XCTAssertEqual(unit, "lbs", "a fresh device's seeded preferences take the server's")
        // Pulled rows are in sync, not pending.
        XCTAssertTrue(ServerPush(store: device.store, server: server, account: account).plan().isEmpty)
    }

    func testPullingTwiceChangesNothing() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)

        let again = try await pull(device, from: server)

        XCTAssertEqual(again, ServerPull.Report())
    }

    // MARK: - Merge rules

    func testAServerEditUpdatesAnUntouchedRow() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let serverEntry = try XCTUnwrap(server.backing.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        let food = try await oats(server.backing)
        try await server.backing.updateFoodEntry(id: serverEntry.id, FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 80, entryDate: day))

        let report = try await pull(device, from: server)

        XCTAssertEqual(report.updated, 1)
        XCTAssertTrue(device.store.all(LocalFoodEntry.self).contains { $0.quantity == 80 })
    }

    func testAnEditMadeHereIsNotOverwrittenByTheServer() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let local = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        let food = try await oats(device)
        try await device.updateFoodEntry(id: local.id, FoodEntryInput(food: food, mealTypeId: local.mealTypeId, quantity: 60, entryDate: day))
        let serverEntry = try XCTUnwrap(server.backing.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        try await server.backing.updateFoodEntry(id: serverEntry.id, FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 90, entryDate: day))

        _ = try await pull(device, from: server)

        XCTAssertTrue(device.store.all(LocalFoodEntry.self).contains { $0.quantity == 60 })
        XCTAssertFalse(device.store.all(LocalFoodEntry.self).contains { $0.quantity == 90 })
    }

    func testAServerDeleteRemovesTheLocalCopyWithoutATombstone() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let serverEntry = try XCTUnwrap(server.backing.store.all(LocalFoodEntry.self).first)
        try await server.backing.deleteFoodEntry(id: serverEntry.id)

        let report = try await pull(device, from: server)

        XCTAssertEqual(report.deleted, 1)
        try await assertSameDay(device, server.backing)
        XCTAssertTrue(device.store.all(LocalTombstone.self).isEmpty, "the server deleted it first")
    }

    func testARowLoggedHereAndNotYetSentIsLeftAlone() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        let food = try await oats(device)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "dinner", quantity: 30, entryDate: day))

        _ = try await pull(device, from: server)

        XCTAssertTrue(device.store.all(LocalFoodEntry.self).contains { $0.quantity == 30 })
        XCTAssertEqual(ServerPush(store: device.store, server: server, account: account).plan().creates, 1)
    }

    func testARowDeletedHereAndNotYetSentStaysDeleted() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let local = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first)
        try await device.deleteFoodEntry(id: local.id)

        _ = try await pull(device, from: server)

        XCTAssertEqual(device.store.all(LocalFoodEntry.self).count, 1)
        XCTAssertEqual(device.store.tombstones(kind: LocalFoodEntry.syncKind).count, 1)
    }

    func testSettingsChangedHereAreKeptUntilSent() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await device.updateUserPreference(.weight, to: "st")

        _ = try await pull(device, from: server)

        let unit = try await device.userPreferences().defaultWeightUnit
        XCTAssertEqual(unit, "st")
    }

    /// Goals come back carried forward per day; only the change is stored.
    func testGoalsAreStoredAsChangesNotOneRowPerDay() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        let later = Calendar.current.date(byAdding: .day, value: 6, to: day)!

        _ = try await ServerPull(store: device.store, server: server, account: account).run(from: day, to: later)

        XCTAssertEqual(device.store.all(LocalGoalRow.self).count, 1)
        let calories = try await device.goals(date: later).calories
        XCTAssertEqual(calories, 2100)
    }

    /// A routine pull must not rewrite rows it didn't change: on the iCloud
    /// store every rewrite is an upload, and a stamp that reaches another
    /// device before its link reads there as an unsent edit.
    func testAPullLeavesUnchangedRowsUntouched() async throws {
        let server = FakeSyncServer()
        try await seedServer(server)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let stamps = device.store.all(LocalFoodEntry.self).map(\.updatedAt)
        let linkStamps = device.store.all(LocalSyncLink.self).map(\.linkedAt).sorted()

        _ = try await pull(device, from: server)

        XCTAssertEqual(device.store.all(LocalFoodEntry.self).map(\.updatedAt), stamps)
        XCTAssertEqual(device.store.all(LocalSyncLink.self).map(\.linkedAt).sorted(), linkStamps)
    }

    /// A food this device created and pushed is the same food when its entry
    /// comes back: no second copy under the server's id.
    func testAPushedFoodDoesNotComeBackAsASecondFood() async throws {
        let device = makeDevice()
        let food = try await oats(device)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day))
        let server = FakeSyncServer()
        _ = try await push(device, to: server)

        _ = try await pull(device, from: server)

        XCTAssertEqual(device.store.all(LocalFood.self).count, 1)
        XCTAssertEqual(device.store.all(LocalFoodEntry.self).first?.foodId, "oats")
    }

    /// Goals set here from day P, not yet sent, while the server still has
    /// the old ones: the days after P keep the new goals.
    func testAnUnsentGoalIsNotUndoneOnTheDaysAfterIt() async throws {
        let server = FakeSyncServer()
        try await seedServer(server) // 2100 from `day`
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let changeDay = Calendar.current.date(byAdding: .day, value: 2, to: day)!
        var mine = try await device.goals(date: changeDay)
        mine.calories = 1800
        try await device.saveGoals(mine, startingOn: changeDay)
        let later = Calendar.current.date(byAdding: .day, value: 5, to: day)!

        _ = try await ServerPull(store: device.store, server: server, account: account).run(from: day, to: later)

        let onChange = try await device.goals(date: changeDay).calories
        let after = try await device.goals(date: Calendar.current.date(byAdding: .day, value: 1, to: changeDay)!).calories
        XCTAssertEqual(onChange, 1800)
        XCTAssertEqual(after, 1800)
        let before = try await device.goals(date: day).calories
        XCTAssertEqual(before, 2100)
    }

    /// A meal category deleted here, waiting to be deleted on the server,
    /// stays deleted.
    func testADeletedMealCategoryIsNotBroughtBack() async throws {
        let server = FakeSyncServer()
        _ = try await server.backing.createMealType(name: "Supper", sortOrder: 50)
        let device = makeDevice()
        _ = try await pull(device, from: server)
        let supper = try XCTUnwrap(device.store.all(LocalMealType.self).first { $0.name == "Supper" })
        try await device.deleteMealType(id: supper.id)

        _ = try await pull(device, from: server)

        XCTAssertFalse(device.store.all(LocalMealType.self).contains { $0.name == "Supper" })
        _ = try await push(device, to: server)
        let serverMeals = try await server.backing.mealTypes()
        XCTAssertFalse(serverMeals.contains { $0.name == "Supper" }, "the push then deletes it there")
    }

    // MARK: - Round trips with the push

    /// Pushed rows are linked under the ids the server gave them, which are
    /// the ids the pull sees — so pulling right after pushing is a no-op.
    func testPullingRightAfterPushingChangesNothing() async throws {
        let device = makeDevice()
        let food = try await oats(device)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day))
        let run = try await device.createCustomExercise(CustomExerciseInput(name: "Run", category: "cardio", modality: .durationDistance))
        _ = try await device.createExerciseEntry(ExerciseEntryInput(exerciseId: run.id, modality: .durationDistance, entryDate: day,
                                                                    durationMinutes: 30, caloriesBurned: 300, distance: 5))
        _ = try await device.logWaterAmount(date: day, milliliters: 250)
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 70]))
        let server = FakeSyncServer()
        _ = try await push(device, to: server)

        let report = try await pull(device, from: server)

        XCTAssertEqual(report.added, 0, "nothing the device sent comes back as new")
        XCTAssertEqual(report.deleted, 0)
        try await assertSameDay(device, server.backing)
    }

    /// iCloud → server on one phone, server → iCloud on another.
    func testADiaryPushedFromOneDeviceArrivesIntactOnAnother() async throws {
        let first = makeDevice()
        let food = try await oats(first)
        let meal = try await first.createMealType(name: "Second breakfast", sortOrder: 15)
        try await first.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 150, entryDate: day))
        let squat = try await first.createCustomExercise(CustomExerciseInput(name: "Squat", category: "strength", modality: .weightReps))
        _ = try await first.createExerciseEntry(ExerciseEntryInput(
            exerciseId: squat.id, modality: .weightReps, entryDate: day, durationMinutes: 20, caloriesBurned: 150,
            sets: [ExerciseSetInput(setNumber: 1, reps: 5, weight: 100)]
        ))
        _ = try await first.logWaterAmount(date: day, milliliters: 500)
        let server = FakeSyncServer()
        _ = try await push(first, to: server)

        let second = makeDevice()
        _ = try await pull(second, from: server)

        try await assertSameDay(first, second)
    }
}
