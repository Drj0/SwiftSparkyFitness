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
//  THE METRIC TILES
//  ----------------
//  Four equal chips used to pick which series to chart, and showed nothing
//  until picked, so comparing protein with carbs meant tapping between them
//  and remembering. Each tile now carries its own daily average: the row is
//  a summary of all four at a glance, and tapping one charts it.
//

import SwiftUI
import Charts

struct NutritionTrendCard: View {
    @ObservedObject var viewModel: ProgressViewModel

    @State private var rawSelection: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var series: MacroSeries { viewModel.selectedSeries }
    private var bars: [DailyNutrition] { viewModel.nutritionBars }
    private var granularity: TrendGranularity { viewModel.loadedRange.granularity }

    private var selected: DailyNutrition? {
        guard let rawSelection else { return nil }
        let bucket = bucketStart(of: rawSelection, granularity)
        return bars.first { $0.date == bucket }
    }

    var body: some View {
        TrendCard(kind: .nutrition) {
            if viewModel.nutrition.isEmpty {
                TrendEmptyState(message: "No food logged in this range. Meals you log on Today add up here.")
            } else {
                headline
                chart
                tiles
            }
        }
        .onChange(of: viewModel.loadedRange) { _, _ in rawSelection = nil }
    }

    // MARK: - Headline

    @ViewBuilder
    private var headline: some View {
        if let selected {
            TrendHeadline(
                eyebrow: viewModel.formattedBucket(selected.date),
                value: Self.number(selected.value(for: series)),
                unit: series.unit,
                detail: Text(selectedDetail(selected))
            )
        } else {
            TrendHeadline(
                eyebrow: "Daily average",
                value: viewModel.average(for: series).map { Self.number($0) } ?? "—",
                unit: series.unit,
                detail: Text(rangeDetail)
            )
        }
    }

    /// "Goal 2,000 kcal · 6 of 7 days logged". The goal is named in words
    /// because it is the dashed line, and the chart has no legend row. A
    /// goal that changed mid-range reads "Goal 2,000 → 2,200 kcal": the step
    /// the dashed line draws, rather than an average nobody ever set.
    private var rangeDetail: String {
        var parts: [String] = []
        if let constant = viewModel.constantGoal {
            parts.append("Goal \(Self.number(constant)) \(series.unit)")
        } else if let first = viewModel.goalLine.first?.value, let last = viewModel.goalLine.last?.value {
            if first != last {
                parts.append("Goal \(Self.number(first)) → \(Self.number(last)) \(series.unit)")
            } else if let low = viewModel.goalLine.map(\.value).min(), let high = viewModel.goalLine.map(\.value).max() {
                // Changed and changed back: "2,000 → 2,000" said nothing.
                parts.append("Goal \(Self.number(low))–\(Self.number(high)) \(series.unit)")
            }
        }
        let days = viewModel.loadedRange.dayCount
        parts.append("\(viewModel.loggedDayCount) of \(days) day\(days == 1 ? "" : "s") logged")
        return parts.joined(separator: " · ")
    }

    /// Always one line, whatever the day — the headline must not change
    /// height under a moving finger, or the chart would jump with it.
    private func selectedDetail(_ bar: DailyNutrition) -> String {
        if granularity == .week {
            return "Daily average over \(bar.loggedDays) logged day\(bar.loggedDays == 1 ? "" : "s")"
        }
        if let goal = viewModel.goal(on: bar.date, for: series) {
            let difference = bar.value(for: series) - goal
            if abs(difference) < 0.5 { return "Right on the \(Self.number(goal)) \(series.unit) goal" }
            return "\(Self.number(abs(difference))) \(series.unit) \(difference > 0 ? "over" : "under") the \(Self.number(goal)) goal"
        }
        // No goal to compare with: say what the day was made of instead.
        switch series {
        case .calories:
            return "Protein \(Self.number(bar.protein))g · Carbs \(Self.number(bar.carbs))g · Fat \(Self.number(bar.fat))g"
        case .protein, .carbs, .fat:
            guard bar.calories > 0 else { return "No calories logged" }
            let perGram: Double = series == .fat ? 9 : 4
            let share = min(bar.value(for: series) * perGram / bar.calories, 1)
            return "\(share.formatted(.percent.precision(.fractionLength(0)))) of the day's calories"
        }
    }

    // MARK: - Chart

