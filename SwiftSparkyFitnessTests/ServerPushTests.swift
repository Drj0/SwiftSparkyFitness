//
//  ServerPushTests.swift
//  SwiftSparkyFitnessTests
//
//  Step 3 of docs/SYNC_SWITCHING_PLAN.md. The push has to be safe to
//  interrupt at any point and safe to run again: these tests break it in
//  each of the ways a phone out of range breaks it, then check the server
//  holds exactly the diary — no gaps, no duplicates.
//

import XCTest
import SwiftData
@testable import SwiftSparkyFitness

@MainActor
final class ServerPushTests: XCTestCase {

    private let account = SyncAccount.key(serverURL: "http://sparky.local:3010", email: "me@example.com")
    private let day = LocalDay.date("2026-09-10")!

    private func makeDevice() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    private func push(_ device: LocalAPIClient, to server: FakeSyncServer) -> ServerPush {
        ServerPush(store: device.store, server: server, account: account)
    }

    private func oats(_ device: LocalAPIClient) async throws -> Food {
        try await device.materializeExternalFood(Food(
            id: "oats", name: "Oats", brand: nil,
            defaultVariant: FoodVariant(id: "oats-v", servingSize: 100, servingUnit: "g", calories: 380, protein: 13, carbs: 67, fat: 7)
        ))
    }

