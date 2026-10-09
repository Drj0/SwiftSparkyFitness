//
//  PerformanceBenchmarks.swift
//  SwiftSparkyFitnessTests
//
//  Times the data-layer paths that run on every write, load or sync, over a
//  year of realistic diary data in an in-memory store. Prints medians as
//  "BENCH <name> <ms>" for before/after comparisons; the asserts only check
//  that the answers stay right, not the timings (too noisy for CI).
//

import SwiftData
import XCTest
@testable import SwiftSparkyFitness

@MainActor
final class PerformanceBenchmarks: XCTestCase {
    private let account = "bench|me@example.com"

    /// A year: 8 foods, 6 drinks and 2 exercise rows (one is Health's
    /// active-energy row) a day, a goal change a fortnight, every row linked
    /// to the server except the last day's.
    private func seededYear() -> (LocalAPIClient, unsynced: Int) {
        let store = LocalStore(inMemory: true)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let exercise = LocalExercise(name: "Running")
        store.context.insert(exercise)
        let linkedAt = Date().addingTimeInterval(3600)
        var unsynced = 0
        for offset in 0..<365 {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = LocalDay.key(day)
            var rows: [(String, String)] = []
            for i in 0..<8 {
                let entry = LocalFoodEntry(entryDate: day, foodId: "f\(i)", foodName: "Food \(i)", mealTypeId: "breakfast",
                                           mealTypeName: "Breakfast", quantity: 100, unit: "g", servingSize: 100,
                                           servingUnit: "g", calories: 250, protein: 10, carbs: 30, fat: 8)
                store.context.insert(entry)
                rows.append((LocalFoodEntry.syncKind, entry.id))
            }
            for _ in 0..<6 {
                let water = LocalWaterEntry(dayKey: key, waterMl: 250)
                store.context.insert(water)
                rows.append((LocalWaterEntry.syncKind, water.id))
            }
            let run = LocalExerciseEntry(entryDate: day, exerciseId: exercise.id, name: "Running", durationMinutes: 30,
                                         caloriesBurned: 300, setsJSON: "[]")
            let health = LocalExerciseEntry(entryDate: day, exerciseId: exercise.id,
                                            name: ExerciseSessionSummary.healthActiveEnergyName,
                                            durationMinutes: 0, caloriesBurned: 450)
            store.context.insert(run)
            store.context.insert(health)
            rows.append((LocalExerciseEntry.syncKind, run.id))
            rows.append((LocalExerciseEntry.syncKind, health.id))
            if offset % 14 == 0 {
                let data = try! JSONEncoder().encode(["calories": JSONValue.number(Double(2000 + offset))])
                let goal = LocalGoalRow(dayKey: key, rawJSON: data)
                store.context.insert(goal)
                rows.append((LocalGoalRow.syncKind, goal.syncKey))
            }
            if offset == 0 { unsynced += rows.count; continue }
            for (kind, localKey) in rows {
                store.context.insert(LocalSyncLink(kind: kind, localKey: localKey, serverId: UUID().uuidString,
                                                   serverAccount: account, linkedAt: linkedAt))
            }
        }
        try! store.context.save()
        return (LocalAPIClient(store: store), unsynced)
    }

    private func median(_ name: String, runs: Int = 5, _ work: () async throws -> Void) async rethrows {
        var times: [Double] = []
        for _ in 0..<runs {
            let start = ContinuousClock.now
            try await work()
            let elapsed = ContinuousClock.now - start
            times.append(Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000)
        }
        print(String(format: "BENCH %@ %.2f ms", name, times.sorted()[runs / 2]))
    }

    func testBenchmarkDataPaths() async throws {
        let (client, unsynced) = seededYear()
        let store = client.store
        let yearAgo = Calendar.current.date(byAdding: .day, value: -364, to: Date())!

        var plan = ServerPush.Plan()
        await median("pushPlan", runs: 3) {
            plan = ServerPush(store: store, server: FakeSyncServer(), account: account).plan()
        }
        XCTAssertEqual(plan.creates, unsynced)
        XCTAssertEqual(plan.updates, 0)

        var summary: ExerciseRangeSummary?
        try await median("exerciseSummaryYear") { summary = try await client.exerciseSummary(from: yearAgo, to: Date()) }
        XCTAssertEqual(summary?.totals.workoutCount, 365)

        var goals: [String: NutritionGoals] = [:]
        try await median("goalsYear") { goals = try await client.goals(from: yearAgo, to: Date()) }
        XCTAssertEqual(goals.count, 365)

        var today = NutritionGoals(raw: [:])
        try await median("goalsDay") { today = try await client.goals(date: Date()) }
        XCTAssertEqual(today.calories, 2000)

        var recents: [Exercise] = []
        try await median("recentExercises") { recents = try await client.recentExercises() }
        XCTAssertEqual(recents.map(\.name), ["Running"])

        var history: [String: ExerciseLastSession] = [:]
        await median("exerciseHistory180") {
            history = await client.exerciseHistory(since: Calendar.current.date(byAdding: .day, value: -180, to: Date())!)
        }
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.values.first?.timesThisWeek, 7)
    }

    /// One render of a year's weight chart asks for a label per point; a
    /// scrub re-renders per step. Timed as the second render, the steady
    /// state while scrubbing.
    func testBenchmarkChartLabels() async {
        let model = ProgressViewModel(user: SessionUser(email: "me@example.com", name: "Me"),
                                      apiClient: LocalAPIClient(store: LocalStore(inMemory: true)))
        let days = (0..<365).map { Calendar.current.date(byAdding: .day, value: -$0, to: model.maxDate)! }
        var labels: [String] = []
        let render = { labels = days.map { model.formattedReading($0) + model.formattedDay($0) } }
        render()
        await median("chartLabelsYearRender") { render() }
        XCTAssertEqual(labels.count, 365)
        XCTAssertEqual(model.formattedDay(model.maxDate), model.maxDate.formatted(.dateTime.day().month(.abbreviated)))
    }
}
