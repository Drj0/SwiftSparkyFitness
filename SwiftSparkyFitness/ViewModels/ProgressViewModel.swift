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

import Foundation
import Combine
import SwiftUI

@MainActor
final class ProgressViewModel: ObservableObject {
    // MARK: - Selection

    @Published var preset: ProgressRangePreset = .month {
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

    @Published private(set) var isLoading = false
    @Published private(set) var hasLoadedOnce = false
    @Published var errorMessage: String?

    /// Diary's floor, for the same reason: there is nothing to chart before
    /// the account existed, and nothing logged after today.
    let minDate: Date
    let maxDate: Date

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

    init(user: SessionUser, apiClient: APIClientProtocol = APIClient.shared) {
        self.apiClient = apiClient
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        maxDate = today
        minDate = min(calendar.startOfDay(for: user.createdAt ?? today), today)
        customEnd = today
        customStart = calendar.date(byAdding: .day, value: -29, to: today) ?? today

        // Settings can change the units every number here is labelled with,
        // and a live TabView keeps this screen alive across tab switches, so
        // nothing re-runs `.task` when the user comes back — the same gap
        // that silently broke every Settings edit after the Module 5 TabView
        // migration.
        NotificationCenter.default.publisher(for: .referenceDataChanged)
            .sink { [weak self] _ in
                Task { @MainActor in await self?.load() }
            }
            .store(in: &cancellables)
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
            start = calendar.date(byAdding: .day, value: -(days - 1), to: maxDate) ?? maxDate
        } else {
            start = calendar.startOfDay(for: customStart)
            end = calendar.startOfDay(for: customEnd)
            if start > end { swap(&start, &end) }
        }

        start = max(start, minDate)
        end = min(max(end, minDate), maxDate)

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
        let asked = calendar.startOfDay(for: min(customStart, customEnd))
        return asked < range.start
    }

    private func reloadForRangeChange() {
        Task { await load() }
    }

    // MARK: - Loading

    /// Loads the currently selected range.
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
        await performLoad()
    }

    private func performLoad() async {
        let window = range
        isLoading = true
        defer { isLoading = false; hasLoadedOnce = true }

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

        // The selection moved while this was in flight, so these numbers
        // describe a range nobody is looking at any more.
        guard window == range else { return }

        var failures: [String] = []

        switch entriesResult {
        case .success(let rows): nutrition = Self.daily(from: rows, formatter: dayFormatter)
        case .failure: failures.append("food")
        }
        switch goalsResult {
        case .success(let value): goalsByDay = value
        case .failure: failures.append("goals")
        }
        switch bodyResult {
        case .success(let rows): bodyRows = rows
        case .failure: failures.append("weight")
        }
        switch workoutsResult {
        case .success(let summary):
            exerciseTotals = summary.totals
            exercise = Self.daily(from: summary, over: window, formatter: dayFormatter)
        case .failure: failures.append("exercise")
        }
        if case .success(let value) = prefsResult { preferences = value }

        errorMessage = Self.message(for: failures)
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

    // MARK: - Derived series

    /// The goal for one day, or nil when none is usefully set.
    ///
    /// `isSet` is the same rule Today uses to decide whether to show its
    /// goal-not-set card: the server returns a populated default row rather
    /// than 404 for an account that never set a goal, so "has a goal" means
    /// "calories > 0", not "a row came back".
    func goal(on day: Date, for series: MacroSeries) -> Double? {
        guard let goals = goalsByDay[dayFormatter.string(from: day)], goals.isSet else { return nil }
        return series.goal(from: goals).flatMap { $0 > 0 ? $0 : nil }
    }

    /// The goal series across the range, as chart points. Stepped, because
    /// goals are date-versioned and the server carries each one forward
    /// until a later row supersedes it.
    var goalLine: [(date: Date, value: Double)] {
        range.allDays.compactMap { day in
            goal(on: day, for: selectedSeries).map { (day, $0) }
        }
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

    /// Weight over the range. One point per day at most, by schema.
    var weightPoints: [BodyTrendPoint] {
        points(for: .weight)
    }

    func points(for field: BodyField) -> [BodyTrendPoint] {
        bodyRows.compactMap { row in
            guard
                let date = dayFormatter.date(from: row.entryDate),
                let value = row.measurements.value(for: field)
            else { return nil }
            return BodyTrendPoint(date: date, value: value)
        }
        .sorted { $0.date < $1.date }
    }

    /// Body fields other than weight that actually carry data in this range,
    /// so the measurements card offers only what there is something to draw
    /// for rather than ten mostly-empty charts.
    var populatedBodyFields: [BodyField] {
        BodyField.allCases.filter { $0 != .weight && !points(for: $0).isEmpty }
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
        guard !nutrition.isEmpty else { return nil }
        return nutrition.reduce(0) { $0 + $1.value(for: series) } / Double(nutrition.count)
    }

    var loggedDayCount: Int { nutrition.count }

    var hasAnyData: Bool {
        !nutrition.isEmpty || !bodyRows.isEmpty || (exerciseTotals?.workoutCount ?? 0) > 0
    }

    func formattedDay(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated))
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
        model.preset = preset
        model.nutrition = nutrition
        model.goalsByDay = goals
        model.bodyRows = body
        if let exercise {
            model.exerciseTotals = exercise.totals
            model.exercise = Self.daily(from: exercise, over: model.range, formatter: model.dayFormatter)
        }
        model.hasLoadedOnce = true
        model.isPreviewSeeded = true
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

    var rangeDescription: String {
        let window = range
        let start = window.start.formatted(.dateTime.day().month(.abbreviated))
        let end = window.end.formatted(.dateTime.day().month(.abbreviated).year())
        return "\(start) – \(end)"
    }
}
