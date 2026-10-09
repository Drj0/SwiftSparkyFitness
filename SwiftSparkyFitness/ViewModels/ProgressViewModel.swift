//
//  ProgressViewModel.swift
//  SwiftSparkyFitness
//
//  Module 6. Everything the Progress tab charts, for one selected range.
//
//  The four reads are independent, so they run concurrently and each one is
//  allowed to fail on its own: a check-in endpoint that 500s should cost the
//  weight card, not the whole screen. `errorMessage` therefore reports what
//  is missing rather than replacing the tab with an error state, except when
//  nothing at all loaded.
//
//  DERIVED SERIES ARE BUILT ONCE PER LOAD
//  --------------------------------------
//  Every card observes this whole object, so any published change — picking
//  a macro, a measurement, a range — re-renders all four. The series those
//  cards draw used to be computed properties: each weight point re-parsed
//  its row's date string, the measurements picker did that for all ten body
//  fields, and the goal line ran a DateFormatter per day, several times per
//  render. They are now built once, when a load lands (`rebuildDerived`),
//  and a render only reads them.
//

import Foundation
import Combine
import SwiftUI
import UIKit

@MainActor
final class ProgressViewModel: ObservableObject {
    // MARK: - Selection

    @Published var preset: ProgressRangePreset = .week {
        didSet { guard preset != oldValue else { return }; reloadForRangeChange() }
    }

    /// Only meaningful while `preset == .custom`. They seed from the current
    /// resolved range so switching to Custom doesn't start on an empty or
    /// nonsensical span.
    @Published var customStart: Date {
        didSet { guard customStart != oldValue, preset == .custom else { return }; reloadForRangeChange() }
    }
    @Published var customEnd: Date {
        didSet { guard customEnd != oldValue, preset == .custom else { return }; reloadForRangeChange() }
    }

    /// Which body field the measurements card is charting. Weight has its own
    /// card, so this offers the rest.
    @Published var selectedBodyField: BodyField = .waist

    /// Which nutrition series the calories/macros card is charting.
    @Published var selectedSeries: MacroSeries = .calories

    // MARK: - Loaded data

    @Published private(set) var nutrition: [DailyNutrition] = []
    @Published private(set) var goalsByDay: [String: NutritionGoals] = [:]
    @Published private(set) var bodyRows: [DatedBodyMeasurements] = []
    @Published private(set) var exercise: [DailyExercise] = []
    @Published private(set) var exerciseTotals: ExerciseRangeSummary.Totals?
    @Published private(set) var preferences: UserPreferences = .serverDefaults

    /// The window the data on screen describes. It trails `range` while a
    /// new selection loads, so the charts keep their axes matched to the
    /// numbers they're drawing instead of jumping ahead of them.
    @Published private(set) var loadedRange: ProgressDateRange

    @Published private(set) var isLoading = false
    /// The newest visible load; only it may clear the dimming. Tapping
    /// through ranges overlaps loads. A count of them kept fresh charts
    /// dimmed and untappable until a superseded one finished too, and
    /// before that the first to land cleared the dimming early.
    private var visibleLoad = 0
    @Published private(set) var hasLoadedOnce = false
    /// Every read that feeds a chart failed, so an empty screen means "we
    /// couldn't ask", not "nothing was logged" — the two need different
    /// screens.
    @Published private(set) var didFailToLoad = false
    @Published var errorMessage: String?

    /// What came before an empty range, so its empty state can tell a
    /// break from a blank slate. Only ever looked up when the range is
    /// empty.
    enum EarlierHistory: Equatable {
        /// Not looked yet, or the look failed.
        case unknown
        /// Nothing logged in the past year.
        case none
        /// The newest day with anything logged in the past year — before
        /// the range, or after it when the range is in the past.
        case lastLogged(Date)
    }
    @Published private(set) var earlierHistory: EarlierHistory = .unknown

    // MARK: - Derived (see the header note)

