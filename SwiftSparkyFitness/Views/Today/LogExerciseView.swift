//
//  LogExerciseView.swift
//  SwiftSparkyFitness
//
//  The calorie estimate depends on duration, so it stays a muted placeholder
//  instead of showing a stale/zero number while duration is empty.
//
//  The private `plainField` helper this file used to carry was a verbatim
//  copy of CustomFoodView's, and sat next to AppTextField in the same form
//  in a different idiom. Both are gone in favour of
//  `AppTextField(style: .filled)`.
//

import SwiftUI

struct LogExerciseView: View {
    @StateObject private var viewModel: LogExerciseViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSaved: () -> Void = {}

    /// Opens on ACTIVITY with the keyboard up; return moves to DURATION,
    /// the only other field that has to be filled in.
    @FocusState private var activityFocused: Bool
    @FocusState private var durationFocused: Bool

    init() {
        _viewModel = StateObject(wrappedValue: LogExerciseViewModel())
    }

    /// Diary's edit path: reopens this same sheet prefilled from an
    /// already-logged session instead of building a new create-mode one.
    init(
        editingEntryId id: String, exerciseId: String, name: String,
        durationMinutes: Double, caloriesBurned: Double, entryDate: Date,
        onSaved: @escaping () -> Void
    ) {
        _viewModel = StateObject(wrappedValue: LogExerciseViewModel(
            editingEntryId: id, exerciseId: exerciseId, name: name,
            durationMinutes: durationMinutes, caloriesBurned: caloriesBurned, entryDate: entryDate
        ))
        self.onSaved = onSaved
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let bannerMessage = viewModel.bannerMessage {
                        ErrorBanner(message: bannerMessage)
                    }

                    labeledField("ACTIVITY", error: viewModel.activityError) {
                        AppTextField(
                            placeholder: "e.g. Running", text: $viewModel.activityName, style: .filled,
                            isInvalid: viewModel.activityError != nil,
                            submitLabel: .next, autocapitalization: .words,
                            focus: $activityFocused
                        )
                        .onSubmit { durationFocused = true }
                    }

                    labeledField("DURATION", error: viewModel.durationError) {
                        AppTextField(
                            placeholder: "Required", text: $viewModel.durationMinutesText, style: .filled,
                            isInvalid: viewModel.durationError != nil, keyboardType: .numberPad,
                            suffix: "min", focus: $durationFocused
                        )
                    }

                    labeledField("INTENSITY", error: nil) {
                        HStack(spacing: 8) {
                            ForEach(ExerciseIntensity.allCases, id: \.self) { level in
                                intensityChip(level)
                            }
                        }
                    }

                    labeledField("CALORIES BURNED (EST.)", error: nil) {
                        estimateReadout
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task { activityFocused = true }
    }

    // Cancel measured ~45 x 17pt and Save ~33 x 17pt. Both now carry a 44pt
    // target; the header's own vertical padding drops from 14 to 2 so the
    // row keeps the height it had.
    private var header: some View {
        HStack {
            Button { dismiss() } label: {
                Text("Cancel")
                    .foregroundStyle(AppColor.secondaryText)
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)

            Spacer()
            Text(viewModel.isEditing ? "Edit Exercise" : "Log Exercise").appDisplay(18).foregroundStyle(AppColor.ink)
            Spacer()

            // save() makes two sequential network calls
            // (findOrCreateExercise, then createExerciseEntry), so on a
            // slow link this sat looking tappable for seconds and a
            // second tap wrote a second session. isSaving was already
            // published — it just wasn't read.
            Button {
                Task {
                    if await viewModel.save() {
                        onSaved()
                        dismiss()
                    }
                }
            } label: {
                Group {
                    if viewModel.isSaving {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Save")
                    }
                }
                .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(viewModel.isSaving)
            .foregroundStyle(viewModel.isSaving ? AppColor.placeholder : AppColor.accent)
            .fontWeight(.semibold)
        }
        .appBody(15)
        .padding(.horizontal, 20)
        .padding(.vertical, 2)
        .overlay(Rectangle().fill(AppColor.hairline).frame(height: 1), alignment: .bottom)
    }

    /// Derived, not editable — so it deliberately drops the input fill every
    /// other row in this form now shares. Inside a beige-fill box it was
    /// indistinguishable from a field the user could tap and type into.
    private var estimateReadout: some View {
        HStack(alignment: .lastTextBaseline, spacing: 6) {
            if let calories = viewModel.estimatedCalories {
                Text("\(Int(calories))")
                    .appDisplay(24)
                    .foregroundStyle(AppColor.ink)
                    .contentTransition(.numericText())
                Text("kcal").appBody(13).foregroundStyle(AppColor.secondaryText)
            } else {
                Text("— fill in duration").appBody(15).foregroundStyle(AppColor.placeholder)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewModel.estimatedCalories)
    }

    private func labeledField<Content: View>(_ label: String, error: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .appBody(12, weight: .semibold)
                .foregroundStyle(error == nil ? AppColor.secondaryText : AppColor.destructive)
            content()
            if let error {
                Text(error).appBody(12).foregroundStyle(AppColor.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func intensityChip(_ level: ExerciseIntensity) -> some View {
        let isSelected = viewModel.intensity == level
        return Button {
            if viewModel.intensity != level {
                Haptics.selection()
                viewModel.intensity = level
            }
        } label: {
            // Solid accent when selected, same as the meal chips, the FAB and
            // the tab bar. These chips used the opposite idiom — soft fill,
            // accent text — so "selected" looked like two different things
            // depending on which sheet you were in.
            Text(level.rawValue)
                .appBody(13, weight: .semibold)
                .foregroundStyle(isSelected ? .white : AppColor.secondaryText)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(isSelected ? AppColor.accent : AppColor.inputBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // Touch target only — measured 112 x 32.3; the pill keeps its
                // painted height.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    LogExerciseView()
}
