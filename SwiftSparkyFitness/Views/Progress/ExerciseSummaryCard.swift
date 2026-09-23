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

    private var days: [DailyExercise] { viewModel.exercise }
    private var totals: ExerciseRangeSummary.Totals? { viewModel.exerciseTotals }

    var body: some View {
        TrendCard(
            title: "Exercise",
            subtitle: subtitle,
            accessory: burnedStat
        ) {
            if let totals, totals.workoutCount > 0 {
                summaryRow(totals)
                chart
            } else {
                TrendEmptyState(message: "No exercise logged in this range.")
            }
        }
    }

    private var subtitle: String? {
        guard let totals, totals.workoutCount > 0 else { return nil }
        return "\(totals.workoutCount) session\(totals.workoutCount == 1 ? "" : "s")"
    }

    private var burnedStat: AnyView? {
        guard let totals, totals.workoutCount > 0 else { return nil }
        return AnyView(
            TrendStat(value: "\(Int(totals.totalCaloriesBurned.rounded())) kcal", label: "burned")
        )
    }

    private func summaryRow(_ totals: ExerciseRangeSummary.Totals) -> some View {
        // ViewThatFits so the row collapses to a column at large text sizes
        // rather than truncating — the same fallback the macro row and ring
        // legend use.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                stat(Self.duration(totals.totalDurationMinutes), "Time")
                rule
                stat("\(totals.workoutCount)", "Sessions")
                rule
                stat(Self.perSession(totals), "Avg / session")
            }
            VStack(alignment: .leading, spacing: 8) {
                stat(Self.duration(totals.totalDurationMinutes), "Time")
                stat("\(totals.workoutCount)", "Sessions")
                stat(Self.perSession(totals), "Avg / session")
            }
        }
    }

    private var rule: some View {
        Rectangle()
            .fill(AppColor.hairline)
            .frame(width: 1)
            .padding(.vertical, 4)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.ink)
            Text(label)
                .appBody(11)
                .foregroundStyle(AppColor.secondaryText)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    private static func duration(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        guard total >= 60 else { return "\(total)m" }
        let hours = total / 60
        let remainder = total % 60
        return remainder == 0 ? "\(hours)h" : "\(hours)h \(remainder)m"
    }

    private static func perSession(_ totals: ExerciseRangeSummary.Totals) -> String {
        guard totals.workoutCount > 0 else { return "—" }
        let average = totals.totalCaloriesBurned / Double(totals.workoutCount)
        return "\(Int(average.rounded())) kcal"
    }

    private var chart: some View {
        Chart(days) { day in
            BarMark(
                x: .value("Day", day.date, unit: .day),
                y: .value("Burned", day.caloriesBurned)
            )
            .foregroundStyle(AppColor.energyGraphic.opacity(0.85))
            .cornerRadius(3)
            .accessibilityLabel(viewModel.formattedDay(day.date))
            .accessibilityValue(
                day.workoutCount == 0
                    ? "No exercise"
                    : "\(Int(day.caloriesBurned.rounded())) kilocalories, \(Self.duration(day.durationMinutes))"
            )
        }
        .progressChartAxes(range: viewModel.range)
        .frame(height: 150)
        .accessibilityLabel("Calories burned per day")
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
