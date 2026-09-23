//
//  ProgressTrends.swift
//  SwiftSparkyFitness
//
//  Module 6 (Progress). The range-scoped counterparts of the single-day
//  models Today and Diary use.
//
//  WHY THIS DOESN'T USE THE SERVER'S OWN TREND ENDPOINTS FOR NUTRITION
//  ------------------------------------------------------------------
//  The backend really does ship pre-computed trend endpoints
//  (`/api/reports/nutrition-trends-with-goals`, `/api/reports`,
//  `/api/daily-summary/range`) and on the face of it they are exactly what
//  this screen wants: one call, zero-filled, goals joined per day. They are
//  not used for calories or macros, and the reason is the same server quirk
//  Module 5 already had to work around on Today's hero ring.
//
//  The app writes food-entry nutrition *already scaled* for the logged
//  quantity, and the server then re-applies `quantity / serving_size` when
//  it aggregates. The two only agree when the logged quantity happens to
//  equal one base serving. Verified live against the running server with a
//  250 g entry of a 100 g / 200 kcal food (the truth is 500 kcal):
//
//      GET /api/daily-summary          foodEntries[].calories    500  <- truth
//      GET /api/daily-summary/range    days[].eaten             1250
//      GET /api/reports                nutritionData[].calories 1250
//      GET /api/reports                tabularData[].calories   1250
//      GET /api/reports/nutrition-trends-with-goals  calories   1250
//
//  `DailySummaryCard` already sums the entries itself for precisely this
//  reason. If Progress charted the aggregates instead, a point reading
//  "1250 kcal" would open a Diary day reading "500 kcal" — the same
//  self-contradiction Module 5 removed, reintroduced one screen over.
//
//  So nutrition is summed here from the raw rows, which
//  `GET /api/food-entries/range/{start}/{end}` returns unscaled and
//  unaggregated (verified: a plain `SELECT ... FROM food_entries`, one row
//  per entry, no meal rollups, so there is nothing to double count). Those
//  are the same rows Today and Diary sum, so the three screens cannot
//  disagree.
//
//  Exercise and weight are NOT affected by any of this — neither is scaled —
//  so those do come from the server's own range endpoints.
//

import Foundation

// MARK: - The selected range

/// The time span the whole tab is scoped to.
///
/// The presets are day counts rather than calendar units on purpose: "last
/// 30 days" is a fixed window a chart can size its axis to, where "this
/// month" changes width as the month goes on.
enum ProgressRangePreset: String, CaseIterable, Identifiable, Hashable {
    case week
    case month
    case threeMonths
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .threeMonths: return "3 months"
        case .custom: return "Custom"
        }
    }

    /// How many days back from today the preset spans, inclusive of today.
    /// `nil` for `.custom`, whose bounds the user picks.
    var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .threeMonths: return 90
        case .custom: return nil
        }
    }
}

/// A resolved, clamped start/end pair.
struct ProgressDateRange: Equatable {
    let start: Date
    let end: Date

    /// The server puts no cap on `/api/goals/for-date` or the reports
    /// endpoints — a custom range of ten years makes it loop day by day
    /// rather than answering 400 — so the client is the only thing bounding
    /// this. 366 is the cap the server's own better-built range endpoints
    /// (`/api/daily-summary/range`, `/api/v2/reports/hydration-nutrition-range`)
    /// already enforce, so it is the number to match rather than invent.
    static let maximumDays = 366

    var dayCount: Int {
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return days + 1
    }

    /// Every calendar day in the range, ascending. Charts that must show a
    /// day with no data as a real zero (exercise) pad against this; charts
    /// where "no data" means "not weighed / not logged" leave a gap instead.
    var allDays: [Date] {
        let calendar = Calendar.current
        var days: [Date] = []
        var cursor = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        while cursor <= last {
            days.append(cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return days
    }
}

// MARK: - Nutrition

/// One logged day of nutrition, summed from that day's raw food entries.
///
/// Only days that actually have entries become points. A day with nothing
/// logged is absent rather than zero: drawing it as 0 kcal would claim the
/// user ate nothing, when the truth is that nothing was recorded — and it
/// would drag every average down with it.
struct DailyNutrition: Identifiable, Equatable {
    let date: Date
    let calories: Double
    let protein: Double
    let carbs: Double
    let fat: Double

    var id: Date { date }

    func value(for series: MacroSeries) -> Double {
        switch series {
        case .calories: return calories
        case .protein: return protein
        case .carbs: return carbs
        case .fat: return fat
        }
    }
}

/// Which series the nutrition chart is showing.
///
/// Colours match the ones Today's summary card already uses for the same
/// quantity, so a macro doesn't change identity between tabs
/// (`DailySummaryCard.macroColumn`: protein accent, carbs carbs, fat energy).
enum MacroSeries: String, CaseIterable, Identifiable, Hashable {
    case calories
    case protein
    case carbs
    case fat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .calories: return "Calories"
        case .protein: return "Protein"
        case .carbs: return "Carbs"
        case .fat: return "Fat"
        }
    }

