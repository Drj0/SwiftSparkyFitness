//
//  ExerciseEntryEditorView.swift
//  SwiftSparkyFitness
//
//  Replaces the old flat LogExerciseView. The exercise is chosen before this
//  screen opens (via ExerciseSearchView, already materialized if it came from
//  an external provider) — this view only builds the log entry, branching its
//  fields on `viewModel.modality`.
//

import SwiftUI

struct ExerciseEntryEditorView: View {
    @StateObject private var viewModel: ExerciseEntryEditorViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var onSaved: () -> Void = {}

    // Separate Bool flags, matching every other form in this app
    // (`AppTextField.focus` takes a plain `FocusState<Bool>.Binding`, which
    // has no public initializer to project a case out of a single `Field?`
    // enum — the enum-unification this started with doesn't compile).
    @FocusState private var durationFocused: Bool
    @FocusState private var distanceFocused: Bool
    @FocusState private var heartRateFocused: Bool
    @FocusState private var caloriesFocused: Bool

    /// False when the caller closes the whole sheet itself on save (Log
    /// Exercise): stepping back here first slid the search list in under a
    /// sheet already on its way down.
    private var dismissesOnSave = true

    init(exercise: Exercise, entryDate: Date = Date(), dismissesOnSave: Bool = true, onSaved: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: ExerciseEntryEditorViewModel(exercise: exercise, entryDate: entryDate))
        self.dismissesOnSave = dismissesOnSave
        self.onSaved = onSaved
    }

    init(editing entry: ExerciseSessionSummary, exercise: Exercise, onSaved: @escaping () -> Void = {}) {
        _viewModel = StateObject(wrappedValue: ExerciseEntryEditorViewModel(editing: entry, exercise: exercise))
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

                    ExercisePhotos(exerciseName: viewModel.exercise.name)

                    exerciseNameRow

                    labeledField("DURATION", error: viewModel.durationError) {
                        AppTextField(
                            // Set-based sessions rarely get timed; their
                            // sets stand in for it (see effectiveMinutes).
                            placeholder: viewModel.modality.usesSets ? "Optional · about 2 min a set" : "Required",
                            text: $viewModel.durationMinutesText, style: .filled,
                            isInvalid: viewModel.durationError != nil, keyboardType: .numberPad,
                            suffix: "min", focus: $durationFocused
                        )
                        .onChange(of: viewModel.durationMinutesText) { _, _ in viewModel.applyEstimateIfNeeded() }
                    }

                    if viewModel.modality.usesSets {
                        setsEditor
                            .onChange(of: viewModel.setRows) { _, _ in viewModel.applyEstimateIfNeeded() }
                    }

                    if viewModel.modality == .durationDistance {
                        labeledField("DISTANCE", error: viewModel.distanceError) {
                            AppTextField(
                                placeholder: "Required", text: $viewModel.distanceText, style: .filled,
                                isInvalid: viewModel.distanceError != nil, keyboardType: .decimalPad,
                                focus: $distanceFocused
                            )
                        }
                        labeledField("AVG HEART RATE (OPTIONAL)", error: nil) {
                            AppTextField(
                                placeholder: "bpm", text: $viewModel.avgHeartRateText, style: .filled,
                                keyboardType: .numberPad, focus: $heartRateFocused
                            )
                        }
                    }

                    labeledField("CALORIES BURNED", error: viewModel.caloriesError) {
                        AppTextField(
                            placeholder: "Required", text: $viewModel.caloriesText, style: .filled,
                            isInvalid: viewModel.caloriesError != nil, keyboardType: .numberPad,
                            suffix: "kcal", focus: $caloriesFocused
                        )
                        if viewModel.caloriesAreEstimated {
                            Text("Estimated from the exercise's intensity and your weight. Type your own to replace it.")
                                .appBody(12)
                                .foregroundStyle(AppColor.secondaryText)
                        }
                    }

                    labeledField("NOTES (OPTIONAL)", error: nil) {
                        AppTextField(placeholder: "How did it feel?", text: $viewModel.notes, style: .filled)
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task { durationFocused = true }
    }

    private var header: some View {
        SheetHeader(
            title: viewModel.isEditing ? "Edit \(viewModel.exercise.name)" : viewModel.exercise.name,
            onCancel: { dismiss() },
            action: SheetAction("Save", isBusy: viewModel.isSaving) {
                Task {
                    if await viewModel.save() {
                        onSaved()
                        if dismissesOnSave { dismiss() }
                    }
                }
            }
        )
    }

    private var exerciseNameRow: some View {
        HStack(spacing: 8) {
            if let category = viewModel.exercise.category {
                Text(category.capitalized)
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(AppColor.secondaryText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(AppColor.inputBackground, in: Capsule())
            }
            Text(viewModel.modality.label)
                .appBody(12)
                .foregroundStyle(AppColor.placeholder)
            Spacer()
        }
    }

    // MARK: - Sets editor (weightReps / repsOnly)

    private var setsEditor: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("SETS")
                    .appBody(12, weight: .semibold)
                    .foregroundStyle(viewModel.setsError == nil ? AppColor.secondaryText : AppColor.destructive)
                Spacer()
                Button {
                    Haptics.light()
                    viewModel.addSet()
                } label: {
                    Label("Add set", systemImage: "plus.circle.fill")
                        .appBody(13, weight: .semibold)
                        .foregroundStyle(AppColor.accent)
                }
                .buttonStyle(.pressable)
            }

            ForEach(Array(viewModel.setRows.enumerated()), id: \.element.id) { index, row in
                setRow(index: index, row: row)
            }

            if let setsError = viewModel.setsError {
                Text(setsError).appBody(12).foregroundStyle(AppColor.destructive)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func setRow(index: Int, row: ExerciseSetRow) -> some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .appBody(13, weight: .semibold)
                .foregroundStyle(AppColor.secondaryText)
                .frame(width: 20)

            AppTextField(
                placeholder: "Reps", text: binding(for: row, \.repsText), style: .filled,
                keyboardType: .numberPad
            )

            if viewModel.modality == .weightReps {
                AppTextField(
                    placeholder: "Weight", text: binding(for: row, \.weightText), style: .filled,
                    keyboardType: .decimalPad, suffix: "kg"
                )
            }

            Button {
                Haptics.warning()
                viewModel.removeSet(row)
            } label: {
                Image(systemName: "minus.circle.fill")
                    .foregroundStyle(AppColor.destructive)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressableCompact)
            .accessibilityLabel("Remove set \(index + 1)")
        }
    }

    /// A single row's field, addressed by index rather than id — `ForEach`
    /// above already keys on id for diffing, but writing back through a
    /// `Binding` needs the current index to find the row again after edits.
    private func binding(for row: ExerciseSetRow, _ keyPath: WritableKeyPath<ExerciseSetRow, String>) -> Binding<String> {
        Binding(
            get: { row[keyPath: keyPath] },
            set: { newValue in
                guard let index = viewModel.setRows.firstIndex(where: { $0.id == row.id }) else { return }
                viewModel.setRows[index][keyPath: keyPath] = newValue
            }
        )
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
}

#Preview {
    ExerciseEntryEditorView(exercise: Exercise.previewSquat)
}
