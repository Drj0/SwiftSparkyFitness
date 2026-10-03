//
//  CustomExerciseView.swift
//  SwiftSparkyFitness
//
//  For anything not found via search. Same shape as CustomFoodView: plain
//  modal sheet, field-level errors, no NavigationStack.
//

import SwiftUI

struct CustomExerciseView: View {
    @StateObject private var viewModel = CustomExerciseViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// What was typed into search before "Create custom exercise" — it's
    /// almost always the name.
    var initialName = ""
    let onSaved: (Exercise) -> Void

    @FocusState private var nameFocused: Bool
    @State private var confirmingDiscard = false

    private var isDirty: Bool { viewModel.isDirty(initialName: initialName) }

    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let bannerMessage = viewModel.bannerMessage {
                        ErrorBanner(message: bannerMessage)
                    }

                    labeledField("NAME", error: viewModel.nameError) {
                        AppTextField(
                            placeholder: "e.g. Kettlebell Swing", text: $viewModel.name, style: .filled,
                            isInvalid: viewModel.nameError != nil,
                            autocapitalization: .words, focus: $nameFocused
                        )
                    }

                    labeledField("CATEGORY (OPTIONAL)", error: nil) {
                        AppTextField(
                            placeholder: "e.g. strength, cardio", text: $viewModel.category, style: .filled,
                            autocapitalization: .never
                        )
                    }

                    labeledField("HOW IS THIS LOGGED?", error: nil) {
                        VStack(spacing: 8) {
                            ForEach(ExerciseModality.allCases, id: \.self) { option in
                                modalityRow(option)
                            }
                        }
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task {
            if viewModel.name.isEmpty { viewModel.name = initialName.capitalized }
            nameFocused = true
        }
        .discardGuard(isDirty: isDirty, isPresented: $confirmingDiscard) { dismiss() }
    }

    private var header: some View {
        SheetHeader(
            title: "Custom Exercise",
            onCancel: { if isDirty { confirmingDiscard = true } else { dismiss() } },
            action: SheetAction("Save", isBusy: viewModel.isSaving) {
                Task {
                    if let exercise = await viewModel.save() {
                        onSaved(exercise)
                        dismiss()
                    }
                }
            }
        )
    }

    private func modalityRow(_ option: ExerciseModality) -> some View {
        let isSelected = viewModel.modality == option
        return Button {
            Haptics.selection()
            viewModel.modality = option
        } label: {
            HStack {
                Text(option.label).appBody(14).foregroundStyle(AppColor.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").foregroundStyle(AppColor.accent)
                }
            }
            .frame(minHeight: 44)
            .padding(.horizontal, 14)
            .background(AppColor.inputBackground)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
    CustomExerciseView { _ in }
}
