//
//  HealthLiveTests.swift
//  SwiftSparkyFitnessTests
//
//  This iPhone's diary mirrors to iCloud, where Health data may not be
//  stored (App Store guideline 5.1.3(ii)): Health's active energy and
//  workouts are read live for the screen and never written to it. A
//  server's copy (no Health reader) still stores them.
//

import XCTest
@testable import SwiftSparkyFitness

@MainActor
final class HealthLiveTests: XCTestCase {
    private final class StubHealth: HealthKitReading {
        var isAvailable = true
        var energy: EnergyReading = .noData
        var workouts: [HealthWorkout] = []
        func requestAuthorization(includingWorkouts: Bool) async throws -> HealthAuthorizationOutcome { .answered }
        func activeEnergy(on date: Date) async throws -> EnergyReading { energy }
        func hasRecentEnergy(days: Int) async -> Bool { false }
        /// HealthKit's range match: anything *overlapping* [start, end).
        func workouts(from start: Date, to end: Date) async throws -> [HealthWorkout] {
            workouts.filter { $0.start < end && $0.start.addingTimeInterval($0.durationMinutes * 60) > start }
        }
    }

    private var health = StubHealth()

    override func setUp() {
        super.setUp()
        health = StubHealth()
        HealthSync.isEnabled = true
        HealthSync.importsWorkouts = true
    }

    override func tearDown() {
        HealthSync.isEnabled = false
        UserDefaults.standard.removeObject(forKey: HealthSync.workoutsKey)
        super.tearDown()
    }

