//
//  ExerciseLoggingTests.swift
//  SwiftSparkyFitnessTests
//
//  The exercise-logging redesign's logic: the on-device history that "last
//  time" and quick log read from, the editor starting from it, the
//  steppers, and the two repeat paths (Recent's quick log, the day list's
//  "Log again").
//
//  Every test runs against an isolated in-memory store.
//

import XCTest
@testable import SwiftSparkyFitness

@MainActor
final class ExerciseLoggingTests: XCTestCase {

    private func makeLocal() -> LocalAPIClient {
        LocalAPIClient(store: LocalStore(inMemory: true))
    }

    private func daysAgo(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: -days, to: Date())!
    }

    private func strength(_ local: LocalAPIClient, named name: String = "Goblet Squat") async throws -> Exercise {
        try await local.createCustomExercise(CustomExerciseInput(name: name, category: "Strength", modality: .weightReps))
    }

    private func sets(_ pairs: [(Int, Double)]) -> [ExerciseSetInput] {
        pairs.enumerated().map { ExerciseSetInput(setNumber: $0.offset + 1, reps: $0.element.0, weight: $0.element.1) }
    }

    private func log(_ local: LocalAPIClient, _ exercise: Exercise, on date: Date, sets: [ExerciseSetInput] = [], minutes: Double = 10, calories: Double = 50, distance: Double? = nil) async throws {
        var input = ExerciseEntryInput(
            exerciseId: exercise.id, modality: exercise.modality ?? .duration, entryDate: date,
            durationMinutes: minutes, caloriesBurned: calories
        )
        input.sets = sets
        input.distance = distance
        _ = try await local.createExerciseEntry(input)
    }

    // MARK: - History

    /// "Last time" has to be the most recent session, not the first one the
    /// fetch happens to return, and the weekly count only this week's.
    func testHistoryKeepsTheLatestSessionAndCountsOnlyThisWeek() async throws {
        let local = makeLocal()
        let squat = try await strength(local)
        try await log(local, squat, on: daysAgo(20), sets: sets([(12, 15)]))
        try await log(local, squat, on: daysAgo(3), sets: sets([(10, 20)]))
        try await log(local, squat, on: Date(), sets: sets([(8, 22.5), (8, 22.5)]))

        let history = await local.exerciseHistory(since: daysAgo(180))
        let last = try XCTUnwrap(history[ExerciseLastSession.key("Goblet Squat")])
        XCTAssertEqual(last.sets.map(\.reps), [8, 8])
        XCTAssertEqual(last.sets.map(\.weight), [22.5, 22.5])
        XCTAssertEqual(last.modality, .weightReps)
        XCTAssertEqual(last.timesThisWeek, 2, "the session 20 days ago isn't this week")
    }

    /// Matched on the normalized name, so a differently-cased row of the
    /// same exercise still finds its history.
    func testHistoryLooksUpByNormalizedName() async throws {
        let local = makeLocal()
        let squat = try await strength(local)
        try await log(local, squat, on: Date(), sets: sets([(5, 40)]))

        let history = await local.exerciseHistory(since: daysAgo(30))
        XCTAssertNotNil(history[ExerciseLastSession.key("goblet squat")])
    }

    /// Apple Health's active-energy row is stored as an exercise entry; it
    /// must never be offered as something to log again.
    func testHistorySkipsHealthActiveEnergy() async throws {
        let local = makeLocal()
        let sentinel = try await local.findOrCreateExercise(named: ExerciseSessionSummary.healthActiveEnergyName)
        try await log(local, sentinel, on: Date(), minutes: 0, calories: 420)

        let history = await local.exerciseHistory(since: daysAgo(30))
        XCTAssertNil(history[ExerciseLastSession.key(ExerciseSessionSummary.healthActiveEnergyName)])
    }

    // MARK: - Editor starting from last time

    func testEditorStartsFromTheLastSessionsSets() {
        let exercise = Exercise(id: "e1", name: "Goblet Squat", category: "Strength", modality: .weightReps, caloriesPerHour: 300)
        let last = ExerciseLastSession(
            date: daysAgo(2), modality: .weightReps, durationMinutes: 4, caloriesBurned: 20,
            distance: nil, sets: sets([(8, 20), (6, 20)]), timesThisWeek: 1
        )
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, lastSession: last, apiClient: makeLocal())

        XCTAssertTrue(viewModel.startsFromLastSession)
        XCTAssertEqual(viewModel.setRows.map(\.repsText), ["8", "6"])
        XCTAssertEqual(viewModel.setRows.map(\.weightText), ["20", "20"])
        // 300 kcal/h over two sets at two minutes each.
        XCTAssertEqual(viewModel.caloriesText, "20")
        XCTAssertTrue(viewModel.caloriesAreEstimated)
    }

    /// A session logged before the exercise's modality changed describes
    /// fields this form doesn't have.
    func testEditorIgnoresALastSessionFromAnotherModality() {
        let exercise = Exercise(id: "e1", name: "Plank", category: "Strength", modality: .weightReps)
        let last = ExerciseLastSession(
            date: daysAgo(1), modality: .duration, durationMinutes: 5, caloriesBurned: 10,
            distance: nil, sets: [], timesThisWeek: 1
        )
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, lastSession: last, apiClient: makeLocal())

        XCTAssertFalse(viewModel.startsFromLastSession)
        XCTAssertEqual(viewModel.setRows.count, 1)
        XCTAssertTrue(viewModel.setRows[0].isBlank)
    }

    func testTimedEditorCarriesDurationAndDistanceOver() {
        let exercise = Exercise(id: "e2", name: "Running", category: "Cardio", modality: .durationDistance, caloriesPerHour: 600)
        let last = ExerciseLastSession(
            date: daysAgo(1), modality: .durationDistance, durationMinutes: 30, caloriesBurned: 300,
            distance: 5, sets: [], timesThisWeek: 1
        )
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, lastSession: last, apiClient: makeLocal())

        XCTAssertEqual(viewModel.durationMinutesText, "30")
        XCTAssertEqual(viewModel.distanceText, "5")
        XCTAssertEqual(viewModel.caloriesText, "300")
    }

    // MARK: - Steppers

    func testAddSetCopiesTheSetAboveAndReestimates() {
        let exercise = Exercise(id: "e1", name: "Goblet Squat", category: "Strength", modality: .weightReps, caloriesPerHour: 300)
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, apiClient: makeLocal())
        viewModel.setRows[0].repsText = "10"
        viewModel.setRows[0].weightText = "20"
        viewModel.applyEstimateIfNeeded()
        XCTAssertEqual(viewModel.caloriesText, "10")

        viewModel.addSet()
        XCTAssertEqual(viewModel.setRows.map(\.repsText), ["10", "10"])
        XCTAssertEqual(viewModel.setRows.map(\.weightText), ["20", "20"])
        XCTAssertEqual(viewModel.caloriesText, "20", "a second set adds two more minutes to the estimate")
    }

    /// A blank field starts from the set above, so the first + on a new set
    /// is a small change from it rather than a climb from zero.
    func testSteppingABlankWeightStartsFromTheSetAbove() {
        let exercise = Exercise(id: "e1", name: "Goblet Squat", category: "Strength", modality: .weightReps)
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, apiClient: makeLocal())
        viewModel.setRows[0].weightText = "20"
        viewModel.addSet()
        viewModel.setRows[1].weightText = ""

        viewModel.step(viewModel.setRows[1], .weight, by: 1)
        XCTAssertEqual(viewModel.setRows[1].weightText, "22.5")
    }

    func testRepsNeverGoBelowZeroAndZeroReadsAsBlank() {
        let exercise = Exercise(id: "e1", name: "Push-up", category: "Strength", modality: .repsOnly)
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, apiClient: makeLocal())
        viewModel.setRows[0].repsText = "1"

        viewModel.step(viewModel.setRows[0], .reps, by: -1)
        XCTAssertEqual(viewModel.setRows[0].repsText, "")
        viewModel.step(viewModel.setRows[0], .reps, by: -1)
        XCTAssertEqual(viewModel.setRows[0].repsText, "")
    }

    func testDurationStepsToTheNextFiveInTheDirectionPressed() {
        let exercise = Exercise(id: "e2", name: "Walking", category: "Cardio", modality: .duration)
        let viewModel = ExerciseEntryEditorViewModel(exercise: exercise, apiClient: makeLocal())

        viewModel.durationMinutesText = "32"
        viewModel.stepDuration(by: 1)
        XCTAssertEqual(viewModel.durationMinutesText, "35")

        viewModel.durationMinutesText = "32"
        viewModel.stepDuration(by: -1)
        XCTAssertEqual(viewModel.durationMinutesText, "30")

        viewModel.durationMinutesText = "30"
        viewModel.stepDuration(by: -1)
        XCTAssertEqual(viewModel.durationMinutesText, "25")

        viewModel.durationMinutesText = "5"
        viewModel.stepDuration(by: -1)
        XCTAssertEqual(viewModel.durationMinutesText, "", "zero minutes is no duration, not a typed 0")
    }

    // MARK: - Repeating a session

    /// Quick log lands on the day the sheet was opened for — logging from
    /// yesterday's page must not file the session under today.
    func testQuickLogRepeatsTheLastSessionOnTheSheetsDay() async throws {
        let local = makeLocal()
        let squat = try await strength(local)
        try await log(local, squat, on: daysAgo(3), sets: sets([(8, 20), (8, 20), (8, 20)]), minutes: 6, calories: 30)

        let viewModel = ExerciseSearchViewModel(entryDate: daysAgo(1), apiClient: local)
        await viewModel.loadHistory()
        XCTAssertEqual(viewModel.lastSessionSummary(for: "Goblet Squat", modality: .weightReps), "3 × 8 · 20 kg · 3 days ago")

        await viewModel.quickLog(squat)

        let yesterday = try await local.dailySummary(date: daysAgo(1)).exerciseSessions
        let logged = try XCTUnwrap(yesterday.first)
        XCTAssertEqual(logged.setsList.map(\.reps), [8, 8, 8])
        XCTAssertEqual(logged.setsList.map(\.setNumber), [1, 2, 3])
        XCTAssertEqual(logged.caloriesBurned, 30)
        XCTAssertTrue(viewModel.justLogged.contains(squat.id))
        XCTAssertNil(viewModel.quickLogError)
        let today = try await local.dailySummary(date: Date()).exerciseSessions
        XCTAssertTrue(today.isEmpty)
    }

    /// The day list's "Log again" copies a logged row as it is.
    func testRepeatingALoggedSessionKeepsItsDetail() async throws {
        let local = makeLocal()
        let run = try await local.createCustomExercise(CustomExerciseInput(name: "Trail Run", category: "Cardio", modality: .durationDistance))
        var input = ExerciseEntryInput(exerciseId: run.id, modality: .durationDistance, entryDate: daysAgo(2), durationMinutes: 40, caloriesBurned: 420)
        input.distance = 6.5
        input.avgHeartRate = 151
        _ = try await local.createExerciseEntry(input)
        let logged = try await local.dailySummary(date: daysAgo(2)).exerciseSessions
        let session = try XCTUnwrap(logged.first)

        let again = ExerciseEntryInput(repeating: session, on: Date())
        XCTAssertEqual(again.exerciseId, run.id)
        XCTAssertEqual(again.modality, .durationDistance)
        XCTAssertEqual(again.durationMinutes, 40)
        XCTAssertEqual(again.caloriesBurned, 420)
        XCTAssertEqual(again.distance, 6.5)
        XCTAssertEqual(again.avgHeartRate, 151)
        XCTAssertTrue(Calendar.current.isDateInToday(again.entryDate))
    }

    // MARK: - Calories for exercises the catalog doesn't know

    /// A custom exercise has no rate of its own; a typical one for its kind
    /// gives Save a labelled estimate instead of a required blank.
    func testCustomExerciseGetsAFallbackRateForItsKind() {
        let viewModel = ExerciseSearchViewModel(apiClient: makeLocal())
        let custom = Exercise(id: "c1", name: "Garage Circuit Thing", category: "Strength", modality: .weightReps)

        let rated = viewModel.withBestRate(custom)
        XCTAssertEqual(rated.caloriesPerHour, 5.0 * ExerciseCatalog.fallbackWeightKg)
    }

    func testFallbackMETUsesModalityWhenTheCategoryIsUnknown() {
        XCTAssertEqual(ExerciseCatalog.fallbackMET(category: "Other", modality: .durationDistance), 7.0)
        XCTAssertEqual(ExerciseCatalog.fallbackMET(category: nil, modality: .duration), 4.0)
        XCTAssertEqual(ExerciseCatalog.fallbackMET(category: "cardio", modality: .duration), 7.0)
    }
}