    /// Bars for the nutrition chart: logged days, or weekly means on the
    /// long ranges (`TrendGranularity`).
    private(set) var nutritionBars: [DailyNutrition] = []
    /// Bars for the exercise chart: every day, or weekly totals.
    private(set) var exerciseBars: [DailyExercise] = []
    /// Weight over the range. One point per day at most, by schema.
    private(set) var weightPoints: [BodyTrendPoint] = []
    /// A smoothed line through `weightPoints` for the long ranges, empty
    /// otherwise (`weightTrend(_:over:)`).
    private(set) var weightTrend: [BodyTrendPoint] = []
    /// Body fields other than weight that actually carry data in this range,
    /// so the measurements card offers only what there is something to draw
    /// for rather than ten mostly-empty charts.
    private(set) var populatedBodyFields: [BodyField] = []
    /// Days in the range with at least one workout.
    private(set) var activeExerciseDays = 0
    private var bodySeries: [BodyField: [BodyTrendPoint]] = [:]
    private var goalsByDate: [Date: NutritionGoals] = [:]
    private var goalLines: [MacroSeries: [(date: Date, value: Double)]] = [:]
    private var averages: [MacroSeries: Double] = [:]

    /// Diary's floor, for the same reason: there is nothing to chart before
    /// the account existed, and nothing logged after today.
    private(set) var minDate: Date
    /// Today. Rolls forward on the next load if the app stays alive past
    /// midnight — the tab lives for the whole session behind the tab bar.
    private(set) var maxDate: Date

    private let apiClient: APIClientProtocol
    private var cancellables = Set<AnyCancellable>()

