//
//  CustomFoodView.swift
//  SwiftSparkyFitness
//
//  Field-level red outline + one-line reason under each bad field; Save
//  with errors just re-shows this same sheet, no alert dialog.
//
//  No NavigationStack here — this is a plain modal sheet with a custom
//  Cancel/Save header, not a push destination, and wrapping it in one
//  reserved extra (invisible but space-occupying) navigation-bar layout
//  that pushed the real header down.
//
//  Every input is one component now. This form used to alternate two:
//  AppTextField (white, bordered, radius 14) for NAME and CALORIES and a
//  private `plainField` helper (beige, borderless, radius 12) for SERVING
//  SIZE and the macros — adjacent rows of the same form in two different
//  idioms, with the helper duplicated verbatim in LogExerciseView. The
//  helper is gone; `AppTextField(style: .filled)` is the sheet input.
//

import SwiftUI

struct CustomFoodView: View {
    @StateObject private var viewModel = CustomFoodViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onSaved: () -> Void

    /// The sheet is here to take typed input, so the keyboard comes up on
    /// NAME rather than costing a tap. NAME and CALORIES are the two
    /// required fields (everything else ships with a usable default), so
    /// they're also what the return key chains between.
    @FocusState private var nameFocused: Bool
    @FocusState private var caloriesFocused: Bool

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
                            placeholder: "Required", text: $viewModel.name, style: .filled,
                            isInvalid: viewModel.nameError != nil,
                            submitLabel: .next, autocapitalization: .words,
                            focus: $nameFocused
                        )
                        .onSubmit { caloriesFocused = true }
                    }

                    labeledField("SERVING SIZE", error: nil) {
                        HStack(spacing: 8) {
                            AppTextField(
                                placeholder: "1", text: $viewModel.servingSize, style: .filled,
                                keyboardType: .decimalPad
                            )
                            AppTextField(
                                placeholder: "serving", text: $viewModel.servingUnit, style: .filled,
                                submitLabel: .done
                            )
                        }
                    }

                    labeledField("CALORIES", error: viewModel.caloriesError) {
                        AppTextField(
                            placeholder: "0", text: $viewModel.calories, style: .filled,
                            isInvalid: viewModel.caloriesError != nil, keyboardType: .numberPad,
                            focus: $caloriesFocused
                        )
                    }

                    HStack(spacing: 10) {
                        labeledField("PROTEIN", error: nil) { macroField($viewModel.protein) }
                        labeledField("CARBS", error: nil) { macroField($viewModel.carbs) }
                        labeledField("FAT", error: nil) { macroField($viewModel.fat) }
                    }
                }
                .padding(18)
                .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: viewModel.bannerMessage)
            }
        }
        .background(AppColor.surface)
        .task { nameFocused = true }
    }

    private var header: some View {
        SheetHeader(
            title: "Custom Food",
            onCancel: { dismiss() },
            // isSaving was published but never rendered, so a double-tap
            // during the round trip created a duplicate custom food.
            action: SheetAction("Save", isBusy: viewModel.isSaving) {
                Task {
                    if await viewModel.save() != nil {
                        onSaved()
                        dismiss()
                    }
                }
            }
        )
    }

    private func macroField(_ text: Binding<String>) -> some View {
        AppTextField(placeholder: "0", text: text, style: .filled, keyboardType: .decimalPad, suffix: "g")
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
    CustomFoodView(onSaved: {})
}
