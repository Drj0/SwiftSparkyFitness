//
//  MeasurementsTrendCard.swift
//  SwiftSparkyFitness
//
//  Body measurements over the range, one field at a time.
//
//  Measurements are not tracked separately from weight — they are columns on
//  the same `check_in_measurements` row, written by the same upsert, so this
//  card reads the rows the weight card already loaded rather than making a
//  second call. Weight has its own card, so this one offers the rest.
//
//  Only fields with something logged in the range are offered. The row has
//  ten columns and most accounts fill two or three; listing all of them
//  would mean a picker mostly made of empty charts. Keeping the selection on
//  a field that has data is the view model's job (`rebuildDerived`), so a
//  range change can't leave this card showing an empty chart.
//

import SwiftUI
import Charts

struct MeasurementsTrendCard: View {
    @ObservedObject var viewModel: ProgressViewModel
    var onLog: (() -> Void)?

    @State private var rawSelection: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fields: [BodyField] { viewModel.populatedBodyFields }
    private var field: BodyField { viewModel.selectedBodyField }
    private var points: [BodyTrendPoint] { viewModel.points(for: field) }
    private var unit: String { field.unitLabel(viewModel.preferences) }
    private var selected: BodyTrendPoint? { rawSelection.flatMap { nearestPoint(points, to: $0) } }
    private var logAction: TrendCardAction? { onLog.map { TrendCardAction(label: "Log measurements", perform: $0) } }

    var body: some View {
        TrendCard(kind: .measurements, action: fields.isEmpty ? nil : logAction) {
            if fields.isEmpty {
                TrendEmptyState(message: "No body measurements in this range.", action: logAction)
            } else {
                if fields.count > 1 { fieldPicker }
                headline
                if points.count > 1 { chart }
            }
        }
        .onChange(of: viewModel.loadedRange) { _, _ in rawSelection = nil }
        .onChange(of: field) { _, _ in rawSelection = nil }
    }

    private func formatted(_ value: Double) -> String {
        viewModel.preferences.formatted(value)
    }

    @ViewBuilder
    private var headline: some View {
        if let first = points.first, let last = points.last {
            if let selected {
                TrendHeadline(
                    eyebrow: "\(field.label) · \(viewModel.formattedBucket(selected.date))",
                    value: formatted(selected.value),
                    unit: unit,
                    detail: selected.date == first.date
                        ? Text("First reading in this range")
                        : changeDetail(selected.value - first.value, unit: unit, since: viewModel.formattedDay(first.date), format: formatted)
                )
            } else {
                TrendHeadline(
                    eyebrow: "\(field.label) · \(Calendar.current.isDateInToday(last.date) ? "today" : viewModel.formattedDay(last.date))",
                    value: formatted(last.value),
                    unit: unit,
                    detail: points.count == 1
                        ? Text("One reading so far. Log another to see a trend.")
                        : changeDetail(last.value - first.value, unit: unit, since: viewModel.formattedDay(first.date), format: formatted)
                )
            }
        }
    }

    private var fieldPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(fields) { option in
                    TrendChip(title: option.label, isSelected: option == field) {
                        guard viewModel.selectedBodyField != option else { return }
                        Haptics.selection()
                        withAnimation(reduceMotion ? nil : .snappy(duration: 0.22)) {
                            viewModel.selectedBodyField = option
                        }
                    }
                }
            }
        }
        // A horizontal scroller inside the card: let the chips run to the
        // card's edges rather than clipping at its padding.
        .contentMargins(.horizontal, AppSpacing.cardPad, for: .scrollContent)
        .padding(.horizontal, -AppSpacing.cardPad)
    }

    private var chart: some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)
        let showsPoints = points.count <= 31
        let selected = selected

        return Chart {
            ForEach(points) { point in
                LineMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value(field.label, point.value)
                )
                .foregroundStyle(AppColor.water)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                .interpolationMethod(.monotone)
                .accessibilityLabel(viewModel.formattedDay(point.date))
                .accessibilityValue("\(formatted(point.value)) \(unit)")

                if showsPoints {
                    PointMark(
                        x: .value("Day", point.date, unit: .day),
                        y: .value(field.label, point.value)
                    )
                    .foregroundStyle(AppColor.water)
                    .symbolSize(24)
                    .accessibilityHidden(true)
                }
            }

            if let selected {
                RuleMark(x: .value("Selected", selected.date, unit: .day))
                    .foregroundStyle(AppColor.ink.opacity(0.25))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                    .accessibilityHidden(true)
                PointMark(
                    x: .value("Day", selected.date, unit: .day),
                    y: .value(field.label, selected.value)
                )
                .symbol {
                    Circle()
                        .fill(AppColor.water)
                        .stroke(AppColor.surface, lineWidth: 2.5)
                        .frame(width: 13, height: 13)
                }
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .progressChartAxes(range: viewModel.loadedRange)
        .chartScrubbing($rawSelection)
        .sensoryFeedback(.selection, trigger: selected?.date)
        .frame(height: 170)
        .accessibilityLabel("\(field.label) trend")
    }
}

#if DEBUG
#Preview("Measurements — a month") {
    ScrollView {
        MeasurementsTrendCard(viewModel: .previewSample())
            .padding(AppSpacing.screenPad)
    }
    .background(AppColor.background)
}
#endif
