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
    /// The last logged weight, shown greyed in an empty weight field and
    /// used as the − / + starting point. Never saved unless the user sets it.
    private let suggestedWeight: Double?

    /// The sheet exists to receive a number, so it opens with the keyboard
    /// already up on its first field. No return-key chaining between the
    /// rest: they're all decimal pads, which have no return key to chain.
    @FocusState private var focusedField: BodyField?
    @State private var confirmingDiscard = false

    init(
        kind: LogBodyViewModel.Kind,
        date: Date,
        existing: BodyMeasurements = .none,
        preferences: UserPreferences = .serverDefaults,
        minDate: Date,
        maxDate: Date,
        suggestedWeight: Double? = nil,
        onSaved: @escaping () -> Void = {}
    ) {
        self.suggestedWeight = suggestedWeight
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
                onCancel: { if viewModel.isDirty { confirmingDiscard = true } else { dismiss() } },
                action: SheetAction("Save", isBusy: viewModel.isSaving) {
                    Task {
                        if await viewModel.save() {
                            onSaved()
                            dismiss()
                        }
                    }
                }
            )

            if viewModel.kind == .weight {
                weightLayout
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        banner
                        dateRow
                        ForEach(viewModel.fields) { field in
                            valueField(field)
                        }
                        Text("Leave a measurement blank to skip it. Clearing one you'd logged before removes it.")
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                    .padding(18)
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
                }
            }
        }
        .background(AppColor.surface)
        .task { focusedField = viewModel.fields.first }
        .discardGuard(isDirty: viewModel.isDirty, isPresented: $confirmingDiscard) { dismiss() }
    }

    @ViewBuilder
    private var banner: some View {
        if let bannerMessage = viewModel.bannerMessage {
            ErrorBanner(message: bannerMessage)
        }
    }

    // MARK: - Weight

    /// One number is the whole job, so it's the hero: large serif digits
    /// (the ring's typeface) centred in the space above the keyboard, with
    /// − / + for small changes and the date as a single row at the bottom.
    /// The old form was a pill and a field at the top of an empty sheet.
    private var weightLayout: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    banner
                    Spacer(minLength: 20)
                    weightHero
                    Spacer(minLength: 20)
                    dateRow
                }
                .padding(18)
                // Fills the visible height (which the keyboard already
                // shrinks), so the hero sits centred and the date row rests
                // just above the keys instead of floating under the header.
                .frame(minHeight: proxy.size.height)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var weightHero: some View {
        let field = BodyField.weight
        let error = viewModel.error(for: field)
        let hint = suggestedWeight.map { viewModel.preferences.formatted($0) } ?? "0"
        return VStack(spacing: 12) {
            HStack(spacing: 16) {
                stepButton(systemImage: "minus", direction: -1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    TextField(hint, text: viewModel.binding(for: field))
                        .appDisplay(64)
                        .foregroundStyle(error == nil ? AppColor.ink : AppColor.destructive)
                        .multilineTextAlignment(.center)
                        .keyboardType(.decimalPad)
                        .focused($focusedField, equals: field)
                        .fixedSize()
                        .accessibilityLabel("Weight in \(viewModel.unitLabel(for: field))")
                    Text(viewModel.unitLabel(for: field))
                        .appBody(20, weight: .semibold)
                        .foregroundStyle(AppColor.secondaryText)
                        .accessibilityHidden(true)
                }
                .frame(minWidth: 150)
                // Fixed geometry between two buttons: past this the digits
                // would push the − / + off the sheet.
                .dynamicTypeSize(...DynamicTypeSize.xxLarge)
                stepButton(systemImage: "plus", direction: 1)
            }

            if let error {
                Text(error).appBody(13).foregroundStyle(AppColor.destructive)
            } else if suggestedWeight != nil, (viewModel.text[field.rawValue] ?? "").isEmpty {
                Text("Last logged \(hint) \(viewModel.unitLabel(for: field)) · − / + to adjust")
                    .appBody(13)
                    .foregroundStyle(AppColor.secondaryText)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func stepButton(systemImage: String, direction: Double) -> some View {
        Button {
            viewModel.step(.weight, by: direction, from: suggestedWeight)
            Haptics.light()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(AppColor.accent)
                .frame(width: 44, height: 44)
                .background(AppColor.accentSoft, in: Circle())
        }
        .buttonStyle(.pressableCompact)
        .accessibilityLabel(direction > 0 ? "Increase by \(viewModel.stepLabel)" : "Decrease by \(viewModel.stepLabel)")
    }

    // MARK: - Date

    /// A settings-style row — label left, the system's compact date button
    /// right — in the same filled style as every other field in the app,
    /// instead of a lone pill under a caption.
    private var dateRow: some View {
        HStack {
            Label("Date", systemImage: "calendar")
                .appBody(15)
                .foregroundStyle(AppColor.ink)
            Spacer()
            DatePicker(
                "Date", selection: $viewModel.date,
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
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .background(AppColor.inputBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12))
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
