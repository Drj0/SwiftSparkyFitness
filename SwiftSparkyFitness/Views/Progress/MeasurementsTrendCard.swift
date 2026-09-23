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
//  would mean a picker mostly made of empty charts.
//

import SwiftUI
import Charts

struct MeasurementsTrendCard: View {
    @ObservedObject var viewModel: ProgressViewModel

    private var fields: [BodyField] { viewModel.populatedBodyFields }
    private var field: BodyField { viewModel.selectedBodyField }
    private var points: [BodyTrendPoint] { viewModel.points(for: field) }
    private var unit: String { field.unitLabel(viewModel.preferences) }

    var body: some View {
        TrendCard(
            title: "Measurements",
            subtitle: fields.isEmpty ? nil : field.label,
            accessory: changeStat
        ) {
            if fields.isEmpty {
                TrendEmptyState(
                    message: "No body measurements logged in this range. Add one from Today's Body card or Diary."
                )
            } else {
                fieldPicker
                if points.count == 1, let only = points.first {
                    TrendSinglePoint(
                        value: "\(viewModel.preferences.formatted(only.value)) \(unit)",
                        caption: "One reading on \(viewModel.formattedDay(only.date)) — log another to see a trend."
                    )
                } else if points.isEmpty {
                    TrendEmptyState(message: "Nothing logged for \(field.label) in this range.")
                } else {
                    chart
                }
            }
        }
        .onAppear(perform: selectAnAvailableField)
        .onChange(of: fields) { _, _ in selectAnAvailableField() }
    }

    /// The default selection is a field this account may never have logged,
    /// and changing the range can take the selected field's data away. Either
    /// way, land on something there is a chart for instead of showing an
    /// empty one.
    private func selectAnAvailableField() {
        guard !fields.isEmpty, !fields.contains(field) else { return }
        viewModel.selectedBodyField = fields[0]
    }

    private var changeStat: AnyView? {
        guard !fields.isEmpty, let change = viewModel.change(for: field) else { return nil }
        let sign = change > 0 ? "+" : (change < 0 ? "−" : "")
        return AnyView(
            TrendStat(
                value: "\(sign)\(viewModel.preferences.formatted(abs(change))) \(unit)",
                label: "over range"
            )
        )
    }

    private var fieldPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(fields) { option in
                    let isSelected = option == field
                    Button {
                        if viewModel.selectedBodyField != option {
                            Haptics.selection()
                            viewModel.selectedBodyField = option
                        }
                    } label: {
                        Text(option.label)
                            .appBody(12, weight: .semibold)
                            .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                            .padding(.horizontal, 12)
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
        // The chips are a horizontal scroller inside a vertical one; without
        // this the card's own padding gets clipped away at the edges.
        .padding(.horizontal, -2)
    }

    private var chart: some View {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.15, 0.5)

        return Chart(points) { point in
            LineMark(
                x: .value("Day", point.date, unit: .day),
                y: .value(field.label, point.value)
            )
            .foregroundStyle(AppColor.water)
            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            .interpolationMethod(.monotone)
            .accessibilityLabel(viewModel.formattedDay(point.date))
            .accessibilityValue("\(viewModel.preferences.formatted(point.value)) \(unit)")

            if points.count <= 31 {
                PointMark(
                    x: .value("Day", point.date, unit: .day),
                    y: .value(field.label, point.value)
                )
                .foregroundStyle(AppColor.water)
                .symbolSize(28)
                .accessibilityHidden(true)
            }
        }
        .chartYScale(domain: (low - pad)...(high + pad))
        .progressChartAxes(range: viewModel.range)
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