    /// A food entry in a custom meal, a lifting session with sets, a drink,
    /// a weigh-in and a goal.
    private func seedDiary(_ device: LocalAPIClient) async throws {
        let food = try await oats(device)
        let meal = try await device.createMealType(name: "Second breakfast", sortOrder: 15)
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: meal.id, quantity: 150, entryDate: day))
        try await device.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 50, entryDate: day))
        let squat = try await device.createCustomExercise(CustomExerciseInput(name: "Squat", category: "strength", modality: .weightReps))
        _ = try await device.createExerciseEntry(ExerciseEntryInput(
            exerciseId: squat.id, modality: .weightReps, entryDate: day, durationMinutes: 20, caloriesBurned: 150,
            sets: [ExerciseSetInput(setNumber: 1, reps: 5, weight: 100)]
        ))
        _ = try await device.logWaterAmount(date: day, milliliters: 500)
        _ = try await device.upsertBodyMeasurements(BodyMeasurementsInput(date: day, values: [.weight: 72.5]))
        var goals = try await device.goals(date: day)
        goals.calories = 2100
        try await device.saveGoals(goals, startingOn: day)
    }

    private func assertServerMatchesDevice(_ server: FakeSyncServer, _ device: LocalAPIClient, file: StaticString = #filePath, line: UInt = #line) async throws {
        let mine = try await device.dailySummary(date: day)
        let theirs = try await server.backing.dailySummary(date: day)
        XCTAssertEqual(theirs.foodEntries.count, mine.foodEntries.count, "food entries", file: file, line: line)
        XCTAssertEqual(theirs.calorieBalance.eaten, mine.calorieBalance.eaten, accuracy: 0.01, "calories eaten", file: file, line: line)
        XCTAssertEqual(Set(theirs.foodEntries.map(\.mealType)), Set(mine.foodEntries.map(\.mealType)), "meals", file: file, line: line)
        XCTAssertEqual(theirs.exerciseSessions.userLogged.count, mine.exerciseSessions.userLogged.count, "exercise", file: file, line: line)
        XCTAssertEqual(theirs.waterIntake, mine.waterIntake, accuracy: 0.5, "water", file: file, line: line)
    }

    // MARK: - Happy path

    func testAFirstPushSendsTheWholeDiaryAndLinksIt() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        let engine = push(device, to: server)
        let plan = engine.plan()
        XCTAssertGreaterThan(plan.creates, 0)

        let report = try await engine.run()

        XCTAssertEqual(report.failures, [])
        XCTAssertEqual(report.sent, plan.total, "what was offered is what was sent")
        try await assertServerMatchesDevice(server, device)
        let value1 = try await server.backing.dailySummary(date: day).exerciseSessions.first?.setsList.first?.weight
        XCTAssertEqual(value1, 100)
        let value2 = try await server.backing.bodyMeasurements(date: day).weight
        XCTAssertEqual(value2, 72.5)
        let value3 = try await server.backing.goals(date: day).calories
        XCTAssertEqual(value3, 2100)
        XCTAssertTrue(engine.plan().isEmpty, "everything is linked afterwards")
    }

    func testASecondPushSendsNothing() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        _ = try await push(device, to: server).run()
        let before = server.mutatingCalls.count

        _ = try await push(device, to: server).run()

        XCTAssertEqual(server.mutatingCalls.count, before)
    }

    func testAnEditIsSentAsAnUpdateNotANewEntry() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        _ = try await push(device, to: server).run()
        let entry = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first { $0.quantity == 150 })
        try await device.updateFoodEntry(id: entry.id, FoodEntryInput(food: try await oats(device), mealTypeId: entry.mealTypeId, quantity: 300, entryDate: day))

        let engine = push(device, to: server)
        XCTAssertEqual(engine.plan().updates, 1)
        _ = try await engine.run()

        try await assertServerMatchesDevice(server, device)
        XCTAssertTrue(server.backing.store.all(LocalFoodEntry.self).contains { $0.quantity == 300 })
    }

    func testADeleteHereDeletesTheServerCopyAndClearsTheLedger() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        _ = try await push(device, to: server).run()
        let entry = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first)
        try await device.deleteFoodEntry(id: entry.id)
        XCTAssertEqual(push(device, to: server).plan().deletes, 1)

        let report = try await push(device, to: server).run()

        XCTAssertEqual(report.deleted, 1)
        try await assertServerMatchesDevice(server, device)
        XCTAssertTrue(device.store.all(LocalTombstone.self).isEmpty)
        XCTAssertNil(device.store.link(kind: LocalFoodEntry.syncKind, localKey: entry.id, account: account))
    }

    // MARK: - Interruptions

    func testAnInterruptedPushResumesWithoutDuplicates() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.goOfflineAfterMutations = 3

        do {
            _ = try await push(device, to: server).run()
            XCTFail("expected the push to stop when the connection dropped")
        } catch {
            XCTAssertTrue(error.isConnectivityFailure)
        }
        server.goOfflineAfterMutations = nil
        _ = try await push(device, to: server).run()

        try await assertServerMatchesDevice(server, device)
    }

    /// The case source_id can't cover: the server made the exercise entry,
    /// then the reply was lost. The retry must find it, not add a second.
    func testAnExerciseEntrySentButNeverLinkedIsMatchedOnRetry() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.dropReplyNext = ["createExerciseEntry"]

        do { _ = try await push(device, to: server).run() } catch { XCTAssertTrue(error.isConnectivityFailure) }
        _ = try await push(device, to: server).run()

        let value4 = try await server.backing.dailySummary(date: day).exerciseSessions.userLogged.count
        XCTAssertEqual(value4, 1)
        XCTAssertEqual(server.calls.filter { $0 == "createExerciseEntry" }.count, 1)
    }

    /// Food entries and drinks rely on the server's upsert instead: a lost
    /// reply and a resend still leave one row.
    func testAFoodEntryAndDrinkSentTwiceStayOneEach() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.dropReplyNext = ["createFoodEntry", "pushWater"]

        do { _ = try await push(device, to: server).run() } catch {}
        do { _ = try await push(device, to: server).run() } catch {}
        _ = try await push(device, to: server).run()

        try await assertServerMatchesDevice(server, device)
    }

    /// An edit made while that row's request is in flight must not be marked
    /// as synced by the reply to the older version.
    func testAnEditDuringTheRequestIsSentNextTime() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        let target = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        let food = try await oats(device)
        var edited = false
        server.beforeCall = { name in
            guard name == "createFoodEntry", !edited else { return }
            edited = true
            target.quantity = 75
            device.store.save()
        }

        _ = try await push(device, to: server).run()

        XCTAssertEqual(push(device, to: server).plan().updates, 1, "the in-flight edit is still pending")
        _ = food
    }

    // MARK: - What isn't sent, and failures

    func testUntouchedDefaultPreferencesDontOverwriteTheServers() async throws {
        let server = FakeSyncServer()
        _ = try await server.backing.updateUserPreference(.weight, to: "lbs")
        let device = makeDevice()

        _ = try await push(device, to: server).run()

        let value5 = try await server.backing.userPreferences().defaultWeightUnit
        XCTAssertEqual(value5, "lbs")
        XCTAssertFalse(server.calls.contains("updateUserPreference"))
    }

    func testSeededMealsLinkByNameAndCustomOnesAreCreated() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()

        _ = try await push(device, to: server).run()

        XCTAssertEqual(server.calls.filter { $0 == "createMealType" }.count, 1, "only the custom meal is created")
        let serverMeals = try await server.backing.mealTypes()
        XCTAssertTrue(serverMeals.contains { $0.name == "Second breakfast" })
        XCTAssertEqual(serverMeals.filter { $0.name == "Breakfast" }.count, 1)
    }

    func testARefusedRowIsReportedAndEverythingElseGoesThrough() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.failNext = ["createExerciseEntry": FakeSyncServer.refused]

        let report = try await push(device, to: server).run()

        XCTAssertEqual(report.failures.map(\.kind), [LocalExerciseEntry.syncKind])
        let value6 = try await server.backing.dailySummary(date: day).foodEntries.count
        XCTAssertEqual(value6, 2)
        // Not linked, so the next push tries it again.
        XCTAssertEqual(push(device, to: server).plan().creates, 1)
        _ = try await push(device, to: server).run()
        try await assertServerMatchesDevice(server, device)
    }

    func testASignedOutSessionStopsThePush() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.failNext = ["createFoodEntry": FakeSyncServer.unauthorized]

        do {
            _ = try await push(device, to: server).run()
            XCTFail("a 401 must stop the run")
        } catch {
            XCTAssertTrue(error.isUnauthorized)
        }
    }

    func testHealthActiveEnergyGoesThroughTheHealthIngest() async throws {
        let device = makeDevice()
        try await device.syncActiveEnergy(kilocalories: 430, date: day)
        let server = FakeSyncServer()

        _ = try await push(device, to: server).run()

        XCTAssertTrue(server.calls.contains("syncActiveEnergy"))
        XCTAssertFalse(server.calls.contains("createExerciseEntry"))
    }

    /// A proxy's 502 while the server restarts is "later", not "refused" —
    /// the delete must still be pending afterwards.
    func testAServerErrorDuringADeleteKeepsItPending() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        _ = try await push(device, to: server).run()
        let entry = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first)
        try await device.deleteFoodEntry(id: entry.id)
        server.failNext = ["deleteFoodEntry": FakeSyncServer.badGateway]

        do {
            _ = try await push(device, to: server).run()
            XCTFail("a 5xx must stop the run")
        } catch {
            XCTAssertTrue(error.isTransientFailure)
        }
        XCTAssertEqual(push(device, to: server).plan().deletes, 1)
        _ = try await push(device, to: server).run()
        try await assertServerMatchesDevice(server, device)
    }

    func testAServerErrorDuringACreateStopsTheRunAndResumes() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.failNext = ["createExerciseEntry": APIError.server(message: "Unavailable", code: nil, status: 503)]

        do { _ = try await push(device, to: server).run() } catch { XCTAssertTrue(error.isTransientFailure) }
        let report = try await push(device, to: server).run()

        XCTAssertEqual(report.failures, [])
        try await assertServerMatchesDevice(server, device)
    }

    /// Deleted while its update was in flight: one tombstone, one delete,
    /// and no touching of models that are already gone.
    func testARowDeletedDuringItsUpdateIsDeletedOnce() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        _ = try await push(device, to: server).run()
        let target = try XCTUnwrap(device.store.all(LocalFoodEntry.self).first { $0.quantity == 50 })
        let targetId = target.id
        let food = try await oats(device)
        try await device.updateFoodEntry(id: targetId, FoodEntryInput(food: food, mealTypeId: target.mealTypeId, quantity: 70, entryDate: day))
        server.beforeCall = { name in
            guard name == "updateFoodEntry" else { return }
            if let row = device.store.fetch(LocalFoodEntry.self, where: #Predicate { $0.id == targetId }).first {
                device.store.delete(row)
            }
        }

        // The same run reaches its delete phase and deletes the server copy.
        let report = try await push(device, to: server).run()
        server.beforeCall = nil

        XCTAssertEqual(report.deleted, 1)
        try await assertServerMatchesDevice(server, device)
        XCTAssertTrue(device.store.all(LocalTombstone.self).isEmpty)
        XCTAssertTrue(push(device, to: server).plan().isEmpty)
    }

    func testTheHandoffIgnoresASecondTapOnSend() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        let model = ServerHandoffModel(user: SessionUser(email: "me@example.com", name: nil), store: device.store,
                                       server: server, serverURL: "http://sparky.local:3010", isICloudDownloading: { false })
        await model.prepare()

        async let first: Void = model.send()
        async let second: Void = model.send()
        _ = await (first, second)

        XCTAssertEqual(server.calls.filter { $0 == "createExerciseEntry" }.count, 1)
        try await assertServerMatchesDevice(server, device)
    }

    func testAHandoffWithRefusedRowsStaysOfferedInSettings() async throws {
        let device = makeDevice()
        try await seedDiary(device)
        let server = FakeSyncServer()
        server.failNext = ["createExerciseEntry": FakeSyncServer.refused]
        PendingServerHandoff.isPending = true
        defer { PendingServerHandoff.isPending = false }
        let model = ServerHandoffModel(user: SessionUser(email: "me@example.com", name: nil), store: device.store,
                                       server: server, serverURL: "http://sparky.local:3010", isICloudDownloading: { false })
        await model.prepare()

        await model.send()

        XCTAssertTrue(PendingServerHandoff.isPending)
        XCTAssertEqual(device.store.syncedHome, .server)
    }

    func testDeletingMostOfTheDiaryAsksFirst() async throws {
        var plan = ServerPush.Plan()
        plan.linked = 100
        plan.deletes = 30
        XCTAssertTrue(plan.needsConfirmation)
        plan.deletes = 5
        XCTAssertFalse(plan.needsConfirmation)
    }
}