    /// The unit a value of this series carries.
    var unit: String {
        self == .calories ? "kcal" : "g"
    }

    /// Goals are per-nutrient columns on the goal row.
    func goal(from goals: NutritionGoals) -> Double? {
        switch self {
        case .calories: return goals.calories
        case .protein: return goals.protein
        case .carbs: return goals.carbs
        case .fat: return goals.fat
        }
    }
}

/// A raw `food_entries` row as `GET /api/food-entries/range/{start}/{end}`
/// returns it — the same numbers the app wrote, before the server's
/// aggregation re-scales them.
///
/// Only the fields this screen sums are modelled; the row carries ~40 more
/// (every micronutrient, images, meal-plan ids) that no chart reads.
struct FoodEntryRangeRow: Decodable {
    let entryDate: String
    let calories: Double?
    let protein: Double?
    let carbs: Double?
    let fat: Double?
}

// MARK: - Body

/// One day's check-in row from
/// `GET /api/measurements/check-in-measurements-range/{start}/{end}`.
///
/// `check_in_measurements` is UNIQUE (user_id, entry_date) and the write is
/// an upsert, so this is at most one row per calendar day — there is no
/// latest-vs-average rule for Progress to pick and no deduplication to do.
/// (Module 4 settled this; the header of `BodyMeasurements` carries the
/// schema quote.)
struct DatedBodyMeasurements: Decodable, Identifiable {
    let entryDate: String
    let measurements: BodyMeasurements

    var id: String { entryDate }

    private enum CodingKeys: String, CodingKey {
        case entryDate
    }

    init(entryDate: String, measurements: BodyMeasurements) {
        self.entryDate = entryDate
        self.measurements = measurements
    }

    init(from decoder: Decoder) throws {
        entryDate = try decoder.container(keyedBy: CodingKeys.self)
            .decode(String.self, forKey: .entryDate)
        // The row carries the check-in columns inline alongside entry_date,
        // so the same payload decodes straight into the existing model
        // rather than duplicating ten optional Doubles here.
        measurements = try BodyMeasurements(from: decoder)
    }
}

/// A charted point for one body field.
struct BodyTrendPoint: Identifiable, Equatable {
    let date: Date
    let value: Double

    var id: Date { date }
}

// MARK: - Exercise

/// `GET /api/exercise-stats/summary?interval=day`.
///
/// This endpoint rather than `/api/exercise-stats/query` — which looks like
/// the more natural "list the workouts in this range" call and is a trap.
/// With neither a category nor a distance bound in the query it silently
/// adds a cardio-only predicate (`exerciseStatsService.ts`: distance > 0, or
/// a cardio category, or a name matching run|walk|cycle|swim|…), so a
/// strength entry just vanishes from a 200 response. Verified live: a day
/// holding "Probe Run" (210 kcal) and "Bench Press" (250 kcal) came back
/// from `/query` as one item, while `/summary` reported both — 460 kcal,
/// 70 minutes, 2 workouts.
///
/// `/summary` also excludes Apple Health's "Active Calories" sentinel in SQL
/// (`AND exercise_name != 'Active Calories'`), which matters because that row
/// is a real `exercise_entries` row with `duration_minutes: 0` that Today and
/// Diary already filter out by name. Summing `/api/reports`'s `exerciseEntries`
/// instead would have counted it as a workout.
struct ExerciseRangeSummary: Decodable {
    let totals: Totals
    let intervalsBreakdown: [Bucket]

    struct Totals: Decodable {
        let totalDurationMinutes: Double
        let totalCaloriesBurned: Double
        let workoutCount: Int
    }

    /// One bucket per interval — a day, for `interval=day`. Buckets with no
    /// exercise are absent rather than zero, so the view model pads them.
    struct Bucket: Decodable {
        let startDate: String
        let durationMinutes: Double
        let caloriesBurned: Double
        let workoutCount: Int
    }
}

/// A day of exercise, zero-filled across the range.
///
/// Zero-filling is right here and wrong for nutrition: a day with no logged
/// workout genuinely burned nothing through exercise, whereas a day with no
/// food entries means "not recorded", not "ate nothing".
struct DailyExercise: Identifiable, Equatable {
    let date: Date
    let caloriesBurned: Double
    let durationMinutes: Double
    let workoutCount: Int

    var id: Date { date }
}
