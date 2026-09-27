//
//  ServerIntegrationTests.swift
//  SwiftSparkyFitnessTests
//
//  The sync engine against a real SparkyFitness server — the only way to
//  know the server's upserts, id handling and payload shapes behave the way
//  the engine assumes. Skipped unless a server is named:
//
//    xcodebuild test ... \
//      TEST_RUNNER_SERVER_URL=http://localhost:3010 \
//      TEST_RUNNER_SPARKY_IT_EMAIL=sync-it@sparky.test \
//      TEST_RUNNER_SPARKY_IT_PASSWORD=...
//
//  (`TEST_RUNNER_` hands the variable to the app process, where
//  `ServerConfig` reads SERVER_URL.) Each run works on its own past day and
//  clears it first, so runs don't see each other.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class ServerIntegrationTests: XCTestCase {

    private var server: APIClient!
    private var account = ""
    private var day = Date()

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let url = env["SERVER_URL"], let email = env["SPARKY_IT_EMAIL"], let password = env["SPARKY_IT_PASSWORD"] else {
            throw XCTSkip("No integration server configured")
        }
        server = APIClient()
        _ = try await server.signIn(email: email, password: password)
        account = SyncAccount.key(serverURL: url, email: email)
        // A day of its own per run, somewhere in 2019.
        let offset = Int(Date().timeIntervalSince1970 / 60) % 360
        day = Calendar.current.date(byAdding: .day, value: offset, to: LocalDay.date("2019-01-01")!)!
        try await clearServerDay()
    }

    override func tearDown() async throws {
        if server != nil { try? await clearServerDay() }
    }

    private func clearServerDay() async throws {
        let summary = try await server.dailySummary(date: day)
        for entry in summary.foodEntries { try await server.deleteFoodEntry(id: entry.id) }
        for session in summary.exerciseSessions.userLogged { try await server.deleteExerciseEntry(id: session.id) }
        for drink in try await server.waterLog(date: day) { try await server.deleteWaterLogEntry(id: drink.id) }
        let body = try await server.bodyMeasurements(date: day)
        if let id = body.id { try await server.deleteBodyMeasurements(id: id) }
    }

    private func seededDevice() async throws -> LocalAPIClient {
        let device = LocalAPIClient(store: LocalStore(inMemory: true))
        let food = try await device.materializeExternalFood(Food(
            id: "it-oats", name: "IT Oats", brand: nil,
            defaultVariant: FoodVariant(id: "it-oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
        let meal = try await device.createMealType(name: "IT Second breakfast", sortOrder: 15)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 150, entryDate: day))
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day))
        let squat = try await device.createCustomExercise(CustomExerciseInput(name: "IT Squat", category: "strength", modality: .weightReps))
        _ = try await device.createExerciseEntry(ExerciseEntryInput(
            exerciseId: squat.id, modality: .weightReps, entryDate: day, durationMinutes: 20, caloriesBurned: 150,
            sets: [ExerciseSetInput(setNumber: 1, reps: 5, weight: 100)]
        ))
        _ = try await device.logWaterAmount(date: day, milliliters: 500)
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 72.5]))
        return device
    }

    func testPushAgainstARealServer() async throws {
        let device = try await seededDevice()
        let engine = ServerPush(store: device.store, server: server, account: account)

        // Everything arrives, in the right meals, with the device's numbers.
        let first = try await engine.run()
        XCTAssertEqual(first.failures, [])
        var summary = try await server.dailySummary(date: day)
        XCTAssertEqual(summary.foodEntries.count, 2)
        XCTAssertEqual(summary.foodEntries.map(\.calories).reduce(0, +), 760, accuracy: 0.5) // 570 + 190
        XCTAssertTrue(summary.foodEntries.contains { $0.mealType.caseInsensitiveCompare("IT Second breakfast") == .orderedSame })
        XCTAssertEqual(summary.exerciseSessions.userLogged.count, 1)
        XCTAssertEqual(summary.exerciseSessions.userLogged.first?.setsList.first?.weight, 100)
        let water = try await server.waterLog(date: day).map(\.waterMl).reduce(0, +)
        XCTAssertEqual(water, 500, accuracy: 0.5)
        let weight = try await server.bodyMeasurements(date: day).weight
        XCTAssertEqual(weight, 72.5)

        // Nothing is left to send.
        XCTAssertTrue(engine.plan().isEmpty)

        // Lost replies: the server has the rows, the device has no links.
        for link in device.store.all(LocalSyncLink.self)
        where [LocalFoodEntry.syncKind, LocalExerciseEntry.syncKind, LocalWaterEntry.syncKind].contains(link.kind) {
            device.store.context.delete(link)
        }
        device.store.save()
        let resend = try await ServerPush(store: device.store, server: server, account: account).run()
        XCTAssertEqual(resend.failures, [])
        summary = try await server.dailySummary(date: day)
        XCTAssertEqual(summary.foodEntries.count, 2, "food entries upsert on source_id")
        XCTAssertEqual(summary.exerciseSessions.userLogged.count, 1, "exercise entries are matched, not duplicated")
        let waterAfter = try await server.waterLog(date: day).map(\.waterMl).reduce(0, +)
        XCTAssertEqual(waterAfter, 500, accuracy: 0.5, "water upserts on source_id")

        // An edit goes out as an update.
        let entry = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        let food = try await device.materializeExternalFood(Food(
            id: "it-oats", name: "IT Oats", brand: nil,
            defaultVariant: FoodVariant(id: "it-oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
        try await device.updateFoodEntry(id: entry.id, FoodEntryInput(food: food, mealTypeId: entry.mealTypeId, quantity: 100, entryDate: day))
        _ = try await ServerPush(store: device.store, server: server, account: account).run()
        summary = try await server.dailySummary(date: day)
        XCTAssertEqual(summary.foodEntries.count, 2)
        XCTAssertTrue(summary.foodEntries.contains { abs($0.quantity - 100) < 0.01 })

        // A delete goes out as a delete.
        try await device.deleteFoodEntry(id: entry.id)
        let deletes = try await ServerPush(store: device.store, server: server, account: account).run()
        XCTAssertEqual(deletes.deleted, 1)
        summary = try await server.dailySummary(date: day)
        XCTAssertEqual(summary.foodEntries.count, 1)
    }
}
