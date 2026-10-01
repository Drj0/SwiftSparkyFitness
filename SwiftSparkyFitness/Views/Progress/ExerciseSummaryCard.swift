//
//  ExerciseSummaryCard.swift
//  SwiftSparkyFitness
//
//  Logged exercise over the selected range: range totals plus a per-day bar.
//
//  The numbers come from `/api/exercise-stats/summary?interval=day`, which
//  matters for two reasons that are easy to get wrong:
//
//  * It excludes Apple Health's "Active Calories" sentinel in SQL. That row
//    is a real `exercise_entries` row with `duration_minutes: 0` which Today
//    and Diary already hide by name; `/api/reports`'s `exerciseEntries` does
//    NOT filter it, so summing that instead counts a phantom workout and
//    inflates the burn (measured: 1088 against a true 1023 on one day).
//  * It does not apply the cardio-only predicate that
//    `/api/exercise-stats/query` silently adds when no category or distance
//    filter is supplied — which drops strength entries from a 200 response.
//
//  Days with no workout are zero, not absent: unlike food, "nothing logged"
//  and "burned nothing through exercise" are the same statement.
//

import SwiftUI
import Charts

struct ExerciseSummaryCard: View {
    @ObservedObject var viewModel: ProgressViewModel

    @State private var rawSelection: Date?

    private var bars: [DailyExercise] { viewModel.exerciseBars }
    private var totals: ExerciseRangeSummary.Totals? { viewModel.exerciseTotals }
    private var granularity: TrendGranularity { viewModel.loadedRange.granularity }

    private var selected: DailyExercise? {
        guard let rawSelection else { return nil }
        let bucket = bucketStart(of: rawSelection, granularity)
        return bars.first { $0.date == bucket }
    }

    var body: some View {
        TrendCard(kind: .exercise) {
            if let totals, totals.workoutCount > 0 {
                headline(totals)
                chart
                TrendStatRow(items: statItems(totals))
            } else {
                TrendEmptyState(message: "No workouts in this range. Workouts you log on Today or in the Exercise tab add up here.")
            }
        }
        .onChange(of: viewModel.loadedRange) { _, _ in rawSelection = nil }
    }

    @ViewBuilder
    private func headline(_ totals: ExerciseRangeSummary.Totals) -> some View {
        if let selected {
            TrendHeadline(
                eyebrow: viewModel.formattedBucket(selected.date),
                value: Self.number(selected.caloriesBurned),
                unit: "kcal",
                detail: Text(
                    selected.workoutCount == 0
                        ? (granularity == .week ? "No workouts that week" : "Rest day")
                        : "\(selected.workoutCount) session\(selected.workoutCount == 1 ? "" : "s") · \(Self.duration(selected.durationMinutes))"
                )
            )
        } else {
            let days = viewModel.loadedRange.dayCount
            TrendHeadline(
                eyebrow: "Burned in workouts",
                value: Self.number(totals.totalCaloriesBurned),
                unit: "kcal",
                detail: Text("Active on \(viewModel.activeExerciseDays) of \(days) day\(days == 1 ? "" : "s")")
            )
        }
    }

    /// Time, sessions and the per-session average, plus distance or lifted
    /// volume when the range has any.
    ///
    /// Module 12: distance/volume are a fourth stat, not always shown — a
    /// range with only strength work has no distance, and one with only
    /// cardio has no lifted volume. Both follow the app's "label from the
    /// preference, never convert" rule. Distance takes priority when both
    /// are present — cardio distance is the more familiar number.
    private func statItems(_ totals: ExerciseRangeSummary.Totals) -> [TrendStatRow.Item] {
        var items: [TrendStatRow.Item] = [
            .init(value: Self.duration(totals.totalDurationMinutes), label: "Time"),
            .init(value: "\(totals.workoutCount)", label: "Sessions"),
            .init(value: Self.perSession(totals), label: "Avg / session"),
        ]
        // Despite the field's name this is NOT meters in the running app:
        // both modes read the on-device summary (`LocalAPIClient`), which
        // sums distance in the unit it was logged in — the user's distance
        // preference, the same one the exercise editor labels its field
        // with. Dividing by 1000 showed a 21.9 km week as "0.0 km".
        if let distance = totals.totalDistanceMeters, distance > 0 {
            let value = distance.formatted(.number.precision(.fractionLength(0...1)))
            items.append(.init(value: "\(value) \(viewModel.preferences.distanceUnitLabel)", label: "Distance"))
        } else if let volume = totals.totalLiftedVolumeKg, volume > 0 {
            items.append(.init(value: "\(Self.number(volume)) kg", label: "Volume"))
        }
        return items
    }

    static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total)m" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static func perSession(_ totals: ExerciseRangeSummary.Totals) -> String {
        guard totals.workoutCount > 0 else { return "—" }
        let average = totals.totalCaloriesBurned / Double(totals.workoutCount)
        return "\(number(average)) kcal"
    }

    private static func number(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }

    private var chart: some View {
        let selectedDate = selected?.date
        let radius: CGFloat = bars.count > 45 ? 1.5 : 4

        return Chart(bars) { day in
            BarMark(
                x: .value("Day", day.date, unit: granularity.component),
                y: .value("Burned", day.caloriesBurned)
            )
            .foregroundStyle(AppColor.energyGraphic.opacity(selectedDate == nil || selectedDate == day.date ? 0.9 : 0.3))
            .cornerRadius(radius)
            .accessibilityLabel(viewModel.formattedBucket(day.date))
            .accessibilityValue(
                day.workoutCount == 0
                    ? "No exercise"
                    : "\(Self.number(day.caloriesBurned)) kilocalories, \(Self.duration(day.durationMinutes))"
            )
        }
        .progressChartAxes(range: viewModel.loadedRange, granularity: granularity)
        .chartScrubbing($rawSelection, granularity: granularity)
        .sensoryFeedback(.selection, trigger: selectedDate)
        .frame(height: 150)
        .accessibilityLabel("Calories burned per \(granularity == .week ? "week" : "day")")
    }
}

#if DEBUG
#Preview("Exercise — a month") {
    ScrollView {
        ExerciseSummaryCard(viewModel: .previewSample())
            .padding(AppSpacing.screenPad)
    }
    .background(AppColor.background)
}
#endif
