//
//  SetGoalsView.swift
//  SwiftSparkyFitness
//
//  Sets the daily calorie / macro / water goals. Reached from the
//  goal-not-set card on Today (whose button used to be a placeholder that
//  raised an "isn't available yet" alert) and from Settings.
//
//  The sheet cannot save until its load succeeds, and that's deliberate
//  rather than defensive: the goal write replaces the entire row, so building
//  one without the server's current values silently zeroes every column this
//  app doesn't model. See NutritionGoals and GoalsViewModel.
//

import SwiftUI

struct SetGoalsView: View {
    @StateObject private var viewModel: GoalsViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focusedField: GoalsViewModel.Field?

    private let onSaved: () -> Void

    init(date: Date = Date(), onSaved: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: GoalsViewModel(date: date))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            SheetHeader(
                title: "Daily Goals",
                onCancel: { dismiss() },
                action: SheetAction("Save", isEnabled: viewModel.canSave) {
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

                    if viewModel.isLoading && viewModel.loaded == nil {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                    } else if viewModel.loadFailed {
                        loadFailedState
                    } else {
                        ForEach(GoalsViewModel.Field.allCases) { field in
                            valueField(field)
                        }

                        Text("Calories drive the main ring. The macro and water targets are optional — leave one blank and its ring just won't show a target.")
                            .appBody(12)
                            .foregroundStyle(AppColor.secondaryText)
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task {
            await viewModel.load()
            focusedField = .calories
        }
    }

    /// Without the current row there is nothing safe to write, so this offers
    /// a retry rather than an empty form that would look editable.
    private var loadFailedState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Couldn't load your current goals.")
                .appBody(15, weight: .semibold)
                .foregroundStyle(AppColor.ink)
            Text("Saving now would overwrite the goals already on your account, so the form stays locked until this loads.")
                .appBody(13)
                .foregroundStyle(AppColor.secondaryText)
            PrimaryButton(title: "Try again", isLoading: viewModel.isLoading) {
                Task { await viewModel.load() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueField(_ field: GoalsViewModel.Field) -> some View {
        let error = viewModel.error(for: field)
        return VStack(alignment: .leading, spacing: 6) {
            Text("\(field.title.uppercased()) (\(viewModel.unitLabel(for: field)))")
                .appBody(12, weight: .semibold)
                .foregroundStyle(error == nil ? AppColor.secondaryText : AppColor.destructive)

            HStack {
                TextField(
                    field == .calories ? "Required" : "Optional",
                    text: viewModel.binding(for: field)
                )
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
    SetGoalsView()
}
