//
//  LogBodyView.swift
//  SwiftSparkyFitness
//
//  The weight sheet and the measurements sheet — same view, different field
//  list, because they're the same backend write (one check_in_measurements
//  row per day). Follows the exact shape Module 2's four logging sheets use:
//  Cancel/title/Save header, then a ScrollView (never a bare
//  `.frame(maxHeight: .infinity)` — see PROGRESS.md for the bug that cost).
//
//  There is no note field: `check_in_measurements` has no notes column
//  (only custom measurement categories do), and a field whose contents get
//  silently dropped on save is worse than no field.
//

import SwiftUI

struct LogBodyView: View {
    @StateObject private var viewModel: LogBodyViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSaved: () -> Void = {}

    /// The sheet exists to receive a number, so it opens with the keyboard
    /// already up on its first field. No return-key chaining between the
    /// rest: they're all decimal pads, which have no return key to chain.
    @FocusState private var focusedField: BodyField?

    init(
        kind: LogBodyViewModel.Kind,
        date: Date,
        existing: BodyMeasurements = .none,
        preferences: UserPreferences = .serverDefaults,
        minDate: Date,
        maxDate: Date,
        onSaved: @escaping () -> Void = {}
    ) {
        _viewModel = StateObject(wrappedValue: LogBodyViewModel(
            kind: kind, date: date, existing: existing,
            preferences: preferences, minDate: minDate, maxDate: maxDate
        ))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            // Cancel measured ~45 x 17pt and Save ~33 x 17pt. Both now carry
            // a 44pt target; the header's own vertical padding drops from 14
            // to 2 so the row keeps the height it had.
            SheetHeader(
                title: viewModel.kind.title,
                onCancel: { dismiss() },
                action: SheetAction("Save", isBusy: viewModel.isSaving) {
                    Task {
                        if await viewModel.save() {
                            onSaved()
                            dismiss()
                        }
                    }
                }
            )

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let bannerMessage = viewModel.bannerMessage {
                        ErrorBanner(message: bannerMessage)
                    }

                    dateField

                    ForEach(viewModel.fields) { field in
                        valueField(field)
                    }

                    if viewModel.kind == .measurements {
                        Text("Leave a measurement blank to skip it. Clearing one you'd logged before removes it.")
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task { focusedField = viewModel.fields.first }
    }

    private var dateField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("DATE")
                .appBody(12, weight: .semibold)
                .foregroundStyle(AppColor.secondaryText)
            DatePicker(
                "", selection: $viewModel.date,
                in: viewModel.minDate...viewModel.maxDate,
                displayedComponents: .date
            )
            .datePickerStyle(.compact)
            .labelsHidden()
            .tint(AppColor.accent)
            // A day holds exactly one check-in row, so changing the date
            // means a different row: reload what's stored there instead of
            // carrying the previous day's numbers into an upsert.
            .onChange(of: viewModel.date) { _, _ in
                Task { await viewModel.reloadExisting() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueField(_ field: BodyField) -> some View {
        let error = viewModel.error(for: field)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(field.label.uppercased()) (\(viewModel.unitLabel(for: field)))")
                .appBody(12, weight: .semibold)
                .foregroundStyle(error == nil ? AppColor.secondaryText : AppColor.destructive)

            HStack {
                TextField("Optional", text: viewModel.binding(for: field))
                    .appBody(15)
                    .foregroundStyle(AppColor.ink)
                    .keyboardType(.decimalPad)
                    .focused($focusedField, equals: field)
                Text(viewModel.unitLabel(for: field))
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(AppColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(error == nil ? .clear : AppColor.destructive, lineWidth: 2)
            )

            if let error {
                Text(error).appBody(12).foregroundStyle(AppColor.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview {
    LogBodyView(
        kind: .measurements, date: Date(),
        minDate: Calendar.current.date(byAdding: .year, value: -1, to: Date())!,
        maxDate: Date()
    )
}