    /// This iPhone's diary: reads Health, stores nothing from it.
    private func makeICloudDiary() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true), health: health)
    }

    private func storedExerciseRows(_ client: LocalAPIClient) -> [LocalExerciseEntry] {
        client.store.all(LocalExerciseEntry.self)
    }

    private func morning(hour: Int = 8) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date())!
    }

    func testActiveEnergyIsReadForTheDayAndNeverStored() async throws {
        health.energy = .kilocalories(430)
        let diary = makeICloudDiary()

        try await diary.syncActiveEnergy(kilocalories: 430, date: Date())
        let day = try await diary.dailySummary(date: Date())

        XCTAssertEqual(day.exerciseSessions.healthActiveEnergy, 430)
        XCTAssertEqual(day.calorieBalance.burned, 430)
        XCTAssertTrue(storedExerciseRows(diary).isEmpty, "Today's write must not land in the iCloud diary")
    }

    func testWorkoutsShowReadOnlyAndAreCountedOnceAgainstActiveEnergy() async throws {
        health.energy = .kilocalories(500)
        health.workouts = [HealthWorkout(id: UUID(), catalogName: "Running", start: morning(), durationMinutes: 30,
                                         kilocalories: 312, distanceMeters: 5000)]
        let diary = makeICloudDiary()

        let imported = await HealthWorkoutImporter.importWorkouts(on: Date(), apiClient: diary, health: health)
        let day = try await diary.dailySummary(date: Date())
        let run = try XCTUnwrap(day.exerciseSessions.userLogged.first)

        XCTAssertFalse(imported, "nothing is imported into this diary")
        XCTAssertTrue(storedExerciseRows(diary).isEmpty)
        XCTAssertEqual(run.name, "Running")
        XCTAssertEqual(run.caloriesBurned, 312)
        XCTAssertEqual(run.distance, 5)
        XCTAssertTrue(run.isHealthWorkout && run.isReadFromHealth)
        XCTAssertNil(run.exerciseId, "no stored row to reopen for editing")
        // Active energy already contains the workout: max(500, 312), not the sum.
        XCTAssertEqual(day.calorieBalance.burned, 500)
    }

    /// A run from 23:30 to 00:30 belongs to the day it started on, once —
    /// not to both days HealthKit's overlapping range returns it for.
    func testAWorkoutAcrossMidnightCountsOnlyOnTheDayItStarted() async throws {
        let today = Calendar.current.startOfDay(for: Date())
        let lateStart = today.addingTimeInterval(-30 * 60)
        health.workouts = [HealthWorkout(id: UUID(), catalogName: "Running", start: lateStart, durationMinutes: 60,
                                         kilocalories: 600, distanceMeters: nil)]
        let diary = makeICloudDiary()

        let yesterday = try await diary.dailySummary(date: lateStart)
        let todays = try await diary.dailySummary(date: today)

        XCTAssertEqual(yesterday.exerciseSessions.userLogged.map(\.name), ["Running"])
        XCTAssertTrue(todays.exerciseSessions.userLogged.isEmpty)
        let week = try await diary.exerciseSummary(from: lateStart, to: today)
        XCTAssertEqual(week.totals.workoutCount, 1)
    }

    func testWorkoutsNeedTheirOwnSwitchAndHealthOn() async throws {
        health.workouts = [HealthWorkout(id: UUID(), catalogName: "Walking", start: morning(), durationMinutes: 20,
                                         kilocalories: 90, distanceMeters: nil)]
        let diary = makeICloudDiary()

        HealthSync.importsWorkouts = false
        var day = try await diary.dailySummary(date: Date())
        XCTAssertTrue(day.exerciseSessions.isEmpty)

        HealthSync.importsWorkouts = true
        HealthSync.isEnabled = false
        day = try await diary.dailySummary(date: Date())
        XCTAssertTrue(day.exerciseSessions.isEmpty)
    }

    /// Rows earlier versions stored leave the diary (and so iCloud), and are
    /// never counted twice alongside the live read.
    func testHealthRowsStoredByEarlierVersionsAreRemoved() async throws {
        health.energy = .kilocalories(400)
        let diary = makeICloudDiary()
        let serverCopy = LocalAPIClient(store: diary.store)
        try await serverCopy.syncActiveEnergy(kilocalories: 380, date: Date())
        let exercise = try await serverCopy.findOrCreateExercise(named: "Cycling")
        _ = try await serverCopy.createExerciseEntry(ExerciseEntryInput(
            exerciseId: exercise.id, modality: .duration, entryDate: morning(), durationMinutes: 40,
            caloriesBurned: 350, notes: HealthWorkoutImporter.note
        ))
        _ = try await serverCopy.createExerciseEntry(ExerciseEntryInput(
            exerciseId: exercise.id, modality: .duration, entryDate: morning(hour: 18), durationMinutes: 20,
            caloriesBurned: 120
        ))
        XCTAssertEqual(storedExerciseRows(diary).count, 3)

        let day = try await diary.dailySummary(date: Date())

        XCTAssertEqual(storedExerciseRows(diary).map(\.caloriesBurned), [120], "only the hand-logged ride stays")
        XCTAssertEqual(day.exerciseSessions.healthActiveEnergy, 400, "Health's live figure, not the stored 380")
        XCTAssertEqual(day.calorieBalance.burned, 520)
    }

    /// A server's copy has no Health reader: it keeps storing, for the server.
    func testAServersCopyStillStoresHealthRows() async throws {
        let serverCopy = LocalAPIClient(store: LocalStore(inMemory: true))
        XCTAssertFalse(serverCopy.readsHealthLive)

        try await serverCopy.syncActiveEnergy(kilocalories: 300, date: Date())

        XCTAssertEqual(storedExerciseRows(serverCopy).map(\.name), [ExerciseSessionSummary.healthActiveEnergyName])
    }

    func testProgressCountsWorkoutsReadFromHealth() async throws {
        health.workouts = [HealthWorkout(id: UUID(), catalogName: "Swimming", start: morning(), durationMinutes: 45,
                                         kilocalories: 380, distanceMeters: 1500)]
        let diary = makeICloudDiary()
        let weekAgo = Calendar.current.date(byAdding: .day, value: -6, to: Date())!

        let summary = try await diary.exerciseSummary(from: weekAgo, to: Date())

        XCTAssertEqual(summary.totals.workoutCount, 1)
        XCTAssertEqual(summary.totals.totalCaloriesBurned, 380)
        XCTAssertEqual(summary.totals.totalDurationMinutes, 45)
    }
}
