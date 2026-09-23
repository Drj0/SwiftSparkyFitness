//
//  NutritionTrendCard.swift
//  SwiftSparkyFitness
//
//  Daily calories and macros against the goal, over the selected range.
//
//  THE GOAL LINE STEPS
//  -------------------
//  Goals are date-versioned. `user_goals` holds one row per effective date
//  and the server carries the most recent one forward until a later row
//  supersedes it, so "the goal" is a function of the day, not a constant.
//  Verified live: a goal written effective 2026-09-10 reads back as 2400 on
//  the 10th onward and 2000 before it, inside a single range response. A
//  chart that drew one horizontal rule would misreport every day before the
//  user last changed their target.
//
//  It is drawn with `.stepEnd` interpolation for the same reason: a goal
//  changed on the 10th applied in full on the 10th. Sloping between the old
//  and new values would imply a ramp that never happened.
//
//  The bars are summed from raw food entries rather than read from the
//  server's own nutrition trend endpoint — see `ProgressTrends.swift` for
//  the measurement showing why those aggregates disagree with Today and
//  Diary by the portion-scaling factor.
//

import SwiftUI
import Charts

struct NutritionTrendCard: View {
    @ObservedObject var viewModel: ProgressViewModel

    private var series: MacroSeries { viewModel.selectedSeries }
    private var points: [DailyNutrition] { viewModel.nutrition }

    var body: some View {
        TrendCard(
            title: "Calories & macros",
            subtitle: subtitle,
            accessory: averageStat
        ) {
            seriesPicker
            if points.isEmpty {
                TrendEmptyState(message: "Nothing logged in this range yet.")
            } else {
                chart
                legend
            }
        }
    }

    private var subtitle: String? {
        guard !points.isEmpty else { return nil }
        let days = viewModel.loggedDayCount
        return "\(days) logged day\(days == 1 ? "" : "s")"
    }

    private var averageStat: AnyView? {
        guard let average = viewModel.average(for: series) else { return nil }
        return AnyView(
            TrendStat(value: "\(Int(average.rounded())) \(series.unit)", label: "daily avg")
        )
    }

    private var seriesPicker: some View {
        HStack(spacing: 6) {
            ForEach(MacroSeries.allCases) { option in
                let isSelected = option == series
                Button {
                    if viewModel.selectedSeries != option {
                        Haptics.selection()
                        viewModel.selectedSeries = option
                    }
                } label: {
                    Text(option.label)
                        .appBody(12, weight: .semibold)
                        .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(isSelected ? AppColor.accent : AppColor.inputBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 9))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityAddTraits(isSelected ? [.isSelected] : [])
            }
        }
    }

    /// The colour a series carries, matching what Today's summary card
    /// already uses for the same quantity so a macro doesn't change identity
    /// between tabs. The `*Graphic` variants are the vibrant cuts intended
    /// for marks rather than text.
    private var seriesColor: Color {
        switch series {
        case .calories: return AppColor.accent
        case .protein: return AppColor.accent
        case .carbs: return AppColor.carbsGraphic
        case .fat: return AppColor.energyGraphic
        }
    }

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value(series.label, point.value(for: series))
                )
                .foregroundStyle(seriesColor.opacity(0.85))
                .cornerRadius(3)
                .accessibilityLabel(viewModel.formattedDay(point.date))
                .accessibilityValue(accessibilityValue(for: point))
            }

            if let constant = viewModel.constantGoal {
                // A goal that never moved, drawn as a rule. A LineMark needs
                // two points, so a one-day range drew nothing at all here
                // while the legend still claimed a goal — caught live.
                RuleMark(y: .value("Goal", constant))
                    .foregroundStyle(AppColor.ink.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .accessibilityHidden(true)
            } else {
                ForEach(viewModel.goalLine, id: \.date) { entry in
                    LineMark(
                        x: .value("Day", entry.date, unit: .day),
                        y: .value("Goal", entry.value),
                        series: .value("Series", "goal")
                    )
                    .foregroundStyle(AppColor.ink.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    // A goal change takes effect in full on its date; a
                    // sloped join would draw a ramp that never happened.
                    .interpolationMethod(.stepEnd)
                    .accessibilityHidden(true)
                }
            }
        }
        .progressChartAxes(range: viewModel.range)
        .frame(height: 180)
        .accessibilityLabel("\(series.label) per day\(viewModel.hasGoalLine ? ", with goal" : "")")
    }

    private func accessibilityValue(for point: DailyNutrition) -> String {
        let value = Int(point.value(for: series).rounded())
        guard let goal = viewModel.goal(on: point.date, for: series) else {
            return "\(value) \(series.unit)"
        }
        return "\(value) of \(Int(goal.rounded())) \(series.unit)"
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(series.label, seriesColor, dashed: false)
            if viewModel.hasGoalLine {
                legendItem("Goal", AppColor.ink.opacity(0.55), dashed: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, _ color: Color, dashed: Bool) -> some View {
        HStack(spacing: 5) {
            if dashed {
                Rectangle()
                    .fill(color)
                    .frame(width: 14, height: 2)
            } else {
                RoundedRectangle(cornerRadius: 2)
                    .fill(color)
                    .frame(width: 10, height: 10)
            }
            Text(label)
                .appBody(11)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize()
        }
    }
}