    /// Set only by the preview factory. Without it the view's `.task` fires a
    /// real load over the seeded data, and the snapshot catches the screen
    /// mid-reload — dimmed by the stale-data opacity — which makes a preview
    /// useless for judging how the finished screen looks.
    private var isPreviewSeeded = false

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)
        return formatter
    }()

    /// See `DiaryViewModel.historyStarts`. Only Custom is floored, and its
    /// pickers read this on their next render.
    func historyStarts(_ createdAt: Date?) {
        let start = min(Calendar.current.startOfDay(for: createdAt ?? Date()), maxDate)
        if start < minDate { minDate = start; objectWillChange.send() }
    }

    init(user: SessionUser, apiClient: APIClientProtocol = AppServices.client) {
        self.apiClient = apiClient
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        maxDate = today
        minDate = min(calendar.startOfDay(for: user.createdAt ?? today), today)
        customEnd = today
        // Floored to the account's start: a seed before it sits outside the
        // pickers' allowed range and reads as a clamp that never happened.
        customStart = max(calendar.date(byAdding: .day, value: -29, to: today) ?? today, minDate)
        loadedRange = ProgressDateRange(start: today, end: today)
        loadedRange = range

        // Settings can change the units every number here is labelled with,
        // and a sync can land new entries, while this screen stays alive
        // behind the tab bar. Quietly: a sync finishing while someone reads
        // the charts shouldn't dim them.
        NotificationCenter.default.publisher(for: .referenceDataChanged)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
            .store(in: &cancellables)

        // Midnight while open, or waking on a later day: today, the preset
        // ranges ending on it, and the day the log sheets open on all move
        // with the clock — not on whichever load happens next.
        NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)
            .merge(with: NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification))
            .sink { [weak self] _ in
                Task { @MainActor in await self?.rollOverToToday() }
            }
            .store(in: &cancellables)
    }

    /// A reload moves `maxDate` first thing, so a new day is one refresh.
    func rollOverToToday() async {
        guard Calendar.current.startOfDay(for: Date()) > maxDate else { return }
        await refresh()
    }

    // MARK: - Range

    /// The selected span, clamped to the account's lifetime and to the
    /// 366-day ceiling the server's own range endpoints enforce.
    ///
    /// The endpoints this screen calls are the *unbounded* ones — they loop
    /// day by day rather than rejecting an absurd span — so this clamp is the
    /// only thing standing between a custom range and a request that never
    /// returns.
    var range: ProgressDateRange {
        let calendar = Calendar.current
        var start: Date
        var end = maxDate

        if let days = preset.days {
            // The whole window, not floored at `minDate`. Floored, a new
            // account saw 1W through 1Y all as the same two days, so the
            // range buttons looked dead; and in on-device mode `minDate` is
            // this install's first launch, which hid history restored from
            // iCloud. Days before any entry just chart as empty.
            start = calendar.date(byAdding: .day, value: -(days - 1), to: maxDate) ?? maxDate
        } else {
            start = calendar.startOfDay(for: customStart)
            end = calendar.startOfDay(for: customEnd)
            if start > end { swap(&start, &end) }
            start = max(start, minDate)
            end = min(max(end, minDate), maxDate)
        }

        let span = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
        if span > ProgressDateRange.maximumDays {
            start = calendar.date(
                byAdding: .day, value: -(ProgressDateRange.maximumDays - 1), to: end
            ) ?? start
        }
        return ProgressDateRange(start: start, end: end)
    }

    /// True when the picked custom span was wider than the cap and got cut
    /// back, so the screen can say so rather than silently showing less than
    /// was asked for.
    var didClampCustomRange: Bool {
        guard preset == .custom else { return false }
        let calendar = Calendar.current
        // The account-lifetime floor isn't the cap this message is about.
        let asked = max(calendar.startOfDay(for: min(customStart, customEnd)), minDate)
        return asked < range.start
    }

    /// The shortest preset that reaches back to `date` — what an empty
    /// range's "show me" button offers, so one tap lands on something
    /// instead of stepping through a chain of empty ranges.
    func shortestPreset(reaching date: Date) -> ProgressRangePreset? {
        let calendar = Calendar.current
        return ProgressRangePreset.allCases.first { option in
            guard let days = option.days, option != preset else { return false }
            let start = calendar.date(byAdding: .day, value: -(days - 1), to: maxDate) ?? maxDate
            return date >= start
        }
    }

    private func reloadForRangeChange() {
        Task { await load() }
    }

    // MARK: - Loading

    /// Loads the currently selected range, dimming what's on screen until it
    /// lands.
    ///
    /// Deliberately does NOT cancel an in-flight load. An earlier version did,
    /// and it lost data: changing the range schedules a load of its own, so a
    /// `.task`/`.refreshable` running at the same moment cancelled it, and the
    /// cancelled run returned without assigning while its caller had already
    /// been told the load was done. Instead every run completes and stamps
    /// its own window; a response for a window the user has since moved off
    /// is discarded on arrival. The newest selection always wins, and no
    /// caller is told a load finished when nothing was written.
    func load() async {
        if isPreviewSeeded { return }
        await performLoad(showsProgress: true)
    }

    /// Re-reads the range without dimming anything — for coming back to the
    /// tab after logging elsewhere, where the numbers usually haven't moved
    /// and a dim-and-restore flash would read as the screen resetting.
    /// Measured: every return to the tab used to run a full dimmed load.
    func refresh() async {
        if isPreviewSeeded { return }
        guard hasLoadedOnce else { return await load() }
        await performLoad(showsProgress: false)
    }

    private func performLoad(showsProgress: Bool) async {
        let today = Calendar.current.startOfDay(for: Date())
        if today > maxDate { maxDate = today }

        let window = range
        if showsProgress {
            visibleLoad += 1
            isLoading = true
        }
        let load = visibleLoad
        defer { if showsProgress, load == visibleLoad { isLoading = false } }

        // Independent reads, run together. `async let` rather than a task
        // group because each result has a different type and each is allowed
        // to fail separately.
        async let entries = result { try await self.apiClient.foodEntries(from: window.start, to: window.end) }
        async let goals = result { try await self.apiClient.goals(from: window.start, to: window.end) }
        async let body = result { try await self.apiClient.bodyMeasurements(from: window.start, to: window.end) }
        async let workouts = result { try await self.apiClient.exerciseSummary(from: window.start, to: window.end) }
        async let prefs = result { try await self.apiClient.userPreferences() }

        let (entriesResult, goalsResult, bodyResult, workoutsResult, prefsResult) =
            await (entries, goals, body, workouts, prefs)

        // Leaving the tab cancels the first load's `.task`. A cancelled run
        // writes nothing: its reads failed *because* it was cancelled, and
        // reporting that as "couldn't load" would be a false alarm.
        guard !Task.isCancelled else { return }

        // The selection moved while this was in flight, so these numbers
        // describe a range nobody is looking at any more.
        guard window == range else { return }

        // A failed read keeps the previous numbers only when they describe
        // this same window (a refresh). After a range change they'd be the
        // old range's data drawn against the new range's axis.
        let isNewWindow = window != loadedRange
        var failures: [String] = []

        switch entriesResult {
        case .success(let rows): nutrition = Self.daily(from: rows, formatter: dayFormatter)
        case .failure:
            failures.append("food")
            if isNewWindow { nutrition = [] }
        }
        switch goalsResult {
        case .success(let value): goalsByDay = value
        case .failure:
            failures.append("goals")
            if isNewWindow { goalsByDay = [:] }
        }
        switch bodyResult {
        case .success(let rows): bodyRows = rows
        case .failure:
            failures.append("weight")
            if isNewWindow { bodyRows = [] }
        }
        switch workoutsResult {
        case .success(let summary):
            exerciseTotals = summary.totals
            exercise = Self.daily(from: summary, over: window, formatter: dayFormatter)
        case .failure:
            failures.append("exercise")
            if isNewWindow { exerciseTotals = nil; exercise = [] }
        }
        if case .success(let value) = prefsResult { preferences = value }

        loadedRange = window
        rebuildDerived()
        didFailToLoad = Set(failures).isSuperset(of: ["food", "weight", "exercise"]) && !hasAnyData
        errorMessage = Self.message(for: failures)
        hasLoadedOnce = true

        if hasAnyData || didFailToLoad {
            earlierHistory = .unknown
        } else if earlierHistory == .unknown || isNewWindow {
            earlierHistory = .unknown
            // Its own task, so the empty state isn't held dimmed behind it.
            Task { await findLastEntry(outside: window) }
        }
    }

    /// Looks through the past year for the newest day with anything logged,
    /// for an empty range's message. The whole year up to today, not only
    /// before the range: an empty custom range in March can sit before
    /// yesterday's entries, and searching behind it told someone with
    /// history that their trends start here. The range itself is empty, so
    /// including it costs nothing. Three reads, only ever for an empty
    /// range.
    private func findLastEntry(outside window: ProgressDateRange) async {
        let calendar = Calendar.current
        let end = maxDate
        let start = calendar.date(byAdding: .day, value: -365, to: end) ?? end

        async let food = try? apiClient.foodEntries(from: start, to: end)
        async let body = try? apiClient.bodyMeasurements(from: start, to: end)
        async let workouts = try? apiClient.exerciseSummary(from: start, to: end)
        let (foodRows, bodyRows, summary) = await (food, body, workouts)

        guard !Task.isCancelled, window == loadedRange, !hasAnyData else { return }
        // Every read failed: that's "couldn't ask", not "nothing logged".
        guard foodRows != nil || bodyRows != nil || summary != nil else {
            earlierHistory = .unknown
            return
        }
        // Day keys compare correctly as strings, so no date parsing until
        // the one winner.
        let keys = (foodRows?.map(\.entryDate) ?? [])
            + (bodyRows?.map(\.entryDate) ?? [])
            + (summary?.intervalsBreakdown.filter { $0.workoutCount > 0 }.map(\.startDate) ?? [])
        if let newest = keys.max(), let date = dayFormatter.date(from: newest) {
            earlierHistory = .lastLogged(Calendar.current.startOfDay(for: date))
        } else {
            earlierHistory = .none
        }
    }

    /// Wraps a throwing call so one failing read can't cancel its siblings.
    private func result<T>(_ work: @escaping () async throws -> T) async -> Result<T, Error> {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private static func message(for failures: [String]) -> String? {
        switch failures.count {
        case 0: return nil
        case 5, 4: return "Couldn't load your progress. Pull to refresh to try again."
        default:
            let list = ListFormatter.localizedString(byJoining: failures)
            return "Couldn't load \(list) for this range."
        }
    }

    // MARK: - Shaping

    /// Sums the raw entries per day — the same arithmetic Today and Diary
    /// apply to the same rows, so the three screens report the same totals.
    ///
    /// A day with no entries produces no point at all. Emitting a zero would
    /// assert the user ate nothing that day and would pull every average
    /// down with it; a gap says "not recorded", which is what it is.
    nonisolated static func daily(from rows: [FoodEntryRangeRow], formatter: DateFormatter) -> [DailyNutrition] {
        var byDay: [Date: (Double, Double, Double, Double)] = [:]
        for row in rows {
            guard let date = formatter.date(from: row.entryDate) else { continue }
            var totals = byDay[date] ?? (0, 0, 0, 0)
            totals.0 += row.calories ?? 0
            totals.1 += row.protein ?? 0
            totals.2 += row.carbs ?? 0
            totals.3 += row.fat ?? 0
            byDay[date] = totals
        }
        return byDay
            .map { DailyNutrition(date: $0.key, calories: $0.value.0, protein: $0.value.1, carbs: $0.value.2, fat: $0.value.3) }
            .sorted { $0.date < $1.date }
    }

    /// Pads the server's sparse day buckets out to every day in the range.
    /// Unlike nutrition, a missing exercise day really is a zero.
    nonisolated static func daily(
        from summary: ExerciseRangeSummary,
        over window: ProgressDateRange,
        formatter: DateFormatter
    ) -> [DailyExercise] {
        var byDay: [Date: ExerciseRangeSummary.Bucket] = [:]
        for bucket in summary.intervalsBreakdown {
            guard let date = formatter.date(from: bucket.startDate) else { continue }
            byDay[Calendar.current.startOfDay(for: date)] = bucket
        }
        return window.allDays.map { day in
            let bucket = byDay[day]
            return DailyExercise(
                date: day,
                caloriesBurned: bucket?.caloriesBurned ?? 0,
                durationMinutes: bucket?.durationMinutes ?? 0,
                workoutCount: bucket?.workoutCount ?? 0
            )
        }
    }

    /// Weekly means over the days that were logged — the same rule as the
    /// range average, so a week with two logged days isn't reported as a
    /// week of fasting.
    nonisolated static func weekly(_ days: [DailyNutrition], calendar: Calendar = .current) -> [DailyNutrition] {
        var buckets: [Date: (calories: Double, protein: Double, carbs: Double, fat: Double, days: Int)] = [:]
        for day in days {
            let week = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
            var bucket = buckets[week] ?? (0, 0, 0, 0, 0)
            bucket.calories += day.calories
            bucket.protein += day.protein
            bucket.carbs += day.carbs
            bucket.fat += day.fat
            bucket.days += 1
            buckets[week] = bucket
        }
        return buckets
            .map { week, bucket in
                let count = Double(bucket.days)
                return DailyNutrition(
                    date: week,
                    calories: bucket.calories / count,
                    protein: bucket.protein / count,
                    carbs: bucket.carbs / count,
                    fat: bucket.fat / count,
                    loggedDays: bucket.days
                )
            }
            .sorted { $0.date < $1.date }
    }

    /// Weekly totals — exercise days are zero-filled, so a sum is the honest
    /// weekly figure.
    nonisolated static func weekly(_ days: [DailyExercise], calendar: Calendar = .current) -> [DailyExercise] {
        var buckets: [Date: (burned: Double, minutes: Double, workouts: Int)] = [:]
        for day in days {
            let week = calendar.dateInterval(of: .weekOfYear, for: day.date)?.start ?? day.date
            var bucket = buckets[week] ?? (0, 0, 0)
            bucket.burned += day.caloriesBurned
            bucket.minutes += day.durationMinutes
            bucket.workouts += day.workoutCount
            buckets[week] = bucket
        }
        return buckets
            .map { DailyExercise(date: $0.key, caloriesBurned: $0.value.burned, durationMinutes: $0.value.minutes, workoutCount: $0.value.workouts) }
            .sorted { $0.date < $1.date }
    }

    /// A centred moving average of the weigh-ins, for ranges long enough
    /// that day-to-day water weight hides the direction.
    ///
    /// Over three months and up, a day's weight swings by more than the
    /// month's real change, and the raw line reads as noise. Each point here
    /// is the mean of the readings within a few days either side — centred,
    /// so the line doesn't lag behind the data the way a running average
    /// does, and time-based, so sparse weigh-ins aren't averaged across
    /// weeks. The window widens with the range, since a year can afford
    /// more smoothing than a quarter. Empty when there's too little to
    /// smooth, and the chart then draws the readings alone.
    nonisolated static func weightTrend(_ points: [BodyTrendPoint], over window: ProgressDateRange) -> [BodyTrendPoint] {
        guard window.dayCount > 45, points.count >= 10 else { return [] }
        let halfWidth = Double(max(3, window.dayCount / 40)) * 86_400
        var lower = 0
        var upper = 0
        var sum = 0.0
        return points.map { point in
            // Two pointers over the sorted readings: O(n), not O(n²).
            while upper < points.count, points[upper].date.timeIntervalSince(point.date) <= halfWidth {
                sum += points[upper].value
                upper += 1
            }
            while point.date.timeIntervalSince(points[lower].date) > halfWidth {
                sum -= points[lower].value
                lower += 1
            }
            return BodyTrendPoint(date: point.date, value: sum / Double(upper - lower))
        }
    }

    /// Rebuilds every derived series from the loaded rows. Called once per
    /// load, never from a render.
    private func rebuildDerived() {
        let window = loadedRange
        let weekly = window.granularity == .week

        nutritionBars = weekly ? Self.weekly(nutrition) : nutrition
        exerciseBars = weekly ? Self.weekly(exercise) : exercise
        activeExerciseDays = exercise.reduce(0) { $0 + ($1.workoutCount > 0 ? 1 : 0) }

        // Body: one date parse per row, then every field it carries.
        var series: [BodyField: [BodyTrendPoint]] = [:]
        for row in bodyRows {
            guard let date = dayFormatter.date(from: row.entryDate) else { continue }
            for field in BodyField.allCases {
                if let value = row.measurements.value(for: field) {
                    series[field, default: []].append(BodyTrendPoint(date: date, value: value))
                }
            }
        }
        for field in series.keys { series[field]?.sort { $0.date < $1.date } }
        bodySeries = series
        weightPoints = series[.weight] ?? []
        weightTrend = Self.weightTrend(weightPoints, over: window)
        populatedBodyFields = BodyField.allCases.filter { $0 != .weight && !(series[$0]?.isEmpty ?? true) }
        // The default selection is a field this account may never have
        // logged, and a new range can take the selected field's data away.
        // Either way, land on something there is a chart for.
        if let first = populatedBodyFields.first, !populatedBodyFields.contains(selectedBodyField) {
            selectedBodyField = first
        }

        // Goals: one date parse per key, then one lookup per day per series.
        var byDate: [Date: NutritionGoals] = [:]
        for (key, goals) in goalsByDay {
            guard let date = dayFormatter.date(from: key) else { continue }
            byDate[Calendar.current.startOfDay(for: date)] = goals
        }
        goalsByDate = byDate
        let days = window.allDays
        var lines: [MacroSeries: [(date: Date, value: Double)]] = [:]
        var means: [MacroSeries: Double] = [:]
        for series in MacroSeries.allCases {
            lines[series] = days.compactMap { day in goal(on: day, for: series).map { (day, $0) } }
            if !nutrition.isEmpty {
                means[series] = nutrition.reduce(0) { $0 + $1.value(for: series) } / Double(nutrition.count)
            }
        }
        goalLines = lines
        averages = means
    }

    // MARK: - Derived series

    /// The goal for one day, or nil when none is usefully set.
    ///
    /// `isSet` is the same rule Today uses to decide whether to show its
    /// goal-not-set card: the server returns a populated default row rather
    /// than 404 for an account that never set a goal, so "has a goal" means
    /// "calories > 0", not "a row came back".
    func goal(on day: Date, for series: MacroSeries) -> Double? {
        guard let goals = goalsByDate[Calendar.current.startOfDay(for: day)], goals.isSet else { return nil }
        return series.goal(from: goals).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The goal series across the range, as chart points. Stepped, because
    /// goals are date-versioned and the server carries each one forward
    /// until a later row supersedes it.
    var goalLine: [(date: Date, value: Double)] {
        goalLines[selectedSeries] ?? []
    }

    var hasGoalLine: Bool { !goalLine.isEmpty }

    /// The single goal value when it never changes across the range — which
    /// is the ordinary case, and also the only case a one-day range can
    /// produce.
    ///
    /// This exists because a `LineMark` needs two points to draw anything: a
    /// range holding one day rendered an invisible goal while the legend
    /// still promised one and the y-axis still stretched to fit it. Found in
    /// the simulator, not by reading the code. A constant goal is drawn as a
    /// rule instead, which is both visible at any width and a truer picture
    /// of "this target applied throughout".
    var constantGoal: Double? {
        let values = goalLine.map(\.value)
        guard let first = values.first else { return nil }
        return values.allSatisfy { $0 == first } ? first : nil
    }

    func points(for field: BodyField) -> [BodyTrendPoint] {
        bodySeries[field] ?? []
    }

    /// Net change across the range — last minus first — for a body field.
    /// Nil when there are fewer than two readings, because one weigh-in is
    /// not a trend and reporting "0.0 kg" for it would imply it was.
    func change(for field: BodyField) -> Double? {
        let series = points(for: field)
        guard let first = series.first, let last = series.last, series.count > 1 else { return nil }
        return last.value - first.value
    }

    /// Mean over the days that have entries, not over the range: averaging in
    /// unlogged days would report a deficit nobody ate.
    func average(for series: MacroSeries) -> Double? {
        averages[series]
    }

    var loggedDayCount: Int { nutrition.count }

    var hasAnyData: Bool {
        !nutrition.isEmpty || !bodyRows.isEmpty || (exerciseTotals?.workoutCount ?? 0) > 0
    }

    /// Today's check-in row, if one is in range — what the log sheets open
    /// on, so saving a weight can't blank this morning's waist.
    var todaysMeasurements: BodyMeasurements {
        let key = dayFormatter.string(from: maxDate)
        return bodyRows.first { $0.entryDate == key }?.measurements ?? .none
    }

    /// "24 Sep", or "2 Oct 2025" outside the current year — on a year's
    /// range, "down 4.5 kg since 2 Oct" read on 1 Oct sounds like tomorrow.
    func formattedDay(_ date: Date) -> String {
        isThisYear(date)
            ? date.formatted(.dateTime.day().month(.abbreviated))
            : date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    /// A chart bucket's name: the day with its weekday ("Tue 24 Sep"), or on
    /// the weekly ranges the week it starts ("Week of 2 Jun"). The first
    /// week can begin before the range does; it is named by the days it
    /// holds ("2 Oct – 3 Oct"), since "Week of 28 Sep" claimed days it
    /// doesn't sum.
    func formattedBucket(_ date: Date) -> String {
        if loadedRange.granularity == .week {
            if date < loadedRange.start, let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: date) {
                return "\(formattedDay(loadedRange.start)) – \(formattedDay(min(weekEnd, loadedRange.end)))"
            }
            return "Week of \(formattedDay(date))"
        }
        return formattedReading(date)
    }

    /// One day's reading ("Tue 24 Sep") at any range. The weight and
    /// measurement charts plot every weigh-in even on the weekly ranges,
    /// where "Week of 12 Mar" implied a weekly figure that wasn't there.
    func formattedReading(_ date: Date) -> String {
        isThisYear(date)
            ? date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
            : date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    private func isThisYear(_ date: Date) -> Bool {
        Calendar.current.isDate(date, equalTo: maxDate, toGranularity: .year)
    }

    #if DEBUG
    /// Seeds a view model with fixed data for SwiftUI previews.
    ///
    /// The published properties are `private(set)`, so a preview can't fill
    /// them from outside; this factory exists so the charts can be rendered
    /// and inspected without a server or a signed-in account. DEBUG-only —
    /// it is not compiled into a release build.
    static func preview(
        nutrition: [DailyNutrition] = [],
        goals: [String: NutritionGoals] = [:],
        body: [DatedBodyMeasurements] = [],
        exercise: ExerciseRangeSummary? = nil,
        preset: ProgressRangePreset = .month
    ) -> ProgressViewModel {
        let user = SessionUser(
            email: "preview@example.com",
            name: "Preview",
            createdAt: Calendar.current.date(byAdding: .day, value: -400, to: Date())
        )
        let model = ProgressViewModel(user: user, apiClient: APIClient.shared)
        model.isPreviewSeeded = true
        model.preset = preset
        model.nutrition = nutrition
        model.goalsByDay = goals
        model.bodyRows = body
        if let exercise {
            model.exerciseTotals = exercise.totals
            model.exercise = Self.daily(from: exercise, over: model.range, formatter: model.dayFormatter)
        }
        model.loadedRange = model.range
        model.rebuildDerived()
        model.hasLoadedOnce = true
        return model
    }

    /// Builds a plausible month of data, so a preview exercises the same
    /// shapes the real screen sees: gaps in the food log, a goal that steps
    /// part-way through, weigh-ins every few days, rest days.
    static func previewSample() -> ProgressViewModel {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.calendar = Calendar(identifier: .gregorian)

        var nutrition: [DailyNutrition] = []
        var goals: [String: NutritionGoals] = [:]
        var body: [DatedBodyMeasurements] = []
        var buckets: [ExerciseRangeSummary.Bucket] = []

        for offset in stride(from: 29, through: 0, by: -1) {
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = formatter.string(from: date)

            // The goal steps ten days in, which is the case a flat rule would
            // misreport.
            goals[key] = NutritionGoals(raw: [
                "calories": .number(offset > 10 ? 2000 : 2400),
                "protein": .number(offset > 10 ? 150 : 180),
                "carbs": .number(offset > 10 ? 250 : 260),
                "fat": .number(offset > 10 ? 67 : 70),
            ])

            // Two unlogged days, to show as gaps rather than zeroes.
            if offset != 7 && offset != 18 {
                let wobble = Double((offset * 37) % 500)
                nutrition.append(DailyNutrition(
                    date: date,
                    calories: 1600 + wobble,
                    protein: 95 + wobble / 20,
                    carbs: 150 + wobble / 8,
                    fat: 55 + wobble / 40
                ))
            }

            if offset % 3 == 0 {
                body.append(DatedBodyMeasurements(
                    entryDate: key,
                    measurements: BodyMeasurements(
                        id: key,
                        weight: 82.0 - Double(29 - offset) * 0.09 + Double((offset * 7) % 5) * 0.2,
                        neck: nil,
                        waist: 88.0 - Double(29 - offset) * 0.05,
                        hips: nil,
                        height: nil,
                        bodyFatPercentage: 21.5 - Double(29 - offset) * 0.03
                    )
                ))
            }

            if offset % 4 == 1 {
                buckets.append(.init(
                    startDate: key,
                    durationMinutes: Double(30 + (offset % 3) * 15),
                    caloriesBurned: Double(260 + (offset % 4) * 70),
                    workoutCount: 1
                ))
            }
        }

        let summary = ExerciseRangeSummary(
            totals: .init(
                totalDurationMinutes: buckets.reduce(0) { $0 + $1.durationMinutes },
                totalCaloriesBurned: buckets.reduce(0) { $0 + $1.caloriesBurned },
                workoutCount: buckets.count
            ),
            intervalsBreakdown: buckets
        )
        return preview(nutrition: nutrition, goals: goals, body: body, exercise: summary)
    }
    #endif

    /// "25 Sep – 1 Oct 2026", with the start's year too when the range
    /// crosses one: a year's range read "2 Oct – 1 Oct 2026", backwards.
    var rangeDescription: String {
        let window = range
        let crossesYear = !Calendar.current.isDate(window.start, equalTo: window.end, toGranularity: .year)
        let start = crossesYear
            ? window.start.formatted(.dateTime.day().month(.abbreviated).year())
            : window.start.formatted(.dateTime.day().month(.abbreviated))
        let end = window.end.formatted(.dateTime.day().month(.abbreviated).year())
        return window.dayCount == 1 ? end : "\(start) – \(end)"
    }
}