    /// The colour a series carries, matching what Today's summary card
    /// already uses for the same quantity so a macro doesn't change identity
    /// between tabs. The `*Graphic` variants are the vibrant cuts intended
    /// for marks rather than text.
    private static func color(_ series: MacroSeries) -> Color {
        switch series {
        case .calories: return AppColor.accent
        case .protein: return AppColor.accent
        case .carbs: return AppColor.carbsGraphic
        case .fat: return AppColor.energyGraphic
        }
    }

    private var chart: some View {
        let color = Self.color(series)
        let selectedDate = selected?.date
        // Narrow bars can't carry a full corner radius; past ~45 of them it
        // rounds a 3pt bar into a pill.
        let radius: CGFloat = bars.count > 45 ? 1.5 : 4
        let goalLine = viewModel.goalLine
        let constantGoal = viewModel.constantGoal

        return Chart {
            ForEach(bars) { bar in
                BarMark(
                    x: .value("Day", bar.date, unit: granularity.component),
                    y: .value(series.label, bar.value(for: series))
                )
                .foregroundStyle(color.opacity(selectedDate == nil || selectedDate == bar.date ? 0.9 : 0.3))
                .cornerRadius(radius)
                .accessibilityLabel(viewModel.formattedBucket(bar.date))
                .accessibilityValue(accessibilityValue(for: bar))
            }

            if let constantGoal {
                // A goal that never moved, drawn as a rule. A LineMark needs
                // two points, so a one-day range drew nothing at all here
                // while the legend still claimed a goal — caught live.
                RuleMark(y: .value("Goal", constantGoal))
                    .foregroundStyle(AppColor.ink.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .accessibilityHidden(true)
            } else {
                ForEach(goalLine, id: \.date) { entry in
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
        .progressChartAxes(range: viewModel.loadedRange, granularity: granularity)
        .chartScrubbing($rawSelection, granularity: granularity)
        .sensoryFeedback(.selection, trigger: selectedDate)
        .frame(height: 180)
        .accessibilityLabel("\(series.label) per \(granularity == .week ? "week" : "day")\(viewModel.hasGoalLine ? ", with goal" : "")")
    }

    private func accessibilityValue(for bar: DailyNutrition) -> String {
        let value = Self.number(bar.value(for: series))
        if granularity == .week {
            return "average \(value) \(series.unit) a day, \(bar.loggedDays) day\(bar.loggedDays == 1 ? "" : "s") logged"
        }
        guard let goal = viewModel.goal(on: bar.date, for: series) else {
            return "\(value) \(series.unit)"
        }
        return "\(value) of \(Self.number(goal)) \(series.unit)"
    }

    // MARK: - Tiles

    private var tiles: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                ForEach(MacroSeries.allCases) { tile($0) }
            }
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow { tile(.calories); tile(.protein) }
                GridRow { tile(.carbs); tile(.fat) }
            }
        }
    }

    private func tile(_ option: MacroSeries) -> some View {
        let isSelected = option == series
        let average = viewModel.average(for: option).map { Self.number($0) } ?? "—"
        let text = option == .calories ? average : "\(average)g"

        return Button {
            guard viewModel.selectedSeries != option else { return }
            Haptics.selection()
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                viewModel.selectedSeries = option
            }
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Self.color(option))
                        .frame(width: 7, height: 7)
                    Text(option.label)
                        .appBody(11, weight: .semibold)
                        .foregroundStyle(isSelected ? AppColor.ink : AppColor.secondaryText)
                }
                Text(text)
                    .appBody(15, weight: .semibold)
                    .foregroundStyle(AppColor.ink)
                    .monospacedDigit()
            }
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(
                isSelected ? AppColor.accentSoft : AppColor.inputBackground,
                in: RoundedRectangle(cornerRadius: AppRadius.sm)
            )
            .overlay(
                RoundedRectangle(cornerRadius: AppRadius.sm)
                    .stroke(isSelected ? AppColor.accent : .clear, lineWidth: 1.5)
            )
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(option.label)
        .accessibilityValue("\(text)\(option == .calories ? " calories" : "") a day on average")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityHint(isSelected ? "" : "Charts \(option.label.lowercased())")
    }

    /// "1,850" — grouped like every other calorie figure in the app.
    static func number(_ value: Double) -> String {
        Int(value.rounded()).formatted()
    }
}
