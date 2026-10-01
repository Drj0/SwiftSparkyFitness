//
//  ProgressTests.swift
//  SwiftSparkyFitnessTests
//
//  The Progress tab's redesign: long ranges and their weekly bars, the
//  weight trend line, the empty state's look back at earlier history, and
//  the loaded window the charts draw against.
//
//  The Module 6 cases (summing, goal steps, clamping, partial failure) stay
//  in the main suite; these cover what the redesign added. Loads run against
//  an in-memory `LocalAPIClient`, so nothing touches the real store.
//

import XCTest
@testable import SwiftSparkyFitness

@MainActor
final class ProgressTests: XCTestCase {

    private let calendar = Calendar.current

    private func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: Date()))!
    }

    private func viewModel(createdDaysAgo: Int = 400, client: APIClientProtocol? = nil) -> ProgressViewModel {
        let user = SessionUser(email: "demo@sparkyfitness.com", name: "Demo", createdAt: daysAgo(createdDaysAgo))
        return ProgressViewModel(user: user, apiClient: client ?? LocalAPIClient(store: LocalStore(inMemory: true)))
    }

    /// The history lookup runs in its own task after the load lands.
    private func waitForEarlierHistory(_ model: ProgressViewModel) async throws {
        for _ in 0..<100 where model.earlierHistory == .unknown {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Ranges

    func testLongPresetsSpanSixMonthsAndAYear() {
        let model = viewModel()
        model.preset = .sixMonths
        XCTAssertEqual(model.range.dayCount, 180)
        model.preset = .year
        XCTAssertEqual(model.range.dayCount, 365)
        XCTAssertLessThanOrEqual(365, ProgressDateRange.maximumDays, "a year must fit under the span cap")
    }

    /// Three months stays daily — a custom quarter included — and anything
    /// longer bars by week.
    func testBarsGoWeeklyPastThreeMonths() {
        let quarter = ProgressDateRange(start: daysAgo(91), end: daysAgo(0))
        let half = ProgressDateRange(start: daysAgo(179), end: daysAgo(0))
        XCTAssertEqual(quarter.granularity, .day)
        XCTAssertEqual(half.granularity, .week)
    }

    /// The segment text is "1W"; VoiceOver must not read that aloud.
    func testSegmentsHaveSpokenLabels() {
        XCTAssertEqual(ProgressRangePreset.week.shortLabel, "1W")
        XCTAssertEqual(ProgressRangePreset.week.spokenLabel, "Last 7 days")
        XCTAssertEqual(ProgressRangePreset.custom.spokenLabel, "Custom range")
    }

    /// A year's range crosses a year boundary; both ends need their year or
    /// the header reads backwards ("2 Oct – 1 Oct 2026").
    func testDatesOutsideThisYearCarryTheirYear() {
        let model = viewModel()
        model.preset = .year
        let start = model.range.start
        // On 31 Dec a 365-day window starts on 1 Jan of the same year.
        if !calendar.isDate(start, equalTo: model.maxDate, toGranularity: .year) {
            XCTAssertTrue(model.rangeDescription.hasPrefix(start.formatted(.dateTime.day().month(.abbreviated).year())))
            XCTAssertTrue(model.formattedDay(start).contains(String(calendar.component(.year, from: start))))
        }

        model.preset = .week
        let thisYear = String(calendar.component(.year, from: model.maxDate))
        XCTAssertFalse(model.formattedDay(model.maxDate).contains(thisYear), "this year's days stay short")
    }

    // MARK: - Weekly buckets

    /// A week's bar is the mean of the days that were logged, not the sum
    /// and not diluted by the unlogged ones.
    func testWeeklyNutritionAveragesOverLoggedDaysOnly() throws {
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: daysAgo(30)))
        let first = week.start
        let second = calendar.date(byAdding: .day, value: 2, to: first)!
        let nextWeek = calendar.date(byAdding: .day, value: 7, to: first)!
        let days = [
            DailyNutrition(date: first, calories: 1000, protein: 50, carbs: 100, fat: 30),
            DailyNutrition(date: second, calories: 2000, protein: 150, carbs: 200, fat: 70),
            DailyNutrition(date: nextWeek, calories: 1800, protein: 120, carbs: 180, fat: 60),
        ]

        let bars = ProgressViewModel.weekly(days)

        XCTAssertEqual(bars.count, 2)
        XCTAssertEqual(bars[0].date, week.start)
        XCTAssertEqual(bars[0].calories, 1500)
        XCTAssertEqual(bars[0].protein, 100)
        XCTAssertEqual(bars[0].loggedDays, 2)
        XCTAssertEqual(bars[1].loggedDays, 1)
    }

    /// Exercise days are zero-filled, so a week's bar is a plain total.
    func testWeeklyExerciseSums() throws {
        let week = try XCTUnwrap(calendar.dateInterval(of: .weekOfYear, for: daysAgo(30)))
        let days = (0..<7).map { offset in
            DailyExercise(
                date: calendar.date(byAdding: .day, value: offset, to: week.start)!,
                caloriesBurned: offset.isMultiple(of: 2) ? 300 : 0,
                durationMinutes: offset.isMultiple(of: 2) ? 30 : 0,
                workoutCount: offset.isMultiple(of: 2) ? 1 : 0
            )
        }

        let bars = ProgressViewModel.weekly(days)

        XCTAssertEqual(bars.count, 1)
        XCTAssertEqual(bars[0].caloriesBurned, 1200)
        XCTAssertEqual(bars[0].durationMinutes, 120)
        XCTAssertEqual(bars[0].workoutCount, 4)
    }

    /// On a long range the loaded bars are weekly; the raw daily series the
    /// averages come from stays daily.
    func testLongRangeLoadsWeeklyBars() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        let food = try await local.materializeExternalFood(Food(
            id: "f1", name: "Food", brand: nil,
            defaultVariant: FoodVariant(id: "v1", servingSize: 100, servingUnit: "g", calories: 500, protein: 10, carbs: 20, fat: 5)
        ))
        for offset in [3, 4, 40, 41, 42] {
            try await local.createFoodEntry(FoodEntryInput(food: food, mealTypeId: "lunch", quantity: 100, entryDate: daysAgo(offset)))
        }
        let model = viewModel(client: local)
        model.preset = .sixMonths
        await model.load()

        XCTAssertEqual(model.loadedRange.granularity, .week)
        XCTAssertEqual(model.nutrition.count, 5, "five logged days")
        XCTAssertLessThanOrEqual(model.nutritionBars.count, 4, "grouped into their weeks")
        XCTAssertEqual(model.nutritionBars.reduce(0) { $0 + $1.loggedDays }, 5)
        for bar in model.nutritionBars {
            XCTAssertEqual(calendar.dateInterval(of: .weekOfYear, for: bar.date)?.start, bar.date)
        }
    }

    // MARK: - Weight trend

    /// Short ranges draw the readings alone; there's nothing to smooth.
    func testWeightTrendIsOnlyDrawnOnLongRanges() {
        let points = (0..<20).map { BodyTrendPoint(date: daysAgo(29 - $0), value: 80) }
        let month = ProgressDateRange(start: daysAgo(29), end: daysAgo(0))
        XCTAssertTrue(ProgressViewModel.weightTrend(points, over: month).isEmpty)
    }

    /// Day-to-day swings average out, and because the window is centred the
    /// trend has no lag: a steady series comes back unchanged at both ends.
    func testWeightTrendSmoothsNoiseWithoutLag() {
        let quarter = ProgressDateRange(start: daysAgo(89), end: daysAgo(0))
        let noisy = (0..<90).map { BodyTrendPoint(date: daysAgo(89 - $0), value: $0.isMultiple(of: 2) ? 80 : 81) }
        let trend = ProgressViewModel.weightTrend(noisy, over: quarter)

        XCTAssertEqual(trend.count, noisy.count)
        XCTAssertEqual(trend.map(\.date), noisy.map(\.date), "one trend point per reading")
        let middle = trend[45].value
        XCTAssertEqual(middle, 80.5, accuracy: 0.1, "the swing averages out")

        let steady = (0..<90).map { BodyTrendPoint(date: daysAgo(89 - $0), value: 78.4) }
        let flat = ProgressViewModel.weightTrend(steady, over: quarter)
        XCTAssertEqual(flat.first!.value, 78.4, accuracy: 0.0001)
        XCTAssertEqual(flat.last!.value, 78.4, accuracy: 0.0001)
    }

    // MARK: - Empty ranges

    /// The empty state offers the shortest range that reaches the last entry
    /// — one tap to something, not a chain of empty ranges.
    func testShortestPresetReachingADate() {
        let model = viewModel()
        model.preset = .week
        XCTAssertEqual(model.shortestPreset(reaching: daysAgo(12)), .month)
        XCTAssertEqual(model.shortestPreset(reaching: daysAgo(100)), .sixMonths)
        XCTAssertEqual(model.shortestPreset(reaching: daysAgo(300)), .year)
        XCTAssertNil(model.shortestPreset(reaching: daysAgo(500)))
    }

    /// A break is told apart from a blank slate by looking back before the
    /// empty range.
    func testEmptyRangeFindsTheLastEntryBeforeIt() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: daysAgo(12), values: [.weight: 72.4]))
        let model = viewModel(client: local)
        model.preset = .week
        await model.load()
        try await waitForEarlierHistory(model)

        XCTAssertFalse(model.hasAnyData)
        XCTAssertEqual(model.earlierHistory, .lastLogged(daysAgo(12)))
    }

    func testAnAccountWithNothingLoggedHasNoEarlierHistory() async throws {
        let model = viewModel()
        await model.load()
        try await waitForEarlierHistory(model)

        XCTAssertFalse(model.hasAnyData)
        XCTAssertEqual(model.earlierHistory, .none)
        XCTAssertFalse(model.didFailToLoad, "empty is not a failure")
    }

    /// A range with data never pays for the look-back.
    func testARangeWithDataSkipsTheLookBack() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: daysAgo(1), values: [.weight: 72.4]))
        let model = viewModel(client: local)
        await model.load()

        XCTAssertTrue(model.hasAnyData)
        XCTAssertEqual(model.earlierHistory, .unknown)
    }

    // MARK: - Loaded window

    /// The charts draw against the window their data describes, which
    /// trails a new selection until its load lands — otherwise the axis
    /// jumps to the new range while the old range's bars are still drawn.
    func testLoadedRangeTrailsTheSelectionUntilTheLoadLands() async {
        let model = viewModel()
        await model.load()
        let week = model.loadedRange

        model.preset = .month
        XCTAssertEqual(model.loadedRange, week, "still the week's data")
        XCTAssertNotEqual(model.range, week)

        await model.load()
        XCTAssertEqual(model.loadedRange, model.range)
        XCTAssertEqual(model.loadedRange.dayCount, 30)
    }

    /// Derived series are built when a load lands, not per render: the
    /// cached weight points match the rows, sorted.
    func testDerivedSeriesAreBuiltFromTheLoad() async throws {
        let local = LocalAPIClient(store: LocalStore(inMemory: true))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: daysAgo(1), values: [.weight: 79, .waist: 86]))
        _ = try await local.upsertBodyMeasurements(BodyMeasurementsInput(date: daysAgo(5), values: [.weight: 80]))
        let model = viewModel(client: local)
        await model.load()

        XCTAssertEqual(model.weightPoints.map(\.value), [80, 79])
        XCTAssertEqual(model.populatedBodyFields, [.waist])
        XCTAssertEqual(model.selectedBodyField, .waist, "lands on a field that has data")
        XCTAssertEqual(model.todaysMeasurements.weight, nil, "nothing logged today")
        XCTAssertEqual(model.change(for: .weight)!, -1, accuracy: 0.0001)
    }
}
