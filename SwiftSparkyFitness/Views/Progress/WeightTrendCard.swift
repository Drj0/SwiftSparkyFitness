//
//  WeightTrendCard.swift
//  SwiftSparkyFitness
//
//  Weight over the selected range, from the check-in rows Module 4 writes.
//
//  One point per day, with no deduplication and no latest-vs-average rule:
//  `check_in_measurements` is UNIQUE (user_id, entry_date) and the write is
//  an upsert, so a day cannot hold two weights. Re-weighing overwrites.
//
//  WHY SWIFT CHARTS AND NOT A HAND-DRAWN PATH
//  ------------------------------------------
//  `RingChart` is hand-drawn, but the reason was specific: `ProgressView`
//  ignored `.tint` and its `scaleEffect` thickening left an artifact. That
//  was a system *control* refusing to be styled, not a rule against
//  frameworks. Swift Charts styles fully through the app's own tokens, and
//  it brings the one thing a hand-rolled `Path` would have to reinvent
//  badly: every mark is a real accessibility element, so VoiceOver can read
//  a series point by point and the audio graph works. The app's own history
//  here is the argument — the hero ring and macro tiles shipped invisible to
//  VoiceOver because they were bespoke graphics, and that had to be fixed
//  afterwards.
//

import SwiftUI
import Charts

struct WeightTrendCard: View {
    @ObservedObject var viewModel: ProgressViewModel
    /// Opens the weight sheet. Every tracker worth the name lets you add a
    /// weigh-in from the chart of them, not only from the day screen.
    var onLog: (() -> Void)?

    /// The weigh-in being inspected — already snapped by `chartScrubbing`,
    /// so it names a real reading. Card-local, so scrubbing re-renders this
    /// card only.
    @State private var rawSelection: Date?

    private var points: [BodyTrendPoint] { viewModel.weightPoints }
    private var unit: String { viewModel.preferences.weightUnitLabel }
    private var selected: BodyTrendPoint? { rawSelection.flatMap { date in points.first { $0.date == date } } }
    private var logAction: TrendCardAction? { onLog.map { TrendCardAction(label: "Log weight", perform: $0) } }

    var body: some View {
        TrendCard(kind: .weight, action: points.isEmpty ? nil : logAction) {
            if points.isEmpty {
                TrendEmptyState(message: "No weigh-ins in this range.", action: logAction)
            } else {
                headline
                if points.count > 1 { chart }
            }
        }
        .onChange(of: viewModel.loadedRange) { _, _ in rawSelection = nil }
    }

    private func formatted(_ value: Double) -> String {
        viewModel.preferences.formatted(value)
    }

    @ViewBuilder
    private var headline: some View {
        if let first = points.first, let last = points.last {
            if let selected {
                TrendHeadline(
                    eyebrow: viewModel.formattedReading(selected.date),
                    value: formatted(selected.value),
                    unit: unit,
                    detail: selected.date == first.date
                        ? Text("First weigh-in in this range")
                        : changeDetail(selected.value - first.value, unit: unit, since: viewModel.formattedDay(first.date), format: formatted)
                )
            } else {
                TrendHeadline(
                    eyebrow: Calendar.current.isDateInToday(last.date) ? "Today" : "Latest · \(viewModel.formattedDay(last.date))",
                    value: formatted(last.value),
                    unit: unit,
                    // A single reading can't be a trend line, so it is
                    // reported as a value, not drawn as a one-point chart —
                    // which renders as an empty plot and reads as a bug.
                    detail: points.count == 1
                        ? Text("One weigh-in so far. Log another to see your trend.")
                        : changeDetail(last.value - first.value, unit: unit, since: viewModel.formattedDay(first.date), format: formatted)
                )
            }
        }
    }

    private var chart: some View {
        // A weight series spans a few kilos inside a two-digit number, so a
        // zero-based axis would flatten every real movement into one line at
        // the top of the plot. The domain hugs the data with a small margin.
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)
        let floor = low - pad
        // Only mark the actual weigh-ins when there are few enough for the
        // dots to mean something; past that they turn the line into a
        // dotted mess.
        let showsPoints = points.count <= 31
        let trend = viewModel.weightTrend
        let hasTrend = !trend.isEmpty
        let selected = selected

        return VStack(alignment: .leading, spacing: 8) {
            Chart {
                // The fill sits under the trend when there is one, so the
                // shape the eye reads is the direction, not the noise.
                ForEach(hasTrend ? trend : points) { point in
                    AreaMark(
                        x: .value("Day", point.date, unit: .day),
                        yStart: .value("Floor", floor),
                        yEnd: .value("Weight", point.value)
                    )
                    .foregroundStyle(
                        .linearGradient(
                            colors: [AppColor.accent.opacity(0.22), AppColor.accent.opacity(0.01)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                }

                ForEach(points) { point in
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Weight", point.value),
                        series: .value("Series", "Weigh-ins")
                    )
                    .foregroundStyle(hasTrend ? AppColor.accent.opacity(0.35) : AppColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: hasTrend ? 1.25 : 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityLabel(viewModel.formattedDay(point.date))
                    .accessibilityValue("\(formatted(point.value)) \(unit)")

                    if showsPoints {
                        PointMark(
                            x: .value("Day", point.date, unit: .day),
                            y: .value("Weight", point.value)
                        )
                        .foregroundStyle(AppColor.accent)
                        .symbolSize(24)
                        .accessibilityHidden(true)
                    }
                }

                ForEach(trend) { point in
                    LineMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value("Weight", point.value),
                        series: .value("Series", "Trend")
                    )
                    .foregroundStyle(AppColor.accent)
                    .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
                    .accessibilityHidden(true)
                }

                if let selected {
                    RuleMark(x: .value("Selected", selected.date, unit: .day))
                        .foregroundStyle(AppColor.ink.opacity(0.25))
                        .lineStyle(StrokeStyle(lineWidth: 1))
                        .accessibilityHidden(true)
                    PointMark(
                        x: .value("Day", selected.date, unit: .day),
                        y: .value("Weight", selected.value)
                    )
                    .symbol {
                        Circle()
                            .fill(AppColor.accent)
                            .stroke(AppColor.surface, lineWidth: 2.5)
                            .frame(width: 13, height: 13)
                    }
                    .accessibilityHidden(true)
                }
            }
            .chartYScale(domain: floor...(high + pad))
            .progressChartAxes(range: viewModel.loadedRange)
            .chartScrubbing($rawSelection) { nearestPoint(points, to: $0)?.date }
            .sensoryFeedback(.selection, trigger: selected?.date)
            .frame(height: 180)
            .accessibilityLabel(hasTrend ? "Weight, with a smoothed trend line" : "Weight trend")

            if hasTrend { legend }
        }
    }

    /// Only when the trend is drawn: two lines need telling apart.
    private var legend: some View {
        HStack(spacing: 14) {
            legendItem("Trend", lineWidth: 2.5, opacity: 1)
            legendItem("Weigh-ins", lineWidth: 1.25, opacity: 0.35)
            Spacer(minLength: 0)
        }
        // A key to the chart, so it stops growing where the chart's own
        // axis labels do — past that it outgrew the lines it labels.
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .accessibilityHidden(true)
    }

    private func legendItem(_ label: String, lineWidth: CGFloat, opacity: Double) -> some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(AppColor.accent.opacity(opacity))
                .frame(width: 16, height: lineWidth)
            Text(label)
                .appBody(11)
                .foregroundStyle(AppColor.secondaryText)
                .fixedSize()
        }
    }
}
