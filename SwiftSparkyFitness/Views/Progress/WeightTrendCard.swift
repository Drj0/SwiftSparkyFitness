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

    private var points: [BodyTrendPoint] { viewModel.weightPoints }
    private var unit: String { viewModel.preferences.weightUnitLabel }

    var body: some View {
        TrendCard(
            title: "Weight",
            subtitle: subtitle,
            accessory: changeStat
        ) {
            if points.isEmpty {
                TrendEmptyState(message: "No weight logged in this range. Log one from Today or Diary and it'll chart here.")
            } else if points.count == 1, let only = points.first {
                TrendSinglePoint(
                    value: "\(viewModel.preferences.formatted(only.value)) \(unit)",
                    caption: "One weigh-in on \(viewModel.formattedDay(only.date)) — log another to see a trend."
                )
            } else {
                chart
            }
        }
    }

    private var subtitle: String? {
        points.isEmpty ? nil : "\(points.count) weigh-\(points.count == 1 ? "in" : "ins")"
    }

    private var changeStat: AnyView? {
        guard let change = viewModel.change(for: .weight) else { return nil }
        // Down is not universally "good" — someone can be gaining on
        // purpose — so the tint marks direction, not approval: the app's
        // ink for a loss, and the same neutral ink for a gain. Only the
        // arrow carries the direction.
        let sign = change > 0 ? "+" : (change < 0 ? "−" : "")
        let magnitude = viewModel.preferences.formatted(abs(change))
        return AnyView(
            TrendStat(value: "\(sign)\(magnitude) \(unit)", label: "over range")
        )
    }

    private var chart: some View {
        // A weight series spans a few kilos inside a two-digit number, so a
        // zero-based axis would flatten every real movement into one line at
        // the top of the plot. The domain hugs the data with a small margin.
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)

        return Chart(points) { point in
            AreaMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Weight", point.value)
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

            LineMark(
                x: .value("Day", point.date, unit: .day),
                y: .value("Weight", point.value)
            )
            .foregroundStyle(AppColor.accent)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            .accessibilityLabel(viewModel.formattedDay(point.date))
            .accessibilityValue("\(viewModel.preferences.formatted(point.value)) \(unit)")

            // Only mark the actual weigh-ins when there are few enough for
            // the dots to mean something; past that they turn the line into
            // a dotted mess.
            if points.count <= 31 {
                PointMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value("Weight", point.value)
                )
                .foregroundStyle(AppColor.accent)
                .symbolSize(28)
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .progressChartAxes(range: viewModel.range)
        .frame(height: 180)
        .accessibilityLabel("Weight trend")
    }
}
